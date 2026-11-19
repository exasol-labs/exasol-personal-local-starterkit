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
        # An offered persona to work with, defined here: the rules are the kit's, whichever personas it ships.
        persona = {"schema_version": 1, "id": "analyst", "title": "Data Analyst", "summary": "SQL and dashboards",
                   "picker": True, "visible": True, "order": 10, "datasets": ["retail_sales"],
                   "mcp_clients": "all", "addons": ["dash-server"]}
        (self.root / "personas/analyst.json").write_text(json.dumps(persona), encoding="utf-8")

    def tearDown(self) -> None:
        self.workspace.cleanup()

    def test_catalog_reads_existing_version_source(self) -> None:
        addons = load_addons(self.root)
        self.assertEqual(len(json.loads((ROOT / "marketplace/catalog.json").read_text())["addons"]), len(addons))
        versions = json.loads((self.root / "versions.json").read_text())
        self.assertEqual([versions["components"][item.id]["version"] for item in addons],
                         [item.version for item in addons])

    def test_names_links_and_abouts_are_the_repositories_on_github(self) -> None:
        # The catalog carries each add-on's GitHub block (tools/addon_github.py writes it); the row's name is the
        # repository's, with the id typed in commands beside it only when the two differ.
        addons = {item.id: item for item in load_addons(self.root)}
        self.assertEqual("dbt-exasol", addons["dbt-exasol"].label)
        self.assertEqual("exasol-json-tables (json-tables)", addons["json-tables"].label)
        self.assertEqual("https://github.com/exasol-labs/exasol-json-tables", addons["json-tables"].github["url"])
        for item in addons.values():
            self.assertEqual(f"https://github.com/{item.github['repo']}", item.github["url"])
            self.assertTrue(item.github["about"])

    def test_a_github_block_that_is_not_the_safe_shape_is_refused(self) -> None:
        # The repo and name go into URLs and file names, the About into a terminal: anything else is refused
        # before a screen is drawn, and a hand-typed label is not a name.
        catalog_path = self.root / "marketplace/catalog.json"
        original = json.loads(catalog_path.read_text())
        good = dict(original["addons"][0]["github"])
        cases = {
            "github must name": None,
            "github.repo must be owner/name": dict(good, repo="https://evil.example/x"),
            "github.repo must be owner/name ": dict(good, repo="../../etc"),
            "github.url must be": dict(good, url="https://evil.example/dash-server"),
            "github.name must be": dict(good, name="dash server;rm"),
            "github.about must be": dict(good, about="line one\nline two"),
            "github.about must be ": dict(good, about="\x1b[31mred"),
            "github.about must be  ": dict(good, about="x" * 301),
            "github.about must be   ": dict(good, about="   "),
        }
        for message, block in cases.items():
            catalog = json.loads(json.dumps(original))
            if block is None:
                del catalog["addons"][0]["github"]
            else:
                catalog["addons"][0]["github"] = block
            catalog_path.write_text(json.dumps(catalog))
            with self.subTest(message.strip()), self.assertRaisesRegex(CatalogError, message.strip()):
                load_addons(self.root)
        for bad in ("two\nlines", "x" * 121, 'a "quote"', 7):
            catalog = json.loads(json.dumps(original))
            catalog["addons"][0]["kit_about"] = bad
            catalog_path.write_text(json.dumps(catalog))
            with self.subTest(kit_about=bad), self.assertRaisesRegex(CatalogError, "kit_about must be one line"):
                load_addons(self.root)
        catalog = json.loads(json.dumps(original))
        catalog["addons"][0]["label"] = "dash-server (hand-typed)"
        catalog_path.write_text(json.dumps(catalog))
        with self.assertRaisesRegex(CatalogError, "comes from GitHub"):
            load_addons(self.root)

    def test_addon_answer_is_normalized_and_validated_before_apply(self) -> None:
        addons = load_addons(self.root)
        self.assertEqual("dash-server,json-tables", parse_addon_answer(addons, " DASH-SERVER , json-tables,dash-server "))
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
        self.assertEqual(["operations", "analyst"],
                         choose_personas(rows, ["analyst", "operations"]))

    def test_visible_false_hides_choice_without_deleting_definition(self) -> None:
        path = self.root / "personas/analyst.json"
        persona = json.loads(path.read_text())
        persona["visible"] = False
        path.write_text(json.dumps(persona))
        self.assertEqual([], load_personas(self.root))
        sys.path.insert(0, str(self.root / "setup/lib"))
        from persona_service import BadInput, picked, selectable
        self.assertEqual("analyst", picked(self.root, "analyst")[0]["id"])
        with self.assertRaisesRegex(BadInput, "disabled"):
            selectable(self.root, "analyst")
        self.assertEqual("analyst", selectable(self.root, "analyst", "analyst")[0]["id"])

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
        self.assertIn("analyst", [row["id"] for row in load_personas(self.root)])

    def test_catalog_choices_are_validated_and_data_driven(self) -> None:
        catalog_path = self.root / "marketplace/catalog.json"
        catalog = json.loads(catalog_path.read_text())
        row = next(row for row in catalog["addons"] if row["id"] == "dash-server")
        row["choices"] = [{"id": "new-editor", "label": "New editor"}]
        catalog_path.write_text(json.dumps(catalog))
        addon = next(row for row in load_addons(self.root) if row.id == "dash-server")
        self.assertIn(("new-editor", "New editor"), addon.choices)
        row["choices"].append({"id": "new-editor", "label": "Duplicate"})
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
        versions["components"]["dash-server"] = ["0.2.1"]
        versions_path.write_text(json.dumps(versions))
        with self.assertRaisesRegex(CatalogError, "component must be an object"):
            load_addons(self.root)
        versions["components"]["dash-server"] = {"version": "0.2.1\nspoofed-row"}
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

        (self.root / "marketplace/addons/dbt_exasol.py").unlink()
        with self.assertRaisesRegex(CatalogError, "dbt-exasol: Python add-on module is missing"):
            _module(self.root, "dbt-exasol")
        self.assertEqual(len(json.loads((ROOT / "marketplace/catalog.json").read_text())["addons"]), len(load_addons(self.root)))
        self.assertTrue(any(line.startswith("dbt-exasol|") for line in rows(self.root, "registry")))
        self.assertFalse(any(line.startswith("dbt-exasol|") for line in rows(self.root, "shell-hooks")))

    def test_unavailable_addons_cannot_be_confirmed(self) -> None:
        addons = load_addons(self.root)
        states = {item.id: {"status": "available"} for item in addons}
        states["json-tables"] = {"status": "managed outside the kit"}
        with self.assertRaisesRegex(CatalogError, "not available"):
            choose_addons(addons, states, ["json-tables"])
        self.assertEqual(["dash-server", "semantic-views"],
                         choose_addons(addons, states, ["semantic-views", "dash-server"]))

    def test_ui_pin_is_validated_and_noninteractive_start_is_read_only(self) -> None:
        self.assertEqual("8.2.8", textual_pin(self.root / "marketplace/defaults.env"))
        result = self.root / "result.json"
        # A non-Windows host: on Windows the launcher answers 11 before anything else
        # (test_windows_never_gets_a_full_screen_menu), so these run as Linux would.
        with patch("launch.sys.platform", "linux"):
            self.assertEqual(10, run(self.root, ["persona", "--out", str(result)]))
        self.assertFalse(result.exists())

    def test_windows_never_gets_a_full_screen_menu(self) -> None:
        # Textual has no inline driver for Windows. 11 sends the caller to the kit's own menus, which stay in
        # the flow; nothing is started, not even the warm-up download.
        (self.root / "marketplace/ui.py").write_text("", encoding="utf-8")
        terminal = SimpleNamespace(isatty=lambda: True)
        for mode in (["persona", "--out", str(self.root / "choice.json")], ["warm"]):
            with patch("launch.sys.platform", "win32"), \
                 patch("launch.sys.stdin", terminal), patch("launch.sys.stdout", terminal), \
                 patch("launch.subprocess.run") as call:
                self.assertEqual(11, run(self.root, mode))
            call.assert_not_called()

    def test_ui_uv_cache_stays_under_the_kit_home(self) -> None:
        (self.root / "marketplace/ui.py").write_text("", encoding="utf-8")
        home = self.root / "kit home"
        terminal = SimpleNamespace(isatty=lambda: True)
        # A home of its own: the environment is cleared, and on Windows Path.home() needs USERPROFILE.
        with patch.dict(os.environ, {"EXAKIT_HOME": str(home), "HOME": str(self.root), "USERPROFILE": str(self.root)}, clear=True), \
             patch("launch.sys.platform", "linux"), \
             patch("launch.sys.stdin", terminal), patch("launch.sys.stdout", terminal), \
             patch("launch.shutil.which", return_value="/usr/bin/uv"), \
             patch("launch.subprocess.run", return_value=SimpleNamespace(returncode=0)) as call:
            self.assertEqual(0, run(self.root, ["persona", "--out", str(self.root / "choice.json")]))
        self.assertEqual(str(home / "cache/uv"), call.call_args.kwargs["env"]["UV_CACHE_DIR"])
        # Its first start downloads Textual: uv trusts the system store, behind an inspecting proxy too (WPS-01).
        self.assertEqual("1", call.call_args.kwargs["env"]["UV_SYSTEM_CERTS"])

    def test_ui_uses_the_managed_python_version(self) -> None:
        (self.root / "marketplace/ui.py").write_text("", encoding="utf-8")
        terminal = SimpleNamespace(isatty=lambda: True)
        with patch.dict(os.environ, {"EXAKIT_MANAGED_PYTHON_VERSION": "3.13", "HOME": str(self.root),
                                     "USERPROFILE": str(self.root)}, clear=True), \
             patch("launch.sys.platform", "linux"), \
             patch("launch.sys.stdin", terminal), patch("launch.sys.stdout", terminal), \
             patch("launch.shutil.which", return_value="/usr/bin/uv"), \
             patch("launch.subprocess.run", return_value=SimpleNamespace(returncode=0)) as call:
            self.assertEqual(0, run(self.root, ["persona", "--out", str(self.root / "choice.json")]))
        argv = call.call_args.args[0]
        self.assertEqual("3.13", argv[argv.index("--python") + 1])
        # uv's own spinner would be the one line on screen that is not the kit's.
        self.assertIn("--quiet", argv)


if __name__ == "__main__":
    unittest.main()
