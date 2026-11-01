"""A disposable add-on test must never acquire ownership of the borrowed database."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

PATH = Path(__file__).parent / "integration/marketplace_lifecycle_live.py"
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


if __name__ == "__main__":
    unittest.main()
