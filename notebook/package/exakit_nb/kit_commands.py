"""The kit's own commands, run from a notebook cell with their output shown as it comes - so nobody has to leave the
notebook for a terminal to check the kit, update it, install an add-on or load a dataset.

    nb.kit_check()                              # what is installed and running, in four lines
    nb.exakit("update")                         # any command of the kit; its log streams into the cell
    nb.exakit("marketplace", "dash-server")     # install an add-on
    nb.addon_ready("dash-server")               # install it if missing, start it if stopped, say where it is

Every call runs the same ``exakit`` the terminal runs (on PATH, else in the kit's bin folder), detached from any
terminal: a question the command would ask takes its default, and a choice is given up front through the variables
the command documents (``nb.exakit("mcp-setup", env={"EXAKIT_MCP_CLIENTS": "claude"})``). Nothing is read from the
notebook's input. The result says the exit code and keeps the output, so a cell can test ``run.ok``.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
from dataclasses import dataclass, field
from typing import Any

from ._kit import exakit_command

TIMEOUT = 1800                              # seconds: an update can fetch and build for a while
STATUS_TIMEOUT = 60
NOT_FOUND = ("The kit's `exakit` was not found on PATH or in its bin folder (~/.local/bin, or EXAKIT_BIN_DIR). "
             "Install the kit first, from a terminal: see the starter kit's README.")


@dataclass
class KitRun:
    """One command run: the words it was called with, its exit code and everything it printed."""
    command: list[str]
    code: int
    output: str = ""
    timed_out: bool = False

    @property
    def ok(self) -> bool:
        return self.code == 0 and not self.timed_out

    @property
    def lines(self) -> list[str]:
        return [line for line in self.output.splitlines() if line.strip()]

    def __bool__(self) -> bool:
        return self.ok

    def __str__(self) -> str:
        words = " ".join(["exakit", *self.command])
        state = "timed out" if self.timed_out else "ok" if self.code == 0 else f"exit {self.code}"
        return f"{words}: {state} ({len(self.lines)} lines)"

    __repr__ = __str__

    def _repr_html_(self) -> str:
        from html import escape
        colour = "#0F7A6B" if self.ok else "#B4232F"
        return f'<p><code>{escape(str(self))}</code></p>' if self.ok else \
            f'<p style="color:{colour}"><code>{escape(str(self))}</code></p>'


def _environment(extra: dict[str, str] | None) -> dict[str, str]:
    env = dict(os.environ)
    env.update({"NO_COLOR": "1", "TERM": "dumb"})          # plain lines: no colour, no spinner, nothing redrawn
    env.pop("EXAKIT_REFUSAL_JSON", None)
    for key, value in (extra or {}).items():
        env[str(key)] = str(value)
    return env


def exakit(*args: str, env: dict[str, str] | None = None, show: bool = True, timeout: float = TIMEOUT) -> KitRun:
    """Run ``exakit <args>`` and show its output line by line as it comes (``show=False`` keeps it quiet); the
    KitRun says how it ended. A command that takes longer than ``timeout`` seconds is stopped and says so."""
    found = exakit_command()
    if not found:
        raise RuntimeError(NOT_FOUND)
    words = [str(a) for a in args]
    detach = {} if os.name == "nt" else {"start_new_session": True}      # no terminal: a question takes its default
    process = subprocess.Popen([*found, *words], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", bufsize=1,
                               env=_environment(env), **detach)
    collected: list[str] = []
    timed_out = False
    try:
        import threading

        timer = threading.Timer(timeout, lambda: _stop(process)) if timeout else None
        if timer:
            timer.daemon = True
            timer.start()
        try:
            assert process.stdout is not None
            for line in process.stdout:
                collected.append(line)
                if show:
                    print(line, end="", flush=True)
        finally:
            if timer:
                timed_out = not timer.is_alive()
                timer.cancel()
        process.wait()
    except KeyboardInterrupt:
        _stop(process)
        process.wait()
        raise
    run = KitRun(words, process.returncode, "".join(collected), timed_out)
    if show:
        print(str(run) if run.ok or timed_out else f"{run} - read the lines above for what to change", flush=True)
    return run


def _stop(process: subprocess.Popen) -> None:
    try:
        if os.name == "nt":
            process.kill()
        else:
            os.killpg(process.pid, signal.SIGTERM)
    except (ProcessLookupError, OSError):
        pass


def kit_json(*args: str, timeout: float = STATUS_TIMEOUT) -> dict[str, Any]:
    """The document a ``--json`` command prints, as a dict; a RuntimeError quoting the output when it is not one."""
    run = exakit(*args, show=False, timeout=timeout)
    try:
        doc = json.loads(run.output)
    except ValueError as err:
        raise RuntimeError(f"exakit {' '.join(args)} did not answer with JSON (exit {run.code}):\n{run.output.strip()[:2000]}") from err
    return doc if isinstance(doc, dict) else {"value": doc}


def kit_status() -> dict[str, Any]:
    """``exakit status --json`` as a dict."""
    return kit_json("status", "--json")


def kit_check(show: bool = True) -> dict[str, Any]:
    """The kit as it is now, in a few lines: installed or not, the database, each add-on service and its address, the
    datasets loaded. Never raises: without the command it says where it looked. Returns the status document ({} when
    there is none)."""
    if not exakit_command():
        if show:
            print(NOT_FOUND)
        return {}
    try:
        status = kit_status()
    except RuntimeError as err:
        if show:
            print(str(err))
        return {}
    if show:
        for line in _status_lines(status):
            print(line)
    return status


def _status_lines(status: dict[str, Any]) -> list[str]:
    if not status.get("installed"):
        lines = [f"The kit is not installed ({status.get('status', 'no install record')})."]
        if status.get("remedy"):
            lines.append(f"Install it with: {status['remedy']}")
        return lines
    runtime = status.get("runtime") or {}
    database = runtime.get("status") or status.get("status") or "unknown"
    head = f"Kit: installed; database {database}"
    if status.get("installing"):
        head += f" (an install is still at step: {status.get('install_step')})"
    lines = [head]
    services = status.get("services") or {}
    urls = status.get("urls") or {}
    if services:
        lines.append("Add-on services: " + ", ".join(f"{name} {state}" + (f" at {urls[name]}" if urls.get(name) else "")
                                                     for name, state in services.items()))
    datasets = status.get("datasets_loaded") or []
    lines.append("Datasets loaded: " + (", ".join(datasets) if datasets else "none yet (the quickstart loads one)"))
    remedies = status.get("remedies") or {}
    for what, remedy in remedies.items():
        lines.append(f"To fix {what}: nb.exakit({_words(remedy)})")
    return lines


def _words(command: str) -> str:
    parts = command.split()
    if parts and parts[0] == "exakit":
        parts = parts[1:]
    return ", ".join(json.dumps(p) for p in parts)


def addon_ready(addon: str, start: bool = True, show: bool = True) -> dict[str, Any]:
    """Make an add-on usable from here: install it when it is not (``exakit marketplace <addon>``), start it when it
    is a service and stopped (``exakit start <addon>``), and say its state and address. Returns {addon, installed,
    state, url}. An add-on the marketplace does not have is a ValueError; a failed install or start a RuntimeError
    (its output was shown)."""
    listing = kit_json("marketplace", "--json")
    addons = {entry.get("id"): entry for entry in listing.get("addons") or [] if isinstance(entry, dict)}
    if addon not in addons:
        raise ValueError(f"No add-on '{addon}' in the marketplace (it has: {', '.join(sorted(addons)) or 'none'}).")
    if not addons[addon].get("installed"):
        if show:
            print(f"Installing the {addon} add-on from here (as `exakit marketplace {addon}` would):", flush=True)
        run = exakit("marketplace", addon, show=show)
        if not run.ok:
            raise RuntimeError(f"The {addon} add-on did not install (exit {run.code}); the lines above say why.")
    status = kit_status()
    state = (status.get("services") or {}).get(addon)
    if start and state is not None and state != "running":
        if show:
            print(f"Starting {addon} (as `exakit start {addon}` would):", flush=True)
        run = exakit("start", addon, show=show)
        if not run.ok:
            raise RuntimeError(f"{addon} did not start (exit {run.code}); the lines above say why.")
        status = kit_status()
        state = (status.get("services") or {}).get(addon)
    url = (status.get("urls") or {}).get(addon)
    found = {"addon": addon, "installed": True, "state": state, "url": url}
    if show:
        print(f"{addon}: {'installed' if state is None else state}" + (f", at {url}" if url else ""))
    return found


def kit_update(*components: str, show: bool = True) -> KitRun:
    """``exakit update`` from here (optionally one component: ``kit_update("notebook")``). After an update that
    touched the notebook helpers, restart this kernel so the new ones load; the line printed says so."""
    run = exakit("update", *components, show=show)
    if show and run.ok:
        print("If the notebook add-on was updated: restart this kernel (Kernel > Restart) so the new helpers load; "
              "a notebook you edited is never overwritten.")
    return run


__all__ = ["KitRun", "addon_ready", "exakit", "kit_check", "kit_json", "kit_status", "kit_update"]
