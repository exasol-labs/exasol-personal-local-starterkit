"""Run Marimo with its output passed on line by line and the login token masked, so the token never reaches a log.
TERM and INT stop Marimo too. Run with the notebook venv's Python by setup/lib/notebook.sh and notebook.ps1:

    python marimo_wrapper.py <token file> <marimo command and arguments...>
"""
import signal
import subprocess
import sys

token = open(sys.argv[1], encoding="utf-8").read().strip()
child = subprocess.Popen(sys.argv[2:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)


def stop(*_):
    child.terminate()


for sig in (signal.SIGTERM, signal.SIGINT):
    signal.signal(sig, stop)
for line in child.stdout:
    sys.stdout.write(line.replace(token, "***") if token else line)
    sys.stdout.flush()
sys.exit(child.wait())
