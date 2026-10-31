"""Register the kit's Jupyter kernel for this user. Its spec carries paths only (the store, the file with its master
password, the kit copy, the kit's datasets), never a secret. Environment: EXAKIT_KERNEL_NAME, EXAKIT_KERNEL_TITLE and the EXAKIT_NB_* paths.

Run by the Python marketplace with the notebook environment’s interpreter.
"""
import os
from ipykernel.kernelspec import install
env = {k: os.environ[k] for k in ("EXAKIT_NB_STORE", "EXAKIT_NB_MASTER_FILE", "EXAKIT_NB_KIT", "EXAKIT_NB_DATASETS") if k in os.environ}
print(install(user=True, kernel_name=os.environ["EXAKIT_KERNEL_NAME"], display_name=os.environ["EXAKIT_KERNEL_TITLE"], env=env))
