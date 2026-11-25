"""Cross-platform services used only after the kit reaches its marketplace.

Install and update operations do not depend on a system Python package. The
existing uv bootstrap supplies the interpreter; this module stays stdlib-only.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from dataclasses import dataclass
from functools import cached_property, lru_cache
from pathlib import Path
from typing import Iterator, Mapping

import kit_telemetry

# Every marketplace command imports this module first, before anything it
# starts can load pyexasol: Exasol's usage telemetry stays off for this
# process and all of its children unless the user set the variable already.
kit_telemetry.default_off()

# A Python child whose output goes to a pipe or a file writes it in the locale's code page: cp1252 on Windows,
# where the first character outside it (the Semantic Views installer's U+2500 rule) ended the install in
# UnicodeEncodeError. Every child this process starts writes UTF-8, the encoding the kit reads it back in
# (_redacted). Forced, not defaulted. The shell entry points export the same pair (common.sh, exakit-common.ps1).
UTF8_CHILD = {"PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8"}


def utf8_child(environment: dict[str, str] | None = None) -> dict[str, str]:
    """``environment`` (this process's when None) with the pair that makes a Python child write UTF-8."""
    return {**(os.environ if environment is None else environment), **UTF8_CHILD}


os.environ.update(UTF8_CHILD)

# uv verifies TLS against its own bundled roots unless told otherwise, so behind a proxy that re-signs TLS (Zscaler,
# Fortinet and similar, with the company's root CA in the system store) every uv download failed with "invalid peer
# certificate" (WPS-01). Every uv this process starts - the add-ons' environments, the marketplace UI - trusts the
# system store, which holds the public roots too. A value the user set, or the older UV_NATIVE_TLS, is left alone.
# The shell entry points do the same (exakit_uv_system_certs in common.sh, Set-ExakitUvSystemCerts in
# exakit-common.ps1).
def uv_system_certs(environment: dict[str, str] | None = None) -> Mapping[str, str]:
    """``environment`` (this process's when None) with UV_SYSTEM_CERTS=1 unless either uv switch is already set."""
    target = os.environ if environment is None else environment
    if not target.get("UV_SYSTEM_CERTS") and not target.get("UV_NATIVE_TLS"):
        target["UV_SYSTEM_CERTS"] = "1"
    return target


uv_system_certs()


class AddonFailure(RuntimeError):
    pass


# A full `exakit uninstall` over a database the user let the kit use (owner user) keeps everything inside it: the
# shells set this while the add-ons are removed (exakit_uninstall_run, Invoke-ExakitUninstallRun), and each add-on's
# removal then takes only its files, services and settings on this computer. The one change made inside that
# database is the kit's own logins and roles going (marketplace/kit_logins.py, run before the add-ons).
KEEP_DATABASE = "EXAKIT_UNINSTALL_KEEP_DATABASE"


def uninstall_keeps_database() -> bool:
    """An add-on's removal leaves the database alone: a full uninstall keeps it (one the user let the kit use)."""
    return os.environ.get(KEEP_DATABASE) == "1"


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


def _keychain_roots() -> str:
    """PEM of the certificates in the macOS keychains that the system trusts for TLS; "" when none can be read.

    A company's inspection root (Zscaler, Fortinet) is installed into the System keychain. A Python that uv
    installed reads only /etc/ssl/cert.pem, the public roots, so its downloads failed behind such a proxy while
    curl, which asks the keychain, worked (WPS-01). Only certificates `security verify-cert` accepts as trusted
    roots are taken: a keychain also holds device identities nothing should trust.
    """
    try:
        listed = subprocess.run(["/usr/bin/security", "find-certificate", "-a", "-p"], capture_output=True,
                                text=True, timeout=20, check=False).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""
    trusted = []
    for pem in re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", listed, re.S):
        try:
            verdict = subprocess.run(["/usr/bin/security", "verify-cert", "-l", "-L", "-R", "offline", "-p", "ssl",
                                      "-c", "/dev/stdin"], input=pem, capture_output=True, text=True, timeout=10,
                                     check=False)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if verdict.returncode == 0:
            trusted.append(pem)
    return "\n".join(trusted)


@lru_cache(maxsize=1)
def keychain_tls_context():
    """The default TLS context plus the keychain's trusted roots; asked once per process, only when needed."""
    import ssl

    context = ssl.create_default_context()
    roots = _keychain_roots()
    if roots:
        with contextlib.suppress(ssl.SSLError, ValueError):
            context.load_verify_locations(cadata=roots)
    return context


class SystemTrustHTTPSHandler(urllib.request.HTTPSHandler):
    """HTTPS that also trusts the macOS keychain: a certificate the default store refuses is asked again with the
    keychain's trusted roots added. Elsewhere Python already reads the system store (Windows' through
    load_default_certs, Linux's bundle), and nothing changes."""

    def https_open(self, req):
        import http.client
        import ssl
        import urllib.error

        try:
            return super().https_open(req)
        except urllib.error.URLError as error:
            if sys.platform != "darwin" or not isinstance(error.reason, ssl.SSLCertVerificationError):
                raise
            return self.do_open(http.client.HTTPSConnection, req, context=keychain_tls_context())


# Every urllib.request.urlopen in the marketplace and its add-ons goes through it.
urllib.request.install_opener(urllib.request.build_opener(SystemTrustHTTPSHandler))


def open_url(request, timeout: float):
    """urllib.request.urlopen with SameHostAuthRedirect and SystemTrustHTTPSHandler."""
    return urllib.request.build_opener(SameHostAuthRedirect, SystemTrustHTTPSHandler).open(request, timeout=timeout)


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


def host_glibc() -> tuple[int, int] | None:
    """The GNU C library this process runs on, as (2, 35); None for musl, or when its version cannot be read.

    os.confstr asks the loaded C library itself. platform.libc_ver() asks the same first, but where that fails it
    falls back to scanning the Python binary for the glibc symbols IT references - the oldest glibc that Python
    needs, not the one the system has - so it is not used as a fallback here.
    """
    try:
        text = os.confstr("CS_GNU_LIBC_VERSION") or ""
    except (AttributeError, ValueError, OSError):
        return None
    match = re.fullmatch(r"glibc\s+(\d+)\.(\d+)(?:\.\d+)*", text.strip())
    return (int(match.group(1)), int(match.group(2))) if match else None


def glibc_floor_reason(document: dict, component: str, platform_key: str) -> str:
    """Why the pinned Linux binary of `component` for `platform_key` cannot run here, or "" when it can.

    The add-on binaries are dynamically linked against glibc, and the loader refuses one that references a newer
    symbol version than the system has ("version `GLIBC_2.38' not found"). The floor each pinned asset needs sits
    beside its digest in versions.json, components.<component>.glibc.<platform key>, measured from the asset's ELF
    version references (`objdump -p <binary>`, the highest GLIBC_x.y it lists). No floor recorded: nothing to check.
    """
    block = document.get("components", {}).get(component, {})
    floors = block.get("glibc") if isinstance(block, dict) else None
    floor = floors.get(platform_key) if isinstance(floors, dict) else None
    match = re.fullmatch(r"(\d+)\.(\d+)", floor) if isinstance(floor, str) else None
    if not match:
        return ""
    have = host_glibc()
    if have is None:
        return f"needs glibc {floor} or newer, and this system's C library is not glibc or its version cannot be read"
    if have < (int(match.group(1)), int(match.group(2))):
        return f"needs glibc {floor} or newer (this system has {have[0]}.{have[1]})"
    return ""


# The kit's database is this named deployment: the folder <root>/deployments/starter-kit-local in the launcher's
# home. Never `default`, which is the user's. Twin of EXAKIT_PERSONAL_DEPLOYMENT (runtime-personal.sh) and
# $script:PersonalDeploymentName (PowerShell).
KIT_DEPLOYMENT = "starter-kit-local"


def personal_launcher_home(environ: Mapping[str, str] | None = None, launcher_home: object = None) -> str:
    """The home the kit's Exasol Personal launcher runs with (macOS and Linux).

    The recorded one (runtime.launcher_home) when given, else EXAKIT_PERSONAL_LAUNCHER_HOME, else the kit's private
    home when its own launcher's binary is in $EXAKIT_HOME/personal/libexec (mode P: next to an Exasol Personal of the
    user's that the kit never touches), else HOME. $EXAKIT_HOME/personal/bin/exasol is no marker: every mode has a
    launcher there. The launcher has no flag for its root, only HOME,
    so every folder of it is derived from this. Twin of detect_personal_deploy_roots (detect.sh).
    """
    env = os.environ if environ is None else environ
    if launcher_home:
        return str(launcher_home)
    if env.get("EXAKIT_PERSONAL_LAUNCHER_HOME"):
        return str(env["EXAKIT_PERSONAL_LAUNCHER_HOME"])
    home = env.get("HOME") or str(Path.home())
    kit_home = env.get("EXAKIT_HOME") or str(Path(home, ".exasol-starter-kit"))
    binary = Path(kit_home, "personal", "libexec", "exasol")
    if os.name != "nt" and binary.is_file() and os.access(binary, os.X_OK):
        return str(Path(kit_home, "personal", "home"))
    return home


def personal_deploy_roots(environ: Mapping[str, str] | None = None,
                          launcher_home: object = None) -> tuple[Path | None, Path]:
    """The Exasol Personal launcher's two deployment roots: (2.5.0+, before 2.5.0).

    2.5.0 keeps its deployments in ~/.exasol/launcher/deployments (%LOCALAPPDATA%\\exasol\\launcher\\... on Windows,
    None there without LOCALAPPDATA, where the launcher cannot run either) and moves the ones earlier launchers left
    in ~/.exasol/personal/deployments (%USERPROFILE% on Windows) there by itself. ~ is the launcher's home
    (personal_launcher_home).
    """
    env = os.environ if environ is None else environ
    if os.name == "nt":
        local = env.get("LOCALAPPDATA")
        profile = env.get("USERPROFILE") or str(Path.home())
        return (Path(local, "exasol", "launcher", "deployments") if local else None,
                Path(profile, ".exasol", "personal", "deployments"))
    home = personal_launcher_home(env, launcher_home)
    return Path(home, ".exasol", "launcher", "deployments"), Path(home, ".exasol", "personal", "deployments")


def personal_deploy_defaults(environ: Mapping[str, str] | None = None,
                             launcher_home: object = None) -> tuple[Path | None, Path]:
    """The kit's own deployment, starter-kit-local, in the launcher's two roots: (2.5.0+, before 2.5.0).

    Twin of detect_personal_deploy_resolve (detect.sh) and Resolve-PersonalDeployDir (exakit-common.ps1).
    """
    new_root, legacy_root = personal_deploy_roots(environ, launcher_home)
    return (new_root / KIT_DEPLOYMENT if new_root is not None else None), legacy_root / KIT_DEPLOYMENT


def _personal_folder_deployment_id(folder: Path) -> str:
    """The launcher's deploymentId for the deployment in ``folder``, or "".

    The launcher's own state first (.exasolLauncherState.json): deployment.json can be older than it, or say
    "local", what the launcher writes there when it cannot read its state. Read as JSON, the top-level key only;
    empty, blank and "local" are no id. Twin of detect_personal_deployment_id (detect.sh) and
    Read-PersonalDeploymentId (exakit-common.ps1).
    """
    for name in (".exasolLauncherState.json", "deployment.json"):
        try:
            doc = json.loads((folder / name).read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        value = doc.get("deploymentId") if isinstance(doc, dict) else None
        if isinstance(value, str) and value.strip() and value.strip() != "local":
            return value.strip()
    return ""


def personal_launcher_deployments(environ: Mapping[str, str] | None = None,
                                  launcher: object = None) -> list[tuple[Path, str]] | None:
    """The launcher's own deployments as (folder, status), in its order (by name), or None when it gives no answer.

    `exasol deployments list --json` (launcher 2.5.0 and later), bounded by a short timeout
    (EXAKIT_PERSONAL_LIST_TIMEOUT, 6 s). The launcher is the one the kit recorded (runtime.launcher, the wrapper in
    mode P, which sets its own home), else the kit's wrapper, else its own (EXAKIT_BIN_DIR/exasol), else the one on
    PATH, as the shells' personal_cli picks it. None for a launcher without the command (2.4.x), one that fails,
    hangs or prints anything but that list: the caller then keeps the folders the kit knows
    (personal_deploy_defaults). No deployment is put first: the kit's own is found by its name or its id, never by
    its place here. Twin of personal_launcher_deployments (runtime-personal.sh) and
    Get-PersonalLauncherDeployments (runtime-personal.ps1).
    """
    env = os.environ if environ is None else environ
    home = env.get("USERPROFILE" if os.name == "nt" else "HOME") or str(Path.home())
    bin_dir = Path(env.get("EXAKIT_BIN_DIR") or str(Path(home, ".local", "bin"))).expanduser()
    kit_home = env.get("EXAKIT_HOME") or str(Path(home, ".exasol-starter-kit"))
    candidates = [Path(str(launcher))] if launcher else []
    if os.name != "nt":
        candidates.append(Path(kit_home, "personal", "bin", "exasol"))
    candidates.append(bin_dir / ("exasol.exe" if os.name == "nt" else "exasol"))
    chosen = next((path for path in candidates if path.is_file()), None)
    if chosen is None:
        found = shutil.which("exasol", path=env["PATH"]) if env.get("PATH") else None
        if not found:
            return None
        chosen = Path(found)
    launcher = chosen
    try:
        timeout = int(env.get("EXAKIT_PERSONAL_LIST_TIMEOUT") or 6)
    except ValueError:
        timeout = 6
    try:
        done = subprocess.run([str(launcher), "deployments", "list", "--json"], capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=timeout, env=dict(env), check=False)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    if done.returncode != 0:
        return None
    # A JSON array, from the first line that opens one (a launcher notice may come before it).
    lines = (done.stdout or "").splitlines()
    doc = None
    for at, line in enumerate(lines):
        if not line.lstrip().startswith("["):
            continue
        try:
            doc = json.JSONDecoder().raw_decode("\n".join(lines[at:]).lstrip())[0]
            break
        except ValueError:
            continue
    if not isinstance(doc, list):
        return None
    rows: list[tuple[Path, str]] = []
    for item in doc:
        if not isinstance(item, dict):
            return None
        path, status = item.get("path"), item.get("status")
        if not isinstance(path, str) or not path or not Path(path).is_absolute():
            continue
        rows.append((Path(path), status if isinstance(status, str) else ""))
    return rows


def id_text(value: object) -> str:
    """A recorded deployment id, or "" for one that is not text: a number, or the Infinity an id like 3e082473 became
    in a record an earlier build wrote, is no id, never another one. The shell's manifest_get answers the same."""
    return value.strip() if isinstance(value, str) else ""


def personal_deployment_dir(recorded: object, environ: Mapping[str, str] | None = None,
                            deployment_id: object = None, ownership: object = None,
                            launcher_home: object = None, launcher: object = None) -> Path | None:
    """The folder a recorded runtime.deployment_dir is in now, or None when it is nowhere.

    A recorded folder still on disk, or one the user chose, is itself (the launcher is not asked). One of the
    launcher's folders that is gone may have been moved by the launcher: launcher 2.5.0 moves the 2.4 one, and a
    launcher may keep its deployments elsewhere. One of the launcher's folders is any folder in its two roots
    (personal_deploy_roots, in its home: ``launcher_home``, runtime.launcher_home), whatever its name (a 0.3.0
    kit's `default`, or starter-kit-local), or one it lists. The candidates are the ones the launcher lists
    (personal_launcher_deployments, asked of ``launcher``, runtime.launcher), or the kit's own name in the two
    roots when it gives no answer, and the recorded name in either root. It is followed ONLY to the one whose
    deployment carries ``deployment_id``, the id the kit recorded (runtime.deployment_id). With no id, or no folder
    with that id, that deployment is the user's own and the answer is None: the kit never takes it for its own.
    Twin of detect_personal_deploy_resolve "recorded" and Resolve-PersonalDeployDir -Recorded.

    A recorded folder still on disk that holds a deployment with ANOTHER id than ``deployment_id`` is not the
    kit's either (its own destroyed, the user's made in the same place: MCU-02), and is None too, unless the user
    adopted it (``ownership`` "user", the installer's one question). The rule of exakit_personal_db_state.
    """
    raw = str(recorded or "")
    if not raw:
        return None
    if Path(raw).exists():
        if not Path(raw).is_dir():
            return None
        want = id_text(deployment_id)
        if want and str(ownership or "") != "user":
            has = _personal_folder_deployment_id(Path(raw))
            if has and has != want:
                return None
        return Path(raw)
    new_root, legacy_root = personal_deploy_roots(environ, launcher_home)
    new, legacy = personal_deploy_defaults(environ, launcher_home)
    same = (lambda a, b: a.lower() == b.lower()) if os.name == "nt" else (lambda a, b: a == b)
    roots = [root for root in (new_root, legacy_root) if root is not None]
    in_root = any(same(str(Path(raw).parent), str(root)) for root in roots)
    want = id_text(deployment_id)
    if not want:
        return None
    listed = personal_launcher_deployments(environ, launcher)
    listed_folders = [path for path, _ in listed] if listed is not None else []
    if not in_root and not any(same(raw, str(folder)) for folder in listed_folders):
        return None
    folders = listed_folders if listed is not None else [home for home in (new, legacy) if home]
    folders = folders + [root / Path(raw).name for root in roots]
    seen: list[str] = []
    for folder in folders:
        if any(same(str(folder), done) for done in seen):
            continue
        seen.append(str(folder))
        if not same(raw, str(folder)) and folder.is_dir() and _personal_folder_deployment_id(folder) == want:
            return folder
    return None


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
_activity_lock = threading.Lock()      # several workers write the table's side channel at the same time


def _activity_records(path: Path, row: str, text: str | None) -> None:
    """Replace ``row``'s "row|text" record in the side channel (``text`` None: remove it), keeping every other row's:
    one record per add-on, several installing side by side. Written whole, then moved in, so the table animator never
    reads half a file."""
    with _activity_lock:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            lines = []
        lines = [line for line in lines if line and not line.startswith(f"{row}|")]
        if text is not None:
            lines.append(f"{row}|{text}")
        fd, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as out:
                out.write("".join(f"{line}\n" for line in lines))
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)


@contextlib.contextmanager
def activity_sink(callback):
    """Route one worker thread's activity to a Textual progress screen."""
    previous = getattr(_activity_local, "callback", None)
    _activity_local.callback = callback
    try:
        yield
    finally:
        _activity_local.callback = previous


def current_activity_sink():
    """The activity callback this thread routes to, or None when it shows activity itself."""
    return getattr(_activity_local, "callback", None)


@contextlib.contextmanager
def log_sink(callback):
    """Route one worker thread's marketplace.log records to ``callback``, one complete record per call (the
    header line and everything the command printed together), instead of appending them to the file. An add-on
    installed beside others holds its records this way until its turn, so the log reads add-on by add-on."""
    previous = getattr(_activity_local, "log", None)
    _activity_local.log = callback
    try:
        yield
    finally:
        _activity_local.log = previous


_LOG_LOCK = threading.Lock()


def append_log(home: Path, text: str) -> None:
    """Append complete records to marketplace.log; one writer at a time, so records never interleave."""
    log_dir = home / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / "marketplace.log"
    with _LOG_LOCK, log_path.open("a", encoding="utf-8") as log:
        log_path.chmod(0o600)
        log.write(text)


def _stamp() -> str:
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


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


# Add-on receipts written before the kit recorded ownership. Kit 0.2.5 and earlier wrote components.<add-on> with its
# version, venv, python and command and no ownership key, and the add-on modules act only on ownership == "kit": after
# an update to this kit the add-ons the kit itself installed could no longer be updated or removed (audit UPG-01). The
# shells read such a receipt as the kit's when a private environment it names lies under the kit home
# (exakit_component_ownership in setup/lib/common.sh, Get-ExakitComponentOwnership in setup/lib/exakit-common.ps1).
# Every read here applies that same rule and every write records the answer (ownership=kit), so the shells and the
# add-on modules agree, and the receipt says it itself from the first write on.
# The Scheduler's 0.2.5 receipt names only its engine under the kit home (version, engine, db_user, schema), hence
# "engine". The VS Code extension's names nothing under the kit home (version, extension_id, code_cli): that exact
# shape with no ownership key was only ever written by the kit, so it is adopted by its shape (audit STA-01).
_LEGACY_OWNED_FIELDS = ("venv", "home", "python", "path", "engine")
_LEGACY_OWNED_SHAPE = ("version", "extension_id", "code_cli")


@lru_cache(maxsize=1)
def _addon_receipts() -> frozenset[str]:
    """components.<name> of every add-on in the catalog beside this module: the receipts the legacy rule covers."""
    try:
        catalog = json.loads(Path(__file__).with_name("catalog.json").read_text(encoding="utf-8"))
        return frozenset(str(row["id"]).replace("-", "_") for row in catalog["addons"])
    except (OSError, ValueError, KeyError, TypeError):
        return frozenset()


def _adopt_legacy_receipts(doc: object, home: Path) -> None:
    """Mark ownership=kit on each add-on receipt that has no ownership and names a venv, home, python, path or engine
    under the kit home, or has the 0.2.5 VS Code extension's shape (a shared binary or a user's tool is never owned by
    inference)."""
    components = doc.get("components") if isinstance(doc, dict) else None
    if not isinstance(components, dict):
        return
    prefix = os.path.normcase(str(home)) + os.sep
    for name in _addon_receipts():
        block = components.get(name)
        if not isinstance(block, dict) or block.get("ownership"):
            continue
        if any(isinstance(block.get(field), str) and os.path.normcase(block[field]).startswith(prefix)
               for field in _LEGACY_OWNED_FIELDS) or \
                all(isinstance(block.get(field), str) and block[field] for field in _LEGACY_OWNED_SHAPE):
            block["ownership"] = "kit"


def made_in_this_database(doc_get, receipt: str) -> bool:
    """Whether what ``receipt`` says the kit created was created in the database the kit uses now.

    ``<receipt>.made_in`` is the deployment id (runtime.deployment_id) it was created in. Another id, or no id of the
    database in use to compare it with, is another database: what is there under the same name is not the kit's. No
    made_in (0.3.0, or a database without an id) is the database the kit recorded: one it changed from since has it
    written then (personal_stamp_made_in, Set-PersonalMadeIn).
    """
    made = doc_get(f"{receipt}.made_in")
    current = id_text(doc_get("runtime.deployment_id"))
    if made is not None and not isinstance(made, (str, bool)):
        # A number an id became (id_text): the id in use now, when it reads as that number, else another database's.
        try:
            return json.loads(current) == made
        except ValueError:
            return False
    made = id_text(made)
    return not made or made == current


class Manifest:
    """Atomic receipt writes using the kit's existing manifest.json.lock file."""

    def __init__(self, path: Path):
        self.path = path

    # Add-ons installed side by side share one Manifest. The file lock keeps other processes out; this keeps
    # this process's threads to one read-modify-write at a time, whatever the platform's lock does within a process.
    _threads = threading.RLock()

    def _load(self) -> dict:
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError as error:
            raise AddonFailure("No starter kit installation is recorded") from error

    def read(self) -> dict:
        doc = self._load()
        _adopt_legacy_receipts(doc, self.path.parent)
        return doc

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
    def locked(self) -> Iterator[None]:
        """Hold the manifest's lock, the one every kit writer takes (the shells' manifest_set included), without
        reading or writing the file. Also for a child process that rewrites manifest.json itself without taking the
        lock (the MCP subsystem records its client entries there): run under this, no other writer's update is lost
        to its read-modify-write. Never call edit() inside it."""
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
        with Manifest._threads, lock:
            _lock_file(lock)
            try:
                yield
            finally:
                _unlock_file(lock)

    @contextlib.contextmanager
    def edit(self) -> Iterator[dict]:
        with self.locked():
            doc = self._load()
            before = json.dumps(doc, sort_keys=True, separators=(",", ":"))
            _adopt_legacy_receipts(doc, self.path.parent)       # written with whatever this edit changes
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

    def adopt_legacy_receipts(self) -> None:
        """Write the ownership read() infers for an add-on receipt from before ownership was recorded; a no-op when
        there is none."""
        with self.edit():
            pass

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
        # A published manifest can predate an add-on this kit ships. Those blocks come from the kit's own versions.json; an advertised block wins.
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
        trust anchor. The kit copy carries the digests its ref was reviewed with; it is itself verified only when the
        installer was given EXAKIT_KIT_SHA256 (an install from a branch, `main` by default, is not), so it anchors the
        components exactly as far as that copy can be trusted. A newer version advertised only remotely gets no
        digest from here."""
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
        env = dict(uv_system_certs(utf8_child(env)))
        values = env
        secrets = sorted({value for name, value in values.items() if value and
                          name.upper().endswith(("PASSWORD", "TOKEN", "_KEY", "SECRET"))},
                         key=len, reverse=True)
        sink = getattr(_activity_local, "log", None)
        if sink is not None:
            # Held for its turn (log_sink): the header and the output go as one record once the command ended.
            header = f"[{_stamp()}] {label}\n"
            with tempfile.TemporaryFile() as output:
                try:
                    result = subprocess.run(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                            stdout=output, stderr=output, check=False, timeout=timeout)
                except (OSError, subprocess.TimeoutExpired) as error:
                    raise AddonFailure(f"{label} did not finish; see exakit logs setup") from error
                finally:
                    output.seek(0)
                    sink(header + "".join(_redacted(output, secrets)))
        else:
            with log_path.open("a", encoding="utf-8") as log:
                log_path.chmod(0o600)
                log.write(f"[{_stamp()}] {label}\n")
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
                        for text in _redacted(output, secrets):
                            log.write(text)
        if result.returncode != 0:
            raise AddonFailure(f"{label} failed (exit {result.returncode}); see exakit logs setup")

    def log_event(self, message: str) -> None:
        safe = message.replace("\r", " ").replace("\n", " ")
        record = f"[{_stamp()}] {safe}\n"
        sink = getattr(_activity_local, "log", None)
        if sink is not None:
            sink(record)
        else:
            append_log(self.home, record)

    def activity(self, label: str) -> None:
        callback = getattr(_activity_local, "callback", None)
        if callback is not None:
            callback(label)
            return
        self.show_activity(label)

    def show_activity(self, label: str, row: str | None = None) -> None:
        """Show one activity line the way the platform asked: the progress table's side channel, else stdout.
        ``row``: the table row it belongs to (an add-on installing beside others); else the current one."""
        activity_file = os.environ.get("EXAKIT_MARKETPLACE_ACTIVITY_FILE")
        if row is None:
            row = os.environ.get("EXAKIT_MARKETPLACE_ACTIVITY_ROW", "")
        if activity_file and row.isdecimal() and int(row) > 0:
            # The platform table already owns stdout. Its animator reads this
            # side channel and draws each add-on's current operation above its bar.
            safe = label.replace("\r", " ").replace("\n", " ").replace("|", " ")
            _activity_records(Path(activity_file), row, safe)
            return
        print(f"  • {label}", flush=True)

    def clear_activity(self, row: str) -> None:
        """The add-on on ``row`` is done: its activity line goes."""
        activity_file = os.environ.get("EXAKIT_MARKETPLACE_ACTIVITY_FILE")
        if activity_file and row.isdecimal() and int(row) > 0 and Path(activity_file).exists():
            _activity_records(Path(activity_file), row, None)


def _redacted(output, secrets: list[str]) -> Iterator[str]:
    """A child's output, line by line, with every secret it could have echoed replaced."""
    for line in output:
        text = line.decode("utf-8", errors="replace")
        for secret in secrets:
            text = text.replace(secret, "[redacted]")
        yield text


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


def cmd_file_bytes(text: str) -> bytes:
    """The bytes of a .cmd file cmd.exe reads as written (audit WIN-02): the user's profile folded into %USERPROFILE%
    (cmd expands it at run time, so the bytes stay ASCII for any user name) and the rest in the console's OEM code
    page, the one cmd.exe reads a batch file in. UTF-8 and strict ASCII both broke a non-ASCII path. A path the OEM
    code page cannot spell is refused by name rather than written wrong."""
    profile = os.environ.get("USERPROFILE", "").rstrip("\\")
    if profile:
        text = re.sub(re.escape(profile + "\\"), lambda _m: "%USERPROFILE%\\", text, flags=re.IGNORECASE)
    encoding = "ascii"
    if os.name == "nt":
        try:
            import ctypes
            encoding = f"cp{ctypes.windll.kernel32.GetOEMCP()}"
        except ImportError:
            pass                                          # a non-Windows Python told it is "nt" (tests): ASCII
        except (AttributeError, OSError):
            encoding = "mbcs"
    try:
        return text.encode(encoding)
    except (UnicodeEncodeError, LookupError) as error:
        raise AddonFailure("A path in this launcher cannot be written for cmd.exe in this console's code page; "
                           "install the kit under a folder whose name uses plain letters") from error


def venv_python(venv: Path) -> Path:
    return venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def venv_executable(venv: Path, name: str) -> Path:
    return venv / (f"Scripts/{name}.exe" if os.name == "nt" else f"bin/{name}")


def cmd_quote(item: object) -> str:
    """One argument for a .cmd file: always quoted, so & ^ | < > in a path stay text, and % doubled, because cmd
    expands %NAME% inside quotes too. Quotes inside an argument are doubled for the C runtime's parser."""
    return '"' + str(item).replace('"', '""').replace("%", "%%") + '"'
