"""Run the pinned Textual UI with uv after the kit's Python bootstrap.

This script needs only the Python standard library. It is called at the persona
boundary by both platform installers; no Textual dependency is imposed on the
database install or read-only `exakit` commands.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


def textual_pin(path: Path) -> str:
    data: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or key != "EXAKIT_TEXTUAL_VERSION" or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2}", value):
            raise ValueError("marketplace/defaults.env has an invalid Textual version")
        data[key] = value
    if "EXAKIT_TEXTUAL_VERSION" not in data:
        raise ValueError("marketplace/defaults.env needs EXAKIT_TEXTUAL_VERSION")
    return data["EXAKIT_TEXTUAL_VERSION"]


def run(root: Path, args: list[str]) -> int:
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print("An interactive terminal is required for the persona/marketplace UI.", file=sys.stderr)
        return 10
    script = root / "marketplace" / "ui.py"
    if not script.is_file():
        print("The marketplace UI is missing from this kit copy.", file=sys.stderr)
        return 11
    pin = textual_pin(root / "marketplace" / "defaults.env")
    uv = shutil.which("uv") or shutil.which("uv.exe")
    environment = dict(os.environ)
    if uv:
        command = [uv, "run", "--no-project", "--python", environment.get("EXAKIT_MANAGED_PYTHON_VERSION", "3.12"),
                   "--with", f"textual=={pin}",
                   "python", str(script), *args]
    else:
        # A deliberately installed matching version works for an offline
        # checkout. An arbitrary ambient Textual would make releases differ.
        try:
            from importlib.metadata import version

            installed = version("textual")
        except Exception:
            installed = None
        if installed != pin:
            print(f"The marketplace UI needs uv or Textual {pin}.", file=sys.stderr)
            return 11
        command = [sys.executable, str(script), *args]
    environment.setdefault("UV_CACHE_DIR", str(Path(environment.get("EXAKIT_HOME") or
                                                      Path.home() / ".exasol-starter-kit") / "cache" / "uv"))
    return subprocess.run(command, check=False, env=environment).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("mode", choices=("persona", "marketplace", "notebook"))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--states", type=Path)
    parser.add_argument("--defaults", default="")
    parser.add_argument("--recorded", default="")
    parser.add_argument("--only", default="")
    parser.add_argument("--frontends", default="jupyterlab,marimo,positron")
    parser.add_argument("--apply", action="store_true")
    parsed = parser.parse_args()
    if parsed.mode in ("marketplace", "notebook") and not parsed.states:
        parser.error(f"{parsed.mode} needs --states")
    try:
        return run(parsed.root, sys.argv[2:])
    except (OSError, ValueError) as error:
        print(f"Marketplace UI could not start: {error}", file=sys.stderr)
        return 11


if __name__ == "__main__":
    raise SystemExit(main())
