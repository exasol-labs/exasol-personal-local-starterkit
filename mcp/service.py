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
    DiscoveredClient,
    Finding,
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
        findings = self._security.preflight(request)
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

        for adapter in adapters:
            location = adapter.locate(self._environment)
            if not location.available or location.path is None:
                findings.append(
                    Finding(
                        code="client_not_supported",
                        severity=Severity.ERROR,
                        message=f"{adapter.display_name()} is not supported on this platform.",
                        scope={"client": adapter.adapter_id()},
                        evidence=location.evidence,
                        recommended_action="Choose a supported client or use a supported platform.",
                        blocking=True,
                    )
                )
                continue
            inspection = adapter.inspect(location.path, request.server_definition.name)
            findings.extend(inspection.findings)
            if any(finding.blocking for finding in inspection.findings):
                continue
            rendered = adapter.render(request.server_definition, inspection)
            findings.extend(adapter.validate_render(rendered))
            if any(finding.blocking for finding in findings):
                continue
            path_exists = location.path.exists()
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
                snapshot_paths.append(location.path)

        if any(finding.blocking for finding in findings):
            return OperationResult(
                request_id=request.request_id,
                operation=request.operation,
                status=OperationStatus.BLOCKED,
                summary="Configuration was blocked by existing client state.",
                findings=findings,
                changes=changes,
                artifacts=artifacts,
            )

        if request.dry_run:
            return OperationResult(
                request_id=request.request_id,
                operation=request.operation,
                status=OperationStatus.NO_CHANGE,
                summary=f"Planned configuration changes for {len(rendered_items)} client(s).",
                findings=findings,
                changes=changes,
                artifacts=artifacts,
                next_actions=[action for adapter in adapters for action in adapter.activation_instructions()],
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
            if findings
            else OperationStatus.SUCCESS,
            summary=f"Configured {len(rendered_items)} client(s) for Exasol MCP access.",
            findings=findings,
            changes=changes,
            artifacts=artifacts,
            backup_reference=snapshot_reference,
            next_actions=[action for adapter in adapters for action in adapter.activation_instructions()],
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
            result.status = self._combine_status(result.findings, validation.findings)
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
        existing_validation = validator.validate_manifest_consistency()
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
                target_clients=request.target_clients,
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
        return OperationResult(
            request_id=request.request_id,
            operation=request.operation,
            status=self._combine_status(discover_result.findings, validation.findings),
            summary=f"Doctor completed with {summarize_findings(findings)}",
            findings=findings,
            verification_evidence=validation.verification_evidence,
            artifacts=active_artifacts,
            details=discover_result.details,
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
        target_artifacts = [
            artifact
            for artifact in active_records
            if target_ids is None or artifact.client in target_ids
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
        return OperationResult(
            request_id=request.request_id,
            operation=request.operation,
            status=self._status_from_findings(findings),
            summary=f"Tracked {len(active_artifacts)} managed artifact(s).",
            findings=findings,
            artifacts=active_artifacts,
            backup_reference=latest_snapshot,
        )

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
