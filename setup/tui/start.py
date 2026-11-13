"""Start exakit's terminal view (exakit_tui) with the kit's own Textual: the version pinned in
marketplace/defaults.env (EXAKIT_TEXTUAL_VERSION), run by the uv the kit vetted - the same way the persona and
marketplace questions run theirs (marketplace/launch.py), so the two share one pin and one download cache.

    python setup/tui/start.py <kit root> --cli=<word>... [--tab T] [--persona ID]

Standard library only. Exit 11: no uv and no matching Textual here (the caller says what to run instead)."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: start.py <kit root> --cli=<word>... [--tab T] [--persona ID]", file=sys.stderr)
        return 2
    root, rest = Path(argv[0]).resolve(), argv[1:]
    sys.path.insert(0, str(root / "marketplace"))
    from launch import textual_pin                           # marketplace/launch.py: the kit's one Textual pin
    from runtime import managed_python_version, vetted_uv

    pin = textual_pin(root / "marketplace" / "defaults.env")
    home = Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit").expanduser()
    environment = dict(os.environ)
    package = str(root / "setup" / "tui")
    environment["PYTHONPATH"] = package + (os.pathsep + environment["PYTHONPATH"] if environment.get("PYTHONPATH") else "")
    environment["EXAKIT_NO_TUI"] = "1"                       # what runs from the view never opens it again
    environment.setdefault("UV_CACHE_DIR", str(home / "cache" / "uv"))
    uv = vetted_uv(home, Path(os.environ.get("EXAKIT_BIN_DIR", str(Path.home() / ".local" / "bin"))).expanduser())
    if uv:
        command = [uv, "run", "--quiet", "--no-project", "--python", managed_python_version(environment),
                   "--with", f"textual=={pin}", "python", "-m", "exakit_tui", f"--root={root}", *rest]
    else:
        try:
            from importlib.metadata import version

            installed = version("textual")
        except Exception:
            installed = None
        if installed != pin:
            print(f"exakit's terminal view needs uv or Textual {pin}. Repair the kit with: exakit update", file=sys.stderr)
            return 11
        command = [sys.executable, "-m", "exakit_tui", f"--root={root}", *rest]
    try:
        return subprocess.run(command, check=False, env=environment).returncode
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
