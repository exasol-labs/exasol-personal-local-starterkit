"""Remove the kit's Jupyter kernel again (EXAKIT_KERNEL_NAME).

Run by setup/lib/notebook.sh and notebook.ps1 with the notebook venv's Python; one file for both, so the two
scripts cannot drift.
"""
import os
from jupyter_client.kernelspec import KernelSpecManager
name = os.environ["EXAKIT_KERNEL_NAME"]
if name in KernelSpecManager().find_kernel_specs():
    KernelSpecManager().remove_kernel_spec(name)
