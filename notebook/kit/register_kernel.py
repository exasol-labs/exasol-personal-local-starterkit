"""Register the kit's Jupyter kernel for this user. Its spec carries paths only (the store, the file with its master
password, the kit copy, the kit's datasets), never a secret. Environment: EXAKIT_KERNEL_NAME, EXAKIT_KERNEL_TITLE and the EXAKIT_NB_* paths.

The spec also carries EXASOL_TELEMETRY_DISABLE, so pyexasol's usage telemetry stays off in the kernel whichever
front end starts it (JupyterLab, VS Code, Positron): the value the user had set when the kernel was registered, else
"1" (marketplace/kit_telemetry.py). Re-running exakit notebook setup re-registers it.

Run by the Python marketplace with the notebook environment’s interpreter.
"""
import os

TELEMETRY = "EXASOL_TELEMETRY_DISABLE"
os.environ.setdefault(TELEMETRY, "1")

from ipykernel.kernelspec import install  # noqa: E402

env = {k: os.environ[k] for k in ("EXAKIT_NB_STORE", "EXAKIT_NB_MASTER_FILE", "EXAKIT_NB_KIT", "EXAKIT_NB_DATASETS", TELEMETRY) if k in os.environ}
print(install(user=True, kernel_name=os.environ["EXAKIT_KERNEL_NAME"], display_name=os.environ["EXAKIT_KERNEL_TITLE"], env=env))
