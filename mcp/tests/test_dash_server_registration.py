"""Tests for registering the dash-server add-on's MCP control plane.

`exakit mcp-setup` registers two managed entries when the add-on is installed:
the `exasol` stdio server every client gets, and dash-server's Streamable HTTP
control plane. The two must merge into the same client config files without
either erasing the other, and a client that cannot express a remote server has
to be skipped without turning the whole setup run into a failure -- an AI client
that can query the database is what setup promised, and dashboards are extra.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from mcp.core.models import DeploymentMode
from mcp.runtime.environment import ExecutionEnvironment
from mcp.runtime.exakit import ExakitRuntimeLoader
from mcp.runtime.filesystem import FileSystem

REPO_ROOT = Path(__file__).resolve().parents[2]

# Every kit-side environment variable that can move the dash-server entry, so a
# developer machine that happens to export one cannot change what these tests
# assert. Each test that cares sets the variable it is testing explicitly.
_DASH_ENV_NAMES = (
    "EXAKIT_DASH_SERVER_PORT",
    "EXAKIT_DASH_SERVER_MCP_NAME",
    "EXAKIT_MCP_SERVER_NAME",
)

# Where each adapter is told to write, so a test never touches the real
# ~/.cursor, ~/.codex or ~/.continue of the machine running it.
_CONFIG_PATH_ENV_NAMES = {
    "cursor": "CURSOR_MCP_CONFIG_PATH",
    "codex": "CODEX_MCP_CONFIG_PATH",
    "claude_code": "CLAUDE_CODE_CONFIG_PATH",
    "claude_desktop": "CLAUDE_DESKTOP_CONFIG_PATH",
    "vscode_copilot": "VSCODE_MCP_CONFIG_PATH",
    "gemini_cli": "GEMINI_CLI_CONFIG_PATH",
    "opencode": "OPENCODE_CONFIG_PATH",
    "continue": "CONTINUE_MCP_CONFIG_PATH",
}

# The clients that can express a remote MCP server, and the one that cannot.
# Codex joined the capable set once its CLI made streamable HTTP first-class
# (`[mcp_servers.<name>] url = "..."`, verified against Codex CLI 0.147.0);
# Claude Desktop's config file still knows only command/args, remote servers
# are added through the app's own Connectors settings.
_HTTP_CAPABLE_CLIENTS = (
    "claude_code",
    "cursor",
    "codex",
    "vscode_copilot",
    "gemini_cli",
    "opencode",
    "continue",
)
_HTTP_INCAPABLE_CLIENTS = ("claude_desktop",)

# A setup run against this fixture reports warnings for a plaintext credential
# and a DSN that is not in host:port form, so "the run did not fail" is a set of
# statuses rather than one value.
_NON_FAILING_STATUSES = {"success", "success_with_warnings", "no_change"}


class _DashServerFixture(unittest.TestCase):
    """A throwaway starter-kit runtime root with credentials on disk.

    The manifest is written per test because the presence and content of the
    `components.dash_server` block is the input under test.
    """

    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-dash-server-"))
        self.runtime_root = self._temp_dir / "runtime"
        credentials = self.runtime_root / "credentials"
        credentials.mkdir(parents=True, exist_ok=True)
        self.password_file = credentials / "db_password"
        self.mcp_password_file = credentials / "mcp_password"
        self.password_file.write_text("starter-secret\n", encoding="utf-8")
        self.mcp_password_file.write_text("readonly-secret\n", encoding="utf-8")
        self.manifest_path = self.runtime_root / "manifest.json"

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def _write_manifest(self, dash_server: dict | None = None) -> None:
        """Write a manifest the loader will accept.

        The validated `mcp_server.connection` block is not optional scenery: the
        loader refuses to produce any server definition without it, so every
        test needs it even when the dash-server block is what it is really
        about. `dash_server=None` models a kit where the add-on was never
        installed.
        """
        components: dict = {
            "mcp_server": {
                "connection": {
                    "user": "mcp_readonly",
                    "password_file": str(self.mcp_password_file),
                    "validated": True,
                }
            }
        }
        if dash_server is not None:
            components["dash_server"] = dash_server
        manifest = {
            "manifest_version": 1,
            "kit_level": 1,
            "runtime": {
                "type": "personal",
                "dsn": "exa-local",
                "user": "sys",
                "password_file": str(self.password_file),
                "tls": "self-signed",
            },
            "components": components,
            "steps_completed": ["runtime", "mcp_server"],
        }
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


class DashServerDefinitionTests(_DashServerFixture):
    """`ExakitRuntimeLoader.load_dash_server` decides whether to register at all."""

    def _loader(self, env: dict[str, str] | None = None) -> ExakitRuntimeLoader:
        return ExakitRuntimeLoader(
            environment=ExecutionEnvironment(
                os_name="darwin",
                home=self._temp_dir,
                env=dict(env or {}),
            ),
            filesystem=FileSystem(),
        )

    def test_load_dash_server_returns_nothing_when_the_manifest_is_missing(self) -> None:
        # mcp-setup can be pointed at a root that holds no manifest yet; that is
        # not an error here, it only means there is no add-on to register.
        self.assertIsNone(self._loader().load_dash_server(self.runtime_root))

    def test_load_dash_server_returns_nothing_when_the_add_on_is_not_installed(self) -> None:
        self._write_manifest()
        self.assertIsNone(self._loader().load_dash_server(self.runtime_root))

    def test_load_dash_server_returns_nothing_when_the_component_block_is_empty(self) -> None:
        # An uninstall that emptied the block instead of deleting it has to read
        # as "not installed", not as a dash-server on the default port.
        self._write_manifest(dash_server={})
        self.assertIsNone(self._loader().load_dash_server(self.runtime_root))

    def test_load_dash_server_points_at_the_recorded_port_over_loopback(self) -> None:
        self._write_manifest(dash_server={"version": "0.4.0", "port": 5137})
        definition = self._loader().load_dash_server(self.runtime_root)
        self.assertIsNotNone(definition)
        self.assertEqual(definition.transport, DeploymentMode.HTTP)
        self.assertEqual(definition.name, "dash-server")
        self.assertEqual(definition.url, "http://127.0.0.1:5137/mcp")
        # The control plane is loopback-only, so there is nothing to hand it:
        # no launch command, no credentials, no environment block.
        self.assertIsNone(definition.command)
        self.assertEqual(definition.args, ())
        self.assertEqual(definition.env, {})

    def test_load_dash_server_falls_back_to_the_default_port_when_none_was_recorded(self) -> None:
        self._write_manifest(dash_server={"version": "0.4.0"})
        definition = self._loader().load_dash_server(self.runtime_root)
        self.assertEqual(definition.url, "http://127.0.0.1:5100/mcp")

    def test_environment_port_outranks_the_recorded_port(self) -> None:
        # Same precedence as the shell side: an explicit choice for this run
        # wins over whatever the installer happened to record.
        self._write_manifest(dash_server={"version": "0.4.0", "port": 5137})
        definition = self._loader({"EXAKIT_DASH_SERVER_PORT": "5199"}).load_dash_server(
            self.runtime_root
        )
        self.assertEqual(definition.url, "http://127.0.0.1:5199/mcp")

    def test_unusable_recorded_port_falls_back_to_the_default(self) -> None:
        # A malformed manifest field must not cost the user MCP setup, so the
        # default answers instead of an exception reaching the CLI.
        self._write_manifest(dash_server={"version": "0.4.0", "port": "not-a-port"})
        definition = self._loader().load_dash_server(self.runtime_root)
        self.assertEqual(definition.url, "http://127.0.0.1:5100/mcp")

    def test_out_of_range_recorded_port_falls_back_to_the_default(self) -> None:
        self._write_manifest(dash_server={"version": "0.4.0", "port": 70000})
        definition = self._loader().load_dash_server(self.runtime_root)
        self.assertEqual(definition.url, "http://127.0.0.1:5100/mcp")

    def test_unusable_environment_port_leaves_the_recorded_port_in_charge(self) -> None:
        # An unusable override is skipped rather than fatal, and the next
        # candidate down the precedence chain answers.
        self._write_manifest(dash_server={"version": "0.4.0", "port": 5137})
        definition = self._loader({"EXAKIT_DASH_SERVER_PORT": "gibberish"}).load_dash_server(
            self.runtime_root
        )
        self.assertEqual(definition.url, "http://127.0.0.1:5137/mcp")

    def test_environment_can_rename_the_dash_server_entry(self) -> None:
        self._write_manifest(dash_server={"version": "0.4.0", "port": 5137})
        definition = self._loader({"EXAKIT_DASH_SERVER_MCP_NAME": "dash"}).load_dash_server(
            self.runtime_root
        )
        self.assertEqual(definition.name, "dash")

    def test_registration_does_not_wait_for_the_add_on_to_be_validated(self) -> None:
        """The entry is a pointer to a port, so it is written regardless.

        Gating on `validated` would withhold the entry from exactly the user who
        needs it: someone whose server is installed but not currently answering,
        who repairs that with `exakit update dash-server` and expects the
        already-registered client to start working.
        """
        self._write_manifest(dash_server={"version": "0.4.0", "port": 5137, "validated": False})
        definition = self._loader().load_dash_server(self.runtime_root)
        self.assertIsNotNone(definition)
        self.assertEqual(definition.url, "http://127.0.0.1:5137/mcp")


class DashServerRegistrationCLITests(_DashServerFixture):
    """End-to-end `python -m mcp` runs, which is how `exakit mcp-setup` calls in."""

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
            # Continue's override names ONE file: the kit server's block file.
            "continue": self._temp_dir / "continue" / "mcpServers" / "exasol-starter-kit.yaml",
        }
        for path in self.client_paths.values():
            path.parent.mkdir(parents=True, exist_ok=True)

    def _env(self, **overrides: str) -> dict[str, str]:
        env = os.environ.copy()
        for name in _DASH_ENV_NAMES:
            env.pop(name, None)
        for client, path in self.client_paths.items():
            env[_CONFIG_PATH_ENV_NAMES[client]] = str(path)
        env.update(overrides)
        return env

    def _run(
        self, argv: list[str], env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-m", "mcp", *argv],
            cwd=REPO_ROOT,
            env=env or self._env(),
            check=False,
            capture_output=True,
            text=True,
        )

    def _setup(self, *clients: str, env: dict[str, str] | None = None) -> dict:
        result = self._run(
            [
                "setup-runtime-clients",
                "--runtime-root",
                str(self.runtime_root),
                "--clients",
                *clients,
            ],
            env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def _read_json(self, client: str) -> dict:
        return json.loads(self.client_paths[client].read_text(encoding="utf-8"))

    def _continue_block_file(self, server_name: str) -> Path:
        """The sibling block file Continue gets for a non-exasol server."""
        base = self.client_paths["continue"]
        return base.with_name(base.stem + "-" + server_name + base.suffix)

    def test_setup_registers_only_the_exasol_server_when_the_add_on_is_absent(self) -> None:
        """No add-on, no second pass -- and no trace of one in the payload."""
        self._write_manifest()
        payload = self._setup("cursor", "gemini_cli", "continue")
        self.assertNotIn("dash_server", payload)
        self.assertNotIn(
            "dash_server_not_registered",
            [finding["code"] for finding in payload.get("findings", [])],
        )
        self.assertEqual(list(self._read_json("cursor")["mcpServers"]), ["exasol"])
        self.assertEqual(list(self._read_json("gemini_cli")["mcpServers"]), ["exasol"])
        self.assertNotIn("dash", self.client_paths["continue"].read_text(encoding="utf-8"))
        self.assertFalse(self._continue_block_file("dash-server").exists())

    def test_setup_registers_the_control_plane_with_every_client_that_supports_http(self) -> None:
        """Each client gets the endpoint in its own dialect, alongside exasol."""
        self._write_manifest(dash_server={"version": "0.4.0", "port": 5137})
        payload = self._setup(*_HTTP_CAPABLE_CLIENTS)
        url = "http://127.0.0.1:5137/mcp"
        self.assertEqual(payload["dash_server"]["server_name"], "dash-server")
        self.assertEqual(payload["dash_server"]["url"], url)
        self.assertEqual(
            sorted(payload["dash_server"]["configured_clients"]),
            sorted(_HTTP_CAPABLE_CLIENTS),
        )
        self.assertEqual(payload["dash_server"]["skipped_clients"], [])

        # Each client's own spelling of "a remote MCP server at this URL".
        self.assertEqual(self._read_json("cursor")["mcpServers"]["dash-server"], {"url": url})
        self.assertEqual(
            self._read_json("claude_code")["mcpServers"]["dash-server"],
            {"type": "http", "url": url},
        )
        self.assertEqual(
            self._read_json("vscode_copilot")["servers"]["dash-server"],
            {"type": "http", "url": url},
        )
        self.assertEqual(
            self._read_json("gemini_cli")["mcpServers"]["dash-server"],
            {"httpUrl": url},
        )
        self.assertEqual(
            self._read_json("opencode")["mcp"]["dash-server"],
            {"type": "remote", "url": url, "enabled": True},
        )
        # Codex: one key, the shape `codex mcp add <name> --url <url>` writes.
        import tomllib
        codex_document = tomllib.loads(self.client_paths["codex"].read_text(encoding="utf-8"))
        self.assertEqual(codex_document["mcp_servers"]["dash-server"], {"url": url})
        self.assertEqual(codex_document["mcp_servers"]["exasol"]["env"]["EXA_USER"], "mcp_readonly")
        dash_block = self._continue_block_file("dash-server").read_text(encoding="utf-8")
        self.assertIn("name: dash-server", dash_block)
        self.assertIn("type: streamable-http", dash_block)
        self.assertIn('url: "' + url + '"', dash_block)

        # The second pass must merge, not replace: the exasol entry the first
        # pass wrote is still there, still pointing at the read-only user.
        self.assertEqual(
            self._read_json("cursor")["mcpServers"]["exasol"]["env"]["EXA_USER"],
            "mcp_readonly",
        )
        self.assertEqual(
            self._read_json("claude_code")["mcpServers"]["exasol"]["env"]["EXA_USER"],
            "mcp_readonly",
        )
        self.assertEqual(self._read_json("vscode_copilot")["servers"]["exasol"]["type"], "stdio")
        self.assertEqual(
            self._read_json("gemini_cli")["mcpServers"]["exasol"]["env"]["EXA_USER"],
            "mcp_readonly",
        )
        self.assertEqual(self._read_json("opencode")["mcp"]["exasol"]["type"], "local")
        self.assertIn("name: exasol", self.client_paths["continue"].read_text(encoding="utf-8"))

    def test_setup_reports_clients_without_remote_support_as_skipped_not_failed(self) -> None:
        """Claude Desktop cannot hold a URL, and that is not a failure.

        It is skipped rather than half-configured, the run still exits 0 with
        the exasol pass's status, and the control plane nobody could take is
        recorded as a warning so the install record says why. The per-client
        finding itself is INFO and worded as a note, not a fault: it is a
        standing fact about the client and is printed on every refresh.
        """
        self._write_manifest(dash_server={"version": "0.4.0", "port": 5137})
        result = self._run(
            [
                "setup-runtime-clients",
                "--runtime-root",
                str(self.runtime_root),
                "--clients",
                *_HTTP_INCAPABLE_CLIENTS,
            ]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertIn(payload["status"], _NON_FAILING_STATUSES)
        self.assertEqual(payload["dash_server"]["configured_clients"], [])
        self.assertEqual(
            sorted(payload["dash_server"]["skipped_clients"]),
            sorted(_HTTP_INCAPABLE_CLIENTS),
        )
        findings = {finding["code"]: finding for finding in payload["findings"]}
        self.assertEqual(findings["dash_server_not_registered"]["severity"], "warning")
        note = findings["client_transport_unsupported"]
        self.assertEqual(note["severity"], "info")
        self.assertIn("has no config-file shape for a remote MCP server", note["message"])
        self.assertIn("http://127.0.0.1:5137/mcp", note["message"])
        self.assertNotIn("cannot be configured", note["message"])

        # The file holds its exasol entry and nothing dash-shaped.
        self.assertEqual(list(self._read_json("claude_desktop")["mcpServers"]), ["exasol"])

    def test_continue_keeps_the_two_servers_in_separate_block_files(self) -> None:
        """Continue loads one server per block file, so the kit writes two.

        The exasol block file keeps its historical name (an existing install
        must not be orphaned) and is compared byte for byte before and after the
        add-on appears, because the dash pass writes into the same directory.
        """
        self._write_manifest()
        self._setup("continue")
        exasol_block = self.client_paths["continue"].read_text(encoding="utf-8")

        self._write_manifest(dash_server={"version": "0.4.0", "port": 5137})
        self._setup("continue")
        self.assertEqual(
            self.client_paths["continue"].read_text(encoding="utf-8"),
            exasol_block,
            "the exasol block file must survive the dash-server pass untouched",
        )
        dash_block_path = self._continue_block_file("dash-server")
        self.assertTrue(dash_block_path.exists())
        dash_block = dash_block_path.read_text(encoding="utf-8")
        self.assertIn("name: dash-server", dash_block)
        self.assertIn("type: streamable-http", dash_block)

    def test_environment_port_override_reaches_the_written_client_entry(self) -> None:
        """The port precedence is not loader-only: the CLI honours it too."""
        self._write_manifest(dash_server={"version": "0.4.0", "port": 5137})
        payload = self._setup("cursor", env=self._env(EXAKIT_DASH_SERVER_PORT="5199"))
        self.assertEqual(payload["dash_server"]["url"], "http://127.0.0.1:5199/mcp")
        self.assertEqual(
            self._read_json("cursor")["mcpServers"]["dash-server"],
            {"url": "http://127.0.0.1:5199/mcp"},
        )

    def test_targeted_uninstall_removes_only_the_dash_server_entry(self) -> None:
        """Removing the add-on must not take the database connection with it."""
        self._write_manifest(dash_server={"version": "0.4.0", "port": 5137})
        self._setup("cursor")
        self.assertEqual(
            sorted(self._read_json("cursor")["mcpServers"]),
            ["dash-server", "exasol"],
        )
        result = self._run(
            [
                "run-runtime-operation",
                "uninstall",
                "--runtime-root",
                str(self.runtime_root),
                "--clients",
                "cursor",
                "--servers",
                "dash-server",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self._read_json("cursor")["mcpServers"]), ["exasol"])
        self.assertEqual(
            self._read_json("cursor")["mcpServers"]["exasol"]["env"]["EXA_USER"],
            "mcp_readonly",
        )

    def test_untargeted_uninstall_removes_both_managed_entries(self) -> None:
        """`--servers` narrows the removal; without it, mcp-remove still clears all."""
        self._write_manifest(dash_server={"version": "0.4.0", "port": 5137})
        self._setup("cursor")
        result = self._run(
            [
                "run-runtime-operation",
                "uninstall",
                "--runtime-root",
                str(self.runtime_root),
                "--clients",
                "cursor",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        # This fixture's Cursor config never held anything but the two kit
        # entries, so removing both leaves an empty document -- which the
        # adapter deletes rather than leaving behind as an empty shell.
        self.assertFalse(self.client_paths["cursor"].exists())


if __name__ == "__main__":
    unittest.main()
