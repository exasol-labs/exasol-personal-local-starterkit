"""The database's TLS pin as the add-ons' launchers hand it on (audit SEC-14).

The kit records the fingerprint of the local database's certificate in the manifest (runtime.tls_fingerprint,
setup/lib/tls_pin.py). The launchers of the add-ons that open their own connections - dash-server, dbt-exasol,
exasol-scheduler - read the manifest themselves and run on whatever Python the add-on brought, so this module needs
nothing but the standard library. With no fingerprint recorded every answer is the plain DSN, as before.
"""

from __future__ import annotations

import re

_HEX = re.compile(r"^[0-9a-f]{64}$")


def fingerprint(doc: dict) -> str | None:
    """The recorded pin, lowercase hex (the form exapump and the scheduler's engine match), or None."""
    recorded = str((doc.get("runtime") or {}).get("tls_fingerprint") or "").strip().lower()
    return recorded if _HEX.match(recorded) else None


def pinned_dsn(dsn: str, pin: str | None) -> str:
    """host/<pin>:port, the pyexasol form; the DSN unchanged without a pin or when it already names one."""
    if not pin or not dsn or "/" in dsn or ":" not in dsn:
        return dsn
    host, port = dsn.rsplit(":", 1)
    return f"{host}/{pin}:{port}"


def client_dsn(doc: dict) -> str:
    """runtime.dsn as a client of the kit's database should use it: pinned once a fingerprint is recorded."""
    dsn = str((doc.get("runtime") or {}).get("dsn") or "")
    return pinned_dsn(dsn, fingerprint(doc))


def host_port(dsn: str) -> tuple[str, int]:
    """(host, port) of a DSN with or without a pin; 127.0.0.1:8563 for what cannot be read."""
    host, _, port = dsn.partition(":")
    host = host.split("/", 1)[0] or "127.0.0.1"
    try:
        return host, int(port)
    except ValueError:
        return host, 8563
