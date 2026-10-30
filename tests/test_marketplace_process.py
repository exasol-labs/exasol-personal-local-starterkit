"""Service lifecycle must only stop a process whose identity the kit recorded."""

from __future__ import annotations

import socket
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from process import ManagedProcess  # noqa: E402


class ManagedProcessTest(unittest.TestCase):
    def test_local_service_starts_and_stops(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            marker = folder / "server.py"
            marker.write_text("from http.server import HTTPServer, BaseHTTPRequestHandler\n"
                              "import sys\n"
                              "class Handler(BaseHTTPRequestHandler):\n"
                              "    def do_GET(self):\n"
                              "        self.send_response(200); self.end_headers()\n"
                              "HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()\n")
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


if __name__ == "__main__":
    unittest.main()
