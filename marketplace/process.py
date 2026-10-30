"""Process and loopback-port ownership for Python-managed add-on services."""

from __future__ import annotations

import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

from runtime import AddonFailure


def _command(pid: int) -> str:
    if sys.platform == "win32":
        shell = "powershell.exe"
        query = f"(Get-CimInstance Win32_Process -Filter 'ProcessId={pid}').CommandLine"
        args = [shell, "-NoProfile", "-NonInteractive", "-Command", query]
    else:
        args = ["ps", "-o", "command=", "-p", str(pid)]
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def listener_pids(port: int) -> set[int]:
    if not 1 <= port <= 65535:
        raise AddonFailure(f"invalid port: {port}")
    if sys.platform == "win32":
        args = ["netstat", "-ano", "-p", "TCP"]
        pattern = re.compile(r"^\s*TCP\s+\S+:" + str(port) + r"\s+\S+\s+LISTENING\s+(\d+)\s*$", re.I)
    elif sys.platform == "darwin" and subprocess.run(["which", "lsof"], capture_output=True).returncode == 0:
        args = ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"]
        pattern = re.compile(r"^\s*(\d+)\s*$")
    else:
        args = ["ss", "-lntp"]
        pattern = re.compile(r"^.*:" + str(port) + r"\s+.*pid=(\d+)")
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return set()
    return {int(match.group(1)) for line in result.stdout.splitlines() if (match := pattern.search(line))}


def port_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


def _creation(pid: int) -> str:
    if sys.platform == "win32":
        # CIM CreationDate is stable across PID reuse and needs no extra Python
        # dependency in the base environment.
        query = f"(Get-CimInstance Win32_Process -Filter 'ProcessId={pid}').CreationDate.ToString('o')"
        args = ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", query]
    else:
        args = ["ps", "-o", "lstart=", "-p", str(pid)]
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


class ManagedProcess:
    def __init__(self, pidfile: Path, log: Path, marker: Path):
        self.pidfile = pidfile
        self.log = log
        self.marker = marker
        self._process: subprocess.Popen | None = None

    def owned_pids(self, port: int) -> set[int]:
        marker = str(self.marker)
        return {pid for pid in listener_pids(port) if marker in _command(pid)}

    def recorded_pid(self) -> int | None:
        try:
            doc = json.loads(self.pidfile.read_text(encoding="utf-8"))
            pid = int(doc["pid"])
            if pid > 0 and doc["created"] == _creation(pid) and str(self.marker) in _command(pid):
                return pid
        except (OSError, ValueError, KeyError, TypeError):
            pass
        return None

    def status(self, port: int) -> str:
        ours = self.owned_pids(port)
        if self.recorded_pid() in ours or ours:
            return "running"
        foreign = listener_pids(port) - ours
        if foreign:
            return f"stopped (port {port} is held by another process: pid {min(foreign)})"
        if port_open(port):
            return f"stopped (port {port} is busy; owner could not be verified)"
        return "stopped"

    def start(self, command: list[str], port: int, *, seconds: int = 60) -> None:
        state = self.status(port)
        if state == "running":
            return
        if state != "stopped":
            raise AddonFailure(state)
        self.pidfile.parent.mkdir(parents=True, exist_ok=True)
        self.log.parent.mkdir(parents=True, exist_ok=True)
        with self.log.open("a", encoding="utf-8") as output:
            kwargs = ({"creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP}
                      if sys.platform == "win32" else {"start_new_session": True})
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                       close_fds=True, **kwargs)
        self._process = process
        created = _creation(process.pid)
        if not created:
            process.terminate()
            raise AddonFailure("Could not record the service process start time")
        self.pidfile.write_text(json.dumps({"pid": process.pid, "created": created}) + "\n", encoding="utf-8")
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self.status(port) == "running":
                return
            if process.poll() is not None:
                break
            time.sleep(1)
        self.stop(port)
        raise AddonFailure(f"Service did not start on port {port}; see {self.log}")

    def stop(self, port: int) -> None:
        pids = self.owned_pids(port)
        recorded = self.recorded_pid()
        if recorded:
            pids.add(recorded)
        for pid in pids:
            try:
                if sys.platform == "win32":
                    subprocess.run(["taskkill", "/PID", str(pid), "/T"], capture_output=True, timeout=10, check=False)
                else:
                    os.kill(pid, signal.SIGTERM)
            except (OSError, subprocess.TimeoutExpired):
                pass
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and any(_command(pid) for pid in pids):
            time.sleep(0.2)
        for pid in pids:
            if _command(pid) and str(self.marker) in _command(pid):
                try:
                    if sys.platform == "win32":
                        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True,
                                       timeout=10, check=False)
                    else:
                        os.kill(pid, signal.SIGKILL)
                except (OSError, subprocess.TimeoutExpired):
                    pass
        self.pidfile.unlink(missing_ok=True)
        if self._process is not None:
            try:
                self._process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            self._process = None
