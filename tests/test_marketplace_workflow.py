"""Workflow command argument and notebook environment contract."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
import workflow_cli  # noqa: E402
from runtime import KitContext, Manifest  # noqa: E402


class WorkflowCliTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text(json.dumps({"components": {"notebook": {"version": "3.1.0"}}}))
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.manifest, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_invalid_id_refused_before_notebook_process(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(workflow_cli.subprocess, "run") as run:
            self.assertEqual(2, workflow_cli.command(self.ctx, ["show", "../other", "--json"]))
        run.assert_not_called()
        self.assertTrue(json.loads(output.getvalue())["rejected"])

    def test_missing_notebook_json_names_a_command_remedy(self) -> None:
        self.manifest.delete("components.notebook")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(1, workflow_cli.command(self.ctx, ["list", "--json"]))
        payload = json.loads(output.getvalue())
        self.assertEqual("exakit marketplace notebook", payload["remedy"])
        self.assertFalse(payload["rejected"])

    def test_list_runs_notebook_module_without_warning_prone_m_flag(self) -> None:
        python = self.home / "notebook-venv/bin/python"
        python.parent.mkdir(parents=True)
        python.touch()
        result = type("Result", (), {"returncode": 0, "stdout": "[]\n", "stderr": ""})()
        with patch.object(workflow_cli.subprocess, "run", return_value=result) as run, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, workflow_cli.command(self.ctx, ["list", "--json"]))
        args, kwargs = run.call_args
        self.assertEqual(str(python), args[0][0])
        self.assertEqual("-c", args[0][1])
        self.assertEqual(["list", "--json"], args[0][-2:])
        self.assertEqual(str(self.home), kwargs["env"]["EXAKIT_HOME"])
        self.assertTrue(kwargs["capture_output"])

    def test_missing_workflow_json_is_one_failure_object(self) -> None:
        python = self.home / "notebook-venv/bin/python"
        python.parent.mkdir(parents=True)
        python.touch()
        result = type("Result", (), {"returncode": 1, "stdout": "", "stderr": "workflow is absent\n"})()
        output = io.StringIO()
        with patch.object(workflow_cli.subprocess, "run", return_value=result), \
             contextlib.redirect_stdout(output):
            self.assertEqual(1, workflow_cli.command(self.ctx, ["show", "wf-20200101-abcdef", "--json"]))
        self.assertEqual("workflow is absent", json.loads(output.getvalue())["error"])

    def test_missing_notebook_is_a_read_only_refusal(self) -> None:
        self.manifest.delete("components.notebook")
        with contextlib.redirect_stderr(io.StringIO()), patch.object(workflow_cli.subprocess, "run") as run:
            self.assertEqual(1, workflow_cli.command(self.ctx, ["list"]))
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
