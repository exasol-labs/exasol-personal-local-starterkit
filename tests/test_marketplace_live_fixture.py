"""A disposable add-on test must never acquire ownership of the borrowed database."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import sys
import os
from unittest.mock import patch

PATH = Path(__file__).parent / "integration/marketplace_lifecycle_live.py"
sys.path.insert(0, str(PATH.parent))
SPEC = importlib.util.spec_from_file_location("marketplace_lifecycle_live", PATH)
live = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(live)
import personal_readonly_guard as guard
sys.path.insert(0, str(PATH.parents[2] / "marketplace"))
from runtime import KitContext, Manifest
from addons import udf_devkit


class LiveFixtureTest(unittest.TestCase):
    def test_fixture_cannot_claim_the_source_database_or_core_components(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            original = {"runtime": {"ownership": "kit", "deployment_dir": "/user/database",
                                    "password_file": "/user/credential"},
                        "components": {"personal": {"ownership": "kit"},
                                       "exasol_vscode": {"ownership": "user"}},
                        "autostart": {"enabled": True}}
            manifest = source / "manifest.json"
            manifest.write_text(json.dumps(original))
            before = manifest.read_bytes()
            fixture = live.fixture_manifest(source)
            self.assertEqual("user", fixture["runtime"]["ownership"])
            self.assertEqual("/user/database", fixture["runtime"]["deployment_dir"])
            self.assertEqual({}, fixture["components"])
            self.assertFalse(fixture["autostart"]["enabled"])
            self.assertEqual(before, manifest.read_bytes())

    def test_database_checks_require_consent_before_creating_a_fixture(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            for addon in ("exasol-scheduler", "udf-devkit"):
                with self.assertRaisesRegex(RuntimeError, "approve-test-writes"):
                    live.run([addon], base / "missing", base / "result.json")
            self.assertEqual([], list(base.iterdir()))

    def test_invalid_upgrade_targets_are_rejected_before_fixture_changes(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            for targets in ({"dbt-exasol": "bad version"}, {"dbt-exasol": "0.0.1"},
                            {"unknown": "99.0.0"}, {"notebook": "99.0.0"}):
                with self.assertRaisesRegex(RuntimeError, "Upgrade targets"):
                    live.run(["dbt-exasol"], base / "missing", base / "result.json", upgrades=targets)
            self.assertEqual([], list(base.iterdir()))

    def test_invalid_baseline_versions_are_rejected_before_fixture_changes(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            for targets in ({"dbt-exasol": "bad version"}, {"dbt-exasol": "99.0.0"},
                            {"unknown": "1.0.0"}, {"notebook": "1.0.0"}):
                with self.assertRaisesRegex(RuntimeError, "Baseline versions|Upgrade targets"):
                    live.run(["dbt-exasol"], base / "missing", base / "result.json", baselines=targets)
            self.assertEqual([], list(base.iterdir()))

    def test_readonly_guard_refuses_every_runtime_mutation(self):
        with tempfile.TemporaryDirectory() as temp:
            denied = Path(temp) / "denied"
            with patch.object(guard.subprocess, "call") as called:
                for command in (["stop"], ["start"], ["delete"], ["slc", "install", "PYTHON3"],
                                ["slc", "custom", "update"], ["slc", "custom", "install"], ["slc", "remove"]):
                    self.assertEqual(97, guard.main(["unreachable-launcher", str(denied), *command]))
                called.assert_not_called()
            self.assertTrue(denied.exists())

    @unittest.skipIf(os.name == "nt", "Native Windows wrapper execution remains a release check")
    def test_udf_runtime_paths_reach_the_guard_and_cannot_reach_the_real_launcher(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source, home, bin_dir = base / "source", base / "fixture", base / "bin"
            for folder in (source, home, bin_dir):
                folder.mkdir()
            reached = base / "real-launcher-reached"
            personal = base / "personal"
            personal.write_text(f'#!/bin/sh\ntouch "{reached}"\nexit 99\n')
            personal.chmod(0o755)
            original = {"runtime": {"deployment_dir": str(base / "database")}, "components": {
                "personal": {"ownership_path": str(personal)},
                "pyexasol": {"python": sys.executable, "ownership": "kit"}}}
            (source / "manifest.json").write_text(json.dumps(original))
            fixture = live.fixture_manifest(source)
            env = {}
            checks = live.DatabaseChecks(source, home, bin_dir, env, fixture, ["udf-devkit"])
            manifest = Manifest(home / "manifest.json")
            manifest.path.write_text(json.dumps(fixture))
            ctx = KitContext(PATH.parents[2], home, bin_dir, manifest, Path("uv"))
            with patch.dict(os.environ, env):
                self.assertEqual(str(checks.guard), udf_devkit._launcher(ctx))
                self.assertEqual(97, udf_devkit._slc(ctx, "custom", "update").returncode)
                with patch.object(udf_devkit, "_kit_command") as kit, \
                     patch.object(udf_devkit, "_database_ready", return_value=True):
                    kit.return_value.returncode = 0
                    kit.return_value.stdout = '{"services":{}}'
                    with self.assertRaises(udf_devkit.UdfFailure):
                        udf_devkit._restart(ctx, [["install", "PYTHON3"]], yes=True, reason="Guard verification")
            self.assertTrue(checks.denied.exists())
            self.assertFalse(reached.exists())


if __name__ == "__main__":
    unittest.main()
