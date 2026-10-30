"""Cross-platform services used only after the kit reaches its marketplace.

Install and update operations do not depend on a system Python package. The
existing uv bootstrap supplies the interpreter; this module stays stdlib-only.
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from dataclasses import dataclass
from functools import cached_property
from pathlib import Path
from typing import Iterator


class AddonFailure(RuntimeError):
    pass


_activity_local = threading.local()


@contextlib.contextmanager
def activity_sink(callback):
    """Route one worker thread's activity to a Textual progress screen."""
    previous = getattr(_activity_local, "callback", None)
    _activity_local.callback = callback
    try:
        yield
    finally:
        _activity_local.callback = previous


def _lock_file(handle) -> None:
    if sys.platform == "win32":
        import msvcrt

        handle.seek(0)
        if not handle.read(1):
            handle.write("0")
            handle.flush()
        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
    else:
        import fcntl

        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)


def _unlock_file(handle) -> None:
    if sys.platform == "win32":
        import msvcrt

        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
    else:
        import fcntl

        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


class Manifest:
    """Atomic receipt writes using the kit's existing manifest.json.lock file."""

    def __init__(self, path: Path):
        self.path = path

    def read(self) -> dict:
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError as error:
            raise AddonFailure("No starter kit installation is recorded") from error

    def get(self, dotted: str, default=None):
        try:
            node = self.read()
        except AddonFailure:
            return default
        for key in dotted.split("."):
            if not isinstance(node, dict) or key not in node:
                return default
            node = node[key]
        return node

    @contextlib.contextmanager
    def edit(self) -> Iterator[dict]:
        if not self.path.exists():
            raise AddonFailure("No starter kit installation is recorded")
        lock_path = self.path.with_name(self.path.name + ".lock")
        lock = None
        # PowerShell opens this same path with FileShare.None. On Windows an
        # attempted open can therefore fail before msvcrt.locking gets a turn.
        for attempt in range(200):
            try:
                lock = lock_path.open("a+", encoding="ascii")
                break
            except PermissionError:
                time.sleep(0.025)
        if lock is None:
            raise AddonFailure("The kit manifest is busy; retry this command")
        with lock:
            _lock_file(lock)
            try:
                doc = self.read()
                before = json.dumps(doc, sort_keys=True, separators=(",", ":"))
                yield doc
                if json.dumps(doc, sort_keys=True, separators=(",", ":")) == before:
                    return
                fd, temp_name = tempfile.mkstemp(prefix=self.path.name + ".", dir=self.path.parent)
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as out:
                        json.dump(doc, out, indent=2)
                        out.write("\n")
                        out.flush()
                        os.fsync(out.fileno())
                    for attempt in range(6):
                        try:
                            os.replace(temp_name, self.path)
                            break
                        except PermissionError:
                            if attempt == 5:
                                raise
                            time.sleep(0.05 * (attempt + 1))
                finally:
                    if os.path.exists(temp_name):
                        os.unlink(temp_name)
            finally:
                _unlock_file(lock)

    def set_many(self, values: dict[str, object]) -> None:
        with self.edit() as doc:
            for dotted, value in values.items():
                node = doc
                parts = dotted.split(".")
                for key in parts[:-1]:
                    node = node.setdefault(key, {})
                    if not isinstance(node, dict):
                        raise AddonFailure(f"Invalid manifest path: {dotted}")
                node[parts[-1]] = value

    def delete(self, *paths: str) -> None:
        with self.edit() as doc:
            for dotted in paths:
                node = doc
                parts = dotted.split(".")
                for key in parts[:-1]:
                    node = node.get(key, {}) if isinstance(node, dict) else {}
                if isinstance(node, dict):
                    node.pop(parts[-1], None)


@dataclass(frozen=True)
class KitContext:
    root: Path
    home: Path
    bin_dir: Path
    manifest: Manifest
    uv: Path

    @classmethod
    def from_environment(cls, root: Path) -> "KitContext":
        home = Path(os.environ.get("EXAKIT_HOME", str(Path.home() / ".exasol-starter-kit"))).expanduser()
        bin_dir = Path(os.environ.get("EXAKIT_BIN_DIR", str(Path.home() / ".local" / "bin"))).expanduser()
        uv_path = shutil.which("uv") or shutil.which("uv.exe")
        if not uv_path:
            candidate = bin_dir / ("uv.exe" if os.name == "nt" else "uv")
            uv_path = str(candidate) if candidate.exists() else None
        return cls(root, home, bin_dir, Manifest(home / "manifest.json"), Path(uv_path) if uv_path else Path("uv"))

    def require_uv(self) -> Path:
        if self.uv.is_file() or shutil.which(str(self.uv)):
            return self.uv
        raise AddonFailure("uv is missing; the kit's Python bootstrap must finish first")

    def path(self, name: str, fallback: Path) -> Path:
        """Honor the add-on path overrides supported by the old launchers."""
        value = os.environ.get(name)
        return Path(value).expanduser() if value else fallback

    def owned_path(self, receipt: str, field: str, name: str, fallback: Path) -> Path:
        """Keep a kit-owned resource on its recorded path after env changes."""
        if self.manifest.get(f"{receipt}.ownership") == "kit":
            recorded = self.manifest.get(f"{receipt}.{field}")
            if isinstance(recorded, str) and recorded:
                return Path(recorded)
        return self.path(name, fallback)

    @cached_property
    def _versions_document(self) -> dict:
        selected = os.environ.get("EXAKIT_MARKETPLACE_VERSIONS_DOC")
        path = Path(selected) if selected else self.root / "versions.json"
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise AddonFailure(f"Cannot read the selected versions document: {path}") from error
        if not isinstance(document, dict) or not isinstance(document.get("components"), dict):
            raise AddonFailure(f"Invalid versions document: {path}")
        return document

    def versions_document(self) -> dict:
        return self._versions_document

    def target_version(self, addon_id: str, default: str) -> str:
        # The platform adapter has already resolved the kit's active cached
        # versions document and explicit override. Use exactly that answer.
        if os.environ.get("EXAKIT_MARKETPLACE_TARGET_VERSION"):
            return os.environ["EXAKIT_MARKETPLACE_TARGET_VERSION"]
        key = "EXAKIT_" + addon_id.upper().replace("-", "_") + "_VERSION"
        if os.environ.get(key):
            return os.environ[key]
        policy = os.environ.get("EXAKIT_VERSION_POLICY", "manifest")
        if policy not in ("manifest", "latest"):
            return default
        # The release's versions.json is the advertised set. The marketplace
        # only carries the fallback when that block is absent or policy=pinned.
        versions = self.versions_document()
        block = versions.get("components", {}).get(addon_id, {})
        pinned = block.get("version")
        if policy == "latest" and addon_id != "json-tables":
            try:
                if block.get("repo"):
                    url = f"https://api.github.com/repos/{block['repo']}/releases/latest"
                    with urllib.request.urlopen(url, timeout=15) as response:
                        tag = json.load(response).get("tag_name", "")
                    if isinstance(tag, str) and tag:
                        return tag[1:] if tag.startswith("v") else tag
                elif block.get("package"):
                    url = f"https://pypi.org/pypi/{block['package']}/json"
                    with urllib.request.urlopen(url, timeout=15) as response:
                        latest = json.load(response).get("info", {}).get("version")
                    if isinstance(latest, str) and latest:
                        return latest
            except (OSError, ValueError, KeyError):
                pass
        return pinned or default

    def run_logged(self, label: str, *argv: str, env: dict[str, str] | None = None,
                   cwd: Path | None = None, timeout: int | None = None) -> None:
        log_dir = self.home / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        log_path = log_dir / "marketplace.log"
        self.activity(label)
        with log_path.open("a", encoding="utf-8") as log:
            log.write(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {label}\n")
            log.flush()
            try:
                result = subprocess.run(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                        check=False, timeout=timeout)
            except (OSError, subprocess.TimeoutExpired) as error:
                raise AddonFailure(f"{label} did not finish; see exakit logs setup") from error
        if result.returncode != 0:
            raise AddonFailure(f"{label} failed (exit {result.returncode}); see exakit logs setup")

    def log_event(self, message: str) -> None:
        log_dir = self.home / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        safe = message.replace("\r", " ").replace("\n", " ")
        with (log_dir / "marketplace.log").open("a", encoding="utf-8") as log:
            log.write(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {safe}\n")

    def activity(self, label: str) -> None:
        callback = getattr(_activity_local, "callback", None)
        if callback is not None:
            callback(label)
            return
        activity_file = os.environ.get("EXAKIT_MARKETPLACE_ACTIVITY_FILE")
        row = os.environ.get("EXAKIT_MARKETPLACE_ACTIVITY_ROW", "")
        if activity_file and row.isdecimal() and int(row) > 0:
            # The platform table already owns stdout. Its animator reads this
            # side channel and draws the current operation above the bar.
            # Replacing one complete record avoids a half-line on a redraw.
            path = Path(activity_file)
            safe = label.replace("\r", " ").replace("\n", " ").replace("|", " ")
            fd, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as out:
                    out.write(f"{row}|{safe}\n")
                os.replace(name, path)
            finally:
                if os.path.exists(name):
                    os.unlink(name)
            return
        print(f"  • {label}", flush=True)


def venv_python(venv: Path) -> Path:
    return venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def venv_executable(venv: Path, name: str) -> Path:
    return venv / (f"Scripts/{name}.exe" if os.name == "nt" else f"bin/{name}")
