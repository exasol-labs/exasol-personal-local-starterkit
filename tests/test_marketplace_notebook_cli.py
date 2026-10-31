"""Notebook contracts through the public Bash and PowerShell entry points."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class NotebookCliTest(unittest.TestCase):
    def test_commands_preserve_data_and_report_recovery(self) -> None:
        commands = []
        if os.name != "nt":
            commands.append(["bash", str(ROOT / "setup/exakit")])
        for shell in (("powershell", "pwsh") if os.name == "nt" else ("pwsh",)):
            if shutil.which(shell):
                commands.append([shell, "-NoProfile", "-File", str(ROOT / "setup/exakit.ps1")])
        self.assertTrue(commands, "No supported CLI shell available")
        for entry in commands:
            with self.subTest(shell=entry[0]), tempfile.TemporaryDirectory(prefix="notebook cli ") as temp:
                base = Path(temp)
                home = base / "kit home"
                home.mkdir()
                bin_dir = base / "kit bin"
                bin_dir.mkdir()
                manifest = home / "manifest.json"
                manifest.write_text('{}', encoding="utf-8")
                environment = {key: value for key, value in os.environ.items()
                               if not key.startswith("EXAKIT_")}
                environment.update(EXAKIT_HOME=str(home), EXAKIT_BIN_DIR=str(bin_dir),
                                   EXAKIT_NO_FANCY="1", EXAKIT_NO_UPDATE_NOTICE="1",
                                   HOME=str(base), USERPROFILE=str(base))

                def run(*args):
                    return subprocess.run([*entry, "notebook", *args], env=environment,
                                          input="", capture_output=True, text=True, timeout=45)

                missing = run("jupyterlab", "--no-browser")
                self.assertNotEqual(0, missing.returncode)
                self.assertIn("exakit marketplace notebook", missing.stdout + missing.stderr)
                receipt = {"components": {"notebook": {"version": "3.1.0", "ownership": "kit"}}}
                manifest.write_text(json.dumps(receipt), encoding="utf-8")
                user_file = home / "notebooks" / "analysis.ipynb"
                user_file.parent.mkdir()
                user_file.write_text("my notebook", encoding="utf-8")
                for args, expected in ((["--invented"], "Unknown option"),
                                       (["--port", "99999"], "port"),
                                       (["jupyterlab", "--no-browser"], "exakit update notebook")):
                    with self.subTest(args=args):
                        result = run(*args)
                        self.assertNotEqual(0, result.returncode)
                        self.assertIn(expected, result.stdout + result.stderr)
                for args in (("stop",), ("marimo", "stop"), ("positron", "stop")):
                    result = run(*args)
                    self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual(receipt, json.loads(manifest.read_text(encoding="utf-8-sig")))
                self.assertEqual("my notebook", user_file.read_text(encoding="utf-8"))
                self.assertFalse((home / "notebook-venv").exists())


if __name__ == "__main__":
    unittest.main()
