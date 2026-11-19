"""The shared add-on dispatcher preserves one JSON result and ownership gates."""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
import service  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402


class ServiceTest(unittest.TestCase):
    def _context(self, home: Path, components: dict | None = None) -> KitContext:
        (home / "manifest.json").write_text(json.dumps({"components": components or {}}), encoding="utf-8")
        return KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))

    def test_json_progress_goes_to_stderr(self) -> None:
        output, progress = io.StringIO(), io.StringIO()

        def invoke(*_args, **_kwargs):
            print("  • Installing an add-on")
            return 0, "ready"

        with patch.object(service, "invoke", side_effect=invoke), \
             redirect_stdout(output), redirect_stderr(progress):
            code = service.main(["dbt-exasol", "install", "--json"])
        self.assertEqual(0, code)
        self.assertEqual("ready", json.loads(output.getvalue())["value"])
        self.assertIn("Installing an add-on", progress.getvalue())

    def test_missing_install_refused_before_module_action(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
            with patch.object(KitContext, "from_environment", return_value=ctx), \
                 patch.object(service, "_module") as module:
                module.return_value = (next(row for row in service.load_addons(ROOT) if row.id == "dash-server"),
                                       type("Addon", (), {"install": staticmethod(lambda _ctx: None)}))
                with self.assertRaisesRegex(AddonFailure, "No starter kit installation"):
                    service.invoke(ROOT, "dash-server", "install")

    def test_external_component_is_never_claimed_by_install_dispatch(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = self._context(home, {"json_tables": {"ownership": "user"}})
            called = []
            module = type("Addon", (), {"install": staticmethod(lambda _ctx: called.append("install"))})
            with patch.object(KitContext, "from_environment", return_value=ctx), \
                 patch.object(service, "_module", return_value=(
                     next(row for row in service.load_addons(ROOT) if row.id == "json-tables"), module)):
                with self.assertRaisesRegex(AddonFailure, "managed outside the kit"):
                    service.invoke(ROOT, "json-tables", "install")
            self.assertEqual([], called)
            self.assertEqual("user", ctx.manifest.get("components.json_tables.ownership"))

    def test_every_addon_preserves_user_unknown_and_untracked_receipts(self) -> None:
        for addon in service.load_addons(ROOT):
            for owner in ("user", "unknown", None):
                for operation in ("update", "uninstall"):
                    with self.subTest(addon=addon.id, owner=owner, operation=operation), \
                         tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {}, clear=True):
                        home = Path(temp)
                        receipt = {"version": "99.0.0"}
                        if owner is not None:
                            receipt["ownership"] = owner
                        ctx = self._context(home, {addon.id.replace("-", "_"): receipt})
                        sentinel = home / "user-files" / "keep.txt"
                        sentinel.parent.mkdir()
                        sentinel.write_text("personal data")
                        before = ctx.manifest.path.read_bytes()
                        _, module = service._module(ROOT, addon.id)
                        with patch.object(module, "install", side_effect=AssertionError("external install")), \
                             patch.object(KitContext, "run_logged", side_effect=AssertionError("external command")):
                            with self.assertRaises(AddonFailure):
                                service.invoke(ROOT, addon.id, operation, ctx=ctx)
                        self.assertEqual(before, ctx.manifest.path.read_bytes())
                        self.assertEqual("personal data", sentinel.read_text())

    def test_external_install_race_cannot_report_success(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = self._context(home)
            module = type("Addon", (), {"system_present": staticmethod(lambda _ctx: False),
                                         "install": staticmethod(lambda _ctx: None)})
            with patch.object(KitContext, "from_environment", return_value=ctx), \
                 patch.object(service, "_module", return_value=(
                     next(row for row in service.load_addons(ROOT) if row.id == "json-tables"), module)):
                with self.assertRaisesRegex(AddonFailure, "was not installed by the kit"):
                    service.invoke(ROOT, "json-tables", "install")
            self.assertIsNone(ctx.manifest.get("components.json_tables.ownership"))


class LegacyReceiptTest(unittest.TestCase):
    """Audit UPG-01: kit 0.2.5 recorded Dash Server and JSON Tables without an ownership key (setup/lib/dash-server.sh
    and json-tables.sh at 14df2ecb). The shells read such a receipt as the kit's when its venv lies under the kit home;
    the add-on modules refused it, so after `exakit update` neither add-on could be updated or removed, and removing
    the kit left `exasol-json-tables` on PATH. These receipts are the exact shape 0.2.5 wrote."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.home, self.bin = base / ".exasol-starter-kit", base / ".local" / "bin"
        files = {
            "dash_venv": self.home / "dash-server-venv" / "bin" / "python",
            "dash_command": self.bin / "dash-server",
            "dash_instance": self.home / "dash-server" / "instance" / "app.json",
            "json_venv": self.home / "json-tables-venv" / "bin" / "python",
            "json_engine": self.home / "json-tables" / "libexec" / "json_to_parquet",
            "json_command": self.bin / "exasol-json-tables",
            "scheduler_engine": self.home / "exasol-scheduler" / "libexec" / "exasol_scheduler",
            "scheduler_command": self.bin / ("exasol-scheduler.cmd" if os.name == "nt" else "exasol-scheduler"),
        }
        for path in files.values():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture\n", encoding="utf-8")
        self.files = files
        components = {
            "dash_server": {"version": "0.2.1", "venv": str(self.home / "dash-server-venv"),
                            "python": str(files["dash_venv"]), "command": str(files["dash_command"]),
                            "port": 5100, "instance": str(self.home / "dash-server" / "instance"), "validated": True},
            "json_tables": {"version": "0.4.1", "venv": str(self.home / "json-tables-venv"),
                            "python": str(files["json_venv"]), "engine": str(files["json_engine"]),
                            "command": str(files["json_command"]), "validated": True},
            # Audit STA-01: the two 0.2.5 receipts that name no venv, home, python or path
            # (setup/lib/exasol-scheduler.sh :578-584 and exasol-vscode.sh :403-405 at 14df2ecb).
            "exasol_scheduler": {"version": "0.4.1", "engine": str(files["scheduler_engine"]),
                                 "db_user": "scheduler_svc", "schema": "SCHED", "bootstrap_revoked": True,
                                 "validated": True},
            "exasol_vscode": {"version": "1.9.1", "extension_id": "exasol.exasol-vscode",
                              "code_cli": "/usr/local/bin/code", "validated": True},
        }
        (self.home / "manifest.json").write_text(json.dumps({"kit": {"version": "0.2.5"}, "components": components},
                                                            indent=2), encoding="utf-8")
        self.ctx = KitContext(ROOT, self.home, self.bin, Manifest(self.home / "manifest.json"), Path("uv"))
        patcher = patch.object(KitContext, "from_environment", return_value=self.ctx)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_service(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = service.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def stored(self, key: str):
        return json.loads(self.ctx.manifest.path.read_text(encoding="utf-8"))["components"][key].get("ownership")

    def test_uninstall_dry_run_previews_and_writes_nothing(self) -> None:
        before = self.ctx.manifest.path.read_bytes()
        code, out, err = self.run_service("dash-server", "uninstall", "--dry-run")
        self.assertEqual(0, code, err)
        self.assertIn(str(self.files["dash_command"]), out)
        self.assertIn("the 'dash-server' MCP entry in each AI client that has it", out)   # the removal takes it out
        code, out, err = self.run_service("json-tables", "uninstall", "--dry-run")
        self.assertEqual(0, code, err)
        self.assertIn(str(self.files["json_command"]), out)
        self.assertEqual(before, self.ctx.manifest.path.read_bytes())

    def test_update_succeeds_and_records_kit_ownership(self) -> None:
        _, dash = service._module(ROOT, "dash-server")
        _, tables = service._module(ROOT, "json-tables")
        with patch.object(dash, "package_version", side_effect=lambda ctx: dash._target(ctx)):
            code, _, err = self.run_service("dash-server", "update")
        self.assertEqual(0, code, err)
        self.assertEqual("kit", self.stored("dash_server"))
        with patch.object(tables, "install", return_value=None), patch.object(tables, "validate", return_value=True):
            code, _, err = self.run_service("json-tables", "update")
        self.assertEqual(0, code, err)
        self.assertEqual("kit", self.stored("json_tables"))

    def test_uninstall_removes_the_json_tables_command(self) -> None:
        code, _, err = self.run_service("json-tables", "uninstall")
        self.assertEqual(0, code, err)
        self.assertFalse(self.files["json_command"].exists())
        self.assertFalse((self.home / "json-tables-venv").exists())
        self.assertIsNone(self.ctx.manifest.get("components.json_tables"))

    def test_a_receipt_pointing_outside_the_kit_home_is_still_refused(self) -> None:
        elsewhere = Path(self.temp.name) / "someone-elses-venv"
        doc = json.loads(self.ctx.manifest.path.read_text(encoding="utf-8"))
        doc["components"]["json_tables"].update({"venv": str(elsewhere), "python": str(elsewhere / "bin" / "python"),
                                                 "engine": str(elsewhere / "json_to_parquet")})
        self.ctx.manifest.path.write_text(json.dumps(doc), encoding="utf-8")
        code, _, err = self.run_service("json-tables", "uninstall", "--dry-run")
        self.assertEqual(1, code)
        self.assertIn("not kit-owned", err)
        code, _, err = self.run_service("json-tables", "update")
        self.assertEqual(1, code)
        self.assertIn("not kit-owned", err)
        self.assertIsNone(self.stored("json_tables"))
        self.assertEqual("kit", self.stored("dash_server"))         # the kit's own receipt beside it is migrated
        self.assertTrue(self.files["json_command"].exists())

    def test_the_scheduler_and_vscode_receipts_preview_their_removal(self) -> None:
        before = self.ctx.manifest.path.read_bytes()
        code, out, err = self.run_service("exasol-scheduler", "uninstall", "--dry-run")
        self.assertEqual(0, code, err)
        self.assertIn(str(self.files["scheduler_command"]), out)
        self.assertIn(str(self.home / "exasol-scheduler"), out)
        # The 0.2.5 -> 0.3.0 upgrade test: the preview listed these paths only, while the removal also stops the
        # service, hands SCHED to the administrator and drops the scheduler's database user.
        self.assertIn("the running scheduler service (it is stopped first)", out)
        self.assertIn("the database user SCHEDULER_SVC (DROP USER); schema SCHED and its tasks stay, handed to sys", out)
        _, vscode = service._module(ROOT, "exasol-vscode")
        with patch.object(vscode, "live_version", return_value="1.9.1"):
            code, out, err = self.run_service("exasol-vscode", "uninstall", "--dry-run")
        self.assertEqual(0, code, err)
        self.assertIn("exasol.exasol-vscode", out)
        self.assertEqual(before, self.ctx.manifest.path.read_bytes())

    def test_the_scheduler_and_vscode_receipts_update_and_record_kit_ownership(self) -> None:
        _, scheduler = service._module(ROOT, "exasol-scheduler")
        with patch.object(scheduler, "_running", return_value=False), \
             patch.object(scheduler, "install", return_value=None), \
             patch.object(scheduler, "validate", return_value=True):
            code, _, err = self.run_service("exasol-scheduler", "update")
        self.assertEqual(0, code, err)
        self.assertEqual("kit", self.stored("exasol_scheduler"))
        _, vscode = service._module(ROOT, "exasol-vscode")
        with patch.object(vscode, "install", return_value=None):
            code, _, err = self.run_service("exasol-vscode", "update")
        self.assertEqual(0, code, err)
        self.assertEqual("kit", self.stored("exasol_vscode"))

    def test_a_scheduler_or_vscode_receipt_owned_by_the_user_is_still_refused(self) -> None:
        for owner in ("user", "unknown"):
            doc = json.loads(self.ctx.manifest.path.read_text(encoding="utf-8"))
            doc["components"]["exasol_scheduler"]["ownership"] = owner
            doc["components"]["exasol_vscode"]["ownership"] = owner
            self.ctx.manifest.path.write_text(json.dumps(doc), encoding="utf-8")
            for addon, receipt in (("exasol-scheduler", "exasol_scheduler"), ("exasol-vscode", "exasol_vscode")):
                for argv in (("uninstall", "--dry-run"), ("update",), ("uninstall",)):
                    with self.subTest(owner=owner, addon=addon, argv=argv):
                        code, out, err = self.run_service(addon, *argv)
                        self.assertEqual(1, code)
                        self.assertIn("not kit-owned", err)
                        self.assertNotIn("removed", (out + err).replace("will not be removed", ""))
                        self.assertEqual(owner, self.stored(receipt))
            self.assertTrue(self.files["scheduler_command"].exists())
            self.assertTrue(self.files["scheduler_engine"].exists())

    def test_an_engine_in_a_sibling_of_the_kit_home_is_not_the_kits(self) -> None:
        sibling = Path(str(self.home) + "-other") / "exasol-scheduler" / "libexec" / "exasol_scheduler"
        doc = json.loads(self.ctx.manifest.path.read_text(encoding="utf-8"))
        doc["components"]["exasol_scheduler"]["engine"] = str(sibling)
        del doc["components"]["exasol_vscode"]["code_cli"]          # not the whole 0.2.5 shape
        self.ctx.manifest.path.write_text(json.dumps(doc), encoding="utf-8")
        code, _, err = self.run_service("exasol-scheduler", "uninstall", "--dry-run")
        self.assertEqual(1, code)
        self.assertIn("not kit-owned", err)
        code, _, err = self.run_service("exasol-vscode", "update")
        self.assertEqual(1, code)
        self.assertIn("not kit-owned", err)
        self.assertIsNone(self.stored("exasol_scheduler"))
        self.assertIsNone(self.stored("exasol_vscode"))


if __name__ == "__main__":
    unittest.main()
