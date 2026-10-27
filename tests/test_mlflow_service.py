"""Server lifecycle without starting a real MLflow process (python3 tests/test_mlflow_service.py)."""
from __future__ import annotations

import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
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

    def test_the_server_is_recognised_by_the_path_form_it_was_started_with(self):
        # start() passes the resolved, forward-slash path in the sqlite URI; on Windows a plain str() of the same
        # path has backslashes, and on macOS /var is a symlink - either way the server must still be known as ours.
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}):
            started = "mlflow server --backend-store-uri sqlite:///" + (service.folder() / "mlflow.db").resolve().as_posix()
            with mock.patch.object(service, "process_command", return_value=started):
                self.assertTrue(service.ours({"pid": 4321}))
            with mock.patch.object(service, "process_command", return_value=started.replace("mlflow.db", "other.db")):
                self.assertFalse(service.ours({"pid": 4321}))
            with mock.patch.object(service, "process_command", return_value="python other_app.py " + started.split(" ", 2)[2]):
                self.assertFalse(service.ours({"pid": 4321}), "a process that is not an MLflow server is never ours")

        class WindowsPath:                       # str() with backslashes, as_posix() with slashes, like on Windows
            def __init__(self, text):
                self.text = text
            def __truediv__(self, name):
                return WindowsPath(self.text + "\\" + name)
            def __str__(self):
                return self.text
            def as_posix(self):
                return self.text.replace("\\", "/")
            def resolve(self):
                return self
        home = WindowsPath(r"C:\Users\pat\.exasol-starter-kit\mlflow")
        windows = r"C:\kit\notebook-venv\Scripts\mlflow.exe server --backend-store-uri sqlite:///C:/Users/pat/.exasol-starter-kit/mlflow/mlflow.db"
        with mock.patch.object(service, "folder", return_value=home), \
                mock.patch.object(service, "process_command", return_value=windows):
            self.assertTrue(service.ours({"pid": 4321}), "on Windows the started server is found by its forward-slash path")

    def test_stop_ends_our_server_and_removes_the_record(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}):
            target = service.record_path()
            target.parent.mkdir()
            target.write_text(json.dumps({"pid": 999999, "url": "http://127.0.0.1:5000", "port": 5000}))
            alive = iter([True, True, False, False])
            with mock.patch.object(service, "ours", side_effect=lambda doc: next(alive)), \
                    mock.patch.object(service.os, "getpgid", return_value=1), \
                    mock.patch.object(service.os, "kill") as kill:
                self.assertEqual(service.stop()["status"], "stopped")
            kill.assert_called_once()
            self.assertEqual(kill.call_args.args[0], 999999)
            self.assertFalse(target.exists())

    def test_a_running_server_is_reused_not_started_twice(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}):
            running = {"status": "running", "url": "http://127.0.0.1:5107", "pid": 1}
            with mock.patch.object(service, "state", return_value=running), \
                    mock.patch.object(service.subprocess, "Popen") as spawn:
                self.assertEqual(service.start(Path(tmp) / "nope", None), running)
            spawn.assert_not_called()

    def test_the_command_line_answers(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}):
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(service.main(["status", "--json"]), 0)
            doc = json.loads(out.getvalue())
            self.assertEqual((doc["ok"], doc["status"], doc["url"]), (True, "stopped", None))
            out = io.StringIO()
            with redirect_stdout(out), mock.patch.object(service, "start", side_effect=RuntimeError("MLflow did not start")):
                self.assertEqual(service.main(["start", "--executable", "x", "--json"]), 1)
            self.assertEqual(json.loads(out.getvalue()), {"ok": False, "error": "MLflow did not start", "remedy": "exakit logs mlflow"})
            for argv in (["status", "--port", "5000"], ["start", "--port", "0", "--executable", "x"], ["start"]):
                with self.subTest(argv=argv), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as stop:
                    service.main(argv)
                self.assertEqual(stop.exception.code, 2)

    def test_explicit_busy_port_is_refused(self):
        socket = mock.MagicMock()
        socket.__enter__.return_value.bind.side_effect = OSError("busy")
        with mock.patch.object(service.socket, "socket", return_value=socket):
            with self.assertRaisesRegex(RuntimeError, "No free port"):
                service.free_port(5107, 0)


if __name__ == "__main__":
    unittest.main()
