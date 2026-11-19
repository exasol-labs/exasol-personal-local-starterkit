"""Selection validation and Python batch control stay independent of the UI."""

from __future__ import annotations

import json
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
import apply as market_apply  # noqa: E402
from integration import install_addon_skills, register_autostart  # noqa: E402
from model import CatalogError, load_addons  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402


class ApplyTest(unittest.TestCase):
    def context(self, home: Path) -> KitContext:
        (home / "manifest.json").write_text('{"components":{}}\n', encoding="utf-8")
        return KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))

    def test_selection_is_validated_in_full_before_any_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            ctx = self.context(Path(temp))
            with patch.object(market_apply, "invoke") as invoke:
                with self.assertRaisesRegex(CatalogError, "unknown add-on"):
                    market_apply.apply(ctx, "dash-server,unknown-addon", lambda _: None)
            invoke.assert_not_called()

    def test_disabled_addon_in_csv_stops_before_first_install(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            ctx = self.context(Path(temp))
            addons = [replace(addon, visible=False) if addon.id == "dbt-exasol" else addon
                      for addon in load_addons(ROOT)]
            with patch.object(market_apply, "load_addons", return_value=addons), \
                 patch.object(market_apply, "invoke") as invoke:
                with self.assertRaisesRegex(CatalogError, "dbt-exasol is disabled"):
                    market_apply.apply(ctx, "dash-server,dbt-exasol", lambda _: None)
            invoke.assert_not_called()

    def test_each_tool_of_an_addon_streams_its_own_row(self) -> None:
        """The producer of an add-on's child rows (audit QAT-02): after the add-on's own done, one record per tool
        that settled, in the line format the shell and PowerShell tables read; a tool still running gets none."""
        with tempfile.TemporaryDirectory() as temp:
            ctx = self.context(Path(temp))

            def invoke(_root, addon_id, operation, *, ctx):
                if operation == "tool-outcomes":
                    return 0, [("local", "done", "installed 1.0"), ("remote", "skipped", "skipped"),
                               ("later", "running", "never a row")]
                return 0, "ready" if operation == "summary" else None

            out = io.StringIO()
            with patch.object(market_apply, "invoke", side_effect=invoke), \
                 patch("addons.dbt_exasol.tool_outcomes", create=True, new=lambda ctx: []), \
                 patch.object(market_apply, "install_addon_skills", return_value=[]), \
                 patch.object(market_apply, "register_autostart", return_value=False), \
                 patch.object(market_apply.KitContext, "from_environment", return_value=ctx), \
                 redirect_stdout(out):
                self.assertEqual(0, market_apply.main(["dbt-exasol", "--stream"]))
            lines = [line for line in out.getvalue().splitlines() if line.startswith("@@EXAKIT|dbt-exasol")]
            done = next(i for i, line in enumerate(lines) if line.startswith("@@EXAKIT|dbt-exasol|done|"))
            self.assertEqual(["@@EXAKIT|dbt-exasol:local|done|installed 1.0|0",
                              "@@EXAKIT|dbt-exasol:remote|skipped|skipped|0"], lines[done + 1:])

    def test_failure_does_not_strand_the_next_addon(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            ctx = self.context(Path(temp))
            events = []
            operations = []

            def invoke(_root, addon_id, operation, *, ctx):
                operations.append((addon_id, operation))
                if addon_id == "dash-server" and operation == "install":
                    raise AddonFailure("download failed")
                return 0, "ready" if operation == "summary" else None

            with patch.object(market_apply, "invoke", side_effect=invoke), \
                 patch.object(market_apply, "install_addon_skills", return_value=[]), \
                 patch.object(market_apply, "register_autostart", return_value=False):
                success = market_apply.apply(ctx, "dash-server,dbt-exasol", events.append)
            self.assertFalse(success)
            self.assertIn(("dbt-exasol", "install"), operations)
            self.assertEqual(["failed", "done"], [event.phase for event in events if event.phase in ("failed", "done")])

    def test_activity_row_is_restored_after_batch_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            ctx = self.context(Path(temp))
            with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_ACTIVITY_ROW": "prior",
                                      "EXAKIT_ADDON_TABLE_IDS": "dash-server"}), \
                 patch.object(market_apply, "invoke", side_effect=AddonFailure("download failed")):
                self.assertFalse(market_apply.apply(ctx, "dash-server", lambda _: None))
                self.assertEqual("prior", os.environ["EXAKIT_MARKETPLACE_ACTIVITY_ROW"])

    def test_validation_and_start_failure_leave_installed_receipt_truthful(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            ctx = self.context(Path(temp))
            events = []

            def invoke(_root, _addon_id, operation, *, ctx):
                if operation == "install":
                    ctx.manifest.set_many({"components.dash_server.ownership": "kit"})
                if operation == "validate":
                    return 1, None
                if operation == "start":
                    raise AddonFailure("port busy")
                return 0, "dashboards at localhost" if operation == "summary" else None

            with patch.object(market_apply, "invoke", side_effect=invoke), \
                 patch.object(market_apply, "install_addon_skills", return_value=[]), \
                 patch.object(market_apply, "register_autostart", return_value=False):
                success = market_apply.apply(ctx, "dash-server", events.append)
            self.assertTrue(success)
            self.assertEqual("kit", ctx.manifest.get("components.dash_server.ownership"))
            self.assertEqual(2, sum(event.phase == "warning" for event in events))
            self.assertEqual("done", events[-1].phase)

    def test_json_mode_keeps_addon_chatter_off_stdout(self) -> None:
        out, err = io.StringIO(), io.StringIO()

        def install(_ctx, _ids, _emit):
            print("package detail")
            return True

        with patch.object(market_apply, "apply", side_effect=install), \
             redirect_stdout(out), redirect_stderr(err):
            code = market_apply.main(["dash-server", "--json"])
        self.assertEqual(0, code)
        self.assertEqual({"ok": True, "events": []}, json.loads(out.getvalue()))
        self.assertIn("package detail", err.getvalue())


class IntegrationTest(unittest.TestCase):
    def context(self, root: Path, home: Path) -> KitContext:
        home.mkdir(parents=True)
        (home / "manifest.json").write_text(json.dumps({"components": {"skills": {"installed": []}}}), encoding="utf-8")
        return KitContext(root, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))

    def test_user_skill_is_preserved_and_not_claimed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            root, home, discovery = path / "root", path / "kit", path / "skills"
            source = root / "skills" / "dash-server"
            source.mkdir(parents=True)
            (source / "SKILL.md").write_text("---\nname: dash-server\naddon: dash-server\n---\nkit\n")
            (root / "versions.json").write_text('{"components":{"skills":{"version":"1"}}}')
            installed = discovery / "dash-server"
            installed.mkdir(parents=True)
            (installed / "SKILL.md").write_text("user")
            ctx = self.context(root, home)
            with patch.dict(os.environ, {"EXAKIT_SKILL_ROOTS": str(discovery)}):
                self.assertEqual([], install_addon_skills(ctx, "dash-server"))
            self.assertEqual("user", (installed / "SKILL.md").read_text())
            self.assertEqual([], ctx.manifest.get("components.skills.installed"))

    def test_a_user_folder_in_one_root_is_kept_and_the_other_root_gets_the_marked_copy(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            root, home, mine, other = path / "root", path / "kit", path / "claude", path / "agents"
            source = root / "skills" / "dash-server"
            source.mkdir(parents=True)
            (source / "SKILL.md").write_text("---\nname: dash-server\naddon: dash-server\n---\nkit\n")
            (root / "versions.json").write_text('{"components":{"skills":{"version":"7"}}}')
            (mine / "dash-server").mkdir(parents=True)
            (mine / "dash-server" / "SKILL.md").write_text("user")
            ctx = self.context(root, home)
            # Recorded by an older kit's presence-based list: still not the kit's without the mark.
            ctx.manifest.set_many({"components.skills.installed": ["dash-server"]})
            separator = ";" if os.name == "nt" else " "             # as _skill_roots splits them
            with patch.dict(os.environ, {"EXAKIT_SKILL_ROOTS": f"{mine}{separator}{other}"}):
                self.assertEqual(["dash-server"], install_addon_skills(ctx, "dash-server"))
                self.assertEqual([], install_addon_skills(ctx, "dash-server"))     # nothing changes the second time
            self.assertEqual("user", (mine / "dash-server" / "SKILL.md").read_text())
            self.assertFalse((mine / "dash-server" / ".exakit-owned").exists())
            self.assertEqual("7\n", (other / "dash-server" / ".exakit-owned").read_text())

    def test_the_add_on_skill_kit_0_2_5_placed_is_the_kits_and_a_user_folder_stays_the_users(self) -> None:
        """The 0.2.5 -> 0.3.0 upgrade: kit 0.2.5 placed tests/lib/dash-server-skill-0.2.5.md (its dash-server skill)
        with no mark and, on Windows, no record of it; the update read it as the user's and kept it stale. It is the
        kit's when the add-on is the kit's (LF or CRLF); a folder with anything else in it, or an add-on the kit did
        not install, stays the user's."""
        shipped = (ROOT / "tests" / "lib" / "dash-server-skill-0.2.5.md").read_bytes()
        for case, content, extra, owner, adopted in (("0.2.5 copy", shipped, None, "kit", True),
                                                     ("0.2.5 copy, CRLF", shipped.replace(b"\n", b"\r\n"), None, "kit", True),
                                                     ("with the user's notes", shipped, "notes.md", "kit", False),
                                                     ("edited by the user", shipped + b"mine\n", None, "kit", False),
                                                     ("an add-on that is not the kit's", shipped, None, "user", False)):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temp:
                path = Path(temp)
                root, home, discovery = path / "root", path / "kit", path / "skills"
                source = root / "skills" / "dash-server"
                source.mkdir(parents=True)
                # Bytes, not text: Windows' text mode would write CRLF and the check below reads bytes.
                (source / "SKILL.md").write_bytes(b"---\nname: dash-server\naddon: dash-server\n---\nkit 0.3.0\n")
                (root / "versions.json").write_text('{"components":{"skills":{"version":"7"}}}')
                (root / "marketplace").mkdir()
                shutil.copy2(ROOT / "marketplace" / "earlier-skill-copies.txt", root / "marketplace")
                placed = discovery / "dash-server"
                placed.mkdir(parents=True)
                (placed / "SKILL.md").write_bytes(content)
                if extra:
                    (placed / extra).write_text("mine")
                ctx = self.context(root, home)
                ctx.manifest.set_many({"components.dash_server.ownership": owner, "components.skills.marked": True})
                with patch.dict(os.environ, {"EXAKIT_SKILL_ROOTS": str(discovery)}):
                    install_addon_skills(ctx, "dash-server")
                self.assertEqual(adopted, (placed / ".exakit-owned").is_file())
                self.assertEqual(adopted, (placed / "SKILL.md").read_bytes().endswith(b"kit 0.3.0\n"))

    def test_kit_skill_is_copied_and_recorded(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            root, home, discovery = path / "root", path / "kit", path / "skills"
            source = root / "skills" / "dash-server"
            source.mkdir(parents=True)
            (source / "SKILL.md").write_text("---\nname: dash-server\naddon: dash-server\n---\nkit\n")
            (root / "versions.json").write_text('{"components":{"skills":{"version":"1"}}}')
            ctx = self.context(root, home)
            with patch.dict(os.environ, {"EXAKIT_SKILL_ROOTS": str(discovery)}):
                self.assertEqual(["dash-server"], install_addon_skills(ctx, "dash-server"))
            self.assertIn("kit", (discovery / "dash-server" / "SKILL.md").read_text())
            self.assertEqual(["dash-server"], ctx.manifest.get("components.skills.installed"))

    def test_mac_autostart_uses_argv_in_plist_with_spaces(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            ctx = self.context(path / "root", path / "kit")
            ctx.manifest.set_many({"autostart.enabled": True})
            launch_dir = path / "Agent Files"
            command = [str(path / "Program Files" / "dash-server"), "--port", "5100"]
            module = type("Addon", (), {"autostart_command": staticmethod(lambda _: command)})
            with patch.object(sys, "platform", "darwin"), \
                 patch.dict(os.environ, {"EXAKIT_LAUNCHAGENT_DIR": str(launch_dir)}), \
                 patch("integration._run_quiet", return_value=True):
                self.assertTrue(register_autostart(ctx, "dash-server", module))
            import plistlib
            doc = plistlib.loads((launch_dir / "com.exasol.exakit.dash-server.plist").read_bytes())
            self.assertEqual(command, doc["ProgramArguments"])

    def test_every_addon_service_can_join_the_boot_set(self) -> None:
        """An add-on with a status hook counts as a service: `exakit status` calls autostart enabled only when every
        service is registered. One without an autostart command kept it "disabled" on every kit that installed
        it."""
        import ast
        for path in sorted((ROOT / "marketplace" / "addons").glob("*.py")):
            names = {node.name for node in ast.parse(path.read_text(encoding="utf-8")).body if isinstance(node, ast.FunctionDef)}
            if "status" in names:
                with self.subTest(addon=path.stem):
                    self.assertIn("autostart_command", names)



class McpEndpointTest(unittest.TestCase):
    """Audit MKT-01: installing Dash Server registers its MCP control plane with the AI clients already connected,
    and removing it takes that entry out again (the exasol entry stays). Until 0.2.5 the shell module did both; after
    the move to Python nothing did. Real `python -m mcp` runs against a sandboxed Cursor config, through the same
    apply and service entry points the bash and PowerShell launchers call."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.home = base / "kit"
        credentials = self.home / "credentials"
        credentials.mkdir(parents=True)
        (credentials / "db_password").write_text("starter-secret\n", encoding="utf-8")
        (credentials / "mcp_password").write_text("readonly-secret\n", encoding="utf-8")
        self.cursor = base / "cursor" / "mcp.json"
        self.gemini = base / "gemini" / "settings.json"
        for path in (self.cursor, self.gemini):
            path.parent.mkdir(parents=True)
        env = patch.dict(os.environ, {"CURSOR_MCP_CONFIG_PATH": str(self.cursor),
                                      "GEMINI_CLI_CONFIG_PATH": str(self.gemini)})
        env.start()
        self.addCleanup(env.stop)
        for name in ("EXAKIT_DASH_SERVER_PORT", "EXAKIT_DASH_SERVER_MCP_NAME"):
            os.environ.pop(name, None)
        (self.home / "manifest.json").write_text(json.dumps({
            "manifest_version": 1,
            "runtime": {"type": "personal", "dsn": "exa-local", "user": "sys",
                        "password_file": str(credentials / "db_password")},
            "components": {"mcp_server": {"backend": "sidecar", "url": "http://127.0.0.1:4896/mcp",
                                          "connection": {"user": "mcp_readonly", "validated": True,
                                                         "password_file": str(credentials / "mcp_password")}}},
        }), encoding="utf-8")
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", Manifest(self.home / "manifest.json"), Path("uv"))

    def connect_cursor(self) -> None:
        """The AI-bridge step of the install (and `exakit mcp-setup`): Cursor connected."""
        result = subprocess.run([sys.executable, "-m", "mcp", "setup-runtime-clients", "--runtime-root",
                                 str(self.home), "--clients", "cursor"],
                                cwd=ROOT, capture_output=True, text=True, check=False)
        self.assertEqual(0, result.returncode, result.stderr)

    def servers(self) -> dict:
        return json.loads(self.cursor.read_text(encoding="utf-8"))["mcpServers"]

    def install_dash_server(self) -> list:
        events = []

        def invoke(_root, addon_id, operation, *, ctx):
            if operation == "install":
                ctx.manifest.set_many({"components.dash_server.version": "0.2.1",
                                       "components.dash_server.port": 5137,
                                       "components.dash_server.ownership": "kit"})
            return 0, None

        with patch.object(market_apply, "invoke", side_effect=invoke), \
             patch.object(market_apply, "install_addon_skills", return_value=[]), \
             patch.object(market_apply, "register_autostart", return_value=False):
            self.assertTrue(market_apply.apply(self.ctx, "dash-server", events.append))
        return events

    def test_install_registers_the_endpoint_and_uninstall_removes_it(self) -> None:
        self.connect_cursor()                                       # first, as on a fresh install
        self.assertEqual(["exasol"], list(self.servers()))
        events = self.install_dash_server()
        self.assertEqual([], [event.detail for event in events if event.phase == "warning"])
        self.assertEqual({"url": "http://127.0.0.1:5137/mcp"}, self.servers().get("dash-server"))
        self.assertFalse(self.gemini.exists())                      # never a client the user did not connect
        self.assertIn("exasol", self.servers())

        import service
        _, module = service._module(ROOT, "dash-server")

        def uninstall(ctx, *, dry_run=False):
            if not dry_run:
                ctx.manifest.delete("components.dash_server")
            return []

        with patch.object(module, "uninstall", side_effect=uninstall):
            service.invoke(ROOT, "dash-server", "uninstall", dry_run=True, ctx=self.ctx)
            self.assertIn("dash-server", self.servers())             # a preview changes nothing
            service.invoke(ROOT, "dash-server", "uninstall", ctx=self.ctx)
        self.assertEqual(["exasol"], list(self.servers()))

    def test_removing_the_addon_leaves_a_client_file_it_cannot_parse_and_names_it(self) -> None:
        self.connect_cursor()
        self.install_dash_server()
        damaged = b"// my servers\n" + self.cursor.read_bytes()        # Cursor reads it; the kit cannot
        self.cursor.write_bytes(damaged)
        import integration
        import service
        _, module = service._module(ROOT, "dash-server")
        warning = integration.unregister_mcp_endpoint(self.ctx, "dash-server", module)
        self.assertEqual(damaged, self.cursor.read_bytes())          # not deleted, not rewritten
        self.assertIn(str(self.cursor), warning)
        self.assertIn("'dash-server'", warning)
        self.assertIn("by hand", warning)

    def test_a_client_connected_after_the_install_gets_the_endpoint_too(self) -> None:
        events = self.install_dash_server()
        self.assertEqual([], [event.detail for event in events if event.phase == "warning"])
        self.assertFalse(self.cursor.exists() or self.gemini.exists())   # nobody connected: no config written
        self.connect_cursor()                                       # the AI-bridge step after it, or exakit mcp-setup
        self.assertEqual({"url": "http://127.0.0.1:5137/mcp"}, self.servers().get("dash-server"))

    def test_a_client_that_cannot_take_a_remote_endpoint_is_no_warning(self) -> None:
        desktop = Path(self.temp.name) / "claude-desktop" / "claude_desktop_config.json"
        desktop.parent.mkdir()
        with patch.dict(os.environ, {"CLAUDE_DESKTOP_CONFIG_PATH": str(desktop)}):
            result = subprocess.run([sys.executable, "-m", "mcp", "setup-runtime-clients", "--runtime-root",
                                     str(self.home), "--clients", "claude_desktop"],
                                    cwd=ROOT, capture_output=True, text=True, check=False)
            self.assertEqual(0, result.returncode, result.stderr)
            events = self.install_dash_server()
        self.assertEqual([], [event.detail for event in events if event.phase == "warning"])
        self.assertNotIn("dash-server", json.loads(desktop.read_text(encoding="utf-8"))["mcpServers"])

    def test_an_addon_without_an_endpoint_runs_no_mcp_command(self) -> None:
        import integration
        with patch.object(integration.subprocess, "run") as run:
            self.assertEqual("", integration.register_mcp_endpoint(self.ctx, "json-tables", object()))
            self.assertEqual("", integration.unregister_mcp_endpoint(self.ctx, "json-tables", object()))
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
