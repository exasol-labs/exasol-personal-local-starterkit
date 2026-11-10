"""runtime.open_url never hands a token to another host on a redirect (SEC-12)."""

from __future__ import annotations

import sys
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from runtime import open_url  # noqa: E402

SEEN: list[str | None] = []


class _Target(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        SEEN.append(self.headers.get("Authorization"))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *_args) -> None:
        pass


def _redirect_to(location: str):
    class _Redirect(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            self.send_response(301)
            self.send_header("Location", location)
            self.end_headers()

        def log_message(self, *_args) -> None:
            pass
    return _Redirect


class RedirectAuthTest(unittest.TestCase):
    def setUp(self) -> None:
        SEEN.clear()
        self.servers = []

    def tearDown(self) -> None:
        for server in self.servers:
            server.shutdown()

    def serve(self, handler) -> int:
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.servers.append(server)
        return server.server_address[1]

    def fetch(self, url: str) -> None:
        request = urllib.request.Request(url, headers={"Authorization": "Bearer t0ken"})
        with open_url(request, timeout=10) as response:
            response.read()

    def test_a_redirect_to_another_host_drops_the_token(self) -> None:
        target = self.serve(_Target)
        start = self.serve(_redirect_to(f"http://localhost:{target}/next"))
        self.fetch(f"http://127.0.0.1:{start}/first")
        self.assertEqual(SEEN, [None])

    def test_a_redirect_on_the_same_host_keeps_it(self) -> None:
        target = self.serve(_Target)
        start = self.serve(_redirect_to(f"http://127.0.0.1:{target}/next"))
        self.fetch(f"http://127.0.0.1:{start}/first")
        self.assertEqual(SEEN, ["Bearer t0ken"])


if __name__ == "__main__":
    unittest.main()
