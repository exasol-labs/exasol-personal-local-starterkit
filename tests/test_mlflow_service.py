"""Server lifecycle without starting a real MLflow process (python3 tests/test_mlflow_service.py)."""
from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mlflow_service", ROOT / "setup/lib/mlflow_service.py")
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


class ServiceTest(unittest.TestCase):
    def test_status_is_read_only_and_names_remedy(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}):
            result = service.state()
            self.assertEqual(result["status"], "stopped")
            self.assertEqual(result["remedy"], "exakit mlflow start")
            self.assertFalse((Path(tmp) / "mlflow").exists())

    def test_stale_pid_is_never_killed(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}):
            target = service.record_path()
            target.parent.mkdir()
            target.write_text(json.dumps({"pid": os.getpid(), "url": "http://127.0.0.1:5000"}))
            with mock.patch.object(service, "process_command", return_value="unrelated program"), \
                    mock.patch.object(service.os, "kill") as kill:
                self.assertEqual(service.stop()["status"], "stopped")
            kill.assert_not_called()
            self.assertFalse(target.exists())

    def test_start_binds_localhost_records_healthy_process_and_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}):
            executable = Path(tmp) / "mlflow-command"
            executable.touch()
            child = mock.Mock(pid=4567)
            child.poll.return_value = None
            with mock.patch.object(service, "state", side_effect=[{"status": "stopped"}, {"status": "running", "url": "http://127.0.0.1:5107"}]), \
                    mock.patch.object(service, "free_port", return_value=5107), \
                    mock.patch.object(service, "healthy", return_value=True), \
                    mock.patch.object(service.subprocess, "Popen", return_value=child) as spawn:
                result = service.start(executable, 5107)
            self.assertEqual(result["status"], "running")
            command = spawn.call_args.args[0]
            self.assertEqual(command[1:6], ["server", "--host", "127.0.0.1", "--port", "5107"])
            self.assertIn("--artifacts-destination", command)
            self.assertEqual(json.loads(service.record_path().read_text())["pid"], 4567)
            self.assertTrue((Path(tmp) / "mlflow/artifacts").is_dir())

    def test_explicit_busy_port_is_refused(self):
        socket = mock.MagicMock()
        socket.__enter__.return_value.bind.side_effect = OSError("busy")
        with mock.patch.object(service.socket, "socket", return_value=socket):
            with self.assertRaisesRegex(RuntimeError, "No free port"):
                service.free_port(5107, 0)


if __name__ == "__main__":
    unittest.main()
