"""The exasol server as the launcher's MCP sidecar (Exasol Personal 2.4.0+).

When `exakit mcp-setup` finds the launcher's MCP server serving as the kit's
read-only user, the manifest records `components.mcp_server.backend = "sidecar"`
with its loopback URL. Every client must then get that URL in its own dialect,
under the same `exasol` name the kit's former stdio server had (so an agent's
tool names do not change), and no client config may hold a password any more. Claude Desktop,
which runs only local servers, gets a stdio bridge to the same URL instead of
being skipped. Doctor speaks MCP to the endpoint over HTTP.
"""

from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import subprocess
import sys
import threading
import unittest

from mcp.core.errors import MCPSubsystemError
from mcp.core.models import DeploymentMode
from mcp.runtime.environment import ExecutionEnvironment
from mcp.runtime.exakit import DEFAULT_MCP_BRIDGE, ExakitRuntimeLoader
from mcp.runtime.filesystem import FileSystem
from mcp.validator.service import ValidatorService
from mcp.tests.test_dash_server_registration import (
    REPO_ROOT,
    _CONFIG_PATH_ENV_NAMES,
    _DASH_ENV_NAMES,
    _DashServerFixture,
)

URL = "http://127.0.0.1:4896/mcp"


def _sidecar_manifest(fixture: _DashServerFixture, **mcp_server: object) -> None:
    fixture._write_manifest()
    document = json.loads(fixture.manifest_path.read_text(encoding="utf-8"))
    document["components"]["mcp_server"].update({"backend": "sidecar", "url": URL, **mcp_server})
    fixture.manifest_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")


class SidecarDefinitionTests(_DashServerFixture):
    def _load(self):
        loader = ExakitRuntimeLoader(
            environment=ExecutionEnvironment(os_name="darwin", home=self._temp_dir, env={}),
            filesystem=FileSystem(),
        )
        return loader.load(self.runtime_root).server_definition

    def test_the_sidecar_is_an_http_definition_named_exasol_with_no_secrets(self) -> None:
        _sidecar_manifest(self)
        definition = self._load()
        self.assertIs(definition.transport, DeploymentMode.HTTP)
        self.assertEqual(definition.name, "exasol")
        self.assertEqual(definition.url, URL)
        self.assertEqual(definition.env, {})
        self.assertNotIn("readonly-secret", json.dumps(definition.__dict__, default=str))

    def test_a_stdio_only_client_gets_the_pinned_bridge_to_the_same_url(self) -> None:
        _sidecar_manifest(self)
        definition = self._load()
        self.assertIs(definition.for_client(True), definition)
        bridge = definition.for_client(False)
        self.assertIs(bridge.transport, DeploymentMode.STDIO)
        self.assertEqual(bridge.args, (DEFAULT_MCP_BRIDGE, "--transport", "streamablehttp", URL))
        self.assertEqual(bridge.env, {})

    def test_a_recorded_bridge_outranks_the_default(self) -> None:
        _sidecar_manifest(self, bridge="mcp-proxy@0.13.9")
        self.assertEqual(self._load().for_client(False).args[0], "mcp-proxy@0.13.9")

    def test_a_url_off_loopback_is_not_trusted(self) -> None:
        _sidecar_manifest(self, url="http://example.com:4896/mcp")
        with self.assertRaises(MCPSubsystemError) as ctx:
            self._load()
        self.assertEqual(ctx.exception.code, "runtime_mcp_server_not_set_up")

    def test_without_the_backend_record_there_is_no_server_to_fall_back_to(self) -> None:
        self._write_manifest()
        document = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        for key in ("backend", "url"):
            document["components"]["mcp_server"].pop(key, None)
        self.manifest_path.write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaises(MCPSubsystemError) as ctx:
            self._load()
        self.assertIn("Run: exakit mcp-setup", str(ctx.exception))


class SidecarSetupCLITests(_DashServerFixture):
    """`python -m mcp setup-runtime-clients` against a sidecar manifest, every client."""

    def setUp(self) -> None:
        super().setUp()
        self.client_paths = {
            "cursor": self._temp_dir / "cursor" / "mcp.json",
            "codex": self._temp_dir / "codex" / "config.toml",
            "claude_code": self._temp_dir / "claude-code" / ".claude.json",
            "claude_desktop": self._temp_dir / "claude-desktop" / "claude_desktop_config.json",
            "vscode_copilot": self._temp_dir / "Code" / "User" / "mcp.json",
            "gemini_cli": self._temp_dir / "gemini" / "settings.json",
            "opencode": self._temp_dir / "opencode" / "opencode.json",
            "continue": self._temp_dir / "continue" / "mcpServers" / "exasol-starter-kit.yaml",
        }
        for path in self.client_paths.values():
            path.parent.mkdir(parents=True, exist_ok=True)

    def _setup(self, *clients: str) -> dict:
        env = os.environ.copy()
        for name in _DASH_ENV_NAMES:
            env.pop(name, None)
        for client, path in self.client_paths.items():
            env[_CONFIG_PATH_ENV_NAMES[client]] = str(path)
        result = subprocess.run(
            [sys.executable, "-m", "mcp", "setup-runtime-clients", "--runtime-root", str(self.runtime_root),
             "--clients", *clients],
            cwd=REPO_ROOT, env=env, check=False, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def _read_json(self, client: str) -> dict:
        return json.loads(self.client_paths[client].read_text(encoding="utf-8"))

    def test_every_client_gets_the_url_and_claude_desktop_the_bridge(self) -> None:
        _sidecar_manifest(self)
        clients = ("claude_code", "cursor", "codex", "vscode_copilot", "gemini_cli", "opencode",
                   "continue", "claude_desktop")
        payload = self._setup(*clients)
        self.assertNotIn("client_transport_unsupported", [f["code"] for f in payload.get("findings", [])])
        self.assertEqual(self._read_json("cursor")["mcpServers"]["exasol"], {"url": URL})
        self.assertEqual(self._read_json("claude_code")["mcpServers"]["exasol"], {"type": "http", "url": URL})
        self.assertEqual(self._read_json("vscode_copilot")["servers"]["exasol"], {"type": "http", "url": URL})
        self.assertEqual(self._read_json("gemini_cli")["mcpServers"]["exasol"], {"httpUrl": URL})
        self.assertEqual(self._read_json("opencode")["mcp"]["exasol"], {"type": "remote", "url": URL, "enabled": True})
        import tomllib
        codex = tomllib.loads(self.client_paths["codex"].read_text(encoding="utf-8"))
        self.assertEqual(codex["mcp_servers"]["exasol"], {"url": URL})
        self.assertIn("type: streamable-http", self.client_paths["continue"].read_text(encoding="utf-8"))
        desktop = self._read_json("claude_desktop")["mcpServers"]["exasol"]
        self.assertEqual(desktop["args"], [DEFAULT_MCP_BRIDGE, "--transport", "streamablehttp", URL])
        self.assertNotIn("env", desktop)
        for path in self.client_paths.values():
            if path.exists():
                self.assertNotIn("readonly-secret", path.read_text(encoding="utf-8"), path)


class _FakeMcp(BaseHTTPRequestHandler):
    """Answers initialize and tools/list the way the sidecar's FastMCP does: an event stream."""

    def do_POST(self) -> None:  # noqa: N802 - the http.server API
        message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if "id" not in message:
            self.send_response(202)
            self.end_headers()
            return
        if message["method"] == "initialize":
            result = {"protocolVersion": "2024-11-05", "capabilities": {}, "serverInfo": {"name": "fake"}}
        else:
            result = {"tools": [{"name": "execute_exasol_query"}, {"name": "list_exasol_schemas"}]}
        body = "event: message\ndata: " + json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}) + "\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("mcp-session-id", "abc")
        self.end_headers()
        self.wfile.write(body.encode("utf-8"))

    def log_message(self, *_args) -> None:
        pass


class HttpHandshakeTests(unittest.TestCase):
    def test_doctor_speaks_mcp_to_the_sidecar_over_http(self) -> None:
        server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeMcp)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_address[1]}/mcp"
            tools = ValidatorService.__new__(ValidatorService)._mcp_http_handshake(url)
            self.assertEqual(tools, ["execute_exasol_query", "list_exasol_schemas"])
        finally:
            server.shutdown()

    def test_an_endpoint_nobody_serves_is_a_launch_failure_naming_the_url(self) -> None:
        result = ValidatorService.__new__(ValidatorService)._validate_http_server("http://127.0.0.1:9/mcp")
        self.assertEqual(result.status, "fail_recoverable")
        self.assertIn("http://127.0.0.1:9/mcp", result.findings[0].message)


if __name__ == "__main__":
    unittest.main()
