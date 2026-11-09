"""Removing a persona changes membership only, including hidden personas."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from persona_membership import remove  # noqa: E402
from runtime import AddonFailure  # noqa: E402


class PersonaMembershipTest(unittest.TestCase):
    def test_remove_keeps_shared_resources_and_is_repeatable(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            path = home / "manifest.json"
            path.write_text(json.dumps({"persona": {"id": "data-scientist,ml-engineer"},
                                        "components": {"notebook": {"version": "3.1.0"}},
                                        "data": {"loaded": True}}))
            remaining, changed = remove(ROOT, home, "data-scientist")
            self.assertEqual(["ml-engineer"], remaining)
            self.assertTrue(changed)
            first = path.read_bytes()
            remaining, changed = remove(ROOT, home, "data-scientist")
            self.assertEqual(["ml-engineer"], remaining)
            self.assertFalse(changed)
            self.assertEqual(first, path.read_bytes())
            doc = json.loads(path.read_text())
            self.assertEqual({"version": "3.1.0"}, doc["components"]["notebook"])
            self.assertTrue(doc["data"]["loaded"])

    def test_remove_says_what_still_starts_at_login(self) -> None:
        """DAY-10: removing the ML Engineer leaves its MLflow server starting at every login; the message says so and
        names the command that stops that - only when the server is set to start and no remaining persona needs it."""
        import subprocess

        def removed(doc: dict) -> str:
            with tempfile.TemporaryDirectory() as temp:
                (Path(temp) / "manifest.json").write_text(json.dumps(doc))
                return subprocess.run([sys.executable, str(ROOT / "setup/lib/persona_service.py"), str(ROOT), "remove",
                                       "ml-engineer"], capture_output=True, text=True, check=True,
                                      env={"EXAKIT_HOME": temp, "PATH": "/usr/bin:/bin"}).stdout
        enabled = {"components": {"udf_devkit": {"mlflow": {"enabled": True}}}}
        said = removed({"persona": {"id": "data-scientist,ml-engineer"}, **enabled})
        self.assertIn("still starts at every login", said)
        self.assertIn("exakit mlflow stop --disable", said)
        self.assertNotIn("every login", removed({"persona": {"id": "data-scientist,ml-engineer"}}))

    def test_unknown_id_is_not_written(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            path = home / "manifest.json"
            path.write_text('{"persona":{"id":"ml-engineer"}}')
            before = path.read_bytes()
            with self.assertRaisesRegex(AddonFailure, "unknown"):
                remove(ROOT, home, "mistyped")
            self.assertEqual(before, path.read_bytes())


if __name__ == "__main__":
    unittest.main()
