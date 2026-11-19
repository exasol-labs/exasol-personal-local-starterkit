"""A stand-in for the database's TLS port, for the TLS-pin tests (audit SEC-14). No database, no network.

    python3 tests/lib/tls_server.py cert <dir> <name>
        Generate a self-signed certificate <dir>/<name>.pem with its key <dir>/<name>.key (openssl), and print the
        lowercase hex SHA-256 of its DER form - the value setup/lib/tls_pin.py must report for it.
    python3 tests/lib/tls_server.py serve <cert.pem> <key> <portfile>
        Answer TLS handshakes on 127.0.0.1 at a port the OS picks, written to <portfile> once listening; runs until
        killed. Every connection gets the certificate and is closed.

Exit 77 from `cert` when there is no openssl (the callers skip).
"""

from __future__ import annotations

import hashlib
import os
import shutil
import socket
import ssl
import subprocess
import sys
import threading
from pathlib import Path


def make_cert(folder: Path, name: str) -> str:
    """A fresh self-signed pair in folder; the certificate's fingerprint."""
    if not shutil.which("openssl"):
        raise FileNotFoundError("openssl")
    folder.mkdir(parents=True, exist_ok=True)
    cert, key = folder / f"{name}.pem", folder / f"{name}.key"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key),
                    "-out", str(cert), "-days", "2", "-subj", f"/CN={name}"],
                   check=True, capture_output=True)
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()


class Server:
    """A TLS listener on 127.0.0.1 in a daemon thread; .port, .close()."""

    def __init__(self, cert: Path, key: Path):
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(str(cert), str(key))
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self) -> None:
        while True:
            try:
                raw, _ = self.sock.accept()
            except OSError:
                return
            try:
                raw.settimeout(5)
                with self.context.wrap_socket(raw, server_side=True):
                    pass
            except (OSError, ssl.SSLError):
                try:
                    raw.close()
                except OSError:
                    pass

    def close(self) -> None:
        self.sock.close()


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "cert":
        try:
            print(make_cert(Path(argv[1]), argv[2]))
        except FileNotFoundError:
            return 77
        return 0
    if len(argv) == 4 and argv[0] == "serve":
        server = Server(Path(argv[1]), Path(argv[2]))
        tmp = argv[3] + ".tmp"
        Path(tmp).write_text(str(server.port))
        os.replace(tmp, argv[3])
        server.thread.join()
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
