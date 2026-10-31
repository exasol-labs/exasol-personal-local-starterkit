"""On-demand JupyterLab, Marimo and Positron commands for the kit notebook add-on."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import webbrowser
from pathlib import Path

from addons import notebook
from process import _command, _creation
from runtime import AddonFailure, KitContext, venv_executable, venv_python


class NotebookParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise AddonFailure(message)


def _healthy(frontend: str, port: int) -> bool:
    path = "/api" if frontend == "jupyterlab" else "/health"
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=2) as response:
            if frontend == "marimo":
                return 200 <= response.status < 400
            return b'"version"' in response.read(4096)
    except (OSError, ValueError):
        return False


def _port_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


def _port(ctx: KitContext, front: str, given: int | None) -> int:
    key = "port" if front == "jupyterlab" else "marimo_port"
    default = 8888 if front == "jupyterlab" else 2718
    raw = given or os.environ.get("EXAKIT_NOTEBOOK_PORT" if front == "jupyterlab" else "EXAKIT_MARIMO_PORT") or ctx.manifest.get(f"components.notebook.{key}", default)
    try:
        value = int(raw)
    except (TypeError, ValueError) as error:
        raise AddonFailure(f"Invalid {front} port: {raw}") from error
    if not 1024 <= value <= 65535:
        raise AddonFailure(f"Invalid {front} port: {raw}")
    return value


def _choose_port(port: int, given: bool) -> int:
    if not _port_open(port):
        return port
    if given:
        raise AddonFailure(f"Port {port} is in use by another program; choose another with --port")
    tries = int(os.environ.get("EXAKIT_NOTEBOOK_PORT_TRIES", "20"))
    for candidate in range(port + 1, min(port + tries + 1, 65536)):
        if not _port_open(candidate):
            print(f"Port {port} is in use, so the notebook uses port {candidate}")
            return candidate
    raise AddonFailure(f"No free notebook port from {port} through {min(port + tries, 65535)}")


class OnDemandServer:
    """A kit-started process identified by command and creation time."""

    def __init__(self, ctx: KitContext, front: str):
        self.ctx = ctx
        self.front = front
        _, home, _ = notebook.paths(ctx)
        self.pidfile = home / ("jupyter.pid" if front == "jupyterlab" else "marimo.pid")
        self.log = ctx.home / "logs" / ("notebook.log" if front == "jupyterlab" else "notebook-marimo.log")
        self.marker = (str(home / "jupyter_server_config.json") if front == "jupyterlab"
                       else str(ctx.root / "notebook" / "kit" / "marimo_wrapper.py"))

    def pid(self) -> int | None:
        try:
            raw = self.pidfile.read_text(encoding="utf-8").strip()
            doc = json.loads(raw) if raw.startswith("{") else {"pid": int(raw)}
            pid = int(doc["pid"])
            command = _command(pid)
            if pid <= 0 or self.marker not in command:
                return None
            if doc.get("created") and doc["created"] != _creation(pid):
                return None
            return pid
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def state(self, port: int) -> str:
        if not self.pid():
            return "stopped"
        return "running" if _healthy(self.front, port) else "starting"

    def recorded_port(self, fallback: int) -> int:
        if self.pid():
            try:
                value = int(json.loads(self.pidfile.read_text(encoding="utf-8"))["port"])
                if 1024 <= value <= 65535:
                    return value
            except (OSError, ValueError, KeyError, TypeError):
                pass
        return fallback

    def wait_ready(self, port: int) -> None:
        deadline = time.monotonic() + int(os.environ.get("EXAKIT_NOTEBOOK_START_TIMEOUT", "60"))
        while time.monotonic() < deadline:
            state = self.state(port)
            if state == "running":
                return
            if state == "stopped":
                break
            time.sleep(1)
        raise AddonFailure(f"{self.front} did not start on port {port}; see {self.log}")

    def start(self, argv: list[str], port: int, *, env: dict[str, str] | None = None) -> None:
        if self.state(port) in ("running", "starting"):
            self.wait_ready(port)
            return
        if _port_open(port):
            raise AddonFailure(f"Port {port} is already in use by another program")
        self.pidfile.parent.mkdir(parents=True, exist_ok=True)
        self.log.parent.mkdir(parents=True, exist_ok=True)
        with self.log.open("a", encoding="utf-8") as output:
            flags = ({"creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP}
                     if os.name == "nt" else {"start_new_session": True})
            process = subprocess.Popen(argv, cwd=notebook.paths(self.ctx)[2], env=env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT, close_fds=True, **flags)
        self.pidfile.write_text(json.dumps({"pid": process.pid, "created": _creation(process.pid), "port": port}) + "\n",
                                encoding="utf-8")
        try:
            self.wait_ready(port)
        except AddonFailure:
            self.stop()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            raise

    def stop(self) -> None:
        pid = self.pid()
        if pid:
            try:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(pid), "/T"], capture_output=True,
                                   check=False, timeout=10)
                else:
                    try:
                        os.killpg(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        # Legacy pidfiles may name a process that did not
                        # start a new session. Its command was checked above.
                        os.kill(pid, signal.SIGTERM)
            except (OSError, subprocess.TimeoutExpired):
                pass
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and self.marker in _command(pid):
                time.sleep(0.2)
            if self.marker in _command(pid):
                try:
                    if os.name == "nt":
                        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True,
                                       check=False, timeout=10)
                    else:
                        os.kill(pid, signal.SIGKILL)
                except (OSError, subprocess.TimeoutExpired):
                    pass
        self.pidfile.unlink(missing_ok=True)
        _, home, _ = notebook.paths(self.ctx)
        (home / ("open-jupyter.html" if self.front == "jupyterlab" else "open-marimo.html")).unlink(missing_ok=True)


def _open_logged_in(ctx: KitContext, front: str, url: str) -> None:
    _, home, _ = notebook.paths(ctx)
    home.mkdir(parents=True, exist_ok=True)
    target = home / ("open-jupyter.html" if front == "jupyterlab" else "open-marimo.html")
    # The browser receives a file path. The token stays in a 0600 local file,
    # not in a shell command or visible CLI argument.
    target.write_text("<!doctype html><meta http-equiv=refresh content=\"0;url=" + url.replace('"', "%22") + "\">\n",
                      encoding="utf-8")
    if os.name != "nt":
        target.chmod(0o600)
    try:
        opened = webbrowser.open(target.as_uri())
    except webbrowser.Error:
        opened = False
    if not opened:
        print(f"Open the login file in your browser: {target}")


def _database_up(ctx: KitContext) -> bool:
    dsn = ctx.manifest.get("runtime.dsn", "")
    try:
        host, port = str(dsn).rsplit(":", 1)
        with socket.create_connection((host, int(port)), timeout=2):
            return True
    except (OSError, ValueError):
        return False


def _confirm(question: str) -> bool:
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return False
    return input(question + " [Y/n] ").strip().lower() in ("", "y", "yes")


def _preflight(ctx: KitContext) -> None:
    venv, _, directory = notebook.paths(ctx)
    python = venv_python(venv)
    healthy = False
    if python.is_file():
        try:
            result = subprocess.run([str(python), "-c", notebook.IMPORT_CHECK],
                                    capture_output=True, check=False, timeout=15)
            healthy = result.returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            pass
    if not healthy:
        condition = "missing" if not python.is_file() else "broken"
        if not _confirm(f"The notebook environment is {condition}. Repair it now (about 1 GB)?"):
            raise AddonFailure(f"The notebook environment is {condition}; repair it with: exakit update notebook")
        notebook.install(ctx)
        if not venv_python(venv).is_file():
            raise AddonFailure("The notebook environment could not be repaired; run exakit update notebook")
    if not _database_up(ctx):
        if not _confirm("The database is not running. Start it now?"):
            raise AddonFailure("The database is not running; start it with: exakit start")
        executable = ctx.bin_dir / ("exakit.cmd" if os.name == "nt" else "exakit")
        if not executable.is_file():
            found = shutil.which("exakit")
            if not found:
                raise AddonFailure("The exakit launcher is missing; repair it with the kit installer")
            executable = Path(found)
        result = subprocess.run([str(executable), "start", "database"], check=False, timeout=300)
        if result.returncode or not _database_up(ctx):
            raise AddonFailure("The database still does not answer; inspect exakit status")
    notebook._write_store(ctx)
    notebook._register_kernel(ctx)
    directory.mkdir(parents=True, exist_ok=True)
    notebook._copy(ctx, "jupyter")


def _find_jupyter(ctx: KitContext) -> Path | None:
    venv = notebook.paths(ctx)[0]
    for name in ("jupyter-lab", "jupyter-notebook"):
        binary = venv_executable(venv, name)
        if binary.is_file():
            return binary
    return notebook._external_jupyter(ctx)


def _ensure_frontend(ctx: KitContext, front: str, setup: bool) -> None:
    present = (_find_jupyter(ctx) if front == "jupyterlab"
               else venv_executable(notebook.paths(ctx)[0], "marimo") if front == "marimo" else None)
    if present and (front != "marimo" or present.is_file()):
        return
    answer = os.environ.get("EXAKIT_NOTEBOOK_JUPYTER" if front == "jupyterlab" else "EXAKIT_NOTEBOOK_MARIMO", "")
    if answer.lower() in {"skip", "no", "0", "false", "none"}:
        raise AddonFailure(f"{front} was skipped; add it with: exakit notebook {front} setup")
    if not setup and not (sys.stdin.isatty() and sys.stdout.isatty()) and answer.lower() != "install":
        raise AddonFailure(f"{front} is missing; install it with: exakit notebook {front} setup")
    if not setup and answer.lower() != "install":
        response = input(f"Install {front} into the kit's notebook environment? [Y/n] ").strip().lower()
        if response not in ("", "y", "yes"):
            raise AddonFailure(f"{front} was not installed")
    prior = os.environ.get("EXAKIT_NOTEBOOK_FRONTENDS")
    try:
        selected = set(notebook._frontends(ctx))
        selected.add(front)
        os.environ["EXAKIT_NOTEBOOK_FRONTENDS"] = ",".join(item for item in notebook.FRONTENDS if item in selected)
        notebook.install(ctx)
    finally:
        if prior is None:
            os.environ.pop("EXAKIT_NOTEBOOK_FRONTENDS", None)
        else:
            os.environ["EXAKIT_NOTEBOOK_FRONTENDS"] = prior


def _start_frontend(ctx: KitContext, front: str, port_arg: int | None, browser: bool, setup: bool) -> None:
    _ensure_frontend(ctx, front, setup)
    if setup:
        print(f"{front} is ready in the kit's notebook environment")
        return
    server = OnDemandServer(ctx, front)
    port = _port(ctx, front, port_arg)
    key = "port" if front == "jupyterlab" else "marimo_port"
    recorded = server.recorded_port(int(ctx.manifest.get(f"components.notebook.{key}", 8888 if front == "jupyterlab" else 2718)))
    state = server.state(recorded)
    if state in ("running", "starting"):
        if port_arg and port_arg != recorded:
            print(f"{front} is already {state} on port {recorded}; --port {port_arg} is ignored")
        port = recorded
        if state == "starting":
            server.wait_ready(port)
    if server.state(port) == "stopped":
        port = _choose_port(port, port_arg is not None)
        venv, home, directory = notebook.paths(ctx)
        if front == "jupyterlab":
            command = _find_jupyter(ctx)
            if command is None:
                raise AddonFailure("JupyterLab is missing; run exakit notebook setup")
            config = home / "jupyter_server_config.json"
            config.write_text(json.dumps({"ContentsManager": {"hide_globs": ["__pycache__", "*.pyc", "*.pyo",
                                                                       ".DS_Store", "*~", ".ipynb_checkpoints", "marimo"]}}),
                              encoding="utf-8")
            token_file = notebook._credential(ctx, "notebook_jupyter_token")
            token = token_file.read_text(encoding="utf-8").strip()
            env = {**os.environ, "JUPYTER_TOKEN": token}
            argv = [str(venv_python(venv)), str(ctx.root / "notebook" / "kit" / "server_wrapper.py"),
                    str(token_file), str(command), "--no-browser", "--ServerApp.ip=127.0.0.1", f"--ServerApp.port={port}",
                    "--ServerApp.port_retries=0", f"--ServerApp.root_dir={directory}", f"--config={config}"]
        else:
            notebook._copy(ctx, "marimo")
            token_file = notebook._credential(ctx, "notebook_marimo_token")
            command = venv_executable(venv, "marimo")
            argv = [str(venv_python(venv)), str(ctx.root / "notebook" / "kit" / "marimo_wrapper.py"),
                    str(token_file), str(command), "edit", str(directory / "marimo"), "--headless", "--host",
                    "127.0.0.1", "--port", str(port), "--token-password-file", str(token_file),
                    "--skip-update-check"]
            env = None
        server.start(argv, port, env=env)
        ctx.manifest.set_many({f"components.notebook.{ 'port' if front == 'jupyterlab' else 'marimo_port'}": port})
    url = f"http://127.0.0.1:{port}/lab" if front == "jupyterlab" else f"http://127.0.0.1:{port}/"
    print(f"{front} is running: {url}")
    if browser:
        token = notebook._credential(ctx, "notebook_jupyter_token" if front == "jupyterlab" else "notebook_marimo_token").read_text(encoding="utf-8").strip()
        suffix = f"?token={token}" if front == "jupyterlab" else f"?access_token={token}"
        _open_logged_in(ctx, front, url + suffix)


def _positron(ctx: KitContext) -> None:
    venv, _, directory = notebook.paths(ctx)
    notebook._run_helper(ctx, "notebooks.py", "positron", str(directory), str(venv_python(venv)), str(venv))
    command = _positron_command()
    if command:
        argv = (["open", "-a", command, str(directory)] if command.endswith(".app") else [command, str(directory)])
        subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"Positron opened on {directory}")
    else:
        print(f"Positron is not installed; the notebook folder is ready: {directory}")


def _positron_command() -> str | None:
    found = shutil.which("positron")
    if found:
        return found
    for candidate in (Path("/Applications/Positron.app"), Path.home() / "Applications" / "Positron.app",
                      Path("/usr/share/positron/positron")):
        if candidate.exists():
            return str(candidate)
    if os.name == "nt":
        for variable, relative in (("LOCALAPPDATA", "Programs/Positron/Positron.exe"),
                                   ("ProgramFiles", "Positron/Positron.exe")):
            base = os.environ.get(variable)
            if base and (Path(base) / relative).is_file():
                return str(Path(base) / relative)
    return None


def _menu(ctx: KitContext) -> list[str] | None:
    """Return the Textual multi-select answer, or None when it was cancelled."""
    jupyter = _find_jupyter(ctx)
    jport = _port(ctx, "jupyterlab", None)
    mport = _port(ctx, "marimo", None)
    jserver = OnDemandServer(ctx, "jupyterlab")
    mserver = OnDemandServer(ctx, "marimo")
    jport = jserver.recorded_port(jport)
    mport = mserver.recorded_port(mport)
    jstate = jserver.state(jport)
    mstate = mserver.state(mport)
    marimo = venv_executable(notebook.paths(ctx)[0], "marimo").is_file()
    positron = _positron_command()
    recorded = str(ctx.manifest.get("components.notebook.front_ends", ""))
    installed = set(recorded.split(","))
    if jupyter and jupyter.is_relative_to(notebook.paths(ctx)[0]):
        try:
            version = subprocess.run([str(jupyter), "--version"], capture_output=True, text=True,
                                     check=False, timeout=10)
            kit_version = version.stdout.strip() if version.returncode == 0 else ""
        except (OSError, subprocess.TimeoutExpired):
            kit_version = ""
        jdetail = f"ready (the kit's {kit_version})" if kit_version else "ready (the kit's)"
    elif jupyter:
        jdetail = f"ready (yours: {jupyter})"
    else:
        jdetail = ("missing - reinstall it" if "jupyterlab" in installed else "not installed - installs it")
        jdetail += " into the kit's environment"
    mdetail = "ready" if marimo else ("missing - reinstall it" if "marimo" in installed else "not installed - installs it")
    tools = [
        {"id": "jupyterlab", "label": "JupyterLab",
         "detail": f"running at http://127.0.0.1:{jport}/lab" if jstate == "running"
                   else f"starting on port {jport}" if jstate == "starting" else jdetail},
        {"id": "marimo", "label": "Marimo",
         "detail": f"running at http://127.0.0.1:{mport}/" if mstate == "running"
                   else f"starting on port {mport}" if mstate == "starting" else mdetail},
        {"id": "positron", "label": "Positron",
         "detail": "found - opens on the notebooks folder" if positron else "not on this machine (get it at positron.posit.co)",
         "disabled": not bool(positron)},
    ]
    with tempfile.TemporaryDirectory(prefix="exakit-notebook-ui-") as temp:
        states = Path(temp) / "states.json"
        result = Path(temp) / "result.json"
        states.write_text(json.dumps({"tools": tools}), encoding="utf-8")
        run = subprocess.run([sys.executable, str(ctx.root / "marketplace" / "launch.py"), str(ctx.root),
                              "notebook", "--states", str(states), "--out", str(result),
                              "--recorded", recorded], check=False)
        if run.returncode == 10:
            return None
        if run.returncode != 0 or not result.is_file():
            raise AddonFailure("The Notebook menu could not start; choose jupyterlab, marimo, or positron explicitly")
        answer = json.loads(result.read_text(encoding="utf-8"))
        return answer["selected"]


def command(ctx: KitContext, args: list[str]) -> int:
    parser = NotebookParser(prog="exakit notebook", add_help=False)
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--port", type=int)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--setup", action="store_true")
    parser.add_argument("--stop", action="store_true")
    parser.add_argument("--marimo", action="store_true")
    parser.add_argument("--positron", action="store_true")
    parser.add_argument("front", nargs="?", choices=("jupyterlab", "marimo", "positron"))
    normalized = ["--" + item if item in ("check", "setup", "stop") else item for item in args]
    parsed, unknown = parser.parse_known_args(normalized)
    if unknown:
        raise AddonFailure(f"Unknown option for exakit notebook: {unknown[0]} (see: exakit help notebook)")
    fronts = {name for name, yes in ((parsed.front, parsed.front is not None),
                                     ("marimo", parsed.marimo), ("positron", parsed.positron)) if yes}
    if len(fronts) > 1:
        raise AddonFailure("Pick one of jupyterlab, marimo and positron")
    explicit_front = bool(fronts)
    front = fronts.pop() if fronts else "jupyterlab"
    if parsed.port is not None and not 1024 <= parsed.port <= 65535:
        raise AddonFailure("--port needs a number between 1024 and 65535")
    if not ctx.manifest.get("components.notebook.version"):
        raise AddonFailure("The notebook add-on is not installed. Install it with: exakit marketplace notebook")
    if parsed.stop:
        if front == "positron":
            print("Positron is yours to close; the kit does not run it")
        else:
            OnDemandServer(ctx, front).stop()
            if not explicit_front:
                OnDemandServer(ctx, "marimo").stop()
            print(f"{front} stopped" if explicit_front else "Notebook servers stopped")
        return 0
    _preflight(ctx)
    if parsed.check:
        master = notebook._credential(ctx, "notebook_store_master_password")
        notebook._run_helper(ctx, "check_connection.py", env={**os.environ,
            "SCS_FILE": str(notebook.paths(ctx)[1] / "connection.scs"),
            "SCS_MASTER_PASSWORD": master.read_text(encoding="utf-8").strip()})
        print("Notebooks connect to the database")
        return 0
    if not explicit_front and not parsed.setup and parsed.port is None and sys.stdin.isatty() and sys.stdout.isatty():
        selected = _menu(ctx)
        if selected is None or not selected:
            print("Nothing opened. Open the notebook tools any time with: exakit notebook")
            return 0
        failures = 0
        for selected_front in selected:
            try:
                if selected_front == "positron":
                    _positron(ctx)
                else:
                    _start_frontend(ctx, selected_front, None, not parsed.no_browser, False)
            except AddonFailure as error:
                failures += 1
                print(f"notebook: {error}", file=sys.stderr)
        if any(item in selected for item in ("jupyterlab", "marimo")):
            print("Stop notebook servers with: exakit notebook stop")
        return 1 if failures else 0
    if front == "positron":
        _positron(ctx)
    else:
        _start_frontend(ctx, front, parsed.port, not parsed.no_browser, parsed.setup)
    return 0


def main(argv: list[str] | None = None) -> int:
    try:
        return command(KitContext.from_environment(Path(__file__).resolve().parent.parent), argv or sys.argv[1:])
    except AddonFailure as error:
        print(f"notebook: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
