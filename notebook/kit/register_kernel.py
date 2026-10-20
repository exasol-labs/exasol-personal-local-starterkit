"""Register the kit's Jupyter kernel for this user. Its spec carries paths only (the store, the file with its master
password, the kit's datasets), never a secret. Environment: EXAKIT_KERNEL_NAME, EXAKIT_KERNEL_TITLE and the EXAKIT_NB_* paths.

Run by setup/lib/notebook.sh and notebook.ps1 with the notebook venv's Python; one file for both, so the two
scripts cannot drift.
"""
import os
from ipykernel.kernelspec import install
env = {k: os.environ[k] for k in ("EXAKIT_NB_STORE", "EXAKIT_NB_MASTER_FILE", "EXAKIT_NB_DATASETS")}
print(install(user=True, kernel_name=os.environ["EXAKIT_KERNEL_NAME"], display_name=os.environ["EXAKIT_KERNEL_TITLE"], env=env))
