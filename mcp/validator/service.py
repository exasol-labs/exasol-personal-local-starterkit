"""Validation services for MCP operations."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import socket
import stat
from typing import Iterable
from urllib.parse import urlparse

from mcp.adapters.registry import AdapterRegistry
from mcp.core.models import (
    ArtifactReference,
    DiscoveredClient,
    Finding,
    OperationRequest,
    Severity,
    VerificationEvidence,
)
from mcp.runtime.environment import ExecutionEnvironment
from mcp.runtime.manifest import ManifestRepository
from mcp.runtime.paths import RuntimePaths


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

    def validate_permission_posture(
        self, artifacts: Iterable[ArtifactReference]
    ) -> StageResult:
        findings: list[Finding] = []
        evidence: list[VerificationEvidence] = []
        for artifact in artifacts:
            path = Path(artifact.path)
            if not path.exists():
                findings.append(
                    Finding(
                        code="managed_artifact_missing",
                        severity=Severity.WARNING,
                        message="Managed artifact is missing from disk.",
                        scope={"path": artifact.path},
                        recommended_action="Run repair or restore the latest snapshot.",
                    )
                )
                continue
            mode = stat.S_IMODE(path.stat().st_mode)
            if self._environment.os_name != "win32" and mode != 0o600:
                findings.append(
                    Finding(
                        code="permission_drift",
                        severity=Severity.WARNING,
                        message="Managed client configuration is not restricted to owner read/write.",
                        scope={"path": artifact.path},
                        evidence=[format(mode, "04o")],
                        recommended_action="Run repair to re-apply restrictive permissions.",
                    )
                )
            else:
                evidence.append(
                    VerificationEvidence(
                        stage="permission_posture",
                        status="pass",
                        details="Managed config uses the expected local file mode.",
                        subject=artifact.path,
                    )
                )
        status = "pass_with_warnings" if findings else "pass"
        return StageResult("permission_posture", status, findings, evidence)

    def validate_manifest_consistency(self) -> StageResult:
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
                        recommended_action="Restore the latest snapshot or rerun configure.",
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
                        recommended_action="Run repair or restore the last known-good snapshot.",
                    )
                )
            else:
                evidence.append(
                    VerificationEvidence(
                        stage="manifest_consistency",
                        status="pass",
                        details="Manifest hash matches the current managed configuration entry.",
                        subject=artifact.path,
                    )
                )
        status = "fail_recoverable" if findings else "pass"
        return StageResult("manifest_consistency", status, findings, evidence)

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
            elif stage_name == "permission_posture":
                stages.append(self.validate_permission_posture(artifact_list))
            elif stage_name == "manifest_consistency":
                stages.append(self.validate_manifest_consistency())
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
