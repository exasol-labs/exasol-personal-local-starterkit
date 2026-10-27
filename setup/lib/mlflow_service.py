"""Local MLflow server lifecycle shared by the sh and PowerShell launchers.

Only a process whose command line names this kit's database is stopped. A stale
pid file is never authority to kill an unrelated process.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def home() -> Path:
    return Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit").expanduser()


def folder() -> Path:
    return home() / "mlflow"


def record_path() -> Path:
    return folder() / "server.json"


def read_record() -> dict:
    try:
        doc = json.loads(record_path().read_text(encoding="utf-8"))
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


def process_command(pid: int) -> str:
    if pid < 1:
        return ""
    try:
        if sys.platform == "win32":
            command = "(Get-CimInstance Win32_Process -Filter 'ProcessId=%d').CommandLine" % pid
            return subprocess.run(["powershell", "-NoProfile", "-Command", command], capture_output=True,
                                  text=True, timeout=5, check=False).stdout.strip()
        return subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True,
                              text=True, timeout=3, check=False).stdout.strip()
    except (OSError, ImportError, subprocess.TimeoutExpired):
        return ""


def ours(doc: dict) -> bool:
    try:
        command = process_command(int(doc.get("pid") or 0))
    except (ValueError, TypeError):
        return False
    # The server is started with the resolved, forward-slash path (the sqlite URI), so that is the form its
    # command line holds. A plain str() has backslashes on Windows, where it never matched: status said stopped
    # for a running server and stop left it running.
    database = folder() / "mlflow.db"
    forms = {str(database), database.as_posix(), database.resolve().as_posix()}
    return bool(command and "mlflow" in command.lower() and "server" in command.lower()
                and any(form in command for form in forms))


def healthy(url: str) -> bool:
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/health", timeout=1) as response:
            return 200 <= response.status < 300
    except (OSError, urllib.error.URLError, ValueError):
        return False


def state() -> dict:
    doc = read_record()
    url = str(doc.get("url") or "")
    running = bool(url and ours(doc) and healthy(url))
    return {"status": "running" if running else "stopped", "url": url if running else None,
            "pid": doc.get("pid") if running else None,
            "remedy": None if running else "exakit mlflow start"}


def free_port(start: int, tries: int = 20) -> int:
    for port in range(start, start + tries + 1):
        with socket.socket() as sock:
            try:
                sock.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise RuntimeError(f"No free port from {start} to {start + tries}; set EXAKIT_MLFLOW_PORT to another port")


def start(executable: Path, port: int | None) -> dict:
    current = state()
    if current["status"] == "running":
        return current
    if not executable.is_file():
        raise RuntimeError("MLflow server is missing from the notebook environment; run exakit update notebook, then exakit mlflow start")
    root = folder()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    artifacts = root / "artifacts"
    artifacts.mkdir(mode=0o700, exist_ok=True)
    selected = free_port(port or int(os.environ.get("EXAKIT_MLFLOW_PORT") or 5000), 0 if port else 20)
    url = f"http://127.0.0.1:{selected}"
    command = [str(executable), "server", "--host", "127.0.0.1", "--port", str(selected),
               "--backend-store-uri", "sqlite:///" + (root / "mlflow.db").resolve().as_posix(),
               "--artifacts-destination", str(artifacts.resolve())]
    log = (root / "server.log").open("a", encoding="utf-8")
    try:
        options = {"stdin": subprocess.DEVNULL, "stdout": log, "stderr": subprocess.STDOUT,
                   "cwd": str(root)}
        if sys.platform == "win32":
            options["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
        else:
            options["start_new_session"] = True
        child = subprocess.Popen(command, **options)
    finally:
        log.close()
    doc = {"url": url, "port": selected, "pid": child.pid}
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if child.poll() is None and healthy(url):
            target = record_path()
            temp = target.with_suffix(".tmp")
            temp.write_text(json.dumps(doc) + "\n", encoding="utf-8")
            os.replace(temp, target)
            return state()
        if child.poll() is not None:
            break
        time.sleep(0.4)
    raise RuntimeError(f"MLflow did not start; read {root / 'server.log'}")


def stop() -> dict:
    doc = read_record()
    if ours(doc):
        pid = int(doc["pid"])
        try:
            if sys.platform != "win32" and os.getpgid(pid) == pid:
                os.killpg(pid, signal.SIGTERM)
            else:
                os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 10
        while ours(doc) and time.monotonic() < deadline:
            time.sleep(0.2)
        if ours(doc):
            raise RuntimeError(f"MLflow process {pid} did not stop; read {folder() / 'server.log'}")
    record_path().unlink(missing_ok=True)
    return state()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="exakit mlflow")
    parser.add_argument("action", choices=("start", "stop", "status", "url"))
    parser.add_argument("--port", type=int)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--executable", type=Path)
    args = parser.parse_args(argv)
    if args.port is not None and not (1 <= args.port <= 65535):
        parser.error("--port must be from 1 to 65535")
    if args.port is not None and args.action != "start":
        parser.error("--port applies to start only")
    try:
        if args.action == "start":
            if args.executable is None:
                parser.error("start needs the kit's MLflow executable")
            result = start(args.executable, args.port)
        elif args.action == "stop":
            result = stop()
        else:
            result = state()
    except (OSError, RuntimeError, ValueError) as err:
        if args.json:
            print(json.dumps({"ok": False, "error": str(err), "remedy": "exakit logs mlflow"}))
        else:
            print(str(err), file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps({"ok": True, **result}))
    elif args.action == "url":
        print(result["url"] or "")
    else:
        print("MLflow: " + result["status"] + (" at " + result["url"] if result["url"] else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
