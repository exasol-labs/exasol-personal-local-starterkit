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
from typing import Iterator, Mapping

import kit_telemetry

# Every marketplace command imports this module first, before anything it
# starts can load pyexasol: Exasol's usage telemetry stays off for this
# process and all of its children unless the user set the variable already.
kit_telemetry.default_off()


class AddonFailure(RuntimeError):
    pass


class SameHostAuthRedirect(urllib.request.HTTPRedirectHandler):
    """Follow a redirect, but never hand the Authorization header to another host.

    urllib copies every header but the content ones onto the redirected request,
    a token included, wherever the redirect points (SEC-12). GitHub redirects a
    renamed repository within api.github.com, which keeps the token; anything
    else gets the request without it.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        import urllib.parse

        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and urllib.parse.urlsplit(newurl).hostname != urllib.parse.urlsplit(req.full_url).hostname:
            new.remove_header("Authorization")
        return new


def open_url(request, timeout: float):
    """urllib.request.urlopen with SameHostAuthRedirect."""
    return urllib.request.build_opener(SameHostAuthRedirect).open(request, timeout=timeout)


def host_machine() -> str:
    """The machine's own CPU architecture, as platform.machine() spells it.

    An x86_64 Python run through Rosetta 2 on Apple silicon reports x86_64, so a
    check that asks it about the Mac answered for the emulator (MAC-03); the
    shell side's detect_arch reads sysctl.proc_translated for the same reason.
    """
    import platform

    machine = platform.machine()
    if sys.platform == "darwin" and machine.lower() in ("x86_64", "amd64", "i386"):
        try:
            translated = subprocess.run(["sysctl", "-n", "sysctl.proc_translated"], capture_output=True,
                                        text=True, timeout=5, check=False).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            translated = ""
        if translated == "1":
            return "arm64"
    return machine


def write_private(path: Path, text: str) -> None:
    """Write a file only its owner can read, owner-only from the moment it exists.

    Writing first and chmod-ing after left a password or token readable under
    the default umask for the time in between (SEC-15). Created 0600; an
    existing file is narrowed before it is truncated and written.
    """
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        if os.name != "nt":
            os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            handle.write(text)
    finally:
        if descriptor != -1:
            os.close(descriptor)


def managed_python_version(environment: Mapping[str, str] | None = None) -> str:
    values = os.environ if environment is None else environment
    return values.get("EXAKIT_MANAGED_PYTHON_VERSION") or "3.12"


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

        # Windows locks are mandatory: reading or writing a byte another handle holds fails with
        # PermissionError, so byte 0 is locked without touching it (a lock may lie past the end of
        # the file). LK_LOCK gives up after ten tries a second apart; a long install keeps waiting.
        handle.seek(0)
        deadline = time.monotonic() + 300
        while True:
            try:
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                return
            except OSError:
                if time.monotonic() > deadline:
                    raise AddonFailure("The kit manifest is busy; retry this command")
                time.sleep(0.025)
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


_LATEST: dict[str, str] = {}


def _latest_published(block: dict) -> str:
    """The newest release of an add-on (GitHub) or package (PyPI) under EXAKIT_VERSION_POLICY=latest: asked once
    per process, through the same opener every download uses; "" when it cannot be asked."""
    if block.get("repo"):
        url, pick = f"https://api.github.com/repos/{block['repo']}/releases/latest", lambda doc: doc.get("tag_name", "")
    elif block.get("package"):
        url, pick = f"https://pypi.org/pypi/{block['package']}/json", lambda doc: doc.get("info", {}).get("version")
    else:
        return ""
    if url not in _LATEST:
        try:
            with open_url(urllib.request.Request(url), 15) as response:
                found = pick(json.load(response))
        except (OSError, ValueError, KeyError):
            found = ""
        found = found if isinstance(found, str) else ""
        _LATEST[url] = found[1:] if found.startswith("v") and block.get("repo") else found
    return _LATEST[url]


def vetted_uv(home: Path, bin_dir: Path) -> str | None:
    """The uv the kit vetted, never merely the first one on PATH, which may be below the version floor the shell
    refuses (exakit_ensure_uv): EXAKIT_UV_BIN, else the path the shell recorded in the manifest
    (components.uv.path), else the kit's own copy in the bin folder, and PATH only when none of them exists."""
    name = "uv.exe" if os.name == "nt" else "uv"
    candidates = [os.environ.get("EXAKIT_UV_BIN", "")]
    try:
        candidates.append(json.loads((home / "manifest.json").read_text(encoding="utf-8"))
                          .get("components", {}).get("uv", {}).get("path", ""))
    except (OSError, ValueError, AttributeError):
        pass
    candidates.append(str(bin_dir / name))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    return shutil.which("uv") or shutil.which("uv.exe")


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
        uv_path = vetted_uv(home, bin_dir)
        return cls(root, home, bin_dir, Manifest(home / "manifest.json"), Path(uv_path) if uv_path else Path("uv"))

    def client_dsn(self) -> str:
        """runtime.dsn as every kit-built pyexasol connection uses it: host/<fingerprint>:port once the kit has
        recorded the database's TLS pin (runtime.tls_fingerprint, audit SEC-14), unchanged before. The pin is
        setup/lib/tls_pin.py's, the one implementation the shells use too."""
        dsn = str(self.manifest.get("runtime.dsn") or "")
        recorded = str(self.manifest.get("runtime.tls_fingerprint") or "").strip()
        if not dsn or not recorded:
            return dsn
        import importlib.util
        path = self.root / "setup" / "lib" / "tls_pin.py"
        spec = importlib.util.spec_from_file_location("exakit_tls_pin", path)
        if spec is None or spec.loader is None or not path.is_file():
            raise AddonFailure(f"The kit copy has no {path}; repair it with: exakit update")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        fingerprint = module.normalize(recorded)
        return module.pinned_dsn(dsn, fingerprint) if fingerprint else dsn

    def require_uv(self) -> Path:
        if self.uv.is_file() or shutil.which(str(self.uv)):
            return self.uv
        raise AddonFailure("uv is missing; the kit's Python bootstrap must finish first")

    @property
    def managed_python_version(self) -> str:
        return managed_python_version()

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
        path = self.versions_path()
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise AddonFailure(f"Cannot read the selected versions document: {path}") from error
        if not isinstance(document, dict) or not isinstance(document.get("components"), dict):
            raise AddonFailure(f"Invalid versions document: {path}")
        # A published manifest can predate an add-on this kit ships (the notebook's frontend pins, the
        # UDF containers). Those blocks come from the kit's own versions.json; an advertised block wins.
        bundled_path = self.root / "versions.json"
        if path != bundled_path:
            try:
                bundled = json.loads(bundled_path.read_text(encoding="utf-8")).get("components", {})
            except (OSError, ValueError, AttributeError):
                bundled = {}
            if isinstance(bundled, dict):
                for name, block in bundled.items():
                    document["components"].setdefault(name, block)
        return document

    def versions_path(self) -> Path:
        selected = os.environ.get("EXAKIT_MARKETPLACE_VERSIONS_DOC")
        return Path(selected) if selected else self.root / "versions.json"

    def versions_document(self) -> dict:
        return self._versions_document

    @cached_property
    def _pinned_document(self) -> dict:
        try:
            document = json.loads((self.root / "versions.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {"components": {}}
        return document if isinstance(document, dict) and isinstance(document.get("components"), dict) \
            else {"components": {}}

    def pinned_document(self) -> dict:
        """This kit copy's own versions.json: where a SHA-256 a download is verified against comes from (SEC-13).
        versions_document() may be the copy fetched from the main branch, which says what is newest but is not a
        trust anchor; the kit copy came from a release (exakit update installs the announced tag) and carries the
        digests that release was reviewed with. A newer version advertised only remotely gets no digest from here."""
        return self._pinned_document

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
            latest = _latest_published(block)
            if latest:
                return latest
        return pinned or default

    def run_logged(self, label: str, *argv: str, env: dict[str, str] | None = None,
                   cwd: Path | None = None, timeout: int | None = None) -> None:
        log_dir = self.home / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        log_path = log_dir / "marketplace.log"
        self.activity(label)
        values = os.environ if env is None else env
        secrets = sorted({value for name, value in values.items() if value and
                          name.upper().endswith(("PASSWORD", "TOKEN", "_KEY", "SECRET"))},
                         key=len, reverse=True)
        with log_path.open("a", encoding="utf-8") as log:
            log_path.chmod(0o600)
            log.write(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {label}\n")
            log.flush()
            # Filter private child diagnostics before appending them to the log.
            with tempfile.TemporaryFile() as output:
                try:
                    result = subprocess.run(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                            stdout=output, stderr=output, check=False, timeout=timeout)
                except (OSError, subprocess.TimeoutExpired) as error:
                    raise AddonFailure(f"{label} did not finish; see exakit logs setup") from error
                finally:
                    output.seek(0)
                    for line in output:
                        text = line.decode("utf-8", errors="replace")
                        for secret in secrets:
                            text = text.replace(secret, "[redacted]")
                        log.write(text)
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


# How long a freshly installed package may take to answer its first import. The first import after `uv pip
# install` compiles every .pyc, and macOS checks each new native library the first time it loads, so on a slow
# disk or a busy machine the dash-server import took longer than the ten seconds the install allowed and the
# whole add-on step ended with "Command ... timed out" (seen on a real install). Two minutes, and a probe that
# still does not answer is "not answered", never the end of the install.
FIRST_IMPORT_TIMEOUT = 120


def probe(argv: list[str], *, timeout: float = FIRST_IMPORT_TIMEOUT) -> subprocess.CompletedProcess | None:
    """Ask a short question of a program (an import, a --version) and answer None when it could not be asked or
    did not answer within `timeout` seconds: the caller treats that as "not answered" and says so, instead of
    letting a TimeoutExpired end the install."""
    try:
        return subprocess.run(argv, capture_output=True, text=True, check=False, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None


def venv_python(venv: Path) -> Path:
    return venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def venv_executable(venv: Path, name: str) -> Path:
    return venv / (f"Scripts/{name}.exe" if os.name == "nt" else f"bin/{name}")


def cmd_quote(item: object) -> str:
    """One argument for a .cmd file: always quoted, so & ^ | < > in a path stay text, and % doubled, because cmd
    expands %NAME% inside quotes too. Quotes inside an argument are doubled for the C runtime's parser."""
    return '"' + str(item).replace('"', '""').replace("%", "%%") + '"'
