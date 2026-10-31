"""Remove the kit's Jupyter kernel again (EXAKIT_KERNEL_NAME).

Run by the Python marketplace with the notebook environment’s interpreter.
"""
import os
from jupyter_client.kernelspec import KernelSpecManager
name = os.environ["EXAKIT_KERNEL_NAME"]
if name in KernelSpecManager().find_kernel_specs():
    KernelSpecManager().remove_kernel_spec(name)
