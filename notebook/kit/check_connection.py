"""Open the database from the encrypted store and run SELECT 1; exit 0 when it answers. Environment: SCS_FILE,
SCS_MASTER_PASSWORD, and EXAKIT_NB_DSN when the kit has pinned the database's TLS certificate (host/<fp>:port,
audit SEC-14): the connector's store has no field for a pin, and its open_pyexasol_connection takes the DSN as an
override, so pyexasol then refuses any other certificate.

Run by the Python marketplace with the notebook environment’s interpreter.
"""
import os
from pathlib import Path

# pyexasol's usage telemetry stays off unless the user set the variable (marketplace/kit_telemetry.py).
os.environ.setdefault("EXASOL_TELEMETRY_DISABLE", "1")

from exasol.nb_connector.connections import open_pyexasol_connection  # noqa: E402
from exasol.nb_connector.secret_store import Secrets  # noqa: E402
pinned = {"dsn": os.environ["EXAKIT_NB_DSN"]} if "/" in os.environ.get("EXAKIT_NB_DSN", "") else {}
conn = open_pyexasol_connection(Secrets(Path(os.environ["SCS_FILE"]), os.environ["SCS_MASTER_PASSWORD"]), **pinned)
try:
    raise SystemExit(0 if conn.execute("SELECT 1").fetchval() == 1 else 1)
finally:
    conn.close()
