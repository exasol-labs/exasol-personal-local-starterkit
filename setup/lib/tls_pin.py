"""The local database's TLS certificate pin (audit SEC-14). Standard library only, Python 3.8+.

The kit's database serves a self-signed certificate, so no client can validate it against a CA. Without a pin,
anything that answers TLS on 127.0.0.1:8563 first (a port squatter) receives the SYS password from every kit
client. The kit therefore records the certificate's fingerprint ONCE, at the moment it has itself just deployed
or started its own database (trust on first use, manifest key runtime.tls_fingerprint), and every kit-built
client pins it:

  - exapump:  certificate_fingerprint = "<hex>" in the profile (compared case-sensitively: lowercase only)
  - pyexasol: dsn "host/<hex>:port" (pyexasol compares case-insensitively)
  - the Exasol MCP server: EXA_DSN, which it hands to pyexasol unchanged

The fingerprint is the lowercase hex SHA-256 of the server's DER certificate - the value both drivers compare.
Both shells (bash and PowerShell) call this one file for the live value; nothing here reads or prints a secret.

    python3 tls_pin.py fingerprint <host> <port> [--timeout SECONDS]
        Print the live fingerprint. Exit 1, with one line on stderr, when nothing answers TLS there.
    python3 tls_pin.py pinned-dsn <dsn> [<fingerprint>]
        Print the DSN with the fingerprint in pyexasol's form (the DSN unchanged without one). Exit 2 on a
        malformed DSN or fingerprint.
"""

from __future__ import annotations

import hashlib
import re
import socket
import ssl
import sys

FINGERPRINT = re.compile(r"[0-9a-f]{64}")


def normalize(value: object) -> str | None:
    """A recorded fingerprint as both drivers accept it (lowercase hex, 64 digits), or None when it is not one."""
    text = str(value or "").strip().lower()
    return text if FINGERPRINT.fullmatch(text) else None


def _split_dsn(dsn: str) -> tuple[str, str]:
    """host and port of HOST:PORT (an existing /fingerprint on the host is dropped). ValueError when not that shape."""
    host, sep, port = str(dsn or "").strip().rpartition(":")
    if not sep or not host or not port.isdigit():
        raise ValueError(f"not a HOST:PORT dsn: {dsn!r}")
    return host.split("/", 1)[0], port


def fingerprint(host: str, port: int | str, timeout: float = 10) -> str:
    """The lowercase hex SHA-256 of the DER certificate served at host:port. OSError (incl. ssl.SSLError and
    socket.timeout) when nothing completes a TLS handshake there. The certificate is not validated here: reading
    it is the point, and the value is only ever compared, never trusted on its own."""
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with socket.create_connection((str(host).strip("[]"), int(port)), timeout=timeout) as raw:
        with context.wrap_socket(raw, server_hostname=str(host).strip("[]") or "localhost") as tls:
            der = tls.getpeercert(binary_form=True)
    if not der:
        raise OSError("the server completed the handshake without a certificate")
    return hashlib.sha256(der).hexdigest()


def pinned_dsn(dsn: str, fp: str | None) -> str:
    """HOST:PORT with the fingerprint in pyexasol's form, HOST/<fp>:PORT; the DSN unchanged when fp is empty.
    ValueError on a malformed DSN, or a fingerprint that is not 64 hex digits."""
    if not fp:
        return dsn
    clean = normalize(fp)
    if clean is None:
        raise ValueError("not a SHA-256 fingerprint")
    host, port = _split_dsn(dsn)
    return f"{host}/{clean}:{port}"


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[0] == "fingerprint":
        timeout = 10.0
        rest = argv[3:]
        if rest[:1] == ["--timeout"] and len(rest) == 2:
            try:
                timeout = float(rest[1])
            except ValueError:
                rest = ["bad"]
            else:
                rest = []
        if rest or not argv[2].isdigit():
            print(__doc__, file=sys.stderr)
            return 2
        try:
            print(fingerprint(argv[1], int(argv[2]), timeout))
        except (OSError, ValueError) as error:
            reason = str(error) or type(error).__name__
            print(f"tls_pin: {argv[1]}:{argv[2]} does not answer TLS ({reason})", file=sys.stderr)
            return 1
        return 0
    if len(argv) in (2, 3) and argv[0] == "pinned-dsn":
        try:
            print(pinned_dsn(argv[1], argv[2] if len(argv) == 3 else None))
        except ValueError as error:
            print(f"tls_pin: {error}", file=sys.stderr)
            return 2
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
