"""Local security and safety checks."""

from __future__ import annotations

from pathlib import Path
import stat
from urllib.parse import urlparse

from mcp.core.models import DeploymentMode, Finding, OperationRequest, Severity


class SecurityPolicy:
    """Enforce safe-by-default request and file behavior."""

    def preflight(self, request: OperationRequest) -> list[Finding]:
        findings: list[Finding] = []
        if request.operation.value in {"configure", "repair"} and request.server_definition is None:
            findings.append(
                Finding(
                    code="missing_server_definition",
                    severity=Severity.ERROR,
                    message="Mutating client configuration requires a server definition.",
                    recommended_action="Provide a transport-specific server definition from the upstream installer.",
                    blocking=True,
                )
            )
            return findings
        if request.server_definition is None:
            return findings
        if request.server_definition.transport != request.deployment_mode:
            findings.append(
                Finding(
                    code="deployment_mode_mismatch",
                    severity=Severity.ERROR,
                    message="The request deployment mode does not match the server definition transport.",
                    recommended_action="Align deployment_mode with server_definition.transport.",
                    blocking=True,
                )
            )
        if request.server_definition.transport == DeploymentMode.STDIO:
            if not request.server_definition.command:
                findings.append(
                    Finding(
                        code="missing_server_command",
                        severity=Severity.ERROR,
                        message="A stdio server definition requires a command.",
                        recommended_action="Populate server_definition.command.",
                        blocking=True,
                    )
                )
        if request.server_definition.transport == DeploymentMode.HTTP:
            parsed = urlparse(request.server_definition.url or "")
            if parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
                findings.append(
                    Finding(
                        code="unsafe_http_target",
                        severity=Severity.CRITICAL,
                        message="HTTP deployment must target a loopback address by default.",
                        evidence=[request.server_definition.url or "<missing-url>"],
                        recommended_action="Bind the MCP HTTP endpoint to localhost and retry.",
                        blocking=True,
                    )
                )
        if request.credential_reference and self._is_plaintext_credential(
            request.credential_reference, request.server_definition
        ):
            findings.append(
                Finding(
                    code="plaintext_credential_reference",
                    severity=Severity.WARNING,
                    message="The database credential is stored as plaintext in the client configuration file.",
                    recommended_action=(
                        "Keep the config file owner-only (0600) and prefer an external or "
                        "OS-keychain credential reference where the client supports it."
                    ),
                )
            )
        return findings

    @staticmethod
    def _is_plaintext_credential(credential, server_definition) -> bool:
        """True when the credential ends up on disk as plaintext.

        Two paths reach the config file as cleartext: a ``literal`` reference
        carries the secret value directly, and an ``inline_env`` reference names
        an env var whose value the adapters write verbatim into the client
        config's env block. The latter is the path the installer actually uses,
        so checking only for ``literal`` left the warning permanently dormant.
        """
        if credential.kind == "literal" and credential.value:
            return True
        if (
            credential.kind == "inline_env"
            and credential.name
            and server_definition is not None
        ):
            return bool(server_definition.env.get(credential.name))
        return False

    def apply_managed_permissions(self, path: Path) -> str | None:
        if path.exists() and path.is_file() and hasattr(path, "chmod"):
            path.chmod(stat.S_IRUSR | stat.S_IWUSR)
            return format(stat.S_IMODE(path.stat().st_mode), "04o")
        return None
