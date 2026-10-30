"""Selection validation and Python batch control stay independent of the UI."""

from __future__ import annotations

import json
import io
import os
import sys
import tempfile
import unittest
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

    def test_invalid_notebook_frontends_stop_entire_batch_before_install(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            ctx = self.context(Path(temp))
            with patch.dict(os.environ, {"EXAKIT_NOTEBOOK_FRONTENDS": "jupyterlab,unknown-tool"}), \
                 patch.object(market_apply, "invoke") as invoke:
                with self.assertRaisesRegex(AddonFailure, "Unknown or repeated notebook frontend"):
                    market_apply.apply(ctx, "dash-server,notebook", lambda _: None)
            invoke.assert_not_called()

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


if __name__ == "__main__":
    unittest.main()
