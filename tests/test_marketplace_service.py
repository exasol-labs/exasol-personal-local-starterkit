"""The shared add-on dispatcher preserves one JSON result and ownership gates."""

from __future__ import annotations

import io
import json
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
            code = service.main(["notebook", "install", "--json"])
        self.assertEqual(0, code)
        self.assertEqual("ready", json.loads(output.getvalue())["value"])
        self.assertIn("Installing an add-on", progress.getvalue())

    def test_missing_install_refused_before_module_action(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
            with patch.object(KitContext, "from_environment", return_value=ctx), \
                 patch.object(service, "_module") as module:
                module.return_value = (next(row for row in service.load_addons(ROOT) if row.id == "notebook"),
                                       type("Addon", (), {"install": staticmethod(lambda _ctx: None)}))
                with self.assertRaisesRegex(AddonFailure, "No starter kit installation"):
                    service.invoke(ROOT, "notebook", "install")

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


if __name__ == "__main__":
    unittest.main()
