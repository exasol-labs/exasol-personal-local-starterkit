"""Watch a disposable kit home for its secrets: process arguments, command output and generated files.

Findings name the place and the secret's label, never the value. Secrets are the
database password files the fixture borrows, every value the disposable kit writes
under credentials/, and credential-named environment values. Values shorter than
eight characters are skipped: they occur by chance in package names and paths.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
from contextlib import contextmanager
from pathlib import Path

MIN_LENGTH = 8
SKIP_DIRS = {"credentials", "site-packages", "__pycache__", "node_modules", ".git"}
MAX_FILE = 2 * 1024 * 1024
CREDENTIAL_ENV = ("PASSWORD", "TOKEN", "_KEY", "SECRET")


def _values_in(path: Path) -> list[str]:
    """A credential file's secrets: its whole text, or each string value of a JSON document."""
    try:
        text = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError):
        return []
    try:
        doc = json.loads(text)
    except ValueError:
        return [text]
    if isinstance(doc, dict):
        return [value for value in doc.values() if isinstance(value, str)]
    return [text] if isinstance(doc, str) else []


def _process_lines() -> list[str]:
    """Every process's command line, as the same user would see it."""
    if os.name == "nt":
        argv = ["powershell.exe", "-NoProfile", "-Command",
                "Get-CimInstance Win32_Process | ForEach-Object { $_.CommandLine }"]
    else:
        argv = ["ps", "-axww", "-o", "command="]
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=20, check=False).stdout.splitlines()
    except (OSError, subprocess.TimeoutExpired):
        return []


class PrivacyWatch:
    def __init__(self, source: Path, home: Path, bin_dir: Path, fixture: dict):
        self.source, self.home, self.bin_dir = source, home, bin_dir
        self.runtime = fixture["runtime"]
        self.findings: list[dict] = []
        self.samples = 0

    def secrets(self) -> dict[str, str]:
        """Read afresh each time: installs write new credentials while the watch runs."""
        found: dict[str, str] = {}
        borrowed = [self.runtime.get("password_file")]
        try:
            manifest = json.loads((self.source / "manifest.json").read_text())
            borrowed.append(manifest.get("components", {}).get("mcp_server", {}).get("connection", {}).get("password_file"))
        except (OSError, ValueError):
            pass
        for index, name in enumerate(borrowed):
            if name and Path(name).is_file():
                for value in _values_in(Path(name)):
                    found[f"database_password_{index}"] = value
        folder = self.home / "credentials"
        if folder.is_dir():
            for path in sorted(folder.rglob("*")):
                if path.is_file():
                    for number, value in enumerate(_values_in(path)):
                        found[f"credentials/{path.relative_to(folder)}#{number}"] = value
        for key, value in os.environ.items():
            if key.upper().endswith(CREDENTIAL_ENV) and value:
                found[f"env:{key}"] = value
        return {label: value for label, value in found.items() if len(value) >= MIN_LENGTH}

    def _note(self, phase: str, where: str, labels: list[str]) -> None:
        for label in sorted(set(labels)):
            entry = {"phase": phase, "where": where, "secret": label}
            if entry not in self.findings:
                self.findings.append(entry)

    def scan_text(self, phase: str, where: str, text: str) -> None:
        self._note(phase, where, [label for label, value in self.secrets().items() if value in text])

    def scan_files(self, phase: str) -> None:
        """Every generated text file in the kit home and bin folder, apart from the credentials store."""
        secrets = self.secrets()
        for root in (self.home, self.bin_dir):
            for folder, dirs, files in os.walk(root):
                dirs[:] = [name for name in dirs if name not in SKIP_DIRS]
                for name in files:
                    path = Path(folder) / name
                    try:
                        if path.is_symlink() or path.stat().st_size > MAX_FILE:
                            continue
                        data = path.read_bytes()
                    except OSError:
                        continue
                    if b"\0" in data[:8192]:
                        continue
                    text = data.decode("utf-8", errors="replace")
                    labels = [label for label, value in secrets.items() if value in text]
                    if labels:
                        self._note(phase, f"file {path.relative_to(root.parent)}", labels)

    @contextmanager
    def watching(self, phase: str):
        """Sample every process's arguments while the block runs."""
        stop = threading.Event()

        def sample() -> None:
            while not stop.is_set():
                secrets = self.secrets()
                for line in _process_lines():
                    labels = [label for label, value in secrets.items() if value in line]
                    if labels:
                        self._note(phase, "process arguments", labels)
                self.samples += 1
                stop.wait(0.2)

        thread = threading.Thread(target=sample, daemon=True)
        thread.start()
        try:
            yield
        finally:
            stop.set()
            thread.join(timeout=30)


def leftovers(before: set[str], after: set[str], kept: list[str]) -> list[str]:
    """Paths the add-on's lifecycle created and its removal left, apart from logs, caches and ``kept``: the user's
    work its removal keeps by design, and the folders that hold it."""
    keep = ("logs/", "cache/", "manifest.json", *kept)
    holders = {item.rstrip("/").rsplit("/", depth)[0] + "/" for item in kept for depth in range(1, item.count("/") + 1)}
    return sorted(path for path in after - before if not path.startswith(keep) and path not in holders)


def paths(folder: Path) -> set[str]:
    """Every file and folder under ``folder``, relative, folders with a trailing slash."""
    found = set()
    for path in folder.rglob("*"):
        relative = path.relative_to(folder).as_posix()
        found.add(relative + "/" if path.is_dir() and not path.is_symlink() else relative)
    return found
