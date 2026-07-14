"""Adapter coverage tests for documented client formats."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import tempfile
import unittest

from mcp.adapters.registry import AdapterRegistry
from mcp.core.models import DeploymentMode, ServerDefinition
from mcp.runtime.environment import ExecutionEnvironment


class AdditionalAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-adapter-tests-"))
        self._workspace = self._temp_dir / "workspace"
        self._workspace.mkdir(parents=True, exist_ok=True)
        self._environment = ExecutionEnvironment(
            os_name="darwin",
            home=self._temp_dir,
            env={
                "CURSOR_MCP_CONFIG_PATH": str(self._temp_dir / "cursor" / "mcp.json"),
                "CODEX_MCP_CONFIG_PATH": str(self._temp_dir / "codex" / "config.toml"),
                "CLAUDE_DESKTOP_CONFIG_PATH": str(
                    self._temp_dir / "claude" / "claude_desktop_config.json"
                ),
                "CLAUDE_CODE_CONFIG_PATH": str(self._temp_dir / "claude-code" / ".claude.json"),
                "VSCODE_MCP_CONFIG_PATH": str(self._temp_dir / "vscode" / "mcp.json"),
                "GEMINI_CLI_CONFIG_PATH": str(self._temp_dir / "gemini" / "settings.json"),
            },
            cwd=self._workspace,
        )
        self._registry = AdapterRegistry()
        self._server = ServerDefinition(
            transport=DeploymentMode.STDIO,
            name="exasol",
            command="/tmp/uvx",
            args=("exasol-mcp-server@1.10.1",),
            env={"EXA_DSN": "127.0.0.1:8563", "EXA_USER": "sys"},
        )

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def test_json_backed_adapters_render_valid_documents(self) -> None:
        for adapter_id, top_level_key in (
            ("claude_desktop", "mcpServers"),
            ("claude_code", "mcpServers"),
            ("cursor", "mcpServers"),
            ("vscode_copilot", "servers"),
            ("gemini_cli", "mcpServers"),
            ("opencode", "mcp"),
        ):
            with self.subTest(adapter=adapter_id):
                adapter = self._registry.get(adapter_id)
                location = adapter.locate(self._environment)
                inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
                rendered = adapter.render(self._server, inspection)
                findings = adapter.validate_render(rendered)
                self.assertEqual(findings, [])
                payload = json.loads(rendered.content or "{}")
                self.assertIn(top_level_key, payload)
                self.assertIn("exasol", payload[top_level_key])

    def test_codex_adapter_renders_valid_toml(self) -> None:
        adapter = self._registry.get("codex")
        location = adapter.locate(self._environment)
        inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
        rendered = adapter.render(self._server, inspection)
        findings = adapter.validate_render(rendered)
        self.assertEqual(findings, [])
        self.assertIn("[mcp_servers.exasol]", rendered.content or "")
        self.assertIn('command = "/tmp/uvx"', rendered.content or "")

    def test_codex_adapter_escapes_windows_command_paths(self) -> None:
        adapter = self._registry.get("codex")
        location = adapter.locate(self._environment)
        inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
        server = ServerDefinition(
            transport=DeploymentMode.STDIO,
            name="exasol",
            command=r"C:\Users\Example\.local\bin\uvx.exe",
            args=("exasol-mcp-server@1.10.1",),
            env={"EXA_DSN": "127.0.0.1:8563", "EXA_USER": "sys"},
        )
        rendered = adapter.render(server, inspection)
        findings = adapter.validate_render(rendered)
        self.assertEqual(findings, [])
        self.assertIn(
            'command = "C:\\\\Users\\\\Example\\\\.local\\\\bin\\\\uvx.exe"',
            rendered.content or "",
        )

    def test_opencode_adapter_renders_local_entry_shape(self) -> None:
        # OpenCode's entry shape is distinctive: the section key is "mcp", the
        # command and its args fold into ONE array, env goes under
        # "environment" (not "env"), and the server marks itself
        # type=local / enabled=true.
        adapter = self._registry.get("opencode")
        location = adapter.locate(self._environment)
        inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
        rendered = adapter.render(self._server, inspection)
        self.assertEqual(adapter.validate_render(rendered), [])
        payload = json.loads(rendered.content or "{}")
        entry = payload["mcp"]["exasol"]
        self.assertEqual(entry["type"], "local")
        self.assertTrue(entry["enabled"])
        self.assertEqual(entry["command"], ["/tmp/uvx", "exasol-mcp-server@1.10.1"])
        self.assertEqual(entry["environment"], {"EXA_DSN": "127.0.0.1:8563", "EXA_USER": "sys"})
        self.assertNotIn("args", entry)
        self.assertNotIn("env", entry)

    def test_opencode_adapter_preserves_unrelated_settings_on_removal(self) -> None:
        adapter = self._registry.get("opencode")
        location = adapter.locate(self._environment)
        assert location.path is not None
        location.path.parent.mkdir(parents=True, exist_ok=True)
        location.path.write_text(
            json.dumps({"theme": "opencode", "mcp": {"exasol": {"type": "local"}}}),
            encoding="utf-8",
        )
        inspection = adapter.inspect(location.path, "exasol")
        removal = adapter.render_removal(inspection, "exasol")
        self.assertFalse(removal.remove_file)
        payload = json.loads(removal.content or "{}")
        self.assertEqual(payload["theme"], "opencode")
        self.assertNotIn("exasol", payload.get("mcp", {}))

    def test_continue_adapter_renders_block_file_yaml(self) -> None:
        # Continue's block file is YAML with top-level name/version/schema and an
        # mcpServers LIST. The command/args stay bare; env values that YAML 1.1
        # would coerce (a bare "no" -> boolean, a bare port -> int) MUST be
        # quoted so they survive as strings.
        adapter = self._registry.get("continue")
        location = adapter.locate(self._environment)
        server = ServerDefinition(
            transport=DeploymentMode.STDIO,
            name="exasol",
            command="uvx",
            args=("exasol-mcp-server@1.10.1",),
            env={"EXA_DSN": "127.0.0.1:8563", "EXA_SSL_CERT_VALIDATION": "no"},
        )
        inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
        rendered = adapter.render(server, inspection)
        self.assertEqual(adapter.validate_render(rendered), [])
        content = rendered.content or ""
        self.assertIn("mcpServers:", content)
        self.assertIn("- name: exasol", content)
        self.assertIn("command: uvx", content)
        self.assertIn("- exasol-mcp-server@1.10.1", content)
        # YAML 1.1 coercion guards:
        self.assertIn('EXA_SSL_CERT_VALIDATION: "no"', content)
        self.assertIn('EXA_DSN: "127.0.0.1:8563"', content)

    def test_continue_adapter_removes_owned_file(self) -> None:
        adapter = self._registry.get("continue")
        location = adapter.locate(self._environment)
        inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
        removal = adapter.render_removal(inspection, "exasol")
        # The block file is kit-owned, so removal deletes it wholesale.
        self.assertTrue(removal.remove_file)
        self.assertIsNone(removal.content)

    def test_codex_adapter_preserves_quoted_table_keys(self) -> None:
        adapter = self._registry.get("codex")
        location = adapter.locate(self._environment)
        assert location.path is not None
        location.path.parent.mkdir(parents=True, exist_ok=True)
        location.path.write_text(
            '\n'.join(
                [
                    'notify = ["/tmp/example", "turn-ended"]',
                    '',
                    '[projects."/Users/example/workspace"]',
                    'trust_level = "trusted"',
                    '',
                    '[mcp_servers.node_repl]',
                    'args = []',
                    'command = "/tmp/node_repl"',
                ]
            )
            + '\n',
            encoding="utf-8",
        )
        inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
        rendered = adapter.render(self._server, inspection)
        findings = adapter.validate_render(rendered)
        self.assertEqual(findings, [])
        self.assertIn('[projects."/Users/example/workspace"]', rendered.content or "")
        self.assertIn("[mcp_servers.exasol]", rendered.content or "")

    def test_claude_code_adapter_preserves_cli_state(self) -> None:
        # ~/.claude.json holds unrelated Claude Code CLI state; the adapter must
        # edit only its mcpServers entry and never delete the file on removal.
        adapter = self._registry.get("claude_code")
        location = adapter.locate(self._environment)
        assert location.path is not None
        location.path.parent.mkdir(parents=True, exist_ok=True)
        state = {
            "installMethod": "brew",
            "projects": {"/Users/example/workspace": {"allowedTools": []}},
            "mcpServers": {"other": {"command": "/tmp/other", "args": []}},
        }
        location.path.write_text(json.dumps(state), encoding="utf-8")

        inspection = adapter.inspect(location.path, "exasol")
        rendered = adapter.render(self._server, inspection)
        self.assertEqual(adapter.validate_render(rendered), [])
        payload = json.loads(rendered.content or "{}")
        self.assertEqual(payload["installMethod"], "brew")            # state preserved
        self.assertIn("/Users/example/workspace", payload["projects"])
        self.assertIn("other", payload["mcpServers"])                 # foreign server kept
        self.assertIn("exasol", payload["mcpServers"])                # ours added

        location.path.write_text(rendered.content or "", encoding="utf-8")
        inspection = adapter.inspect(location.path, "exasol")
        removal = adapter.render_removal(inspection, "exasol")
        self.assertFalse(removal.remove_file)                         # never delete the file
        payload = json.loads(removal.content or "{}")
        self.assertEqual(payload["installMethod"], "brew")
        self.assertNotIn("exasol", payload.get("mcpServers", {}))
        self.assertIn("other", payload.get("mcpServers", {}))

    def test_claude_code_removal_keeps_file_even_when_empty(self) -> None:
        adapter = self._registry.get("claude_code")
        location = adapter.locate(self._environment)
        assert location.path is not None
        location.path.parent.mkdir(parents=True, exist_ok=True)
        only_ours = {"mcpServers": {"exasol": {"command": "/tmp/uvx", "args": []}}}
        location.path.write_text(json.dumps(only_ours), encoding="utf-8")
        inspection = adapter.inspect(location.path, "exasol")
        removal = adapter.render_removal(inspection, "exasol")
        self.assertFalse(removal.remove_file)
        self.assertEqual(json.loads(removal.content or "{}"), {})

    def test_vscode_copilot_renders_stdio_type(self) -> None:
        adapter = self._registry.get("vscode_copilot")
        location = adapter.locate(self._environment)
        inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
        rendered = adapter.render(self._server, inspection)
        self.assertEqual(adapter.validate_render(rendered), [])
        payload = json.loads(rendered.content or "{}")
        self.assertEqual(payload["servers"]["exasol"]["type"], "stdio")

    def test_gemini_cli_adapter_preserves_settings(self) -> None:
        # ~/.gemini/settings.json holds unrelated CLI settings; the adapter must
        # edit only its mcpServers entry and never delete the file on removal.
        adapter = self._registry.get("gemini_cli")
        location = adapter.locate(self._environment)
        assert location.path is not None
        location.path.parent.mkdir(parents=True, exist_ok=True)
        state = {"theme": "dark", "mcpServers": {"other": {"command": "/tmp/other", "args": []}}}
        location.path.write_text(json.dumps(state), encoding="utf-8")
        inspection = adapter.inspect(location.path, "exasol")
        rendered = adapter.render(self._server, inspection)
        self.assertEqual(adapter.validate_render(rendered), [])
        payload = json.loads(rendered.content or "{}")
        self.assertEqual(payload["theme"], "dark")
        self.assertIn("other", payload["mcpServers"])
        self.assertIn("exasol", payload["mcpServers"])
        location.path.write_text(rendered.content or "", encoding="utf-8")
        inspection = adapter.inspect(location.path, "exasol")
        removal = adapter.render_removal(inspection, "exasol")
        self.assertFalse(removal.remove_file)
        payload = json.loads(removal.content or "{}")
        self.assertEqual(payload["theme"], "dark")
        self.assertNotIn("exasol", payload.get("mcpServers", {}))

    def test_discover_reports_supported_adapters(self) -> None:
        for adapter_id in (
            "claude_desktop",
            "claude_code",
            "cursor",
            "codex",
            "vscode_copilot",
            "gemini_cli",
            "opencode",
            "continue",
        ):
            with self.subTest(adapter=adapter_id):
                adapter = self._registry.get(adapter_id)
                detection = adapter.detect(self._environment)
                self.assertTrue(detection.location.available)
                self.assertIn(detection.confidence, {"low", "medium", "high"})


if __name__ == "__main__":
    unittest.main()
