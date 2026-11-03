"""Generated dash-server command's cross-platform Python target."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import kit_telemetry


def connection(doc: dict) -> tuple[str, str | None]:
    """(user, password file) the dashboards query as: the kit's validated READ-ONLY user, the
    identity every AI client already uses - a shared dashboard must not run with the
    database administrator's rights, and the notebooks' Share step refuses a profile that
    does. The administrator only while no read-only user exists yet (a kit set up before
    it, or one whose MCP step failed); `exakit mcp-setup` then makes one."""
    readonly = (doc.get("components", {}).get("mcp_server") or {}).get("connection") or {}
    runtime = doc.get("runtime", {})
    if readonly.get("validated") is True and readonly.get("user") and readonly.get("password_file") \
            and Path(readonly["password_file"]).is_file():
        return readonly["user"], readonly["password_file"]
    return runtime.get("user", "SYS"), runtime.get("password_file")


def admin_profile_to_repair(instance: Path, name: str, runtime: dict, user: str) -> bool:
    """True when the stored profile is the one an earlier kit seeded as the administrator and
    the read-only user can replace it. Dash Server seeds its profile once and keeps it after
    (a profile an agent changed is never reverted), so that one is rewritten on this start;
    any other profile, one a person or an agent set to another user, is left alone."""
    admin = str(runtime.get("user", "")).upper()
    if not admin or user.upper() == admin:
        return False
    try:
        stored = json.loads((instance / "gitops-repo" / "profiles" / "exasol" / f"{name}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return str(stored.get("user", "")).upper() == admin and stored.get("dsn") == runtime.get("dsn")


def main() -> int:
    home = Path(os.environ.get("EXAKIT_HOME", str(Path.home() / ".exasol-starter-kit")))
    doc = json.loads((home / "manifest.json").read_text(encoding="utf-8"))
    addon = doc["components"]["dash_server"]
    runtime = doc.get("runtime", {})
    port = int(addon["port"])
    env = dict(os.environ)
    kit_telemetry.default_off(env)
    env.setdefault("DASH_SERVER_INSTANCE_PATH", addon["instance"])
    user, credential = connection(doc)
    if runtime.get("dsn") and credential and Path(credential).is_file() and not env.get("DASH_SERVER_EXASOL_DSN"):
        name = env.get("EXAKIT_DASH_SERVER_PROFILE", "starter-kit")
        env.setdefault("EXA_PASSWORD", Path(credential).read_text(encoding="utf-8").strip())
        env["DASH_SERVER_EXASOL_PROFILE_NAME"] = name
        env["DASH_SERVER_EXASOL_DSN"] = runtime["dsn"]
        env["DASH_SERVER_EXASOL_USER"] = user
        env["DASH_SERVER_EXASOL_SECRET_ENV_VAR"] = "EXA_PASSWORD"
        env.setdefault("DASH_SERVER_EXASOL_TLS_VERIFY", "false")
        if admin_profile_to_repair(Path(addon["instance"]), name, runtime, user):
            env["DASH_SERVER_EXASOL_OVERWRITE"] = "true"
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
