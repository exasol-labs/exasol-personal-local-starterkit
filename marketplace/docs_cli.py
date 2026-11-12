"""`exakit docs`: open the kit's documentation, served from this computer by the notebook add-on's Python."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from runtime import KitContext, venv_python

ROOT = Path(__file__).resolve().parent.parent


def command(ctx: KitContext, words: list[str]) -> int:
    """Run exakit_nb.docs.main in the notebook add-on's Python: it has the site's server, and the kit copy the site
    is in. Refused (exit 1, with the install command) when the add-on is not installed."""
    if not ctx.manifest.get("components.notebook.version"):
        print("The notebook add-on is not installed; it carries the documentation. "
              "Install it with: exakit marketplace notebook", file=sys.stderr)
        return 1
    recorded = ctx.manifest.get("components.notebook.venv")
    venv = Path(recorded) if recorded else ctx.path("EXAKIT_NOTEBOOK_VENV", ctx.home / "notebook-venv")
    python = venv_python(venv)
    if not python.is_file():
        print(f"The notebook environment is missing ({python}). Repair it with: exakit notebook setup", file=sys.stderr)
        return 1
    package = str(ctx.root / "notebook" / "package")
    environment = {**os.environ, "EXAKIT_NB_KIT": str(ctx.root),
                   "PYTHONPATH": os.pathsep.join(p for p in (package, os.environ.get("PYTHONPATH", "")) if p)}
    line = [str(python), "-c",
            "import importlib,sys;sys.exit(importlib.import_module('exakit_nb.docs').main(sys.argv[1:]))", *words]
    try:
        return subprocess.run(line, env=environment, check=False).returncode
    except KeyboardInterrupt:
        return 0


def main(argv: list[str] | None = None) -> int:
    return command(KitContext.from_environment(ROOT), list(sys.argv[1:] if argv is None else argv))


if __name__ == "__main__":
    sys.exit(main())
