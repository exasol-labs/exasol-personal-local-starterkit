"""Shared domain models for MCP operations."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Mapping, Sequence

from .serialization import to_primitive


def utc_now() -> str:
    """Return an RFC3339-ish UTC timestamp without microseconds."""

    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


class OperationName(str, Enum):
    DISCOVER = "discover"
    INSTALL = "install"
    CONFIGURE = "configure"
    VALIDATE = "validate"
    REPAIR = "repair"
    BACKUP = "backup"
    RESTORE = "restore"
    DOCTOR = "doctor"
    UNINSTALL = "uninstall"
    STATUS = "status"


class DeploymentMode(str, Enum):
    STDIO = "stdio"
    HTTP = "http"


class OperationStatus(str, Enum):
    SUCCESS = "success"
    SUCCESS_WITH_WARNINGS = "success_with_warnings"
    NO_CHANGE = "no_change"
    BLOCKED = "blocked"
    FAILED_RECOVERABLE = "failed_recoverable"
    FAILED_TERMINAL = "failed_terminal"


class Severity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"
    CRITICAL = "critical"


class OwnershipState(str, Enum):
    MANAGED = "managed"
    OBSERVED = "observed"
    CONFLICTING = "conflicting"
    ORPHANED = "orphaned"


class ChangeKind(str, Enum):
    CREATE = "create"
    UPDATE = "update"
    REMOVE = "remove"
    RESTORE = "restore"
    NOOP = "noop"


@dataclass
class CredentialReference:
    kind: str
    name: str | None = None
    value: str | None = None

    @classmethod
    def from_raw(cls, raw: Mapping[str, Any] | None) -> "CredentialReference | None":
        if raw is None:
            return None
        return cls(kind=str(raw["kind"]), name=raw.get("name"), value=raw.get("value"))


@dataclass
class DsnReference:
    kind: str
    value: str | None = None

    @classmethod
    def from_raw(cls, raw: Mapping[str, Any] | None) -> "DsnReference | None":
        if raw is None:
            return None
        return cls(kind=str(raw["kind"]), value=raw.get("value"))


@dataclass
class ServerDefinition:
    transport: DeploymentMode
    name: str = "exasol"
    command: str | None = None
    args: tuple[str, ...] = ()
    env: dict[str, str] = field(default_factory=dict)
    url: str | None = None
    headers: dict[str, str] = field(default_factory=dict)

    @classmethod
    def from_raw(cls, raw: Mapping[str, Any] | None) -> "ServerDefinition | None":
        if raw is None:
            return None
        return cls(
            transport=DeploymentMode(str(raw["transport"])),
            name=str(raw.get("name") or "exasol"),
            command=raw.get("command"),
            args=tuple(str(item) for item in raw.get("args", [])),
            env={str(key): str(value) for key, value in raw.get("env", {}).items()},
            url=raw.get("url"),
            headers={
                str(key): str(value) for key, value in raw.get("headers", {}).items()
            },
        )


@dataclass
class Finding:
    code: str
    severity: Severity
    message: str
    scope: dict[str, Any] = field(default_factory=dict)
    evidence: list[str] = field(default_factory=list)
    recommended_action: str | None = None
    blocking: bool = False


@dataclass
class ChangeRecord:
    kind: ChangeKind
    path: str
    ownership_state: OwnershipState
    applied: bool
    reason: str


@dataclass
class ArtifactReference:
    artifact_id: str
    path: str
    kind: str
    ownership_state: OwnershipState
    client: str
    content_hash: str | None = None
    permissions: str | None = None
    created_at: str | None = None
    updated_at: str | None = None
    removed_at: str | None = None
    source_adapter: str | None = None
    manifest_version: str = "1"
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class VerificationEvidence:
    stage: str
    status: str
    details: str
    subject: str


@dataclass
class NextAction:
    kind: str
    message: str


@dataclass
class DiscoveredClient:
    client: str
    detected: bool
    confidence: str
    path: str | None = None
    evidence: list[str] = field(default_factory=list)
    capabilities: dict[str, Any] = field(default_factory=dict)


@dataclass
class OperationRequest:
    operation: OperationName
    target_clients: tuple[str, ...] = ()
    deployment_mode: DeploymentMode = DeploymentMode.STDIO
    dry_run: bool = False
    force: bool = False
    runtime_root: str | None = None
    ownership_mode: OwnershipState = OwnershipState.MANAGED
    server_definition: ServerDefinition | None = None
    credential_reference: CredentialReference | None = None
    dsn_reference: DsnReference | None = None
    request_id: str | None = None
    create_snapshot: bool = True
    validate_after_apply: bool = True
    patch_mode_allowed: bool = False
    include_capabilities: bool = True
    snapshot_id: str | None = None
    snapshot_label: str | None = None
    snapshot_current_state_first: bool = True
    repair_strategy: str = "auto"
    allow_restore: bool = True
    include_recommendations: bool = True
    remove_runtime_cache: bool = True
    stages: tuple[str, ...] = (
        "environment",
        "config_syntax",
        "connectivity",
        "permission_posture",
        "manifest_consistency",
    )

    @classmethod
    def from_raw(cls, raw: Mapping[str, Any]) -> "OperationRequest":
        return cls(
            request_id=raw.get("request_id"),
            operation=OperationName(str(raw["operation"])),
            target_clients=tuple(str(item) for item in raw.get("target_clients", [])),
            deployment_mode=DeploymentMode(str(raw.get("deployment_mode", "stdio"))),
            dry_run=bool(raw.get("dry_run", False)),
            force=bool(raw.get("force", False)),
            runtime_root=raw.get("runtime_root"),
            ownership_mode=OwnershipState(str(raw.get("ownership_mode", "managed"))),
            server_definition=ServerDefinition.from_raw(raw.get("server_definition")),
            credential_reference=CredentialReference.from_raw(
                raw.get("credential_reference")
            ),
            dsn_reference=DsnReference.from_raw(raw.get("dsn_reference")),
            create_snapshot=bool(raw.get("create_snapshot", True)),
            validate_after_apply=bool(raw.get("validate_after_apply", True)),
            patch_mode_allowed=bool(raw.get("patch_mode_allowed", False)),
            include_capabilities=bool(raw.get("include_capabilities", True)),
            snapshot_id=raw.get("snapshot_id"),
            snapshot_label=raw.get("snapshot_label"),
            snapshot_current_state_first=bool(
                raw.get("snapshot_current_state_first", True)
            ),
            repair_strategy=str(raw.get("repair_strategy", "auto")),
            allow_restore=bool(raw.get("allow_restore", True)),
            include_recommendations=bool(raw.get("include_recommendations", True)),
            remove_runtime_cache=bool(raw.get("remove_runtime_cache", True)),
            stages=tuple(str(item) for item in raw.get("stages", cls.stages)),
        )

    def runtime_root_path(self, home: Path) -> Path:
        raw = self.runtime_root or "~/.exasol-starter-kit"
        if raw == "~":
            return home
        if raw.startswith("~/"):
            return home / raw[2:]
        if raw.startswith("~"):
            raise ValueError(
                f"Unsupported runtime_root {raw!r}: '~user' expansion is not "
                "supported; use an absolute path."
            )
        path = Path(raw)
        if path.is_absolute():
            return path
        return home / raw


@dataclass
class OperationResult:
    operation: OperationName
    status: OperationStatus
    summary: str
    request_id: str | None = None
    findings: list[Finding] = field(default_factory=list)
    changes: list[ChangeRecord] = field(default_factory=list)
    artifacts: list[ArtifactReference] = field(default_factory=list)
    backup_reference: str | None = None
    verification_evidence: list[VerificationEvidence] = field(default_factory=list)
    next_actions: list[NextAction] = field(default_factory=list)
    details: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return to_primitive(self)
