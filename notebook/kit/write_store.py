"""Write the kit's database connection into the notebook connector's encrypted store (only what changed).

Environment: SCS_FILE, SCS_MASTER_PASSWORD (the store and its master password), EXAKIT_NB_HOST, EXAKIT_NB_PORT,
EXAKIT_NB_USER and EXAKIT_NB_PWFILE (the file holding the password - never the password itself). Prints changed|same.

Run by setup/lib/notebook.sh and notebook.ps1 with the notebook venv's Python; one file for both, so the two
scripts cannot drift.
"""
import os
from pathlib import Path
from exasol.nb_connector.ai_lab_config import AILabConfig as K, StorageBackend
from exasol.nb_connector.secret_store import Secrets
store = Secrets(Path(os.environ["SCS_FILE"]), os.environ["SCS_MASTER_PASSWORD"])
wanted = {K.storage_backend: StorageBackend.onprem.name, K.db_host_name: os.environ["EXAKIT_NB_HOST"],
          K.db_port: os.environ["EXAKIT_NB_PORT"], K.db_user: os.environ["EXAKIT_NB_USER"],
          K.db_password: open(os.environ["EXAKIT_NB_PWFILE"], encoding="utf-8").read().strip(),
          K.db_encryption: "True", K.cert_vld: "False"}
changed = [k.name for k, v in wanted.items() if store.get(k) != v]
for key in changed:
    store.save(key, wanted[K[key]])
print("changed" if changed else "same")
