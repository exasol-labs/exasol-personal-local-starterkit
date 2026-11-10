"""Read the notebook add-on's workflow records through its own Python package."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

from runtime import KitContext, venv_python

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_ID = re.compile(r"^wf-[0-9]{8}-[0-9a-f]{6}$")


def _refuse(message: str, code: int = 2, *, json_output: bool = False,
            remedy: str | None = None) -> int:
    if json_output:
        print(json.dumps({"ok": False, "error": message, "rejected": code == 2,
                          "remedy": remedy}, separators=(",", ":")))
    else:
        print(message, file=sys.stderr)
    return code


def command(ctx: KitContext, words: list[str]) -> int:
    wants_json = os.environ.get("EXAKIT_REFUSAL_JSON") == "1" or any(
        word in ("--json", "-j") for word in words)

    def reject(message: str, code: int = 2, *, remedy: str | None = None) -> int:
        return _refuse(message, code, json_output=wants_json, remedy=remedy)

    if not words:
        return reject("Name what to do: exakit workflow list | exakit workflow show <id> (exakit workflow --help).")
    action, *rest = words
    if action in ("--help", "-h"):
        print("Use: exakit workflow list [--json] | show <id> [--json]")
        return 0
    if action not in ("list", "show"):
        return reject(f"Unknown workflow command '{action}' (supported: list, show).")
    workflow_id = ""
    json_output = False
    for word in rest:
        if word in ("--json", "-j"):
            json_output = True
        elif word in ("--help", "-h"):
            print("Use: exakit workflow list [--json] | show <id> [--json]")
            return 0
        elif word.startswith("-"):
            return reject(f"Unknown option '{word}' for workflow (supported: --json).")
        elif workflow_id:
            return reject("Name one workflow: exakit workflow show <id> [--json]")
        else:
            workflow_id = word
    if action == "list" and workflow_id:
        return reject("list takes no argument: exakit workflow list [--json]")
    if action == "show" and not workflow_id:
        return reject("Name the workflow: exakit workflow show <id> [--json] (exakit workflow list)")
    if workflow_id and not WORKFLOW_ID.fullmatch(workflow_id):
        return reject(f"Not a workflow id: '{workflow_id}' (expected wf-YYYYMMDD-xxxxxx; exakit workflow list)")
    if not ctx.manifest.get("components.notebook.version"):
        return reject("The notebook add-on is not installed; its helpers write the workflow log. "
                      "Install it with: exakit marketplace notebook", 1,
                      remedy="exakit marketplace notebook")
    recorded = ctx.manifest.get("components.notebook.venv")
    venv = Path(recorded) if recorded else ctx.path("EXAKIT_NOTEBOOK_VENV", ctx.home / "notebook-venv")
    python = venv_python(venv)
    if not python.is_file():
        return reject(f"The notebook environment is missing ({python}). Repair it with: exakit notebook setup", 1,
                      remedy="exakit notebook setup")
    args = [action, *([workflow_id] if workflow_id else []), *(["--json"] if json_output else [])]
    environment = {**os.environ, "EXAKIT_HOME": str(ctx.home)}
    # Import the already loaded helper module; `-m` produces a RuntimeWarning
    # because its package exports a function under the same name.
    command_line = [str(python), "-c", "import importlib,sys;sys.exit(importlib.import_module('exakit_nb.workflow').main(sys.argv[1:]))", *args]
    try:
        if json_output:
            result = subprocess.run(command_line, env=environment, check=False,
                                    capture_output=True, text=True)
            if result.returncode:
                return reject(result.stderr.strip() or "Could not read notebook workflows",
                              result.returncode)
            print(result.stdout, end="")
            return 0
        return subprocess.run(command_line, env=environment, check=False).returncode
    except OSError as error:
        return reject(f"Could not read notebook workflows: {error}", 1)


def main() -> int:
    return command(KitContext.from_environment(ROOT), sys.argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
