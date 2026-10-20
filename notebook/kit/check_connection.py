"""Open the database from the encrypted store and run SELECT 1; exit 0 when it answers. Environment: SCS_FILE,
SCS_MASTER_PASSWORD.

Run by setup/lib/notebook.sh and notebook.ps1 with the notebook venv's Python; one file for both, so the two
scripts cannot drift.
"""
import os
from pathlib import Path
from exasol.nb_connector.connections import open_pyexasol_connection
from exasol.nb_connector.secret_store import Secrets
conn = open_pyexasol_connection(Secrets(Path(os.environ["SCS_FILE"]), os.environ["SCS_MASTER_PASSWORD"]))
try:
    raise SystemExit(0 if conn.execute("SELECT 1").fetchval() == 1 else 1)
finally:
    conn.close()
