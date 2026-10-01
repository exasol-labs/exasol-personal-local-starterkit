"""Public orchestration service for MCP operations."""

from __future__ import annotations

from pathlib import Path
from typing import Iterable

from mcp.adapters.base import ClientAdapter, RenderResult
from mcp.adapters.registry import AdapterRegistry
from mcp.core.errors import BlockingOperationError, MCPSubsystemError
from mcp.core.models import (
    ArtifactReference,
    ChangeKind,
    ChangeRecord,
    DeploymentMode,
    DiscoveredClient,
    Finding,
    NextAction,
    OperationName,
    OperationRequest,
    OperationResult,
    OperationStatus,
    OwnershipState,
    Severity,
    VerificationEvidence,
)
from mcp.diagnostics.reporting import summarize_findings
from mcp.runtime.environment import ExecutionEnvironment
from mcp.runtime.filesystem import FileSystem
from mcp.runtime.manifest import ManifestRepository
from mcp.runtime.paths import RuntimePaths
from mcp.runtime.snapshots import SnapshotRepository
from mcp.security.policy import SecurityPolicy
from mcp.validator.service import StageResult, ValidatorService


class MCPAccessSubsystem:
    """Main entry point for discovery, configuration, and lifecycle operations."""

    def __init__(
        self,
        environment: ExecutionEnvironment | None = None,
        registry: AdapterRegistry | None = None,
        filesystem: FileSystem | None = None,
    ) -> None:
        self._environment = environment or ExecutionEnvironment.current()
        self._registry = registry or AdapterRegistry()
        self._filesystem = filesystem or FileSystem()
        self._security = SecurityPolicy()

    def execute(self, raw_request: dict | OperationRequest) -> OperationResult:
        request = (
            raw_request
            if isinstance(raw_request, OperationRequest)
            else OperationRequest.from_raw(raw_request)
        )
        runtime_paths = RuntimePaths(request.runtime_root_path(self._environment.home))
        manifest_repository = ManifestRepository(runtime_paths, self._filesystem)
        snapshots = SnapshotRepository(runtime_paths, manifest_repository, self._filesystem)
        validator = ValidatorService(self._registry, manifest_repository, self._environment)

        dispatch = {
            OperationName.DISCOVER: self._discover,
            OperationName.INSTALL: self._install,
            OperationName.CONFIGURE: self._configure,
            OperationName.VALIDATE: self._validate,
            OperationName.REPAIR: self._repair,
            OperationName.BACKUP: self._backup,
            OperationName.RESTORE: self._restore,
            OperationName.DOCTOR: self._doctor,
            OperationName.UNINSTALL: self._uninstall,
            OperationName.STATUS: self._status,
        }
        return dispatch[request.operation](request, runtime_paths, manifest_repository, snapshots, validator)

    def _discover(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        snapshots: SnapshotRepository,
        validator: ValidatorService,
    ) -> OperationResult:
        del runtime_paths, manifest_repository, snapshots, validator
        adapters = self._resolve_target_adapters(request)
        discovered_clients: list[DiscoveredClient] = []
        findings: list[Finding] = []
        for adapter in adapters:
            detection = adapter.detect(self._environment)
            discovered_clients.append(
                DiscoveredClient(
                    client=adapter.adapter_id(),
                    detected=detection.detected,
                    confidence=detection.confidence,
                    path=str(detection.location.path) if detection.location.path else None,
                    evidence=detection.evidence,
                    capabilities=self._capabilities_dict(adapter)
                    if request.include_capabilities
                    else {},
                )
            )
            if not detection.detected:
                findings.append(
                    Finding(
                        code="client_not_detected",
                        severity=Severity.INFO,
                        message=f"{adapter.display_name()} is not installed on this machine (skipped).",
                        scope={"client": adapter.adapter_id()},
                        evidence=detection.evidence,
                        recommended_action="Install the client (or pass an explicit config-path override) if you want it configured.",
                    )
                )
        status = self._status_from_findings(findings)
        summary = (
            f"Discovered {sum(client.detected for client in discovered_clients)} supported client(s)."
        )
        return OperationResult(
            request_id=request.request_id,
            operation=request.operation,
            status=status,
            summary=summary,
            findings=findings,
            details={"discovered_clients": [client.__dict__ for client in discovered_clients]},
        )

    def _install(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        snapshots: SnapshotRepository,
        validator: ValidatorService,
    ) -> OperationResult:
        del runtime_paths, manifest_repository, snapshots, validator
        finding = Finding(
            code="operation_out_of_scope",
            severity=Severity.WARNING,
            message="Installing the MCP server runtime is handled by the Exasol starter-kit installer, not by this tool.",
            recommended_action="Invoke the upstream installer-owned runtime installation workflow first.",
            blocking=True,
        )
        return OperationResult(
            request_id=request.request_id,
            operation=request.operation,
            status=OperationStatus.BLOCKED,
            summary="Install is reserved for upstream installer integration and remains blocked here.",
            findings=[finding],
        )

    def _configure(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        snapshots: SnapshotRepository,
        validator: ValidatorService,
    ) -> OperationResult:
        runtime_paths.ensure()
        findings = list(self._security.preflight(request))
        blocking = [finding for finding in findings if finding.blocking]
        if blocking:
            return OperationResult(
                request_id=request.request_id,
                operation=request.operation,
                status=OperationStatus.BLOCKED,
                summary="Configuration is blocked by request or policy validation.",
                findings=findings,
            )
        if request.server_definition is None:
            raise BlockingOperationError(
                "missing_server_definition",
                "Server definition is required for configure.",
            )

        adapters = self._resolve_target_adapters(request)
        rendered_items: list[tuple[ClientAdapter, RenderResult, ArtifactReference, bool]] = []
        changes: list[ChangeRecord] = []
        artifacts: list[ArtifactReference] = []
        snapshot_paths: list[Path] = []
        skipped_clients: list[dict[str, str]] = []
        # `findings` is the reporting list: everything, including per-client
        # complaints. `status_findings` drives the run status and deliberately
        # excludes the complaints of clients we skipped — one client's broken
        # or unsupported config says nothing about the others.
        status_findings: list[Finding] = list(findings)

        for adapter in adapters:
            rendered, config_path, client_findings = self._render_for_client(adapter, request)
            findings.extend(client_findings)
            if rendered is None or config_path is None:
                skipped_clients.append(self._skip_record(adapter, client_findings))
                continue
            status_findings.extend(client_findings)
            path_exists = config_path.exists()
            change_kind = ChangeKind.UPDATE if path_exists else ChangeKind.CREATE
            rendered_item = self._build_artifact(adapter, rendered, request)
            rendered_items.append((adapter, rendered, rendered_item, path_exists))
            artifacts.append(rendered_item)
            changes.append(
                ChangeRecord(
                    kind=change_kind,
                    path=str(rendered.path),
                    ownership_state=OwnershipState.MANAGED,
                    applied=not request.dry_run,
                    reason="render_managed_client_config",
                )
            )
            if path_exists:
                snapshot_paths.append(config_path)

        configured_adapters = [adapter for adapter, _, _, _ in rendered_items]
        details = {
            "configured_clients": [adapter.adapter_id() for adapter in configured_adapters],
            "skipped_clients": skipped_clients,
        }
        # Activation instructions only for the clients we actually rendered:
        # telling someone to restart a client we skipped is noise.
        next_actions = [
            action
            for adapter in configured_adapters
            for action in adapter.activation_instructions()
        ]

        if not rendered_items:
            # Nothing could be rendered for any requested client: the honest
            # answer is that the whole operation did nothing.
            return OperationResult(
                request_id=request.request_id,
                operation=request.operation,
                status=OperationStatus.BLOCKED,
                summary=self._configure_summary(
                    "Configuration was blocked by existing client state.", skipped_clients
                ),
                findings=findings,
                changes=changes,
                artifacts=artifacts,
                details=details,
            )

        if request.dry_run:
            return OperationResult(
                request_id=request.request_id,
                operation=request.operation,
                status=OperationStatus.NO_CHANGE,
                summary=self._configure_summary(
                    f"Planned configuration changes for {len(rendered_items)} client(s).",
                    skipped_clients,
                ),
                findings=findings,
                changes=changes,
                artifacts=artifacts,
                next_actions=next_actions,
                details=details,
            )

        snapshot_reference = None
        if request.create_snapshot:
            snapshot_record = snapshots.create_snapshot(
                request.operation.value,
                snapshot_paths,
                request.snapshot_label,
            )
            snapshot_reference = snapshot_record["snapshot_id"]

        for adapter, rendered, artifact, _ in rendered_items:
            del adapter
            self._apply_render(rendered)
            artifact.permissions = self._security.apply_managed_permissions(rendered.path)
            stored_artifact = manifest_repository.upsert_artifact(artifact)
            artifacts[artifacts.index(artifact)] = stored_artifact

        result = OperationResult(
            request_id=request.request_id,
            operation=request.operation,
            status=OperationStatus.SUCCESS_WITH_WARNINGS
            if (status_findings or skipped_clients)
            else OperationStatus.SUCCESS,
            summary=self._configure_summary(
                f"Configured {len(rendered_items)} client(s) for Exasol MCP access.",
                skipped_clients,
            ),
            findings=findings,
            changes=changes,
            artifacts=artifacts,
            backup_reference=snapshot_reference,
            next_actions=next_actions,
            details=details,
        )
        if request.validate_after_apply:
            validation = self._run_validation(
                request,
                runtime_paths,
                manifest_repository,
                validator,
                artifacts or self._active_artifacts(manifest_repository),
            )
            result.findings.extend(validation.findings)
            result.verification_evidence.extend(validation.verification_evidence)
            result.status = self._configure_status(
                status_findings, validation.findings, skipped_clients
            )
        return result

    def _validate(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        snapshots: SnapshotRepository,
        validator: ValidatorService,
    ) -> OperationResult:
        del snapshots
        artifacts = self._active_artifacts(manifest_repository)
        result = self._run_validation(request, runtime_paths, manifest_repository, validator, artifacts)
        result.request_id = request.request_id
        result.operation = request.operation
        return result

    def _repair(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        snapshots: SnapshotRepository,
        validator: ValidatorService,
    ) -> OperationResult:
        findings = self._security.preflight(request)
        if any(finding.blocking for finding in findings):
            return OperationResult(
                request_id=request.request_id,
                operation=request.operation,
                status=OperationStatus.BLOCKED,
                summary="Repair is blocked by request or policy validation.",
                findings=findings,
            )
        # With the desired definition in hand this sees an entry that is intact
        # but superseded, not just a hand-edited one -- which is the whole
        # difference between repair fixing a stale version pin and repair
        # answering "already consistent" forever.
        existing_validation = validator.validate_manifest_consistency(request.server_definition)
        findings.extend(existing_validation.findings)
        if not existing_validation.findings:
            return OperationResult(
                request_id=request.request_id,
                operation=request.operation,
                status=OperationStatus.NO_CHANGE,
                summary="Managed state is already consistent; no repair was needed.",
                verification_evidence=existing_validation.evidence,
            )
        if request.dry_run:
            return OperationResult(
                request_id=request.request_id,
                operation=request.operation,
                status=OperationStatus.NO_CHANGE,
                summary="Repair plan computed without applying changes.",
                findings=findings,
                verification_evidence=existing_validation.evidence,
            )
        if request.create_snapshot:
            snapshots.create_snapshot(
                request.operation.value,
                [Path(artifact.path) for artifact in self._active_artifacts(manifest_repository)],
                request.snapshot_label,
            )
        if request.server_definition is not None:
            configure_request = OperationRequest(
                request_id=request.request_id,
                operation=OperationName.CONFIGURE,
                target_clients=self._repair_targets(request, existing_validation.findings),
                deployment_mode=request.deployment_mode,
                dry_run=False,
                force=request.force,
                runtime_root=request.runtime_root,
                ownership_mode=request.ownership_mode,
                server_definition=request.server_definition,
                credential_reference=request.credential_reference,
                dsn_reference=request.dsn_reference,
                create_snapshot=False,
                validate_after_apply=True,
                stages=request.stages,
            )
            result = self._configure(
                configure_request,
                runtime_paths,
                manifest_repository,
                snapshots,
                validator,
            )
            result.operation = request.operation
            result.summary = "Re-rendered and repaired the managed client configuration."
            return result
        latest_snapshot = request.snapshot_id or manifest_repository.latest_snapshot_id()
        if latest_snapshot and request.allow_restore:
            restore_request = OperationRequest(
                request_id=request.request_id,
                operation=OperationName.RESTORE,
                runtime_root=request.runtime_root,
                snapshot_id=latest_snapshot,
                snapshot_current_state_first=False,
                stages=request.stages,
            )
            result = self._restore(
                restore_request,
                runtime_paths,
                manifest_repository,
                snapshots,
                validator,
            )
            result.operation = request.operation
            result.summary = "Restored the latest snapshot to repair managed state."
            return result
        return OperationResult(
            request_id=request.request_id,
            operation=request.operation,
            status=OperationStatus.FAILED_RECOVERABLE,
            summary="Repair detected configuration changes but could not fix them automatically. Recreate the configuration with configure, or restore a snapshot.",
            findings=findings,
            verification_evidence=existing_validation.evidence,
        )

    def _backup(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        snapshots: SnapshotRepository,
        validator: ValidatorService,
    ) -> OperationResult:
        del runtime_paths, validator
        snapshot_record = snapshots.create_snapshot(
            request.operation.value,
            [Path(artifact.path) for artifact in self._active_artifacts(manifest_repository)],
            request.snapshot_label,
        )
        return OperationResult(
            request_id=request.request_id,
            operation=request.operation,
            status=OperationStatus.SUCCESS,
            summary="Created a snapshot of the current managed state.",
            backup_reference=snapshot_record["snapshot_id"],
            details={
                "snapshot_id": snapshot_record["snapshot_id"],
                "snapshot_path": str(snapshots._paths.backups_dir / snapshot_record["snapshot_id"]),
            },
        )

    def _restore(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        snapshots: SnapshotRepository,
        validator: ValidatorService,
    ) -> OperationResult:
        if not request.snapshot_id:
            return OperationResult(
                request_id=request.request_id,
                operation=request.operation,
                status=OperationStatus.BLOCKED,
                summary="Restore requires a snapshot_id.",
                findings=[
                    Finding(
                        code="missing_snapshot_id",
                        severity=Severity.ERROR,
                        message="A snapshot identifier is required for restore.",
                        recommended_action="Provide snapshot_id in the restore request.",
                        blocking=True,
                    )
                ],
            )
        if request.snapshot_current_state_first:
            snapshots.create_snapshot(
                "pre_restore",
                [Path(artifact.path) for artifact in self._active_artifacts(manifest_repository)],
                "pre_restore",
            )
        changes = snapshots.restore_snapshot(request.snapshot_id)
        for artifact in self._active_artifacts(manifest_repository):
            path = Path(artifact.path)
            if path.exists():
                adapter = self._registry.get(artifact.client)
                entry_name = str(artifact.metadata.get("entry_name", "exasol"))
                inspection = adapter.inspect(path, entry_name)
                artifact.content_hash = inspection.managed_hash
                artifact.permissions = self._security.apply_managed_permissions(path)
                manifest_repository.upsert_artifact(artifact)
        validation = self._run_validation(
            request,
            runtime_paths,
            manifest_repository,
            validator,
            self._active_artifacts(manifest_repository),
        )
        return OperationResult(
            request_id=request.request_id,
            operation=request.operation,
            status=self._combine_status([], validation.findings),
            summary="Restored the requested snapshot.",
            changes=changes,
            artifacts=self._active_artifacts(manifest_repository),
            backup_reference=request.snapshot_id,
            findings=validation.findings,
            verification_evidence=validation.verification_evidence,
        )

    def _doctor(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        snapshots: SnapshotRepository,
        validator: ValidatorService,
    ) -> OperationResult:
        del snapshots
        discover_result = self._discover(
            OperationRequest(
                request_id=request.request_id,
                operation=OperationName.DISCOVER,
                target_clients=request.target_clients,
                include_capabilities=request.include_capabilities,
            ),
            runtime_paths,
            manifest_repository,
            None,  # type: ignore[arg-type]
            validator,
        )
        active_artifacts = self._active_artifacts(manifest_repository)
        validation = self._run_validation(
            request,
            runtime_paths,
            manifest_repository,
            validator,
            active_artifacts,
        )
        findings = discover_result.findings + validation.findings
        # One row per supported client with a state derived from HEALTH, not
        # from the existence of a manifest record. The screen used to call a
        # client "connected" because an artifact existed for it -- with the
        # entry deleted from the file, and for clients that were not installed
        # at all -- and the JSON carried no per-client state whatsoever.
        #   connected                  managed, client detected, no warning/error names it
        #   needs_attention            managed, a warning/error names it (drift, missing entry, launch failure)
        #   configured_client_missing  managed, but the client is not on this machine
        #   not_set_up                 client detected, not managed
        #   not_installed              neither
        discovered_by_id = {
            entry.get("client"): entry
            for entry in (discover_result.details or {}).get("discovered_clients", [])
        }
        managed_ids = {artifact.client for artifact in active_artifacts}
        troubled_ids: set[str] = set()
        for finding in validation.findings:
            if finding.severity in (Severity.WARNING, Severity.ERROR, Severity.CRITICAL):
                client_id = (finding.scope or {}).get("client")
                if client_id:
                    troubled_ids.add(client_id)
                else:
                    # A finding with no client scope (a manifest-wide drift, a
                    # launch failure of the shared server) taints every managed client.
                    troubled_ids.update(managed_ids)
        client_states: list[dict[str, str | None]] = []
        for adapter in self._registry.all():
            adapter_id = adapter.adapter_id()
            detected = bool((discovered_by_id.get(adapter_id) or {}).get("detected"))
            managed = adapter_id in managed_ids
            if managed and not detected:
                state = "configured_client_missing"
            elif managed and adapter_id in troubled_ids:
                state = "needs_attention"
            elif managed:
                state = "connected"
            elif detected:
                state = "not_set_up"
            else:
                state = "not_installed"
            client_states.append({"client": adapter_id, "state": state})
        details = dict(discover_result.details or {})
        details["clients"] = client_states
        # Findings already carry their own remedy; doctor was throwing it away
        # and returning next_actions=[] alongside a non-empty findings list. That
        # is the field an unattended caller branches on, so an empty one reads as
        # "nothing to do" on a machine with problems. Blocking findings first,
        # then the rest, de-duplicated while preserving order.
        _seen_actions: set[str] = set()
        next_actions: list[NextAction] = []
        for _finding in sorted(findings, key=lambda f: not f.blocking):
            _action = (_finding.recommended_action or "").strip()
            if not _action or _action in _seen_actions:
                continue
            _seen_actions.add(_action)
            next_actions.append(NextAction(kind=_finding.code, message=_action))

        return OperationResult(
            request_id=request.request_id,
            operation=request.operation,
            status=self._combine_status(discover_result.findings, validation.findings),
            summary=f"Doctor completed with {summarize_findings(findings)}",
            findings=findings,
            next_actions=next_actions,
            verification_evidence=validation.verification_evidence,
            artifacts=active_artifacts,
            details=details,
        )

    def _uninstall(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        snapshots: SnapshotRepository,
        validator: ValidatorService,
    ) -> OperationResult:
        del validator
        active_records = self._active_artifacts(manifest_repository)
        target_ids = set(request.target_clients) if request.target_clients else None
        target_servers = set(request.target_servers) if request.target_servers else None
        target_artifacts = [
            artifact
            for artifact in active_records
            if (target_ids is None or artifact.client in target_ids)
            and (
                target_servers is None
                or str(artifact.metadata.get("entry_name", "exasol")) in target_servers
            )
        ]
        if not target_artifacts:
            return OperationResult(
                request_id=request.request_id,
                operation=request.operation,
                status=OperationStatus.NO_CHANGE,
                summary="No managed artifacts matched the uninstall request.",
            )
        if request.create_snapshot:
            snapshot = snapshots.create_snapshot(
                request.operation.value,
                [Path(artifact.path) for artifact in target_artifacts],
                request.snapshot_label,
            )
            backup_reference = snapshot["snapshot_id"]
        else:
            backup_reference = None
        changes: list[ChangeRecord] = []
        for artifact in target_artifacts:
            adapter = self._registry.get(artifact.client)
            entry_name = str(artifact.metadata.get("entry_name", "exasol"))
            inspection = adapter.inspect(Path(artifact.path), entry_name)
            rendered = adapter.render_removal(inspection, entry_name)
            self._apply_render(rendered)
            manifest_repository.mark_removed(artifact.artifact_id)
            changes.append(
                ChangeRecord(
                    kind=ChangeKind.REMOVE,
                    path=artifact.path,
                    ownership_state=OwnershipState.MANAGED,
                    applied=True,
                    reason="remove_managed_client_config_entry",
                )
            )
        if request.remove_runtime_cache:
            self._filesystem.prune_empty_parents(runtime_paths.manifest_path.parent, runtime_paths.runtime_root)
        return OperationResult(
            request_id=request.request_id,
            operation=request.operation,
            status=OperationStatus.SUCCESS,
            summary=f"Removed managed configuration from {len(target_artifacts)} client artifact(s).",
            changes=changes,
            backup_reference=backup_reference,
        )

    def _status(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        snapshots: SnapshotRepository,
        validator: ValidatorService,
    ) -> OperationResult:
        del runtime_paths, snapshots, validator
        active_artifacts = self._active_artifacts(manifest_repository)
        findings = []
        if not active_artifacts:
            findings.append(
                Finding(
                    code="no_managed_artifacts",
                    severity=Severity.INFO,
                    message="No managed MCP client configuration is currently recorded.",
                )
            )
        latest_snapshot = manifest_repository.latest_snapshot_id()
        # One row per SUPPORTED client, not per recorded artifact. The reader of
        # `exakit mcp-status` is asking "is my Claude set up?", and a count of
        # artifacts cannot answer that: it says how many rows exist, never which
        # clients they belong to or which of yours are missing.
        #
        # Three states, because "no config" has two different causes and only one
        # of them has an action:
        #   configured    - the kit manages this client's config (path shown)
        #   not_set_up    - the client is on this machine, but not configured
        #   not_installed - the client is not here at all, so there is nothing to do
        by_client = {artifact.client: artifact for artifact in active_artifacts}
        clients: list[dict[str, str | None]] = []
        for adapter in self._registry.all():
            adapter_id = adapter.adapter_id()
            artifact = by_client.get(adapter_id)
            if artifact is not None:
                clients.append({"client": adapter_id, "state": "configured", "path": artifact.path})
                continue
            # Detection touches the filesystem and belongs to the adapter, so a
            # client whose probe raises must not take the whole status screen
            # down with it. Unknown means "not here", which prints no action.
            try:
                detected = adapter.detect(self._environment).detected
            except Exception:  # noqa: BLE001 - a read-only screen never fails here
                detected = False
            clients.append(
                {
                    "client": adapter_id,
                    "state": "not_set_up" if detected else "not_installed",
                    "path": None,
                }
            )
        return OperationResult(
            request_id=request.request_id,
            operation=request.operation,
            status=self._status_from_findings(findings),
            summary=f"Tracked {len(active_artifacts)} managed artifact(s).",
            findings=findings,
            artifacts=active_artifacts,
            backup_reference=latest_snapshot,
            details={"clients": clients},
        )

    @staticmethod
    def _repair_targets(
        request: OperationRequest, findings: list[Finding]
    ) -> tuple[str, ...]:
        """The clients repair should hand configure: the ones actually at fault.

        Repair used to pass the caller's whole client list straight through, and
        the caller is normally "every supported client" -- harmless while repair
        only ever ran on a file someone had hand-edited, because that state is
        rare and the user had asked for a rewrite anyway. Now that a superseded
        entry also triggers repair, that list would have configure CREATE managed
        entries in every client installed on the machine, including the ones the
        user deliberately never connected. So the findings choose the targets.

        An explicit client selection still narrows it. If the intersection is
        empty -- findings for clients the caller did not name -- the selection is
        used unchanged, which is exactly what happened before.
        """

        named = tuple(
            dict.fromkeys(
                str(finding.scope["client"])
                for finding in findings
                if finding.scope.get("client")
            )
        )
        if request.target_clients:
            narrowed = tuple(
                client for client in named if client in request.target_clients
            )
            return narrowed or request.target_clients
        return named or request.target_clients

    def _render_for_client(
        self, adapter: ClientAdapter, request: OperationRequest
    ) -> tuple[RenderResult | None, Path | None, list[Finding]]:
        """Locate, inspect and render ONE client.

        Every skip decision here is taken from this adapter's own findings and
        nothing else. Deciding from a shared, cross-client list made the
        outcome depend on the order the clients happened to be processed in:
        one client with an unparseable config file (a 0-byte ``mcp.json`` left
        behind by a VS Code update is the case seen in the field) silenced
        every client that came after it.

        Returns ``(rendered, config_path, findings)``; ``rendered`` is ``None``
        when this client has to be skipped.
        """

        findings: list[Finding] = []
        if request.server_definition is None:  # pragma: no cover - guarded by the caller
            raise BlockingOperationError(
                "missing_server_definition",
                "Server definition is required for configure.",
            )
        server_definition = request.server_definition
        capabilities = adapter.describe_capabilities()
        if server_definition.transport is DeploymentMode.HTTP and not capabilities.supports_http:
            # Not every client can express a remote server, and the ones that
            # cannot are skipped rather than half-configured: an entry this
            # adapter cannot render is an entry the user would have to clean up.
            # This is a standing fact about the client, not something this run
            # did wrong, so it is INFO and worded as a note -- "cannot be
            # configured ... (skipped)" under a warning glyph on every update
            # read as a failure and prompted support questions. The URL is in
            # the message so it can be added through the client's own settings.
            findings.append(
                Finding(
                    code="client_transport_unsupported",
                    severity=Severity.INFO,
                    message=(
                        f"{adapter.display_name()} has no config-file shape for a remote "
                        f"MCP server, so the '{server_definition.name}' endpoint "
                        f"({server_definition.url}) is not registered there."
                    ),
                    scope={
                        "client": adapter.adapter_id(),
                        "server": server_definition.name,
                        "transport": server_definition.transport.value,
                    },
                    evidence=[f"Endpoint: {server_definition.url}"],
                    recommended_action=(
                        f"Add {server_definition.url} in {adapter.display_name()}'s own settings "
                        "if it supports remote MCP servers; nothing else is affected."
                    ),
                )
            )
            return None, None, findings
        location = adapter.locate_for_server(self._environment, server_definition.name)
        if not location.available or location.path is None:
            # Not blocking, and not an error for the run: "this client is not
            # supported on this platform" is a fact about this one client. As a
            # blocking (or even ERROR) finding it dragged every other client's
            # configuration down with it.
            findings.append(
                Finding(
                    code="client_not_supported",
                    severity=Severity.WARNING,
                    message=f"{adapter.display_name()} is not supported on this platform (skipped).",
                    scope={"client": adapter.adapter_id()},
                    evidence=location.evidence,
                    recommended_action="Choose a supported client or use a supported platform.",
                )
            )
            return None, None, findings
        inspection = adapter.inspect(location.path, server_definition.name)
        findings.extend(inspection.findings)
        if any(finding.blocking for finding in findings):
            return None, location.path, findings
        rendered = adapter.render(server_definition, inspection)
        findings.extend(adapter.validate_render(rendered))
        if any(finding.blocking for finding in findings):
            return None, location.path, findings
        return rendered, location.path, findings

    @staticmethod
    def _skip_record(adapter: ClientAdapter, client_findings: list[Finding]) -> dict[str, str]:
        """Describe one skipped client so callers can report it per client."""

        reason = next(
            (finding for finding in client_findings if finding.blocking),
            client_findings[0] if client_findings else None,
        )
        return {
            "client": adapter.adapter_id(),
            "display_name": adapter.display_name(),
            "reason_code": reason.code if reason else "unknown",
            "reason": reason.message if reason else "Client was skipped.",
            "recommended_action": (reason.recommended_action or "") if reason else "",
        }

    @staticmethod
    def _configure_summary(sentence: str, skipped_clients: list[dict[str, str]]) -> str:
        summary = sentence
        if skipped_clients:
            names = ", ".join(item["display_name"] for item in skipped_clients)
            summary += f" Skipped {len(skipped_clients)} client(s): {names}."
        return summary

    @staticmethod
    def _configure_status(
        status_findings: list[Finding],
        validation_findings: list[Finding],
        skipped_clients: list[dict[str, str]],
    ) -> OperationStatus:
        """Status for a configure run that applied at least one client.

        A skipped client's own findings never reach here: they are reported, but
        a per-client failure must not turn a run that did configure other
        clients into a blocked one. A skip still costs the run its clean
        SUCCESS, and a genuine validation failure still wins.

        Post-apply validation needs the same treatment, and does not get it for
        free. It walks the manifest, which still carries the record a skipped
        client earned on an earlier successful run, so it reports drift for a
        file this run deliberately refused to touch. Left in the status that
        turns the second run into failed_recoverable -- CLI exit 1, "MCP
        configure failed" -- for a run that configured every client it could and
        correctly declined the one it could not. Those findings stay in the
        result, because the drift is real and worth showing; they just do not
        get to decide the status of the clients we did configure.
        """

        skipped_ids = {record["client"] for record in skipped_clients}
        own_validation = [
            finding
            for finding in validation_findings
            if finding.scope.get("client") not in skipped_ids
        ]
        status = MCPAccessSubsystem._status_from_findings(
            list(status_findings) + own_validation
        )
        if skipped_clients and status == OperationStatus.SUCCESS:
            return OperationStatus.SUCCESS_WITH_WARNINGS
        return status

    def _resolve_target_adapters(self, request: OperationRequest) -> list[ClientAdapter]:
        if request.target_clients:
            return [self._registry.get(client_id) for client_id in request.target_clients]
        return self._registry.all()

    def _build_artifact(
        self,
        adapter: ClientAdapter,
        rendered: RenderResult,
        request: OperationRequest,
    ) -> ArtifactReference:
        return ArtifactReference(
            artifact_id="",
            path=str(rendered.path),
            kind="client_config",
            ownership_state=OwnershipState.MANAGED,
            client=adapter.adapter_id(),
            content_hash=rendered.managed_hash,
            source_adapter=adapter.adapter_id(),
            metadata={
                "entry_name": rendered.entry_name,
                "transport": request.deployment_mode.value,
            },
        )

    def _apply_render(self, rendered: RenderResult) -> None:
        if rendered.remove_file:
            self._filesystem.remove_file(rendered.path)
            return
        self._filesystem.write_text(rendered.path, rendered.content or "")

    def _run_validation(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        validator: ValidatorService,
        artifacts: Iterable[ArtifactReference],
    ) -> OperationResult:
        del manifest_repository
        stages = validator.run(request, runtime_paths, artifacts)
        findings = [finding for stage in stages for finding in stage.findings]
        evidence = [item for stage in stages for item in stage.evidence]
        return OperationResult(
            operation=OperationName.VALIDATE,
            status=self._status_from_stage_results(stages),
            summary=f"Validation completed across {len(stages)} stage(s).",
            findings=findings,
            verification_evidence=evidence,
            artifacts=list(artifacts),
        )

    def _active_artifacts(
        self, manifest_repository: ManifestRepository
    ) -> list[ArtifactReference]:
        return [ArtifactReference(**record) for record in manifest_repository.list_active_artifacts()]

    @staticmethod
    def _status_from_stage_results(stages: list[StageResult]) -> OperationStatus:
        statuses = {stage.status for stage in stages}
        if "fail_blocking" in statuses:
            return OperationStatus.FAILED_TERMINAL
        if "fail_recoverable" in statuses:
            return OperationStatus.FAILED_RECOVERABLE
        if "pass_with_warnings" in statuses:
            return OperationStatus.SUCCESS_WITH_WARNINGS
        return OperationStatus.SUCCESS

    @staticmethod
    def _status_from_findings(findings: list[Finding]) -> OperationStatus:
        # Severity-aware: only WARNING or worse changes the outcome. INFO
        # findings (a client that simply isn't installed, "no managed config
        # recorded", etc.) are expected state, not problems, so they leave the
        # status at SUCCESS instead of the misleading success_with_warnings.
        if any(finding.blocking or finding.severity == Severity.CRITICAL for finding in findings):
            return OperationStatus.BLOCKED
        if any(finding.severity == Severity.ERROR for finding in findings):
            return OperationStatus.FAILED_RECOVERABLE
        if any(finding.severity == Severity.WARNING for finding in findings):
            return OperationStatus.SUCCESS_WITH_WARNINGS
        return OperationStatus.SUCCESS

    @staticmethod
    def _combine_status(
        existing_findings: list[Finding], validation_findings: list[Finding]
    ) -> OperationStatus:
        return MCPAccessSubsystem._status_from_findings(existing_findings + validation_findings)

    @staticmethod
    def _capabilities_dict(adapter: ClientAdapter) -> dict[str, object]:
        capabilities = adapter.describe_capabilities()
        return {
            "supports_stdio": capabilities.supports_stdio,
            "supports_http": capabilities.supports_http,
            "supports_managed_file": capabilities.supports_managed_file,
            "supports_patch_mode": capabilities.supports_patch_mode,
            "supports_env_block": capabilities.supports_env_block,
            "requires_restart": capabilities.requires_restart,
            "platforms": list(capabilities.platforms),
        }
