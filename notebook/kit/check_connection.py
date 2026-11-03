"""Open the database from the encrypted store and run SELECT 1; exit 0 when it answers. Environment: SCS_FILE,
SCS_MASTER_PASSWORD.

Run by the Python marketplace with the notebook environment’s interpreter.
"""
import os
from pathlib import Path

# pyexasol's usage telemetry stays off unless the user set the variable (marketplace/kit_telemetry.py).
os.environ.setdefault("EXASOL_TELEMETRY_DISABLE", "1")

from exasol.nb_connector.connections import open_pyexasol_connection  # noqa: E402
from exasol.nb_connector.secret_store import Secrets  # noqa: E402
conn = open_pyexasol_connection(Secrets(Path(os.environ["SCS_FILE"]), os.environ["SCS_MASTER_PASSWORD"]))
try:
    raise SystemExit(0 if conn.execute("SELECT 1").fetchval() == 1 else 1)
finally:
    conn.close()
