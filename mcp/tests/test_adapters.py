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
from mcp.runtime.exakit import DEFAULT_MCP_PACKAGE, DEFAULT_MCP_VERSION

# The package spec the kit actually renders into client configs. Derived from the
# runtime defaults rather than repeated as a literal, so a version bump in
# versions.json (which CI keeps in step with DEFAULT_MCP_VERSION) does not have
# to be chased through the fixtures.
MCP_SPEC = f"{DEFAULT_MCP_PACKAGE}@{DEFAULT_MCP_VERSION}"


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
            args=(MCP_SPEC,),
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

    def test_codex_adapter_renders_a_remote_server_as_url_only(self) -> None:
        """The shape `codex mcp add <name> --url <url>` writes: one `url` key."""
        adapter = self._registry.get("codex")
        self.assertTrue(adapter.describe_capabilities().supports_http)
        location = adapter.locate(self._environment)
        inspection = adapter.inspect(location.path, "dash-server")  # type: ignore[arg-type]
        server = ServerDefinition(
            transport=DeploymentMode.HTTP,
            name="dash-server",
            url="http://127.0.0.1:5100/mcp",
        )
        rendered = adapter.render(server, inspection)
        self.assertEqual(adapter.validate_render(rendered), [])
        import tomllib
        document = tomllib.loads(rendered.content or "")
        self.assertEqual(document["mcp_servers"]["dash-server"], {"url": "http://127.0.0.1:5100/mcp"})
        self.assertNotIn("command", rendered.content or "")
        self.assertNotIn("env", rendered.content or "")

    def test_codex_adapter_escapes_windows_command_paths(self) -> None:
        adapter = self._registry.get("codex")
        location = adapter.locate(self._environment)
        inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
        server = ServerDefinition(
            transport=DeploymentMode.STDIO,
            name="exasol",
            command=r"C:\Users\Example\.local\bin\uvx.exe",
            args=(MCP_SPEC,),
            env={"EXA_DSN": "127.0.0.1:8563", "EXA_USER": "sys"},
        )
        rendered = adapter.render(server, inspection)
        findings = adapter.validate_render(rendered)
        self.assertEqual(findings, [])
        self.assertIn(
            'command = "C:\\\\Users\\\\Example\\\\.local\\\\bin\\\\uvx.exe"',
            rendered.content or "",
        )

    def test_codex_adapter_keeps_every_existing_value_type(self) -> None:
        """Adding the kit's entry must not change anything already in config.toml.

        Regression: the ChatGPT app writes `startup_timeout_sec = 120.0` for its
        own MCP server, the kit re-wrote it as the string "120.0", and ChatGPT
        then refused to start ("invalid type: string \\"120.0\\", expected f64").
        """
        import tomllib
        adapter = self._registry.get("codex")
        location = adapter.locate(self._environment)
        path: Path = location.path  # type: ignore[assignment]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            'model = "gpt-5"\n'
            "when = 2026-11-10T09:00:00Z\n"
            "day = 2026-11-10\n"
            "ratio = 0.25\n"
            "big = 1e+20\n"
            "never = inf\n"
            'note = "tab\\there\\nline \\"q\\" \\\\ \\u0001"\n'
            "mixed = [1, [2.5, \"x\"], { k = 1.0 }]\n"
            "\n"
            "[mcp_servers.node_repl]\n"
            'command = "/Applications/ChatGPT.app/node_repl"\n'
            "startup_timeout_sec = 120.0\n"
            "tool_timeout_sec = 60\n"
            "\n"
            "[mcp_servers.node_repl.env]\n"
            'KEY = "1"\n'
            "\n"
            "[[profiles.list]]\n"
            'name = "a"\n'
            "\n"
            "[[profiles.list]]\n"
            'name = "b"\n'
            "[profiles.list.sub]\n"
            "x = 3.0\n"
            "\n"
            '[projects."/Users/someone/My Project"]\n'
            'trust_level = "trusted"\n',
            encoding="utf-8",
        )
        before = tomllib.loads(path.read_text(encoding="utf-8"))
        inspection = adapter.inspect(path, "exasol")
        rendered = adapter.render(self._server, inspection)
        self.assertEqual(adapter.validate_render(rendered), [])
        after = tomllib.loads(rendered.content or "")
        node = after["mcp_servers"]["node_repl"]
        self.assertIsInstance(node["startup_timeout_sec"], float)
        self.assertEqual(node["startup_timeout_sec"], 120.0)
        self.assertIn("startup_timeout_sec = 120.0", rendered.content or "")
        self.assertIsInstance(node["tool_timeout_sec"], int)
        exasol = after["mcp_servers"].pop("exasol")
        self.assertEqual(exasol["command"], "/tmp/uvx")
        self.assertEqual(after, before)
        # Removing the kit's entry again gives back the user's document.
        path.write_text(rendered.content or "", encoding="utf-8")
        removal = adapter.render_removal(adapter.inspect(path, "exasol"), "exasol")
        self.assertEqual(adapter.validate_render(removal), [])
        self.assertEqual(tomllib.loads(removal.content or ""), before)

    def test_codex_adapter_refuses_a_write_that_would_change_user_values(self) -> None:
        from mcp.adapters.base import RenderResult
        adapter = self._registry.get("codex")
        rendered = RenderResult(
            path=self._temp_dir / "codex" / "config.toml",
            content='startup_timeout_sec = "120.0"\n',
            managed_hash=None,
            entry_name="exasol",
            expected_document={"startup_timeout_sec": 120.0},
        )
        findings = adapter.validate_render(rendered)
        self.assertEqual([f.code for f in findings], ["lossy_render_output"])
        self.assertTrue(findings[0].blocking)

    def test_json_adapters_keep_the_users_values_order_and_text(self) -> None:
        """Adding the kit's entry changes nothing else in a JSON client config:
        no value changes type, keys keep the user's order, and non-ASCII text
        stays readable instead of turning into \\u escapes."""
        user = {
            "zeta": 1,
            "alpha": {
                "timeout": 120.0, "big": 12345678901234567890, "none": None, "flag": False,
                "name": "Müller ✓", "esc": "a\nb\t\"q\"\\", "list": [1, 2.5, "x", None, {"k": [1.0]}],
            },
            "mcpServers": {"other": {"command": "node", "args": ["a.js"], "timeout": 30.0}},
            "servers": {"other": {"type": "stdio", "command": "node"}},
            "mcp": {"other": {"type": "local", "command": ["node"]}},
        }
        for adapter_id in ("claude_desktop", "claude_code", "cursor", "vscode_copilot", "gemini_cli", "opencode"):
            with self.subTest(adapter=adapter_id):
                adapter = self._registry.get(adapter_id)
                path: Path = adapter.locate(self._environment).path  # type: ignore[assignment]
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(user, indent=2), encoding="utf-8")
                rendered = adapter.render(self._server, adapter.inspect(path, "exasol"))
                self.assertEqual(adapter.validate_render(rendered), [])
                content = rendered.content or ""
                self.assertIn("Müller ✓", content)
                after = json.loads(content)
                self.assertEqual(list(after)[:2], ["zeta", "alpha"])
                self.assertIsInstance(after["alpha"]["timeout"], float)
                for key in ("mcpServers", "servers", "mcp"):
                    after[key].pop("exasol", None)
                after.pop("$schema", None)  # OpenCode adds its schema reference.
                self.assertEqual(after, user)

    def test_continue_yaml_values_read_back_as_the_same_strings(self) -> None:
        """Every value the kit writes into Continue's YAML block must parse back
        as the identical string: no number, date, boolean or parse error."""
        from mcp.adapters.continue_dev import _yaml_scalar
        # Without PyYAML (CI): every risky value must come out double-quoted,
        # and a double-quoted scalar here is a JSON string, so it decodes exact.
        for risky in ("0x1F", "0b101", "1_000", "2026-11-10", ".inf", "@scope/pkg", "-", "no", "y", "8563", "line\nbreak", ""):
            with self.subTest(risky=risky):
                quoted = _yaml_scalar(risky)
                self.assertTrue(quoted.startswith('"'), quoted)
                self.assertEqual(json.loads(quoted), risky)
        try:
            import yaml  # type: ignore[import-untyped]
        except ModuleNotFoundError:
            return
        values = [
            "no", "y", "n", "on", "~", "null", "8563", "1.0", "0x1F", "0o17", "0b101", "1_000",
            "2026-11-10", "2026-11-10T09:00:00Z", ".inf", ".NaN", "@scope/pkg", "-", "a#b",
            "a: b", "Müller", "C:\\Users\\x", "line\nbreak", "tab\tx", "", "!tag", "*a", "&a",
            "exasol", "exasol-mcp-server@1.2.0", "/usr/bin/uvx", "127.0.0.1:8563", "\x01",
        ]
        for value in values:
            with self.subTest(value=value):
                parsed = yaml.safe_load("k: " + _yaml_scalar(value))["k"]
                self.assertIsInstance(parsed, str)
                self.assertEqual(parsed, value)
        self.assertEqual(_yaml_scalar("exasol"), "exasol")
        self.assertEqual(_yaml_scalar("EXA_DSN"), "EXA_DSN")

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
        self.assertEqual(entry["command"], ["/tmp/uvx", MCP_SPEC])
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
            args=(MCP_SPEC,),
            env={"EXA_DSN": "127.0.0.1:8563", "EXA_SSL_CERT_VALIDATION": "no"},
        )
        inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
        rendered = adapter.render(server, inspection)
        self.assertEqual(adapter.validate_render(rendered), [])
        content = rendered.content or ""
        self.assertIn("mcpServers:", content)
        self.assertIn("- name: exasol", content)
        self.assertIn("command: uvx", content)
        self.assertIn(f"- {MCP_SPEC}", content)
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

    def test_vscode_copilot_removal_keeps_the_file(self) -> None:
        """mcp.json is VS Code's, not the kit's: removing the last kit entry
        leaves an empty servers table, never a deleted file. An uninstall used
        to remove the whole file once the kit's entries were the last in it."""
        adapter = self._registry.get("vscode_copilot")
        location = adapter.locate(self._environment)
        inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
        rendered = adapter.render(self._server, inspection)
        location.path.parent.mkdir(parents=True, exist_ok=True)  # type: ignore[union-attr]
        location.path.write_text(rendered.content or "", encoding="utf-8")  # type: ignore[union-attr]
        inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
        removal = adapter.render_removal(inspection, "exasol")
        self.assertFalse(removal.remove_file)
        self.assertEqual(json.loads(removal.content or "{}"), {"servers": {}})

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

    def _env_without_overrides(self, home, path=""):
        """An environment with NO config-path overrides: detection runs the real rule.

        EXAKIT_MCP_APP_ROOTS IS STILL SET, and that is not an exception to the
        "no overrides" above: it is the sandbox control, not a config path.
        Detection on darwin counts an installed ``<name>.app`` as evidence, and
        without this the probe reads the DEVELOPER'S OWN /Applications - so
        `test_kit_only_config_is_not_evidence_of_the_client` failed on any
        machine that happened to have Cursor installed, and passed everywhere
        else. It was measuring the machine, not the rule. Pointed at an empty
        directory, these tests answer the same way on every host.
        """
        app_roots = self._temp_dir / "no-applications"
        app_roots.mkdir(parents=True, exist_ok=True)
        return ExecutionEnvironment(
            os_name="darwin",
            home=home,
            env={"PATH": path, "EXAKIT_MCP_APP_ROOTS": str(app_roots)},
            cwd=home,
        )

    def test_kit_only_config_is_not_evidence_of_the_client(self) -> None:
        """THE BUG: detection was 'the config file exists'. The kit writes that
        file, so a client it had configured once counted as installed forever --
        including clients that were never on the machine."""
        home = self._temp_dir / "home-kit-only"
        (home / ".cursor").mkdir(parents=True)
        (home / ".cursor" / "mcp.json").write_text(
            json.dumps({"mcpServers": {"exasol": {"command": "uvx", "args": ["exasol-mcp-server@2.2.0"]}}}),
            encoding="utf-8",
        )
        detection = self._registry.get("cursor").detect(self._env_without_overrides(home))
        self.assertFalse(detection.detected)
        self.assertIn("not evidence", " ".join(detection.evidence))

    def test_config_with_the_users_own_settings_is_evidence(self) -> None:
        home = self._temp_dir / "home-own-settings"
        (home / ".gemini").mkdir(parents=True)
        (home / ".gemini" / "settings.json").write_text(
            json.dumps({"theme": "dark", "mcpServers": {"exasol": {"command": "uvx"}}}), encoding="utf-8"
        )
        detection = self._registry.get("gemini_cli").detect(self._env_without_overrides(home))
        self.assertTrue(detection.detected)
        self.assertEqual(detection.confidence, "high")

    def test_a_program_on_path_is_evidence_even_with_no_config(self) -> None:
        home = self._temp_dir / "home-program"
        bindir = home / "bin"
        bindir.mkdir(parents=True)
        program = bindir / "codex"
        program.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        program.chmod(0o755)
        detection = self._registry.get("codex").detect(self._env_without_overrides(home, path=str(bindir)))
        self.assertTrue(detection.detected)
        self.assertEqual(detection.confidence, "medium")   # installed, no config yet
        # And a kit-only config beside a real program reads as high.
        (home / ".codex").mkdir()
        (home / ".codex" / "config.toml").write_text('[mcp_servers.exasol]\ncommand = "uvx"\n', encoding="utf-8")
        detection = self._registry.get("codex").detect(self._env_without_overrides(home, path=str(bindir)))
        self.assertTrue(detection.detected)
        self.assertEqual(detection.confidence, "high")

    def test_the_clients_own_files_beside_a_kit_only_config_are_evidence(self) -> None:
        home = self._temp_dir / "home-own-files"
        (home / ".continue" / "mcpServers").mkdir(parents=True)
        (home / ".continue" / "mcpServers" / "exasol-starter-kit.yaml").write_text("name: exasol\n", encoding="utf-8")
        env = self._env_without_overrides(home)
        self.assertFalse(self._registry.get("continue").detect(env).detected)   # the block file alone: the kit's
        (home / ".continue" / "config.yaml").write_text("name: mine\n", encoding="utf-8")
        self.assertTrue(self._registry.get("continue").detect(env).detected)    # Continue's own config: installed

    def test_an_override_path_keeps_the_file_rule(self) -> None:
        """An explicit config path is the caller vouching for the client."""
        (self._temp_dir / "cursor").mkdir(parents=True, exist_ok=True)   # the overridden path's directory
        detection = self._registry.get("cursor").detect(self._environment)
        self.assertTrue(detection.detected)
        self.assertIn("path overridden", " ".join(detection.evidence))

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
