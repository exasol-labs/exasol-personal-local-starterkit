"""Where the kit is, for any notebook tool: the four paths the helpers need, from the Jupyter kernel's environment when it
set them, else from the kit's own files - so the same helpers connect in Marimo, Positron, VS Code or a plain script
that runs the kit's notebook Python, with no kernel of ours involved.

The kit's home is found, in order: the folder around the Python running this (the kit's notebook environment lives in
the home, so a moved EXAKIT_HOME is followed), then EXAKIT_HOME, then ~/.exasol-starter-kit. The store and the master
password file are the ones the notebook add-on recorded in the manifest at its install. Paths only: nothing here reads a
secret.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from functools import lru_cache
from pathlib import Path

VARIABLES = ("EXAKIT_NB_STORE", "EXAKIT_NB_MASTER_FILE", "EXAKIT_NB_KIT", "EXAKIT_NB_DATASETS")


def _home() -> Path | None:
    """The kit's home: the folder that holds manifest.json and the kit copy."""
    candidates = [Path(sys.prefix).resolve().parent]
    if os.environ.get("EXAKIT_HOME"):
        candidates.append(Path(os.environ["EXAKIT_HOME"]).expanduser())
    candidates.append(Path.home() / ".exasol-starter-kit")
    return next((c for c in candidates if (c / "manifest.json").is_file() and (c / "kit").is_dir()), None)


@lru_cache(maxsize=1)
def _from_files() -> dict[str, str]:
    home = _home()
    if home is None:
        return {}
    try:
        recorded = json.loads((home / "manifest.json").read_text(encoding="utf-8"))["components"]["notebook"]
        store, master = recorded["store_file"], recorded["master_file"]
    except (OSError, ValueError, KeyError, TypeError):
        return {}
    kit = home / "kit"
    return {"EXAKIT_NB_STORE": str(store), "EXAKIT_NB_MASTER_FILE": str(master), "EXAKIT_NB_KIT": str(kit),
            "EXAKIT_NB_DATASETS": str(kit / "data" / "datasets")}


def setting(name: str) -> str | None:
    """One of the four paths: the kernel's variable when set, else found from the kit's files, else None."""
    return os.environ.get(name) or _from_files().get(name)


def exakit_command() -> list[str] | None:
    """How to run the kit's ``exakit`` command from a notebook: on PATH (exakit.cmd on Windows), else in the kit's bin
    folder (EXAKIT_BIN_DIR, else ~/.local/bin); None when there is none."""
    found = shutil.which("exakit")
    if found:
        return [found]
    folder = Path(os.environ.get("EXAKIT_BIN_DIR") or Path.home() / ".local" / "bin")
    for name in ("exakit.cmd", "exakit") if os.name == "nt" else ("exakit",):
        if (folder / name).is_file():
            return [str(folder / name)]
    return None
