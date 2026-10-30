"""Ownership, receipt and credential invariants for Python add-on lifecycle."""

from __future__ import annotations

import json
import io
import os
import shutil
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from runtime import AddonFailure, KitContext, Manifest, activity_sink  # noqa: E402
from addons import dash_server, dbt_exasol, exasol_scheduler, exasol_vscode, json_tables  # noqa: E402
from service import invoke  # noqa: E402


class ManifestTest(unittest.TestCase):
    def test_recorded_kit_paths_survive_changed_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "kit"
            home.mkdir()
            store = Manifest(home / "manifest.json")
            recorded = Path(temp) / "recorded"
            other = Path(temp) / "other"
            store.path.write_text(json.dumps({"components": {
                "dash_server": {"ownership": "kit", "venv": str(recorded / "dash-venv"),
                                "instance": str(recorded / "dash/instance"), "command": str(recorded / "dash-bin")},
                "dbt_exasol": {"ownership": "kit", "venv": str(recorded / "dbt-venv"),
                               "profiles_dir": str(recorded / "dbt"), "command": str(recorded / "dbt-bin")},
                "json_tables": {"ownership": "kit", "venv": str(recorded / "json-venv"),
                                "engine": str(recorded / "json/libexec/engine"), "command": str(recorded / "json-bin")},
                "exasol_scheduler": {"ownership": "kit", "engine": str(recorded / "sched/libexec/engine"),
                                     "command": str(recorded / "sched-bin")}}}))
            ctx = KitContext(ROOT, home, home / "bin", store, Path("uv"))
            with patch.dict(os.environ, {"EXAKIT_DASH_SERVER_VENV": str(other),
                                      "EXAKIT_DBT_EXASOL_VENV": str(other),
                                      "EXAKIT_JSON_TABLES_VENV": str(other),
                                      "EXAKIT_EXASOL_SCHEDULER_HOME": str(other)}):
                self.assertEqual(recorded / "dash-venv", dash_server.paths(ctx)[0])
                self.assertEqual(recorded / "dbt-venv", dbt_exasol.paths(ctx)[0])
                self.assertEqual(recorded / "json-venv", json_tables.paths(ctx)[0])
                self.assertEqual(recorded / "sched", exasol_scheduler.paths(ctx)[0])

    def test_parallel_receipts_are_not_lost(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "manifest.json"
            path.write_text("{}\n")
            store = Manifest(path)
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(lambda index: store.set_many({f"components.item_{index}.version": "1"}), range(24)))
            self.assertEqual(24, len(store.read()["components"]))

    def test_missing_manifest_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(AddonFailure):
                Manifest(Path(temp) / "missing.json").set_many({"x.y": "z"})

    def test_version_source_uses_release_then_marketplace_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "versions.json").write_text(json.dumps({"components": {"dbt-exasol": {"version": "2.0.0"}}}))
            home = root / "home"
            home.mkdir()
            ctx = KitContext(root, home, root / "bin", Manifest(home / "manifest.json"), Path("uv"))
            with patch.dict("os.environ", {"EXAKIT_VERSION_POLICY": "manifest"}, clear=True):
                self.assertEqual("2.0.0", ctx.target_version("dbt-exasol", "1.0.0"))
                self.assertEqual("1.0.0", ctx.target_version("missing-addon", "1.0.0"))
            with patch.dict("os.environ", {"EXAKIT_VERSION_POLICY": "pinned"}, clear=True):
                self.assertEqual("1.0.0", ctx.target_version("dbt-exasol", "1.0.0"))
            with patch.dict("os.environ", {"EXAKIT_DBT_EXASOL_VERSION": "9.0.0"}, clear=True):
                self.assertEqual("9.0.0", ctx.target_version("dbt-exasol", "1.0.0"))

    def test_selected_manifest_pairs_version_with_asset_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "checkout"
            root.mkdir()
            (root / "versions.json").write_text(json.dumps({"components": {
                "exasol-vscode": {"version": "1.0.0", "sha256": {"vsix": "b" * 64}}}}))
            cache = Path(temp) / "version cache.json"
            cache.write_text(json.dumps({"components": {
                "exasol-vscode": {"version": "2.0.0", "sha256": {"vsix": "a" * 64}},
                "json-tables": {"version": "v2.0.0", "release": "json-tables-v2", "sha256": {"wheel": "c" * 64}}}}))
            home = Path(temp) / "home"
            home.mkdir()
            ctx = KitContext(root, home, root / "bin", Manifest(home / "manifest.json"), Path("uv"))
            with patch.dict(os.environ, {"EXAKIT_VERSION_POLICY": "manifest",
                                      "EXAKIT_MARKETPLACE_VERSIONS_DOC": str(cache)}, clear=True):
                self.assertEqual("2.0.0", ctx.target_version("exasol-vscode", "1.0.0"))
                cache.write_text("{invalid")
                self.assertEqual("a" * 64, exasol_vscode.expected_digest(ctx, "2.0.0", "editor.vsix"))
                self.assertEqual("json-tables-v2", json_tables._release_info(ctx, "v2.0.0")[1])
            with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_VERSIONS_DOC": str(cache)}, clear=True):
                with self.assertRaises(AddonFailure):
                    KitContext(root, home, root / "bin", Manifest(home / "manifest.json"), Path("uv")).versions_document()

    def test_logged_step_updates_activity_above_progress(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
            activity = home / "marketplace.activity"
            with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_ACTIVITY_FILE": str(activity),
                                      "EXAKIT_MARKETPLACE_ACTIVITY_ROW": "4"}), \
                 patch("sys.stdout", new_callable=io.StringIO) as output:
                ctx.run_logged("Installing verified package", sys.executable, "-c", "pass")
            self.assertEqual("4|Installing verified package\n", activity.read_text())
            self.assertEqual("", output.getvalue(), "a live table owns stdout")

    def test_activity_without_a_table_remains_plain_text(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
            with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_ACTIVITY_FILE": str(home / "unused"),
                                      "EXAKIT_MARKETPLACE_ACTIVITY_ROW": ""}), \
                 patch("sys.stdout", new_callable=io.StringIO) as output:
                ctx.activity("Checking package")
            self.assertIn("Checking package", output.getvalue())
            self.assertFalse((home / "unused").exists())

    def test_textual_activity_sink_keeps_stdout_clean(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
            labels = []
            with patch("sys.stdout", new_callable=io.StringIO) as output:
                with activity_sink(labels.append):
                    ctx.activity("Downloading release")
            self.assertEqual(["Downloading release"], labels)
            self.assertEqual("", output.getvalue())


class DbtLifecycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "kit"
        self.home.mkdir()
        self.bin_dir = Path(self.temp.name) / "bin"
        self.bin_dir.mkdir()
        self.credential = Path(self.temp.name) / "secret.txt"
        self.credential.write_text("sensitive-test-password\n")
        self.store = Manifest(self.home / "manifest.json")
        self.store.path.write_text(json.dumps({"runtime": {"dsn": "localhost:8563", "user": "SYS",
                                                         "password_file": str(self.credential)}}))
        self.ctx = KitContext(ROOT, self.home, self.bin_dir, self.store, Path(shutil.which("uv") or "/usr/bin/uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_install_writes_no_secret_and_reuses_existing_package(self) -> None:
        venv, profile_dir, launcher = dbt_exasol.paths(self.ctx)
        python = venv / "bin/python"
        dbt = venv / "bin/dbt"
        python.parent.mkdir(parents=True)
        python.write_text("fake")
        dbt.write_text("fake")
        with patch.object(dbt_exasol, "package_version", return_value="1.12.1"), \
             patch.object(dbt_exasol, "validate", return_value=True), \
             patch.object(KitContext, "run_logged") as run_logged:
            dbt_exasol.install(self.ctx)
        run_logged.assert_not_called()
        self.assertTrue(launcher.is_file())
        self.assertNotIn("sensitive-test-password", (profile_dir / "profiles.yml").read_text())
        self.assertNotIn("sensitive-test-password", launcher.read_text())
        self.assertEqual("kit", self.store.get("components.dbt_exasol.ownership"))

    def test_uninstall_preserves_user_files_and_refuses_unowned(self) -> None:
        with self.assertRaises(AddonFailure):
            dbt_exasol.uninstall(self.ctx)
        venv, profile_dir, launcher = dbt_exasol.paths(self.ctx)
        venv.mkdir()
        profile_dir.mkdir()
        (profile_dir / "profiles.yml").write_text("generated")
        (profile_dir / "my-project.yml").write_text("personal")
        launcher.write_text("generated")
        self.store.set_many({"components.dbt_exasol.ownership": "kit"})
        self.assertEqual(3, len(dbt_exasol.uninstall(self.ctx, dry_run=True)))
        self.assertTrue(launcher.exists())
        dbt_exasol.uninstall(self.ctx)
        self.assertFalse(venv.exists())
        self.assertFalse(launcher.exists())
        self.assertTrue((profile_dir / "my-project.yml").exists())
        self.assertIsNone(self.store.get("components.dbt_exasol"))


class VscodeOwnershipTest(unittest.TestCase):
    def test_external_extension_is_reused_without_claim_or_download(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "kit"
            home.mkdir()
            store = Manifest(home / "manifest.json")
            store.path.write_text("{}\n")
            ctx = KitContext(ROOT, home, Path(temp) / "bin", store, Path("/usr/bin/uv"))
            with patch.object(exasol_vscode, "code_cli", return_value=Path("/fake/code")), \
                 patch.object(exasol_vscode, "live_version", return_value="1.8.0"), \
                 patch.object(exasol_vscode.urllib.request, "urlopen") as urlopen:
                exasol_vscode.install(ctx)
            urlopen.assert_not_called()
            self.assertIsNone(store.get("components.exasol_vscode"))
            with self.assertRaises(AddonFailure):
                exasol_vscode.uninstall(ctx)


class DashOwnershipTest(unittest.TestCase):
    def test_uninstall_keeps_dashboard_instance(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "kit"
            home.mkdir()
            store = Manifest(home / "manifest.json")
            store.path.write_text(json.dumps({"components": {"dash_server": {"ownership": "kit", "version": "0.1.1"}}}))
            ctx = KitContext(ROOT, home, Path(temp) / "bin", store, Path("uv"))
            venv, state, launcher = dash_server.paths(ctx)
            venv.mkdir()
            state.joinpath("instance").mkdir(parents=True)
            state.joinpath("instance", "my-dashboard.py").write_text("keep me")
            launcher.parent.mkdir()
            launcher.write_text("generated")
            with patch.object(dash_server, "stop"):
                targets = dash_server.uninstall(ctx, dry_run=True)
                self.assertEqual(2, len(targets))
                self.assertTrue(venv.exists())
                dash_server.uninstall(ctx)
            self.assertFalse(venv.exists())
            self.assertFalse(launcher.exists())
            self.assertTrue(state.joinpath("instance", "my-dashboard.py").exists())
            self.assertIsNone(store.get("components.dash_server"))


class JsonTablesArtifactTest(unittest.TestCase):
    def test_bad_digest_deletes_download_and_refuses_install(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            store = Manifest(home / "manifest.json")
            store.path.write_text("{}\n")
            ctx = KitContext(ROOT, home, home / "bin", store, Path("uv"))
            destination = home / "engine"
            response = io.BytesIO(b"wrong asset")
            response.url = "https://github.com/release/engine"
            with patch.object(json_tables.urllib.request, "urlopen", return_value=response):
                with self.assertRaisesRegex(AddonFailure, "Checksum mismatch"):
                    json_tables._asset(ctx, "owner/repo", "tag", "engine", "linux-x86_64",
                                       {"sha256": {"linux-x86_64": "0" * 64}}, None, destination)
            self.assertFalse(destination.exists())

    def test_external_install_is_never_claimed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            store = Manifest(home / "manifest.json")
            store.path.write_text(json.dumps({"components": {"json_tables": {"ownership": "user", "version": "v0.3.2"}}}))
            ctx = KitContext(ROOT, home, home / "bin", store, Path("uv"))
            with patch.object(json_tables, "_asset") as asset:
                json_tables.install(ctx)
            asset.assert_not_called()
            self.assertEqual("user", store.get("components.json_tables.ownership"))


class ServiceDispatchTest(unittest.TestCase):
    def test_missing_install_refuses_before_any_addon_side_effect(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            with patch.dict("os.environ", {"EXAKIT_HOME": temp}), \
                 patch.object(dbt_exasol, "install") as install:
                with self.assertRaisesRegex(AddonFailure, "No starter kit installation"):
                    invoke(ROOT, "dbt-exasol", "install")
            install.assert_not_called()

    def test_disabled_addon_cannot_be_newly_installed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "marketplace").mkdir()
            (root / "marketplace/addons").mkdir()
            for module in (ROOT / "marketplace/addons").glob("*.py"):
                (root / "marketplace/addons" / module.name).touch()
            catalog = json.loads((ROOT / "marketplace/catalog.json").read_text())
            for row in catalog["addons"]:
                if row["id"] == "dbt-exasol":
                    row["visible"] = False
            (root / "marketplace/catalog.json").write_text(json.dumps(catalog))
            (root / "versions.json").write_text((ROOT / "versions.json").read_text())
            with self.assertRaisesRegex(AddonFailure, "disabled"):
                invoke(root, "dbt-exasol", "install")

    def test_unknown_addon_is_rejected_before_mutation(self) -> None:
        from model import CatalogError

        with self.assertRaises(CatalogError):
            invoke(ROOT, "not-listed", "install")


if __name__ == "__main__":
    unittest.main()
