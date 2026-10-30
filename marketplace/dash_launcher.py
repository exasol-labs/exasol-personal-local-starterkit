"""Generated dash-server command's cross-platform Python target."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


def main() -> int:
    home = Path(os.environ.get("EXAKIT_HOME", str(Path.home() / ".exasol-starter-kit")))
    doc = json.loads((home / "manifest.json").read_text(encoding="utf-8"))
    addon = doc["components"]["dash_server"]
    runtime = doc.get("runtime", {})
    port = int(addon["port"])
    env = dict(os.environ)
    env.setdefault("DASH_SERVER_INSTANCE_PATH", addon["instance"])
    credential = runtime.get("password_file")
    if runtime.get("dsn") and credential and Path(credential).is_file() and not env.get("DASH_SERVER_EXASOL_DSN"):
        env.setdefault("EXA_PASSWORD", Path(credential).read_text(encoding="utf-8").strip())
        env["DASH_SERVER_EXASOL_PROFILE_NAME"] = env.get("EXAKIT_DASH_SERVER_PROFILE", "starter-kit")
        env["DASH_SERVER_EXASOL_DSN"] = runtime["dsn"]
        env["DASH_SERVER_EXASOL_USER"] = runtime.get("user", "SYS")
        env["DASH_SERVER_EXASOL_SECRET_ENV_VAR"] = "EXA_PASSWORD"
        env.setdefault("DASH_SERVER_EXASOL_TLS_VERIFY", "false")
    env["DASH_SERVER_HOST"] = "127.0.0.1"
    env["DASH_SERVER_PORT"] = str(port)
    command = Path(addon["venv"]) / ("Scripts/dash-server.exe" if os.name == "nt" else "bin/dash-server")
    # The kit's control plane is unauthenticated, so no caller-provided host
    # argument may move it off loopback. Always use the recorded port.
    extras = []
    skip = False
    for arg in sys.argv[1:]:
        if skip:
            skip = False
        elif arg in ("--host", "--port"):
            skip = True
        elif not arg.startswith(("--host=", "--port=")):
            extras.append(arg)
    argv = [str(command), *extras, "--host", "127.0.0.1", "--port", str(port)]
    if os.name == "nt":
        return subprocess.call(argv, env=env)
    os.execve(str(command), argv, env)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
