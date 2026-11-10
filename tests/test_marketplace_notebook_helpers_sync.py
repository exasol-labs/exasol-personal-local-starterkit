"""The exakit.nb helpers follow the kit copy (DAY-07).

`exakit update exakit` refreshes the kit's notebooks, which import the exakit.nb helpers and exasol-mlflow from the
notebook environment. sync_helpers reinstalls those two local packages when the kit copy's code differs from the one
they were installed from, and does nothing when it is the same or there is no kit-owned notebook environment.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from addons import notebook  # noqa: E402
from runtime import KitContext, Manifest, venv_python  # noqa: E402


class HelpersSyncTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        home = Path(self.temp.name) / "kit"
        home.mkdir()
        self.manifest = Manifest(home / "manifest.json")
        self.manifest.path.write_text(json.dumps({"components": {"notebook": {"ownership": "kit"}}}))
        self.ctx = KitContext(ROOT, home, Path(self.temp.name) / "bin", self.manifest, Path("uv"))
        self.calls: list[tuple] = []

    def tearDown(self) -> None:
        self.temp.cleanup()

    def environment(self) -> None:
        python = venv_python(notebook.paths(self.ctx)[0])
        python.parent.mkdir(parents=True)
        python.write_text("", encoding="utf-8")

    def run_sync(self) -> bool:
        with patch.object(KitContext, "run_logged", lambda _self, *args, **_kw: self.calls.append(args)), \
                patch.object(KitContext, "require_uv", lambda _self: Path("uv")):
            return notebook.sync_helpers(self.ctx)

    def test_no_notebook_environment_nothing_to_do(self) -> None:
        self.assertFalse(self.run_sync())
        self.assertEqual(self.calls, [])

    def test_changed_kit_code_reinstalls_the_two_packages_once(self) -> None:
        self.environment()
        self.manifest.set_many({"components.notebook.helpers_digest": "from-the-old-kit"})
        self.assertTrue(self.run_sync())
        label, *command = self.calls[0]
        self.assertIn("helpers", label)
        self.assertIn("exakit-nb", command)
        self.assertIn(str(ROOT / "notebook" / "package"), command)
        self.assertIn(str(ROOT / "packages" / "exasol-mlflow"), command)
        self.assertEqual(self.manifest.get("components.notebook.helpers_digest"), notebook._helpers_digest(self.ctx))
        self.assertFalse(self.run_sync())                 # recorded: the next open does nothing
        self.assertEqual(len(self.calls), 1)

    def test_an_environment_the_kit_does_not_own_is_left_alone(self) -> None:
        self.environment()
        self.manifest.set_many({"components.notebook.ownership": "user"})
        self.assertFalse(self.run_sync())


if __name__ == "__main__":
    unittest.main()
