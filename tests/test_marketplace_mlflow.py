"""MLflow command behavior is one Python implementation on both platforms."""

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
import mlflow_cli  # noqa: E402
from runtime import KitContext, Manifest  # noqa: E402


class MlflowCommandTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text(json.dumps({"components": {"udf_devkit": {"version": "0.1.0"}}}))
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.manifest, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_status_json_is_one_object_without_installed_kit(self) -> None:
        self.manifest.path.unlink()
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(mlflow_cli.mlflow_service, "state",
                                                     return_value={"status": "stopped", "url": None}):
            self.assertEqual(0, mlflow_cli.command(self.ctx, ["status", "--json"]))
        self.assertEqual("stopped", json.loads(output.getvalue())["status"])
        self.assertFalse(self.home.joinpath("manifest.json").exists())

    def test_start_marks_enabled_only_after_success(self) -> None:
        with patch.object(mlflow_cli, "_server", return_value=Path("/kit/mlflow")), \
             patch.object(mlflow_cli.mlflow_service, "start", return_value={"status": "running", "url": "http://127.0.0.1:5000"}):
            self.assertEqual(0, mlflow_cli.command(self.ctx, ["start", "--port", "5000"]))
        self.assertIs(self.manifest.get("components.udf_devkit.mlflow.enabled"), True)

    def test_start_failure_keeps_disabled(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()), \
             patch.object(mlflow_cli, "_server", side_effect=RuntimeError("package missing")):
            self.assertEqual(1, mlflow_cli.command(self.ctx, ["start"]))
        self.assertIsNone(self.manifest.get("components.udf_devkit.mlflow.enabled"))

    def test_disable_stops_and_clears_enabled_receipt(self) -> None:
        self.manifest.set_many({"components.udf_devkit.mlflow.enabled": True})
        with patch.object(mlflow_cli.mlflow_service, "stop", return_value={"status": "stopped", "url": None}):
            self.assertEqual(0, mlflow_cli.command(self.ctx, ["stop", "--disable", "--json"]))
        self.assertIs(self.manifest.get("components.udf_devkit.mlflow.enabled"), False)

    def test_invalid_option_refused_before_service_action(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()), \
             patch.object(mlflow_cli.mlflow_service, "start") as start:
            with self.assertRaises(SystemExit) as error:
                mlflow_cli.command(self.ctx, ["start", "--disable"])
        self.assertEqual(2, error.exception.code)
        start.assert_not_called()

    def test_json_refusal_is_one_object_with_actionable_dependency(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(mlflow_cli.mlflow_service, "start") as start:
            self.assertEqual(2, mlflow_cli.command(self.ctx, ["start", "--disable", "--json"]))
        self.assertTrue(json.loads(output.getvalue())["rejected"])
        start.assert_not_called()

        self.manifest.delete("components.udf_devkit")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(1, mlflow_cli.command(self.ctx, ["start", "-j"]))
        self.assertEqual("exakit marketplace udf-devkit", json.loads(output.getvalue())["remedy"])

    def test_replay_missing_notebook_is_json_refusal(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(1, mlflow_cli.command(self.ctx, ["replay", "-j"]))
        self.assertEqual("exakit marketplace notebook", json.loads(output.getvalue())["remedy"])

    def test_server_version_is_pinned_in_root_manifest(self) -> None:
        self.assertEqual("3.17.2", mlflow_cli._server_pin(self.ctx))


if __name__ == "__main__":
    unittest.main()
