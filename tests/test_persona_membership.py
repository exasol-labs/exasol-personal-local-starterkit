"""Removing a persona changes membership only, including hidden personas."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
sys.path.insert(0, str(ROOT / "tests"))
from persona_membership import remove  # noqa: E402
from release_kit import kit_with_hidden_parts_on  # noqa: E402
from runtime import AddonFailure  # noqa: E402

# The fixture personas of tests/release_kit.py: analyst offered, engineer not (a hidden one is removed the same way).
_KIT_DIR = tempfile.TemporaryDirectory()
KIT = kit_with_hidden_parts_on(Path(_KIT_DIR.name) / "kit")


def tearDownModule() -> None:
    _KIT_DIR.cleanup()


class PersonaMembershipTest(unittest.TestCase):
    def test_remove_keeps_shared_resources_and_is_repeatable(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            path = home / "manifest.json"
            path.write_text(json.dumps({"persona": {"id": "analyst,engineer"},
                                        "components": {"dbt_exasol": {"version": "1.12.3"}},
                                        "data": {"loaded": True}}))
            remaining, changed = remove(KIT, home, "analyst")
            self.assertEqual(["engineer"], remaining)
            self.assertTrue(changed)
            first = path.read_bytes()
            remaining, changed = remove(KIT, home, "analyst")
            self.assertEqual(["engineer"], remaining)
            self.assertFalse(changed)
            self.assertEqual(first, path.read_bytes())
            doc = json.loads(path.read_text())
            self.assertEqual({"version": "1.12.3"}, doc["components"]["dbt_exasol"])
            self.assertTrue(doc["data"]["loaded"])

    def test_unknown_id_is_not_written(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            path = home / "manifest.json"
            path.write_text('{"persona":{"id":"engineer"}}')
            before = path.read_bytes()
            with self.assertRaisesRegex(AddonFailure, "unknown"):
                remove(KIT, home, "mistyped")
            self.assertEqual(before, path.read_bytes())


if __name__ == "__main__":
    unittest.main()
