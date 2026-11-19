"""A disposable add-on test must never acquire ownership of the borrowed database."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import sys

PATH = Path(__file__).parent / "integration/marketplace_lifecycle_live.py"
sys.path.insert(0, str(PATH.parent))
SPEC = importlib.util.spec_from_file_location("marketplace_lifecycle_live", PATH)
live = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(live)


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
            for addon in ("exasol-scheduler",):
                with self.assertRaisesRegex(RuntimeError, "approve-test-writes"):
                    live.run([addon], base / "missing", base / "result.json")
            self.assertEqual([], list(base.iterdir()))

    def test_invalid_upgrade_targets_are_rejected_before_fixture_changes(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            for targets in ({"dbt-exasol": "bad version"}, {"dbt-exasol": "0.0.1"},
                            {"unknown": "99.0.0"}, {"json-tables": "99.0.0"}):
                with self.assertRaisesRegex(RuntimeError, "Upgrade targets"):
                    live.run(["dbt-exasol"], base / "missing", base / "result.json", upgrades=targets)
            self.assertEqual([], list(base.iterdir()))

    def test_invalid_baseline_versions_are_rejected_before_fixture_changes(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            for targets in ({"dbt-exasol": "bad version"}, {"dbt-exasol": "99.0.0"},
                            {"unknown": "1.0.0"}, {"json-tables": "1.0.0"}):
                with self.assertRaisesRegex(RuntimeError, "Baseline versions|Upgrade targets"):
                    live.run(["dbt-exasol"], base / "missing", base / "result.json", baselines=targets)
            self.assertEqual([], list(base.iterdir()))


if __name__ == "__main__":
    unittest.main()
