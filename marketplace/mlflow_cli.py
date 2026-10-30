"""Cross-platform `exakit mlflow` command for the persona's local service."""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import subprocess
import sys
from contextlib import nullcontext, redirect_stderr, redirect_stdout
from pathlib import Path

from runtime import AddonFailure, KitContext, venv_executable, venv_python

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "setup" / "lib"))
import mlflow_service  # noqa: E402


def _notebook_venv(ctx: KitContext) -> Path:
    recorded = ctx.manifest.get("components.notebook.venv")
    return Path(recorded) if recorded else ctx.path("EXAKIT_NOTEBOOK_VENV", ctx.home / "notebook-venv")


def _require_notebook(ctx: KitContext, purpose: str) -> Path:
    python = venv_python(_notebook_venv(ctx))
    if not python.is_file():
        raise AddonFailure(f"The notebook add-on is needed for {purpose}: exakit marketplace notebook")
    return python


def _server_pin(ctx: KitContext) -> str:
    document = ctx.versions_document()
    value = document.get("components", {}).get("udf-devkit", {}).get("mlflow_server")
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2}", value):
        raise AddonFailure("versions.json needs a pinned udf-devkit MLflow server version")
    return value


def _server(ctx: KitContext) -> Path:
    if not ctx.manifest.get("components.udf_devkit.version"):
        raise AddonFailure("The UDF dev kit is not installed. Install it with: exakit marketplace udf-devkit")
    python = _require_notebook(ctx, "MLflow")
    probe = subprocess.run([str(python), "-c", "import mlflow.server"], capture_output=True,
                           check=False, timeout=15)
    if probe.returncode:
        ctx.require_uv()
        ctx.run_logged("Installing the local MLflow server", str(ctx.uv), "pip", "install", "--python",
                       str(python), f"mlflow=={_server_pin(ctx)}")
        probe = subprocess.run([str(python), "-c", "import mlflow.server"], capture_output=True,
                               check=False, timeout=15)
        if probe.returncode:
            raise AddonFailure("MLflow server could not be installed. Read: exakit logs setup")
    executable = venv_executable(_notebook_venv(ctx), "mlflow")
    if not executable.is_file():
        raise AddonFailure("MLflow server executable is missing; run exakit update notebook")
    return executable


def _options(words: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="exakit mlflow")
    parser.add_argument("action", choices=("start", "stop", "status", "url", "replay", "disable"))
    parser.add_argument("rest", nargs=argparse.REMAINDER)
    args = parser.parse_args(words)
    if args.action == "replay":
        return args
    parser = argparse.ArgumentParser(prog=f"exakit mlflow {args.action}")
    parser.add_argument("--json", "-j", action="store_true")
    if args.action == "start":
        parser.add_argument("--port", type=int)
    if args.action == "stop":
        parser.add_argument("--disable", action="store_true")
    parsed = parser.parse_args(args.rest)
    if args.action == "start" and parsed.port is not None and not 1 <= parsed.port <= 65535:
        parser.error("--port must be from 1 to 65535")
    parsed.action = args.action
    return parsed


def command(ctx: KitContext, words: list[str]) -> int:
    json_requested = any(word in ("--json", "-j") for word in words)
    if json_requested:
        errors = io.StringIO()
        with redirect_stderr(errors):
            try:
                options = _options(words)
            except SystemExit as error:
                if error.code == 0:
                    return 0
                print(json.dumps({"ok": False, "error": errors.getvalue().strip(),
                                  "rejected": True, "remedy": None}, separators=(",", ":")))
                return 2
    else:
        options = _options(words)
    if options.action == "replay":
        try:
            python = _require_notebook(ctx, "replay")
            replay_args = ["--json" if arg == "-j" else arg for arg in options.rest]
            return subprocess.run([str(python), "-m", "exasol_mlflow", "replay", *replay_args],
                                  check=False).returncode
        except (AddonFailure, OSError) as error:
            if json_requested:
                print(json.dumps({"ok": False, "error": str(error),
                                  "remedy": "exakit marketplace notebook"}))
            else:
                print(str(error), file=sys.stderr)
            return 1
    json_mode = options.json
    try:
        with redirect_stdout(sys.stderr) if json_mode else nullcontext():
            if options.action == "start":
                executable = _server(ctx)
                result = mlflow_service.start(executable, options.port)
                ctx.manifest.set_many({"components.udf_devkit.mlflow.enabled": True})
            elif options.action in ("stop", "disable"):
                result = mlflow_service.stop()
                if options.action == "disable" or options.disable:
                    ctx.manifest.set_many({"components.udf_devkit.mlflow.enabled": False})
            else:
                result = mlflow_service.state()
    except (AddonFailure, OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        if json_mode:
            message = str(error)
            remedy = ("exakit marketplace udf-devkit" if "UDF dev kit is not installed" in message else
                      "exakit marketplace notebook" if "notebook add-on is needed" in message else
                      "exakit logs mlflow")
            print(json.dumps({"ok": False, "error": message, "remedy": remedy}))
        else:
            print(str(error), file=sys.stderr)
        return 1
    if json_mode:
        print(json.dumps({"ok": True, **result}))
    elif options.action == "url":
        print(result["url"] or "")
    else:
        print("MLflow: " + result["status"] + (" at " + result["url"] if result["url"] else ""))
        if (options.action == "disable" or
                (options.action == "stop" and options.disable)):
            print("MLflow will not start with exakit start until: exakit mlflow start")
    return 0


def main() -> int:
    ctx = KitContext.from_environment(ROOT)
    os.environ.setdefault("EXAKIT_HOME", str(ctx.home))
    return command(ctx, sys.argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
