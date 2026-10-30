"""Notebook marketplace child rows and selected-key handoff."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
import metadata  # noqa: E402
from model import CatalogError  # noqa: E402


class NotebookChoicesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)

    def test_rows_keep_versions_descriptions_and_default_ticks(self) -> None:
        document = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))
        document["components"]["notebook"]["frontends"]["jupyterlab"] = "99.1.2"
        active = self.home / "versions.json"
        active.write_text(json.dumps(document), encoding="utf-8")
        env = {"EXAKIT_HOME": str(self.home), "EXAKIT_MARKETPLACE_VERSIONS_DOC": str(active),
               "EXAKIT_NOTEBOOK_MARIMO": "skip"}
        with patch.dict(os.environ, env, clear=True), \
             patch("addons.notebook._external_jupyter", return_value=None), \
             patch("notebook_cli._positron_command", return_value=None):
            rows = metadata.notebook_choices(ROOT, "notebook-rows")
        self.assertEqual(3, len(rows))
        self.assertIn("jupyterlab|JupyterLab|99.1.2|not on this machine", rows[0])
        self.assertTrue(rows[0].endswith("|1"))
        self.assertTrue(rows[1].endswith("|0"))
        self.assertTrue(rows[2].endswith("|1"))

    def test_normalization_uses_catalog_order_and_rejects_unknown(self) -> None:
        self.assertEqual(["jupyterlab,positron"],
                         metadata.notebook_choices(ROOT, "notebook-normalize", "positron,jupyterlab"))
        self.assertEqual(["none"], metadata.notebook_choices(ROOT, "notebook-normalize", ""))
        with self.assertRaisesRegex(CatalogError, "Unknown notebook choice"):
            metadata.notebook_choices(ROOT, "notebook-normalize", "unlisted")

    def test_rows_report_external_jupyter_and_positron(self) -> None:
        external = self.home / "tools" / "jupyter-lab"
        env = {"EXAKIT_HOME": str(self.home), "EXAKIT_VERSION_POLICY": "pinned"}
        with patch.dict(os.environ, env, clear=True), \
             patch("addons.notebook._external_jupyter", return_value=external), \
             patch("notebook_cli._positron_command", return_value="positron"):
            rows = metadata.notebook_choices(ROOT, "notebook-rows")
        self.assertIn("yours (", rows[0])
        self.assertIn("jupyter-lab) is used as it is", rows[0])
        self.assertIn("yours: pointed at the kit's Python", rows[2])

    def test_bash_fallback_stops_before_menu_on_bad_frontends(self) -> None:
        script = (f'. "{ROOT / "setup/lib/common.sh"}"\n'
                  'ui_checkbox_menu() { printf "MENU OPENED\\n"; }\n'
                  'notebook_questions\n')
        env = {**os.environ, "EXAKIT_HOME": str(self.home), "EXAKIT_VERSION_POLICY": "pinned",
               "EXAKIT_NOTEBOOK_FRONTENDS": "unknown-tool"}
        result = subprocess.run(["bash", "-c", script], env=env, text=True,
                                capture_output=True, timeout=30, check=False)
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("MENU OPENED", result.stdout)
        self.assertIn("Unknown or repeated notebook frontend", result.stderr)

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell is not installed")
    def test_powershell_fallback_uses_python_rows_and_selected_keys(self) -> None:
        script = (f'. "{ROOT / "setup/lib/exakit-common.ps1"}"\n'
                  f'. "{ROOT / "setup/lib/persona.ps1"}"\n'
                  '$rows = @(Get-NotebookTableChildren)\n'
                  'Set-NotebookTableChildrenPicked -Keys @("positron", "marimo")\n'
                  '"$($rows.Count)|$($rows[0].Key)|$env:EXAKIT_NOTEBOOK_FRONTENDS"\n')
        env = {**os.environ, "EXAKIT_HOME": str(self.home), "EXAKIT_VERSION_POLICY": "pinned"}
        result = subprocess.run(["pwsh", "-NoProfile", "-Command", script], env=env,
                                text=True, capture_output=True, timeout=45, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("3|jupyterlab|marimo,positron", result.stdout)


if __name__ == "__main__":
    unittest.main()
