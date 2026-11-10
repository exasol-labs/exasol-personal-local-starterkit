"""Helpers for reading the installed starter-kit runtime state."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import shutil

from mcp.core.errors import MCPSubsystemError
from mcp.core.models import DeploymentMode, ServerDefinition

from .environment import ExecutionEnvironment
from .filesystem import FileSystem
from .paths import RuntimePaths


DEFAULT_MCP_COMMAND = "uvx"                 # runs the Claude Desktop bridge below
DEFAULT_MCP_PACKAGE = "exasol-mcp-server"
# The version of the server the sidecar image is (its tag): CI keeps it equal to versions.json components.mcp.version.
DEFAULT_MCP_VERSION = "2.4.0"
DEFAULT_SERVER_NAME = "exasol"
# The kit's one MCP server: the launcher's (Exasol Personal 2.4.0+), a sidecar
# next to the database answering Streamable HTTP on loopback, connected as the
# kit's read-only MCP user (setup/lib/mcp.sh mcp_sidecar_apply). Recorded in the
# manifest as components.mcp_server.backend = "sidecar" with its url. There is
# no other server to fall back to: a sidecar that does not serve is healed by
# mcp_sidecar_apply (exakit mcp-setup, exakit mcp-doctor), never replaced.
SIDECAR_BACKEND = "sidecar"
# Claude Desktop runs only local (stdio) servers: it reaches the sidecar through
# this bridge, run by the uvx the kit already has. Pinned; versions.json
# components.mcp.bridge overrides it through the manifest.
DEFAULT_MCP_BRIDGE = "mcp-proxy@0.13.0"
# The dash-server add-on's MCP control plane. dash-server speaks Streamable
# HTTP on a port it records at install time (5100 unless something already held
# it), so it is registered as a URL, not a command.
DASH_SERVER_SERVER_NAME = "dash-server"
DASH_SERVER_DEFAULT_PORT = 5100
DASH_SERVER_HOST = "127.0.0.1"
DASH_SERVER_MCP_PATH = "/mcp"


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
        sidecar_url = str(component_state.get("url") or "").strip()
        if component_state.get("backend") != SIDECAR_BACKEND or not sidecar_url.startswith("http://127.0.0.1:"):
            raise MCPSubsystemError(
                "runtime_mcp_server_not_set_up",
                "The MCP server beside your database is not set up yet. Run: exakit mcp-setup",
            )
        command = self._resolve_mcp_command(component_state)
        server_name = str(
            self._environment.env.get("EXAKIT_MCP_SERVER_NAME") or DEFAULT_SERVER_NAME
        ).strip()
        # The launcher's server: clients get its URL and nothing secret - the
        # read-only user's password lives in the deployment's sidecar
        # definition (0600, the launcher's), not in any client's config.
        bridge = str(component_state.get("bridge") or DEFAULT_MCP_BRIDGE).strip()
        definition = ServerDefinition(
            transport=DeploymentMode.HTTP,
            name=server_name,
            url=sidecar_url,
            bridge=ServerDefinition(
                transport=DeploymentMode.STDIO,
                name=server_name,
                command=command,
                args=(bridge, "--transport", "streamablehttp", sidecar_url),
            ),
        )
        return ExakitRuntimeContext(
            runtime_root=runtime_root,
            dsn=dsn,
            user=connection_user,
            password=password,
            password_file=password_file,
            server_definition=definition,
        )

    def load_dash_server(self, runtime_root: Path) -> ServerDefinition | None:
        """The dash-server add-on's MCP control plane, or None when it is absent.

        Registration is decided by the add-on's own manifest block, which its
        installer writes and its uninstall removes wholesale — so "installed"
        and "registered" cannot drift apart. Deliberately NOT gated on
        ``validated``: the entry is a pointer to a port, and it becomes correct
        the moment the server is running, which is exactly the state a user
        repairs with `exakit update dash-server`.

        Unlike the exasol server there is nothing secret here — no credentials,
        no env block — because the control plane is loopback-only.
        """
        paths = RuntimePaths(runtime_root)
        manifest_path = paths.manifest_path
        if not manifest_path.exists():
            return None
        try:
            document = self._filesystem.read_json(manifest_path)
        except Exception:  # noqa: BLE001 - an unreadable manifest is the caller's problem
            return None
        components = document.get("components")
        if not isinstance(components, dict):
            return None
        component_state = components.get("dash_server")
        if not isinstance(component_state, dict) or not component_state:
            return None
        port = self._dash_server_port(component_state)
        name = str(
            self._environment.env.get("EXAKIT_DASH_SERVER_MCP_NAME")
            or DASH_SERVER_SERVER_NAME
        ).strip()
        return ServerDefinition(
            transport=DeploymentMode.HTTP,
            name=name,
            url=f"http://{DASH_SERVER_HOST}:{port}{DASH_SERVER_MCP_PATH}",
        )

    def _dash_server_port(self, component_state: dict) -> int:
        """The port every dash-server command agrees on.

        Same precedence as the Python add-on: an
        explicit environment choice outranks the recorded port, which outranks
        the default. A recorded value that is not a port is ignored rather than
        raising — a malformed manifest field must not cost the user MCP setup.
        """
        for raw in (
            self._environment.env.get("EXAKIT_DASH_SERVER_PORT"),
            component_state.get("port"),
        ):
            try:
                port = int(str(raw).strip())
            except (TypeError, ValueError):
                continue
            if 1 <= port <= 65535:
                return port
        return DASH_SERVER_DEFAULT_PORT

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
