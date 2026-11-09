"""udf-devkit's status names a removed notebook add-on instead of a bare "stopped" (DAY-06).

The MLflow server, its login entry and the container build tools run from the notebook environment, so removing
the notebook add-on stops them; the status says why and what brings them back.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from addons import udf_devkit  # noqa: E402
from runtime import KitContext, Manifest, venv_python  # noqa: E402


class UdfStatusTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        home = Path(self.temp.name) / "kit"
        home.mkdir()
        manifest = Manifest(home / "manifest.json")
        manifest.path.write_text(json.dumps({"components": {"udf_devkit": {"mlflow": {"enabled": True}}}}))
        self.ctx = KitContext(ROOT, home, Path(self.temp.name) / "bin", manifest, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_without_the_notebook_environment_status_names_it(self) -> None:
        with patch.object(udf_devkit, "_mlflow") as mlflow:
            state = udf_devkit.status(self.ctx)
        self.assertIn("needs the notebook add-on", state)
        self.assertIn("exakit marketplace notebook", state)
        mlflow.assert_not_called()

    def test_with_it_status_is_the_server_state(self) -> None:
        from addons.notebook import paths

        python = venv_python(paths(self.ctx)[0])
        python.parent.mkdir(parents=True)
        python.write_text("", encoding="utf-8")
        answer = subprocess.CompletedProcess([], 0, stdout='{"status": "running"}', stderr="")
        with patch.object(udf_devkit, "_mlflow", return_value=answer):
            self.assertEqual(udf_devkit.status(self.ctx), "running")


if __name__ == "__main__":
    unittest.main()
