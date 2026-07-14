"""Helpers for reading the installed starter-kit runtime state."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import shutil

from mcp.core.errors import MCPSubsystemError
from mcp.core.models import DeploymentMode, ServerDefinition

from .environment import ExecutionEnvironment
from .filesystem import FileSystem
from .paths import RuntimePaths


DEFAULT_MCP_COMMAND = "uvx"
DEFAULT_MCP_PACKAGE = "exasol-mcp-server"
DEFAULT_MCP_VERSION = "1.10.1"
DEFAULT_SERVER_NAME = "exasol"
LOCAL_SELF_SIGNED_TLS_ENV = {"EXA_SSL_CERT_VALIDATION": "no"}
DEFAULT_READ_ONLY_MCP_SETTINGS = {
    "enable_read_query": True,
    "enable_summarize_table": True,
    "enable_query_profiling": True,
    "enable_write_query": False,
    "enable_write_bucketfs": False,
}


@dataclass
class ExakitRuntimeContext:
    runtime_root: Path
    dsn: str
    user: str
    password: str
    password_file: Path
    server_definition: ServerDefinition


class ExakitRuntimeLoader:
    """Load DSN, credentials, and MCP launch details from the kit runtime."""

    def __init__(
        self,
        environment: ExecutionEnvironment | None = None,
        filesystem: FileSystem | None = None,
    ) -> None:
        self._environment = environment or ExecutionEnvironment.current()
        self._filesystem = filesystem or FileSystem()

    def load(self, runtime_root: Path) -> ExakitRuntimeContext:
        paths = RuntimePaths(runtime_root)
        manifest_path = paths.manifest_path
        if not manifest_path.exists():
            raise MCPSubsystemError(
                "runtime_manifest_missing",
                f"No starter-kit manifest was found at {manifest_path}.",
            )
        document = self._filesystem.read_json(manifest_path)
        runtime = self._require_mapping(document, "runtime")
        dsn = str(runtime.get("dsn") or "").strip()
        if not dsn:
            raise MCPSubsystemError(
                "runtime_dsn_missing",
                "The starter-kit manifest does not contain runtime.dsn yet.",
            )
        user = str(runtime.get("user") or "").strip()
        if not user:
            raise MCPSubsystemError(
                "runtime_user_missing",
                "The starter-kit manifest does not contain runtime.user yet.",
            )
        password_file_raw = str(runtime.get("password_file") or "").strip()
        if not password_file_raw:
            raise MCPSubsystemError(
                "runtime_password_file_missing",
                "The starter-kit manifest does not contain runtime.password_file yet.",
            )
        connection_user, connection_password_file_raw = self._resolve_mcp_connection(
            document,
            user,
            password_file_raw,
        )
        password_file = Path(connection_password_file_raw).expanduser()
        if not password_file.exists():
            raise MCPSubsystemError(
                "runtime_password_file_unreadable",
                f"The password file recorded in the starter-kit manifest does not exist: {password_file}",
            )
        password = self._filesystem.read_text(password_file).strip()
        if not password:
            raise MCPSubsystemError(
                "runtime_password_missing",
                f"The password file is empty: {password_file}",
            )

        components = document.get("components", {})
        component_state = components.get("mcp_server", {}) if isinstance(components, dict) else {}
        package = str(
            self._environment.env.get("EXAKIT_MCP_PACKAGE")
            or component_state.get("package")
            or DEFAULT_MCP_PACKAGE
        ).strip()
        version = str(
            self._environment.env.get("EXAKIT_MCP_VERSION")
            or component_state.get("version")
            or DEFAULT_MCP_VERSION
        ).strip()
        command = self._resolve_mcp_command(component_state)
        server_name = str(
            self._environment.env.get("EXAKIT_MCP_SERVER_NAME") or DEFAULT_SERVER_NAME
        ).strip()
        env = {
            "EXA_DSN": dsn,
            "EXA_USER": connection_user,
            "EXA_PASSWORD": password,
            "EXA_MCP_SETTINGS": json.dumps(DEFAULT_READ_ONLY_MCP_SETTINGS),
        }
        env.update(self._ssl_environment(runtime, dsn))
        # The install validated the server only with OpenSSL's ARM fast paths
        # disabled (this guest advertises SVE its host CPU cannot execute —
        # see setup/lib/mcp.sh mcp_validate). Launch clients the same way.
        if component_state.get("openssl_armcap_workaround") is True:
            env["OPENSSL_armcap"] = "0"
        definition = ServerDefinition(
            transport=DeploymentMode.STDIO,
            name=server_name,
            command=command,
            args=(f"{package}@{version}",),
            env=env,
        )
        return ExakitRuntimeContext(
            runtime_root=runtime_root,
            dsn=dsn,
            user=connection_user,
            password=password,
            password_file=password_file,
            server_definition=definition,
        )

    def _resolve_mcp_command(self, component_state: dict) -> str:
        for candidate in self._candidate_mcp_commands(component_state):
            if candidate:
                return candidate
        return DEFAULT_MCP_COMMAND

    def _candidate_mcp_commands(self, component_state: dict) -> tuple[str, ...]:
        env_command = str(self._environment.env.get("EXAKIT_MCP_COMMAND") or "").strip()
        manifest_command = str(component_state.get("command") or "").strip()
        uv_path = str(component_state.get("uv_path") or "").strip()
        resolved_path = shutil.which(DEFAULT_MCP_COMMAND) or ""
        local_bin = self._environment.home / ".local" / "bin"
        platform_candidates = (
            local_bin / "uvx",
            local_bin / "uvx.exe",
        )

        derived_from_uv: list[str] = []
        if uv_path:
            uv_binary = Path(uv_path).expanduser()
            derived_from_uv.extend(
                [
                    str(uv_binary.with_name("uvx")),
                    str(uv_binary.with_name("uvx.exe")),
                ]
            )

        discovered: list[str] = []
        for raw in (
            env_command,
            manifest_command,
            *derived_from_uv,
            *(str(path) for path in platform_candidates if path.exists()),
            resolved_path,
            DEFAULT_MCP_COMMAND,
        ):
            candidate = str(raw).strip()
            if candidate and candidate not in discovered:
                discovered.append(candidate)
        return tuple(discovered)

    @staticmethod
    def _require_mapping(document: dict, key: str) -> dict:
        value = document.get(key, {})
        if not isinstance(value, dict):
            raise MCPSubsystemError(
                "runtime_manifest_invalid",
                f"The starter-kit manifest field '{key}' must be a JSON object.",
            )
        return value

    @staticmethod
    def _resolve_mcp_connection(
        document: dict,
        runtime_user: str,
        runtime_password_file: str,
    ) -> tuple[str, str]:
        del runtime_password_file
        components = document.get("components", {})
        if not isinstance(components, dict):
            raise MCPSubsystemError(
                "runtime_mcp_connection_missing",
                "The starter-kit manifest does not contain a validated MCP connection yet.",
            )
        mcp_component = components.get("mcp_server", {})
        if not isinstance(mcp_component, dict):
            raise MCPSubsystemError(
                "runtime_mcp_connection_missing",
                "The starter-kit manifest does not contain a validated MCP connection yet.",
            )
        if "connection" not in mcp_component:
            raise MCPSubsystemError(
                "runtime_mcp_connection_missing",
                "The starter-kit manifest does not contain a validated MCP connection yet.",
            )
        connection = mcp_component.get("connection", {})
        if not isinstance(connection, dict) or not connection:
            raise MCPSubsystemError(
                "runtime_mcp_connection_missing",
                "The starter-kit manifest does not contain a validated MCP connection yet.",
            )
        if connection.get("validated") is not True:
            raise MCPSubsystemError(
                "runtime_mcp_connection_unvalidated",
                "The MCP connection exists but has not been validated as dedicated read-only access yet.",
            )
        user = str(connection.get("user") or "").strip()
        password_file = str(connection.get("password_file") or "").strip()
        if not user or not password_file:
            raise MCPSubsystemError(
                "runtime_mcp_connection_incomplete",
                "The validated MCP connection is missing its user or password_file.",
            )
        if user == runtime_user:
            raise MCPSubsystemError(
                "runtime_mcp_connection_not_isolated",
                "The MCP connection must use a dedicated read-only database user, not the runtime admin user.",
            )
        return user, password_file

    @staticmethod
    def _ssl_environment(runtime: dict, dsn: str) -> dict[str, str]:
        """Match the local Exasol Personal self-signed TLS posture."""
        tls = str(runtime.get("tls") or "").strip().lower()
        local_dsn = dsn.startswith(("127.0.0.1:", "localhost:", "[::1]:"))
        if tls in {"self-signed", "self_signed", "selfsigned"} or local_dsn:
            return dict(LOCAL_SELF_SIGNED_TLS_ENV)
        return {}
