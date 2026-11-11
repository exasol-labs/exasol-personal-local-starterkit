"""Service lifecycle must only stop a process whose identity the kit recorded."""

from __future__ import annotations

import socket
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from process import ManagedProcess  # noqa: E402
from runtime import AddonFailure  # noqa: E402


class ManagedProcessTest(unittest.TestCase):
    def test_local_service_starts_and_stops(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            marker = folder / "server.py"
            # socketserver.TCPServer, not http.server.HTTPServer: HTTPServer looks up socket.getfqdn() when it
            # binds, which takes longer than the start timeout on a CI runner whose DNS does not answer quickly.
            marker.write_text("from http.server import BaseHTTPRequestHandler\n"
                              "import socketserver, sys\n"
                              "class Handler(BaseHTTPRequestHandler):\n"
                              "    def do_GET(self):\n"
                              "        self.send_response(200); self.end_headers()\n"
                              "socketserver.TCPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()\n")
            with socket.socket() as probe:
                try:
                    probe.bind(("127.0.0.1", 0))
                except PermissionError:
                    self.skipTest("local TCP bind is blocked by this sandbox")
                port = probe.getsockname()[1]
            service = ManagedProcess(folder / "server.pid", folder / "server.log", marker)
            try:
                service.start([sys.executable, str(marker), str(port)], port, seconds=10)
                self.assertEqual("running", service.status(port))
            finally:
                service.stop(port)
            self.assertEqual("stopped", service.status(port))
            self.assertFalse(service.pidfile.exists())

    def test_a_start_that_loses_the_race_to_another_starter_is_not_a_failure(self) -> None:
        """Two starters bring the same service up at once (the kit's install, and the login service it registers).
        The one that loses exits, because the port is taken. The service is running, so the start succeeded; it
        fails only when nobody's process of this service holds the port."""
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            marker = folder / "server.py"
            marker.write_text("import socketserver, sys, time\n"
                              "from http.server import BaseHTTPRequestHandler\n"
                              "if sys.argv[2] == 'lose': time.sleep(1.5); sys.exit(1)\n"
                              "if sys.argv[2] == 'late': time.sleep(2.5)\n"
                              "socketserver.TCPServer(('127.0.0.1', int(sys.argv[1])), BaseHTTPRequestHandler).serve_forever()\n")
            with socket.socket() as probe:
                try:
                    probe.bind(("127.0.0.1", 0))
                except PermissionError:
                    self.skipTest("local TCP bind is blocked by this sandbox")
                port = probe.getsockname()[1]
            service = ManagedProcess(folder / "server.pid", folder / "server.log", marker)
            # The other starter's process: the same service, listening a moment after ours has given up.
            other = subprocess.Popen([sys.executable, str(marker), str(port), "late"], stdin=subprocess.DEVNULL,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                service.start([sys.executable, str(marker), str(port), "lose"], port, seconds=20)
                self.assertEqual("running", service.status(port))
                self.assertIsNone(other.poll(), "the other starter's process is the one left running")
            finally:
                other.terminate()
                other.wait(timeout=5)
            self.assertEqual("stopped", service.status(port))
            with self.assertRaisesRegex(AddonFailure, "exited with code 1"):          # nobody else: a real failure
                with unittest.mock.patch.object(ManagedProcess, "_another_started", return_value=False):
                    service.start([sys.executable, str(marker), str(port), "lose"], port, seconds=20)

    def test_start_timeout_cleans_its_pid_and_can_retry(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            marker = folder / "server.py"
            marker.write_text("import socketserver, sys, time\n"
                              "from http.server import BaseHTTPRequestHandler\n"
                              "if sys.argv[2] == 'delay': time.sleep(60)\n"
                              "socketserver.TCPServer(('127.0.0.1', int(sys.argv[1])), BaseHTTPRequestHandler).serve_forever()\n")
            with socket.socket() as probe:
                try:
                    probe.bind(("127.0.0.1", 0))
                except PermissionError:
                    self.skipTest("local TCP bind is blocked by this sandbox")
                port = probe.getsockname()[1]
            other = folder / "other-service.json"
            other.write_text('{"ownership":"user","pid":123}')
            service = ManagedProcess(folder / "server.pid", folder / "server.log", marker)
            try:
                with self.assertRaisesRegex(AddonFailure, "Service did not start"):
                    service.start([sys.executable, str(marker), str(port), "delay"], port, seconds=1)
                self.assertFalse(service.pidfile.exists())
                self.assertEqual("stopped", service.status(port))
                service.start([sys.executable, str(marker), str(port), "ready"], port, seconds=10)
                self.assertEqual("running", service.status(port))
                self.assertEqual('{"ownership":"user","pid":123}', other.read_text())
            finally:
                service.stop(port)


if __name__ == "__main__":
    unittest.main()
