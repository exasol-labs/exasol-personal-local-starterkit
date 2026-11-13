"""The kit, as the terminal view reads it: every fact comes from the kit's own `exakit ... --json` answers, and every
change is the very `exakit` command a person would type. Nothing here reimplements the kit."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any


def _last_json(text: str) -> dict[str, Any]:
    """The JSON object a command printed: its whole output, else the last line that parses (a notice may come
    first)."""
    text = (text or "").strip()
    if not text:
        return {}
    try:
        found = json.loads(text)
        return found if isinstance(found, dict) else {"rows": found}
    except ValueError:
        pass
    start = text.rfind("\n{")
    while start != -1:
        try:
            found = json.loads(text[start + 1:])
            return found if isinstance(found, dict) else {"rows": found}
        except ValueError:
            start = text.rfind("\n{", 0, start)
    try:
        found = json.loads(text[text.index("{"):])
        return found if isinstance(found, dict) else {"rows": found}
    except ValueError:
        return {}


class Kit:
    """Runs the kit's CLI. ``cli`` is the command that starts it (["bash", ".../setup/exakit"], or PowerShell with
    exakit.ps1 on Windows); ``root`` the kit copy it belongs to."""

    def __init__(self, cli: list[str], root: Path) -> None:
        self.cli, self.root = list(cli), root

    def env(self) -> dict[str, str]:
        env = dict(os.environ)
        env["EXAKIT_NO_TUI"] = "1"           # a command started from here never opens this view again
        return env

    def command(self, *args: str) -> list[str]:
        return self.cli + [str(a) for a in args]

    def json(self, *args: str, timeout: int = 180) -> dict[str, Any]:
        """One read: `exakit <args> --json`. A command that fails still answers with its object (installed: false,
        error, remedy); one that prints nothing is {"_error": what it said on stderr}."""
        try:
            done = subprocess.run(self.command(*args, "--json"), capture_output=True, text=True, encoding="utf-8",
                                  errors="replace", timeout=timeout, env=self.env(), stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return {"_error": f"exakit {' '.join(args)} did not answer within {timeout} s"}
        except OSError as exc:
            return {"_error": f"exakit could not be started: {exc}"}
        found = _last_json(done.stdout)
        if not found:
            said = [line for line in (done.stderr or done.stdout or "").splitlines() if line.strip()]
            return {"_error": said[-1].strip() if said else f"exakit {' '.join(args)} gave no answer (exit {done.returncode})"}
        return found

    # -- facts the CLI has no JSON for: read from the kit copy, as the notebook helpers read them ---------------------
    _ADAPTER_ID = re.compile(r'def adapter_id\(self\)[^:]*:\s*return "([^"]+)"|adapter_id_value="([^"]+)"')
    _DISPLAY = re.compile(r'def display_name\(self\)[^:]*:\s*return "([^"]+)"|display_name_value="([^"]+)"')

    def client_names(self) -> dict[str, str]:
        """{client id: its name}: every AI client the kit can connect (its MCP adapters)."""
        names: dict[str, str] = {}
        for path in sorted((self.root / "mcp" / "adapters").glob("*.py")):
            text = path.read_text(encoding="utf-8", errors="replace")
            found, shown = self._ADAPTER_ID.search(text), self._DISPLAY.search(text)
            if found and shown:
                names[found.group(1) or found.group(2)] = shown.group(1) or shown.group(2)
        return names

    def datasets(self) -> dict[str, dict[str, str]]:
        """{dataset id: {label, description}} from the kit's dataset definitions (data/datasets/<id>/dataset.conf)."""
        out: dict[str, dict[str, str]] = {}
        for conf in sorted((self.root / "data" / "datasets").glob("*/dataset.conf")):
            values: dict[str, str] = {}
            for line in conf.read_text(encoding="utf-8", errors="replace").splitlines():
                key, sep, value = line.partition("=")
                if sep and not line.lstrip().startswith("#"):
                    values[key.strip().lower()] = value.strip().strip('"').strip("'")
            out[values.get("id") or conf.parent.name] = {"label": values.get("label") or conf.parent.name,
                                                         "description": values.get("description", "")}
        return out
