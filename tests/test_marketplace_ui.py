"""The Python boundary remains safe when release metadata or selections change."""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from model import CatalogError, choose_addons, choose_personas, load_addons, load_personas, parse_addon_answer  # noqa: E402
from launch import run, textual_pin  # noqa: E402


class MarketplaceModelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.workspace = tempfile.TemporaryDirectory()
        self.root = Path(self.workspace.name)
        for folder in ("marketplace", "personas", "setup/lib"):
            (self.root / folder).mkdir(parents=True)
        (self.root / "marketplace/addons").mkdir()
        for module in (ROOT / "marketplace/addons").glob("*.py"):
            (self.root / "marketplace/addons" / module.name).touch()
        shutil.copy2(ROOT / "marketplace/catalog.json", self.root / "marketplace/catalog.json")
        shutil.copy2(ROOT / "marketplace/defaults.env", self.root / "marketplace/defaults.env")
        shutil.copy2(ROOT / "versions.json", self.root / "versions.json")
        shutil.copy2(ROOT / "setup/lib/persona_service.py", self.root / "setup/lib/persona_service.py")
        shutil.copy2(ROOT / "personas/data-scientist.json", self.root / "personas/data-scientist.json")

    def tearDown(self) -> None:
        self.workspace.cleanup()

    def test_catalog_reads_existing_version_source(self) -> None:
        addons = load_addons(self.root)
        self.assertEqual(7, len(addons))
        versions = json.loads((self.root / "versions.json").read_text())
        self.assertEqual([versions["components"][item.id]["version"] for item in addons],
                         [item.version for item in addons])

    def test_addon_answer_is_normalized_and_validated_before_apply(self) -> None:
        addons = load_addons(self.root)
        self.assertEqual("dash-server,notebook", parse_addon_answer(addons, " DASH-SERVER , notebook,dash-server "))
        self.assertEqual("all", parse_addon_answer(addons, " ALL "))
        self.assertEqual("none", parse_addon_answer(addons, " none "))
        with self.assertRaisesRegex(CatalogError, "empty add-on ID"):
            parse_addon_answer(addons, "dash-server,")
        with self.assertRaisesRegex(CatalogError, "Unknown marketplace add-on"):
            parse_addon_answer(addons, "dash-server,missing")

    def test_new_persona_is_available_from_json_without_code_edit(self) -> None:
        new = {"schema_version": 1, "id": "operations", "title": "Operations",
               "summary": "Review local jobs", "picker": True, "order": 1,
               "datasets": [], "mcp_clients": "skip", "addons": []}
        (self.root / "personas/operations.json").write_text(json.dumps(new))
        rows = load_personas(self.root)
        self.assertEqual("operations", rows[0]["id"])
        self.assertEqual(["operations", "data-scientist"],
                         choose_personas(rows, ["data-scientist", "operations"]))

    def test_visible_false_hides_choice_without_deleting_definition(self) -> None:
        path = self.root / "personas/data-scientist.json"
        persona = json.loads(path.read_text())
        persona["visible"] = False
        path.write_text(json.dumps(persona))
        self.assertEqual([], load_personas(self.root))
        sys.path.insert(0, str(self.root / "setup/lib"))
        from persona_service import BadInput, picked, selectable
        self.assertEqual("data-scientist", picked(self.root, "data-scientist")[0]["id"])
        with self.assertRaisesRegex(BadInput, "disabled"):
            selectable(self.root, "data-scientist")
        self.assertEqual("data-scientist", selectable(self.root, "data-scientist", "data-scientist")[0]["id"])

        catalog_path = self.root / "marketplace/catalog.json"
        catalog = json.loads(catalog_path.read_text())
        catalog["addons"][0]["visible"] = False
        catalog_path.write_text(json.dumps(catalog))
        self.assertFalse(load_addons(self.root)[0].visible)
        states = {item.id: {"status": "available"} for item in load_addons(self.root)}
        with self.assertRaisesRegex(CatalogError, "unknown"):
            choose_addons(load_addons(self.root), states, ["dash-server"])
        from runtime import KitContext, Manifest
        from service import invoke
        home = self.root / "kit"
        home.mkdir()
        (home / "manifest.json").write_text("{}\n", encoding="utf-8")
        manifest = Manifest(home / "manifest.json")
        manifest.set_many({"components.dash_server.ownership": "kit", "components.dash_server.version": "0.1.1"})
        ctx = KitContext(self.root, home, home / "bin", manifest, Path("uv"))
        with patch("addons.dash_server.package_version", return_value="0.1.1"):
            self.assertEqual((0, "0.1.1"), invoke(self.root, "dash-server", "installed-version", ctx=ctx))
        self.assertEqual("kit", manifest.get("components.dash_server.ownership"))
        catalog["addons"][0]["visible"] = True
        catalog_path.write_text(json.dumps(catalog))
        self.assertEqual(["dash-server"], choose_addons(load_addons(self.root), states, ["dash-server"]))
        persona["visible"] = True
        path.write_text(json.dumps(persona))
        self.assertIn("data-scientist", [row["id"] for row in load_personas(self.root)])

    def test_catalog_choices_are_validated_and_data_driven(self) -> None:
        catalog_path = self.root / "marketplace/catalog.json"
        catalog = json.loads(catalog_path.read_text())
        notebook = next(row for row in catalog["addons"] if row["id"] == "notebook")
        notebook["choices"].append({"id": "new-editor", "label": "New editor"})
        catalog_path.write_text(json.dumps(catalog))
        addon = next(row for row in load_addons(self.root) if row.id == "notebook")
        self.assertIn(("new-editor", "New editor"), addon.choices)
        notebook["choices"].append({"id": "new-editor", "label": "Duplicate"})
        catalog_path.write_text(json.dumps(catalog))
        with self.assertRaisesRegex(CatalogError, "repeated choice"):
            load_addons(self.root)

    def test_bad_release_data_fails_before_any_install(self) -> None:
        data = json.loads((self.root / "marketplace/catalog.json").read_text())
        data["addons"].append(dict(data["addons"][0]))
        (self.root / "marketplace/catalog.json").write_text(json.dumps(data))
        with self.assertRaisesRegex(CatalogError, "repeated"):
            load_addons(self.root)

    def test_catalog_requires_a_python_addon(self) -> None:
        path = self.root / "marketplace/catalog.json"
        data = json.loads(path.read_text())
        data["addons"][0]["backend"] = "legacy"
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(CatalogError, "unsupported backend"):
            load_addons(self.root)

    def test_malformed_version_blocks_and_line_breaks_are_refused(self) -> None:
        versions_path = self.root / "versions.json"
        versions = json.loads(versions_path.read_text())
        versions["components"]["notebook"] = ["3.1.0"]
        versions_path.write_text(json.dumps(versions))
        with self.assertRaisesRegex(CatalogError, "component must be an object"):
            load_addons(self.root)
        versions["components"]["notebook"] = {"version": "3.1.0\nspoofed-row"}
        versions_path.write_text(json.dumps(versions))
        with self.assertRaisesRegex(CatalogError, "invalid version"):
            load_addons(self.root)

        catalog_path = self.root / "marketplace/catalog.json"
        catalog = json.loads(catalog_path.read_text())
        catalog["addons"][0]["default_version"] = "0.1.1\nspoofed-row"
        catalog_path.write_text(json.dumps(catalog))
        with self.assertRaisesRegex(CatalogError, "default_version"):
            load_addons(self.root)

    def test_missing_python_module_is_a_catalog_error(self) -> None:
        from metadata import rows
        from service import _module

        (self.root / "marketplace/addons/udf_devkit.py").unlink()
        with self.assertRaisesRegex(CatalogError, "udf-devkit: Python add-on module is missing"):
            _module(self.root, "udf-devkit")
        self.assertEqual(7, len(load_addons(self.root)))
        self.assertTrue(any(line.startswith("udf-devkit|") for line in rows(self.root, "registry")))
        self.assertFalse(any(line.startswith("udf-devkit|") for line in rows(self.root, "shell-hooks")))

    def test_unavailable_addons_cannot_be_confirmed(self) -> None:
        addons = load_addons(self.root)
        states = {item.id: {"status": "available"} for item in addons}
        states["notebook"] = {"status": "managed outside the kit"}
        with self.assertRaisesRegex(CatalogError, "not available"):
            choose_addons(addons, states, ["notebook"])
        self.assertEqual(["dash-server", "json-tables"],
                         choose_addons(addons, states, ["json-tables", "dash-server"]))

    def test_ui_pin_is_validated_and_noninteractive_start_is_read_only(self) -> None:
        self.assertEqual("8.2.8", textual_pin(self.root / "marketplace/defaults.env"))
        result = self.root / "result.json"
        self.assertEqual(10, run(self.root, ["persona", "--out", str(result)]))
        self.assertFalse(result.exists())

    def test_ui_uv_cache_stays_under_the_kit_home(self) -> None:
        (self.root / "marketplace/ui.py").write_text("", encoding="utf-8")
        home = self.root / "kit home"
        terminal = SimpleNamespace(isatty=lambda: True)
        with patch.dict(os.environ, {"EXAKIT_HOME": str(home)}, clear=True), \
             patch("launch.sys.stdin", terminal), patch("launch.sys.stdout", terminal), \
             patch("launch.shutil.which", return_value="/usr/bin/uv"), \
             patch("launch.subprocess.run", return_value=SimpleNamespace(returncode=0)) as call:
            self.assertEqual(0, run(self.root, ["persona", "--out", str(self.root / "choice.json")]))
        self.assertEqual(str(home / "cache/uv"), call.call_args.kwargs["env"]["UV_CACHE_DIR"])

    def test_ui_uses_the_managed_python_version(self) -> None:
        (self.root / "marketplace/ui.py").write_text("", encoding="utf-8")
        terminal = SimpleNamespace(isatty=lambda: True)
        with patch.dict(os.environ, {"EXAKIT_MANAGED_PYTHON_VERSION": "3.13"}, clear=True), \
             patch("launch.sys.stdin", terminal), patch("launch.sys.stdout", terminal), \
             patch("launch.shutil.which", return_value="/usr/bin/uv"), \
             patch("launch.subprocess.run", return_value=SimpleNamespace(returncode=0)) as call:
            self.assertEqual(0, run(self.root, ["persona", "--out", str(self.root / "choice.json")]))
        argv = call.call_args.args[0]
        self.assertEqual("3.13", argv[argv.index("--python") + 1])


if __name__ == "__main__":
    unittest.main()
