"""A stand-in for setup/lib/describe_service.py in the command suites (tests/describe-command.sh and its PowerShell
twin): prints what the shell asked of the service - its arguments and the connection settings it was given (the
password file's PATH, never its content) - as one JSON object, and exits with STUB_EXIT (0 by default), so the
suites prove the argument check, the pass-through and the exit codes without a database."""

import json
import os
import sys

print(json.dumps({"args": sys.argv[1:], "dsn": os.environ.get("EXAKIT_PYX_DSN"), "user": os.environ.get("EXAKIT_PYX_USER"),
                  "pwfile": os.environ.get("EXAKIT_PYX_PWFILE")}))
sys.exit(int(os.environ.get("STUB_EXIT", "0")))
