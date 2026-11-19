"""An add-on's SQL preprocessor module, registered with or retired from the kit's framework.

The mechanism is setup/preprocessor/manage.py (register-module / retire-module, see
setup/preprocessor/modules/README.md); this is how an add-on calls it. Neither call raises: a framework that is
declined, not set up, or not in the database skips the module, and a registration that fails is logged. The add-on
is installed either way, and the framework's own verify pass (every installer run and `exakit update`) registers
it later.

    register(ctx, "semantic-views")                                   # a pinned module
    register(ctx, "json-tables", artifact=path, note="exasol-json-tables v0.4.1 + 2 wrappers")   # generated
    retire(ctx, "semantic-views")                                     # before the add-on is removed

Each returns (status, message): status is "ok", "skipped" or "failed"; message is the line to show, or "".
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from runtime import KitContext

TIMEOUT = 600
STATUS = {0: "ok", 5: "skipped"}


def exapump_path(ctx: KitContext) -> str:
    """The exapump the kit's own steps use: the recorded one, else the one on PATH, else the kit's bin."""
    recorded = ctx.manifest.get("components.exapump.path")
    if isinstance(recorded, str) and Path(recorded).is_file():
        return recorded
    return shutil.which("exapump") or str(ctx.bin_dir / ("exapump.exe" if os.name == "nt" else "exapump"))


def _run(ctx: KitContext, verb: str, addon: str, extra: list[str]) -> tuple[str, str]:
    manage = ctx.root / "setup" / "preprocessor" / "manage.py"
    if not manage.is_file():
        return "skipped", ""
    argv = [sys.executable, str(manage), verb, "--exapump", exapump_path(ctx),
            "--profile", os.environ.get("EXAKIT_EXAPUMP_PROFILE", "starter-kit"),
            "--manifest", str(ctx.manifest.path), "--log", str(ctx.home / "logs" / "marketplace.log"), addon, *extra]
    env = dict(os.environ)
    config = ctx.home / "exapump" / "config.toml"      # where the kit keeps the starter-kit profile (exapump.sh/.ps1)
    if not env.get("EXAPUMP_CONFIG") and config.is_file():
        env["EXAPUMP_CONFIG"] = str(config)
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=TIMEOUT, check=False, env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        message = f"{addon}: the SQL preprocessor module step did not run ({error})"
        ctx.log_event(message)
        return "failed", message
    lines = [line.split(" ", 1)[1] for line in done.stdout.splitlines()
             if line[:3] in ("OK ", "INF", "WAR", "FAI") and " " in line]
    message = lines[-1] if lines else ""
    for line in lines:
        ctx.log_event(f"preprocessor module: {line}")
    if done.returncode not in STATUS and not message:
        message = f"{addon}: the SQL preprocessor module step exited with {done.returncode}"
        ctx.log_event(message)
    return STATUS.get(done.returncode, "failed"), message


def register(ctx: KitContext, addon: str, *, artifact: Path | None = None, note: str | None = None) -> tuple[str, str]:
    extra: list[str] = []
    if artifact is not None:
        extra += ["--artifact", str(artifact)]
    if note:
        extra += ["--note", note]
    return _run(ctx, "register-module", addon, extra)


def retire(ctx: KitContext, addon: str) -> tuple[str, str]:
    return _run(ctx, "retire-module", addon, [])
