"""Validation services for MCP operations."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import json
import socket
import stat
from typing import Iterable
from urllib.parse import urlparse

from mcp.adapters.base import AdapterInspection, ClientAdapter
from mcp.adapters.registry import AdapterRegistry
from mcp.runtime.filesystem import OWNER_ONLY_ACL, describe_protection
from mcp.core.models import (
    ArtifactReference,
    DeploymentMode,
    DiscoveredClient,
    Finding,
    OperationRequest,
    ServerDefinition,
    Severity,
    VerificationEvidence,
)
from mcp.runtime.environment import ExecutionEnvironment
from mcp.runtime.manifest import ManifestRepository
from mcp.runtime.paths import RuntimePaths


# Every drift finding names the SAME next step, and names it as a command the
# reader can type. "Run repair" named an operation of this module that no
# exakit command exposes by that name: the agent reading `mcp-doctor --json`
# went looking for `exakit mcp-repair`, which does not exist, while the human
# form of the very same command would have repaired it.
REPAIR_ACTION = (
    "Run: exakit mcp-doctor (it repairs drift and re-checks; --json only reports)"
)


class _ServerLaunchError(RuntimeError):
    """The configured MCP server started but did not behave like an MCP server."""


@dataclass
class StageResult:
    stage: str
    status: str
    findings: list[Finding] = field(default_factory=list)
    evidence: list[VerificationEvidence] = field(default_factory=list)


def _stage_status(findings: list[Finding]) -> str:
    # Severity-aware, mirroring the service's _status_from_findings so the
    # stage path and the findings path can never disagree: INFO findings are
    # expected state and keep the stage at "pass"; only WARNING or worse
    # downgrades it.
    if any(finding.blocking or finding.severity == Severity.CRITICAL for finding in findings):
        return "fail_blocking"
    if any(finding.severity == Severity.ERROR for finding in findings):
        return "fail_recoverable"
    if any(finding.severity == Severity.WARNING for finding in findings):
        return "pass_with_warnings"
    return "pass"


class ValidatorService:
    """Run staged validation across environment, files, and manifest state."""

    def __init__(
        self,
        registry: AdapterRegistry,
        manifest_repository: ManifestRepository,
        environment: ExecutionEnvironment,
    ) -> None:
        self._registry = registry
        self._manifest_repository = manifest_repository
        self._environment = environment

    def validate_environment(
        self, request: OperationRequest, runtime_paths: RuntimePaths
    ) -> StageResult:
        findings: list[Finding] = []
        evidence: list[VerificationEvidence] = []
        runtime_paths.ensure()
        evidence.append(
            VerificationEvidence(
                stage="environment",
                status="pass",
                details="Runtime root is accessible.",
                subject=str(runtime_paths.runtime_root),
            )
        )
        managed_clients = {
            record.get("client")
            for record in self._manifest_repository.list_active_artifacts()
        }
        for client_id in request.target_clients or tuple(
            adapter.adapter_id() for adapter in self._registry.all()
        ):
            adapter = self._registry.get(client_id)
            detection = adapter.detect(self._environment)
            if detection.detected:
                evidence.append(
                    VerificationEvidence(
                        stage="environment",
                        status="pass",
                        details=f"{adapter.display_name()} detection confidence: {detection.confidence}.",
                        subject=adapter.adapter_id(),
                    )
                )
            elif client_id in managed_clients:
                # A managed Exasol entry exists but the client itself is gone
                # (uninstalled after setup, or detection broke) — the one
                # not-detected case that IS warning-worthy.
                findings.append(
                    Finding(
                        code="managed_client_missing",
                        severity=Severity.WARNING,
                        message=f"{adapter.display_name()} has a managed Exasol entry but the client is no longer detected.",
                        scope={"client": adapter.adapter_id()},
                        evidence=detection.evidence,
                        recommended_action=f"Reinstall the client, or remove the stale entry with 'exakit mcp-remove {adapter.adapter_id()}'.",
                    )
                )
            # A client that is neither installed nor managed is expected
            # state, not a problem: discover already reports it as an INFO
            # "not installed (skipped)". Re-warning here counted the same
            # absent client twice and degraded healthy doctor runs to
            # success_with_warnings.
        status = _stage_status(findings)
        return StageResult("environment", status, findings, evidence)

    def validate_config_syntax(
        self, artifacts: Iterable[ArtifactReference]
    ) -> StageResult:
        findings: list[Finding] = []
        evidence: list[VerificationEvidence] = []
        for artifact in artifacts:
            adapter = self._registry.get(artifact.client)
            entry_name = str(artifact.metadata.get("entry_name", "exasol"))
            inspection = adapter.inspect(Path(artifact.path), entry_name)
            findings.extend(inspection.findings)
            if inspection.file_valid:
                evidence.append(
                    VerificationEvidence(
                        stage="config_syntax",
                        status="pass",
                        details="Client configuration is valid JSON and structurally compatible.",
                        subject=artifact.client,
                    )
                )
        if any(finding.blocking for finding in findings):
            status = "fail_blocking"
        elif findings:
            status = "pass_with_warnings"
        else:
            status = "pass"
        return StageResult("config_syntax", status, findings, evidence)

    def validate_connectivity(self, request: OperationRequest) -> StageResult:
        evidence: list[VerificationEvidence] = []
        findings: list[Finding] = []
        if request.dsn_reference is None or request.dsn_reference.kind != "literal":
            findings.append(
                Finding(
                    code="connectivity_not_verified",
                    severity=Severity.WARNING,
                    message="Connectivity could not be verified because no literal DSN was provided.",
                    recommended_action="Provide a host:port literal DSN when connectivity probing is required.",
                )
            )
            return StageResult("connectivity", "pass_with_warnings", findings, evidence)
        host, port = self._parse_host_port(request.dsn_reference.value or "")
        if host is None or port is None:
            findings.append(
                Finding(
                    code="invalid_dsn_literal",
                    severity=Severity.WARNING,
                    message="Connectivity probing expects a literal DSN in host:port form.",
                    evidence=[request.dsn_reference.value or "<missing-dsn>"],
                    recommended_action="Use a host:port DSN for transport-level validation.",
                )
            )
            return StageResult("connectivity", "pass_with_warnings", findings, evidence)
        try:
            with socket.create_connection((host, port), timeout=1.0):
                pass
        except OSError as exc:
            findings.append(
                Finding(
                    code="connectivity_failed",
                    severity=Severity.ERROR,
                    message="TCP connectivity to the configured Exasol endpoint failed.",
                    evidence=[str(exc)],
                    recommended_action="Verify the DSN and the local network path before continuing.",
                )
            )
            return StageResult("connectivity", "fail_recoverable", findings, evidence)
        evidence.append(
            VerificationEvidence(
                stage="connectivity",
                status="pass",
                details=f"Successfully opened a TCP connection to {host}:{port}.",
                subject=request.dsn_reference.value or "",
            )
        )
        return StageResult("connectivity", "pass", findings, evidence)

    def validate_server_launch(self, request: OperationRequest) -> StageResult:
        """Speak MCP to the configured server: the launcher's sidecar, at its loopback URL.

        WHY: every other stage inspects paperwork. Config syntax reads the client
        file, connectivity opens a TCP socket to the DATABASE, manifest
        consistency compares hashes — so a client whose entry is present and
        well-formed could be reported "connected" while the server behind it does
        not answer. This stage is the one that would catch it, because it is the
        only one that talks to the server. There is no other server to try: the
        sidecar is the kit's only one, and exakit mcp-setup heals it.
        """
        definition = request.server_definition
        if definition is not None and definition.transport is DeploymentMode.HTTP and definition.url:
            return self._validate_http_server(definition.url)
        findings = [
            Finding(
                code="server_launch_not_verified",
                severity=Severity.INFO,
                message="No MCP server URL was supplied, so the server was not asked.",
                recommended_action="Run 'exakit mcp-doctor' on an installed kit to verify the server itself.",
            )
        ]
        return StageResult("server_launch", "pass_with_warnings", findings, [])

    # The launcher's MCP sidecar is already running when doctor asks: no first
    # download to wait for, so a short budget.
    HTTP_HANDSHAKE_TIMEOUT_SECONDS = 15

    def _validate_http_server(self, url: str) -> StageResult:
        """The server is the launcher's MCP sidecar (an HTTP endpoint): speak MCP to it there.

        Nothing is started - the sidecar runs with the database - so a refusal
        names the launcher's own status command rather than a command to run.
        """
        findings: list[Finding] = []
        evidence: list[VerificationEvidence] = []
        try:
            tools = self._mcp_http_handshake(url)
        except _ServerLaunchError as exc:
            findings.append(
                Finding(
                    code="server_launch_failed",
                    severity=Severity.ERROR,
                    blocking=True,
                    message=f"The MCP server at {url} did not complete an MCP handshake: {exc}",
                    recommended_action=(
                        "Check that the database is running (exakit status; 'exakit start' starts both), then "
                        "'exakit mcp-setup', which restarts or recreates the server; 'exasol mcp status' shows "
                        "its own state."
                    ),
                )
            )
            return StageResult("server_launch", "fail_recoverable", findings, evidence)
        evidence.append(
            VerificationEvidence(
                stage="server_launch",
                status="pass",
                details=f"The MCP server answered at {url} and offered {len(tools)} tools.",
                subject=url,
            )
        )
        return StageResult("server_launch", "pass", findings, evidence)

    def _mcp_http_handshake(self, url: str) -> list[str]:
        """initialize + tools/list over Streamable HTTP. Returns the tool names.

        The answer is JSON or an event stream (``data: {...}`` lines), whichever
        the server chose; the session id it hands back on initialize goes with
        every later request, as the transport requires.
        """
        import urllib.error
        import urllib.request

        session: dict[str, str] = {}

        def post(message: dict) -> dict | None:
            headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
            headers.update(session)
            request = urllib.request.Request(url, data=json.dumps(message).encode("utf-8"),
                                             headers=headers, method="POST")
            try:
                with urllib.request.urlopen(request, timeout=self.HTTP_HANDSHAKE_TIMEOUT_SECONDS) as response:
                    sid = response.headers.get("mcp-session-id")
                    if sid:
                        session["mcp-session-id"] = sid
                    body = response.read().decode("utf-8", errors="replace")
            except urllib.error.HTTPError as exc:
                raise _ServerLaunchError(f"HTTP {exc.code}") from exc
            except (urllib.error.URLError, OSError) as exc:
                raise _ServerLaunchError(f"not reachable ({getattr(exc, 'reason', exc)})") from exc
            if "id" not in message:
                return None
            for chunk in [body] + [line[5:].strip() for line in body.splitlines() if line.startswith("data:")]:
                try:
                    answer = json.loads(chunk)
                except ValueError:
                    continue
                if isinstance(answer, dict) and answer.get("id") == message["id"]:
                    return answer
            raise _ServerLaunchError("the server answered something that is not MCP")

        post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                         "clientInfo": {"name": "exakit-mcp-doctor", "version": "1"}}})
        post({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        answer = post({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}) or {}
        if "error" in answer:
            raise _ServerLaunchError(str((answer["error"] or {}).get("message", "tools/list failed")))
        tools = [tool.get("name", "") for tool in (answer.get("result") or {}).get("tools", [])
                 if isinstance(tool, dict)]
        if not tools:
            raise _ServerLaunchError("the server offered no tools")
        return tools

    def validate_permission_posture(
        self, artifacts: Iterable[ArtifactReference]
    ) -> StageResult:
        findings: list[Finding] = []
        evidence: list[VerificationEvidence] = []
        # One finding per FILE. Two managed entries in the same file (exasol and
        # an add-on's) are two artifacts on one path, and a loosened mode was
        # reported once per artifact - the same sentence twice in doctor's output.
        seen_paths: set[str] = set()
        for artifact in artifacts:
            if artifact.path in seen_paths:
                continue
            seen_paths.add(artifact.path)
            path = Path(artifact.path)
            if not path.exists():
                findings.append(
                    Finding(
                        code="managed_artifact_missing",
                        severity=Severity.WARNING,
                        message="Managed artifact is missing from disk.",
                        # The client is in scope on EVERY per-artifact finding:
                        # doctor's per-client state taints every managed client
                        # for a finding that names none, so one client's file
                        # read as four clients needing attention.
                        scope={"path": artifact.path, "client": artifact.client},
                        recommended_action=REPAIR_ACTION,
                    )
                )
                continue
            # WINDOWS USED TO SHORT-CIRCUIT INTO THE PASS. The condition read
            # `os_name != "win32" and mode != 0o600`, so on Windows it was
            # always false and control fell to the else - recording
            # "uses the expected local file mode" about a mode that means
            # nothing there and an ACL nobody had looked at. These are the AI
            # client configs that carry EXA_PASSWORD in plaintext, and
            # mcp-doctor is the command the docs point at for exactly this
            # question. The drift is not hypothetical either: the files belong
            # to the CLIENTS, which rewrite them on their own schedule, and a
            # rewrite that creates a new file re-inherits the parent ACL and
            # discards the owner-only DACL protect_path applied.
            #
            # describe_protection is the read side of protect_path, and it has
            # three answers rather than two, because "I could not look" is not
            # the same as "it is fine".
            posture = describe_protection(path)
            if posture is None:
                evidence.append(
                    VerificationEvidence(
                        stage="permission_posture",
                        status="unverified",
                        details=(
                            "Could not read this file's permissions, so its posture is "
                            "unknown - this is not a pass."
                        ),
                        subject=artifact.path,
                    )
                )
            elif posture in {OWNER_ONLY_ACL, "0600"}:
                evidence.append(
                    VerificationEvidence(
                        stage="permission_posture",
                        status="pass",
                        details=(
                            "Managed config carries an owner-only ACL."
                            if posture == OWNER_ONLY_ACL
                            else "Managed config uses the expected local file mode."
                        ),
                        subject=artifact.path,
                    )
                )
            else:
                findings.append(
                    Finding(
                        code="permission_drift",
                        severity=Severity.WARNING,
                        message="Managed client configuration is not restricted to owner read/write.",
                        scope={"path": artifact.path, "client": artifact.client},
                        evidence=[posture],
                        recommended_action=REPAIR_ACTION,
                    )
                )
        status = "pass_with_warnings" if findings else "pass"
        return StageResult("permission_posture", status, findings, evidence)

    def validate_manifest_consistency(
        self, desired: ServerDefinition | None = None
    ) -> StageResult:
        """Compare every managed entry against the manifest AND against ``desired``.

        The manifest hash answers "has anyone touched this since we wrote it?".
        On its own that misses the other way a managed entry goes wrong: nobody
        touched it, an update moved the definition on, and the entry is now a
        faithful copy of what we wrote THEN rather than what we would write NOW.
        Passing the desired definition in is what makes that case visible;
        without it this stage can only ever see a hand edit.
        """

        findings: list[Finding] = []
        evidence: list[VerificationEvidence] = []
        for record in self._manifest_repository.list_active_artifacts():
            artifact = ArtifactReference(**record)
            adapter = self._registry.get(artifact.client)
            entry_name = str(artifact.metadata.get("entry_name", "exasol"))
            path = Path(artifact.path)
            inspection = adapter.inspect(path, entry_name)
            if not path.exists():
                findings.append(
                    Finding(
                        code="manifest_drift_missing_artifact",
                        severity=Severity.ERROR,
                        message="Managed artifact recorded in the manifest is missing.",
                        scope={"path": artifact.path, "client": artifact.client},
                        recommended_action=REPAIR_ACTION,
                    )
                )
                continue
            if inspection.managed_hash != artifact.content_hash:
                findings.append(
                    Finding(
                        code="manifest_drift_hash_mismatch",
                        severity=Severity.ERROR,
                        message="Managed client configuration has drifted from the manifest.",
                        scope={"path": artifact.path, "client": artifact.client},
                        evidence=[
                            f"manifest={artifact.content_hash}",
                            f"current={inspection.managed_hash}",
                        ],
                        recommended_action=REPAIR_ACTION,
                    )
                )
                continue
            evidence.append(
                VerificationEvidence(
                    stage="manifest_consistency",
                    status="pass",
                    details="Manifest hash matches the current managed configuration entry.",
                    subject=artifact.path,
                )
            )
            # The hash check above passed, so the entry is intact. Whether it is
            # also CURRENT is a separate question with a separate answer.
            outdated = self._outdated_entry_finding(adapter, artifact, entry_name, inspection, desired)
            if outdated is not None:
                findings.append(outdated)
        # Severity-aware, via the same helper the other stages use. The two
        # drift findings are ERROR, so they still yield "fail_recoverable"
        # exactly as the old unconditional expression did; an out-of-date entry
        # is a WARNING and lands on "pass_with_warnings" instead, because a
        # client pinned to last month's server is behind, not broken.
        status = _stage_status(findings)
        return StageResult("manifest_consistency", status, findings, evidence)

    @staticmethod
    def _outdated_entry_finding(
        adapter: ClientAdapter,
        artifact: ArtifactReference,
        entry_name: str,
        inspection: AdapterInspection,
        desired: ServerDefinition | None,
    ) -> Finding | None:
        """Report an intact entry that is no longer the one we would write.

        Re-rendering the desired definition against the file as it stands is the
        comparison: every adapter's ``render`` reports the hash the entry WOULD
        have, in the same shape ``inspect`` reports the hash it DOES have, which
        is the invariant the manifest check already relies on. Rendering is a
        pure computation -- nothing is written -- so the read-only callers stay
        read-only.
        """

        if desired is None:
            return None
        desired = desired.for_client(adapter.describe_capabilities().supports_http)
        if desired is None:
            return None
        if desired.name != entry_name:
            # This artifact records a different server entry than the one the
            # desired definition describes; there is nothing to compare.
            return None
        try:
            rendered = adapter.render(desired, inspection)
        except (ValueError, NotImplementedError):
            # An adapter that cannot render this definition at all (a non-stdio
            # transport, a definition with no command) has nothing to say about
            # how current the entry is. Configure reports that on its own path.
            return None
        if rendered.managed_hash is None or rendered.managed_hash == inspection.managed_hash:
            return None
        return Finding(
            code="managed_entry_outdated",
            severity=Severity.WARNING,
            message=(
                f"{adapter.display_name()} still has the managed Exasol entry from an "
                "earlier setup; it no longer matches the one this kit would write "
                "(the MCP server moved to another port, or the entry predates the "
                "launcher's MCP server, are the usual reasons)."
            ),
            scope={"path": artifact.path, "client": artifact.client},
            # Hashes only, deliberately: the rendered entry carries the managed
            # env block, and that block holds the database password.
            evidence=[
                f"installed={inspection.managed_hash}",
                f"expected={rendered.managed_hash}",
            ],
            recommended_action="Run 'exakit mcp-doctor' to re-write the entry from the current definition.",
        )

    def run(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        artifacts: Iterable[ArtifactReference],
    ) -> list[StageResult]:
        artifact_list = list(artifacts)
        stages: list[StageResult] = []
        for stage_name in request.stages:
            if stage_name == "environment":
                stages.append(self.validate_environment(request, runtime_paths))
            elif stage_name == "config_syntax":
                stages.append(self.validate_config_syntax(artifact_list))
            elif stage_name == "connectivity":
                stages.append(self.validate_connectivity(request))
            elif stage_name == "server_launch":
                stages.append(self.validate_server_launch(request))
            elif stage_name == "permission_posture":
                stages.append(self.validate_permission_posture(artifact_list))
            elif stage_name == "manifest_consistency":
                # The desired definition travels with the request, so validate
                # and doctor get the out-of-date check for free once the caller
                # supplies one.
                stages.append(self.validate_manifest_consistency(request.server_definition))
        return stages

    @staticmethod
    def _parse_host_port(raw: str) -> tuple[str | None, int | None]:
        if not raw:
            return None, None
        if "://" in raw:
            parsed = urlparse(raw)
            return parsed.hostname, parsed.port
        host, separator, port_text = raw.rpartition(":")
        if not separator:
            return None, None
        # Bracketed IPv6 literals ("[::1]:8563") must lose the brackets
        # before being handed to socket.create_connection.
        if host.startswith("[") and host.endswith("]"):
            host = host[1:-1]
        try:
            return host, int(port_text)
        except ValueError:
            return None, None
