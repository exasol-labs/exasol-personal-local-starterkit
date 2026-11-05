"""The database's TLS pin (audit SEC-14): setup/lib/tls_pin.py and the Python clients that apply it.

    python3 -m unittest tests/test_tls_pin.py

What it pins:
  - fingerprint() reports the lowercase hex SHA-256 of the DER certificate a TLS port serves - checked against a
    local TLS server started here with a freshly generated self-signed certificate - and the CLI prints the same,
    or exits 1 with one line when nothing answers TLS
  - pinned_dsn() is pyexasol's host/<fp>:port, the DSN unchanged without a fingerprint, and refuses a malformed one
  - the MCP stdio server's EXA_DSN, the marketplace's client DSN and the notebook helpers carry the pin exactly when
    the manifest records one, and are unchanged otherwise
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "setup" / "lib"))
sys.path.insert(0, str(ROOT / "tests" / "lib"))
sys.path.insert(0, str(ROOT / "marketplace"))
sys.path.insert(0, str(ROOT / "notebook" / "package"))

import tls_pin  # noqa: E402
import tls_server  # noqa: E402

FP = "9b82cc4885a52d4372333b60ce0b0e88bce82e03809c6dd08c4d737af9d398ae"
CLI = [sys.executable, str(ROOT / "setup" / "lib" / "tls_pin.py")]


def _closed_port() -> int:
    import socket
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


@unittest.skipUnless(shutil.which("openssl"), "needs openssl to make a self-signed certificate")
class LiveFingerprint(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = Path(tempfile.mkdtemp())
        cls.expected = tls_server.make_cert(cls.folder, "one")
        cls.other = tls_server.make_cert(cls.folder, "two")
        cls.server = tls_server.Server(cls.folder / "one.pem", cls.folder / "one.key")

    @classmethod
    def tearDownClass(cls):
        cls.server.close()
        shutil.rmtree(cls.folder, ignore_errors=True)

    def test_reports_the_sha256_of_the_der_certificate(self):
        value = tls_pin.fingerprint("127.0.0.1", self.server.port, timeout=5)
        self.assertEqual(value, self.expected)
        self.assertRegex(value, r"^[0-9a-f]{64}$")   # lowercase: exapump compares case-sensitively
        self.assertNotEqual(value, self.other)

    def test_is_stable_across_connections(self):
        self.assertEqual(tls_pin.fingerprint("127.0.0.1", self.server.port),
                         tls_pin.fingerprint("127.0.0.1", str(self.server.port)))

    def test_cli_prints_it(self):
        done = subprocess.run(CLI + ["fingerprint", "127.0.0.1", str(self.server.port)],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), self.expected)

    def test_cli_exits_1_when_nothing_answers_tls(self):
        port = _closed_port()
        done = subprocess.run(CLI + ["fingerprint", "127.0.0.1", str(port), "--timeout", "2"],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 1)
        self.assertEqual(done.stdout, "")
        self.assertIn("does not answer TLS", done.stderr)
        self.assertEqual(len(done.stderr.strip().splitlines()), 1)

    def test_a_plain_tcp_listener_is_not_tls(self):
        import socket
        import threading
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)

        def answer():
            conn, _ = listener.accept()
            conn.sendall(b"HTTP/1.0 200 OK\r\n\r\n")
            conn.close()

        threading.Thread(target=answer, daemon=True).start()
        try:
            with self.assertRaises(OSError):
                tls_pin.fingerprint("127.0.0.1", listener.getsockname()[1], timeout=3)
        finally:
            listener.close()


class PinnedDsn(unittest.TestCase):
    def test_pyexasol_form(self):
        self.assertEqual(tls_pin.pinned_dsn("127.0.0.1:8563", FP), f"127.0.0.1/{FP}:8563")

    def test_uppercase_is_lowered(self):
        self.assertEqual(tls_pin.pinned_dsn("127.0.0.1:8563", FP.upper()), f"127.0.0.1/{FP}:8563")

    def test_unchanged_without_a_fingerprint(self):
        self.assertEqual(tls_pin.pinned_dsn("127.0.0.1:8563", None), "127.0.0.1:8563")
        self.assertEqual(tls_pin.pinned_dsn("127.0.0.1:8563", ""), "127.0.0.1:8563")

    def test_an_old_pin_is_replaced_not_stacked(self):
        self.assertEqual(tls_pin.pinned_dsn(f"127.0.0.1/{'0' * 64}:8563", FP), f"127.0.0.1/{FP}:8563")

    def test_refuses_what_is_not_a_fingerprint_or_a_dsn(self):
        for bad in ("abc", FP[:-1], FP + "0", "z" * 64):
            with self.assertRaises(ValueError):
                tls_pin.pinned_dsn("127.0.0.1:8563", bad)
        with self.assertRaises(ValueError):
            tls_pin.pinned_dsn("127.0.0.1", FP)

    def test_normalize(self):
        self.assertEqual(tls_pin.normalize(FP.upper()), FP)
        self.assertIsNone(tls_pin.normalize("nope"))
        self.assertIsNone(tls_pin.normalize(None))

    def test_cli(self):
        done = subprocess.run(CLI + ["pinned-dsn", "127.0.0.1:8563", FP], capture_output=True, text=True)
        self.assertEqual((done.returncode, done.stdout.strip()), (0, f"127.0.0.1/{FP}:8563"))
        done = subprocess.run(CLI + ["pinned-dsn", "127.0.0.1:8563"], capture_output=True, text=True)
        self.assertEqual((done.returncode, done.stdout.strip()), (0, "127.0.0.1:8563"))
        done = subprocess.run(CLI + ["pinned-dsn", "127.0.0.1:8563", "xyz"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)
        done = subprocess.run(CLI + ["nonsense"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)


def _manifest(home: Path, fingerprint: str | None) -> Path:
    password = home / "credentials" / "mcp_readonly_password"
    password.parent.mkdir(parents=True, exist_ok=True)
    password.write_text("not-a-real-password\n")
    runtime = {"type": "personal", "dsn": "127.0.0.1:8563", "user": "sys",
               "password_file": str(home / "credentials" / "personal_sys_password")}
    if fingerprint is not None:
        runtime["tls_fingerprint"] = fingerprint
    document = {"runtime": runtime, "components": {"mcp_server": {
        "package": "exasol-mcp-server", "version": "2.4.0", "command": "uvx",
        "connection": {"user": "mcp_readonly", "password_file": str(password), "validated": True}}}}
    path = home / "manifest.json"
    path.write_text(json.dumps(document))
    return path


class McpStdioServer(unittest.TestCase):
    def _env(self, fingerprint):
        from mcp.runtime.exakit import ExakitRuntimeLoader
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            _manifest(home, fingerprint)
            loader = ExakitRuntimeLoader()
            with mock.patch.object(ExakitRuntimeLoader, "_resolve_mcp_command", return_value="uvx"):
                context = loader.load(home)
            return context.server_definition.env

    def test_exa_dsn_is_pinned_when_a_fingerprint_is_recorded(self):
        env = self._env(FP)
        self.assertEqual(env["EXA_DSN"], f"127.0.0.1/{FP}:8563")
        self.assertEqual(env["EXA_SSL_CERT_VALIDATION"], "no")   # self-signed: the pin is the check

    def test_exa_dsn_is_unchanged_without_one(self):
        self.assertEqual(self._env(None)["EXA_DSN"], "127.0.0.1:8563")

    def test_a_malformed_record_is_not_a_pin(self):
        self.assertEqual(self._env("not-hex")["EXA_DSN"], "127.0.0.1:8563")


class MarketplaceClientDsn(unittest.TestCase):
    def _dsn(self, fingerprint):
        from runtime import KitContext, Manifest
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            path = _manifest(home, fingerprint)
            return KitContext(ROOT, home, home / "bin", Manifest(path), Path("uv")).client_dsn()

    def test_pinned(self):
        self.assertEqual(self._dsn(FP), f"127.0.0.1/{FP}:8563")

    def test_unpinned(self):
        self.assertEqual(self._dsn(None), "127.0.0.1:8563")


class NotebookHelpers(unittest.TestCase):
    def test_pinned_dsn_matches_the_kit_helper(self):
        from exakit_nb import _kit
        self.assertEqual(_kit.pinned_dsn("127.0.0.1:8563", FP), tls_pin.pinned_dsn("127.0.0.1:8563", FP))
        self.assertEqual(_kit.pinned_dsn("127.0.0.1:8563", None), "127.0.0.1:8563")

    def test_tls_fingerprint_reads_the_manifest(self):
        from exakit_nb import _kit
        self.assertEqual(_kit.tls_fingerprint({"runtime": {"tls_fingerprint": FP.upper()}}), FP)
        self.assertIsNone(_kit.tls_fingerprint({"runtime": {"tls_fingerprint": "nope"}}))
        self.assertIsNone(_kit.tls_fingerprint({"runtime": {}}))
        self.assertIsNone(_kit.tls_fingerprint({}))

    def test_connect_passes_the_pinned_dsn_and_a_callers_dsn_wins(self):
        try:
            import exakit_nb
        except ImportError as error:   # the notebook environment's own packages (pandas, ...)
            self.skipTest(f"exakit_nb does not import here: {error}")

        class Store:
            def get(self, key, default=None):
                return {"db_host_name": "127.0.0.1", "db_port": "8563"}.get(getattr(key, "name", key), default)

        fake_config = SimpleNamespace(db_host_name="db_host_name", db_port="db_port")
        fake_module = SimpleNamespace(AILabConfig=fake_config)
        with mock.patch.dict(sys.modules, {"exasol.nb_connector.ai_lab_config": fake_module}), \
                mock.patch.object(exakit_nb, "tls_fingerprint", return_value=FP):
            self.assertEqual(exakit_nb._pinned(Store(), {})["dsn"], f"127.0.0.1/{FP}:8563")
            self.assertEqual(exakit_nb._pinned(Store(), {"dsn": "mine:1"})["dsn"], "mine:1")
        with mock.patch.object(exakit_nb, "tls_fingerprint", return_value=None):
            self.assertEqual(exakit_nb._pinned(Store(), {"schema": "X"}), {"schema": "X"})


if __name__ == "__main__":
    unittest.main()
