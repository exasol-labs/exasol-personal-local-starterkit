"""Verified Exasol Scheduler install with a dedicated, least privilege user."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path

from process import ManagedProcess, _command, _creation
from runtime import AddonFailure, KitContext, venv_python

ID = "exasol-scheduler"
RECEIPT = "components.exasol_scheduler"
REPO = "exasol-labs/exasol-scheduler"
HEX = re.compile(r"^[0-9a-f]{64}$")
IDENT = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")


def paths(ctx: KitContext) -> tuple[Path, Path, Path, Path, Path]:
    recorded_engine = ctx.manifest.get(f"{RECEIPT}.engine") if ctx.manifest.get(f"{RECEIPT}.ownership") == "kit" else None
    home = Path(recorded_engine).parent.parent if recorded_engine else ctx.path("EXAKIT_EXASOL_SCHEDULER_HOME", ctx.home / "exasol-scheduler")
    launcher = ctx.owned_path(RECEIPT, "command", "EXAKIT_EXASOL_SCHEDULER_BIN", ctx.bin_dir /
                        ("exasol-scheduler.cmd" if os.name == "nt" else "exasol-scheduler"))
    engine = home / "libexec" / ("exasol_scheduler.exe" if os.name == "nt" else "exasol_scheduler")
    log = ctx.path("EXAKIT_EXASOL_SCHEDULER_LOG", ctx.home / "logs" / "exasol-scheduler.log")
    credential = ctx.home / "credentials" / "exasol_scheduler_password"
    return home, launcher, engine, log, credential


def _platform() -> str | None:
    system = platform.system().lower()
    arch = platform.machine().lower()
    if system == "darwin":
        system = "macos"
    elif system == "windows":
        system = "windows"
    elif system == "linux":
        system = "linux"
    else:
        return None
    if arch in ("aarch64", "arm64"):
        arch = "arm64"
    elif arch in ("x86_64", "amd64"):
        arch = "x86_64"
    else:
        return None
    if system == "windows" and arch != "x86_64":
        return None
    return f"{system}-{arch}"


def applicable(ctx: KitContext) -> bool:
    return _platform() is not None


def applicable_reason(ctx: KitContext) -> str:
    return f"no prebuilt scheduler binary is published for {platform.system()}/{platform.machine()}"


def installed_version(ctx: KitContext) -> str | None:
    engine = paths(ctx)[2]
    version = ctx.manifest.get(f"{RECEIPT}.version")
    return str(version).removeprefix("v") if engine.is_file() and version else None


def system_present(ctx: KitContext) -> bool:
    found = shutil.which("exasol_scheduler") or shutil.which("exasol_scheduler.exe")
    return bool(found and Path(found).resolve() != paths(ctx)[2].resolve())


def _version(ctx: KitContext) -> str:
    from model import load_addons

    fallback = next(row.default_version for row in load_addons(ctx.root) if row.id == ID)
    return ctx.target_version(ID, fallback).removeprefix("v")


def _asset(ctx: KitContext, version: str) -> tuple[str, str, str]:
    token = _platform()
    if not token:
        raise AddonFailure(applicable_reason(ctx))
    tag = os.environ.get("EXAKIT_EXASOL_SCHEDULER_RELEASE_TAG") or f"v{version}"
    if not re.fullmatch(r"v?[0-9A-Za-z._+-]+", tag):
        raise AddonFailure("invalid scheduler release tag")
    name = f"exasol_scheduler-{tag}-{token}.{'zip' if os.name == 'nt' else 'tar.gz'}"
    repo = os.environ.get("EXAKIT_EXASOL_SCHEDULER_REPO", REPO)
    if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repo):
        raise AddonFailure("invalid scheduler repository")
    return repo, tag, name


def _https(url: str):
    if not url.startswith("https://"):
        raise AddonFailure("scheduler assets must use HTTPS")
    response = urllib.request.urlopen(url, timeout=60)
    if not response.url.startswith("https://"):
        response.close()
        raise AddonFailure("scheduler asset redirected away from HTTPS")
    return response


def _digest(ctx: KitContext, version: str, repo: str, tag: str, name: str) -> str | None:
    versions = ctx.versions_document()
    block = versions.get("components", {}).get(ID, {})
    if not os.environ.get("EXAKIT_EXASOL_SCHEDULER_RELEASE_TAG") and \
       version == str(block.get("version", "")).removeprefix("v"):
        pin = block.get("sha256", {}).get(_platform(), "")
        if isinstance(pin, str) and HEX.fullmatch(pin.lower()):
            return pin.lower()
    base = f"https://github.com/{repo}/releases/download/{tag}/{name}"
    try:
        with _https(base + ".sha256") as response:
            sidecar = response.read(4096).decode("ascii").split()[0].lower()
        if HEX.fullmatch(sidecar):
            return sidecar
    except (OSError, ValueError, IndexError, UnicodeError):
        pass
    try:
        with _https(f"https://api.github.com/repos/{repo}/releases/tags/{tag}") as response:
            assets = json.load(response).get("assets", [])
        for asset in assets:
            if asset.get("name") == name:
                digest = str(asset.get("digest", "")).removeprefix("sha256:").lower()
                if HEX.fullmatch(digest):
                    return digest
    except (OSError, ValueError, KeyError):
        pass
    return None


def _download(ctx: KitContext, version: str, archive: Path) -> None:
    repo, tag, name = _asset(ctx, version)
    url = f"https://github.com/{repo}/releases/download/{tag}/{name}"
    expected = _digest(ctx, version, repo, tag, name)
    if not expected and os.environ.get("EXAKIT_ALLOW_UNVERIFIED_EXASOL_SCHEDULER") != "1":
        raise AddonFailure(f"No checksum for {name}; refusing an unverified archive")
    digest = hashlib.sha256()
    try:
        with _https(url) as response, archive.open("wb") as output:
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                digest.update(chunk)
                output.write(chunk)
        if expected and digest.hexdigest() != expected:
            raise AddonFailure(f"Checksum mismatch for {name}")
    except Exception:
        archive.unlink(missing_ok=True)
        raise


def _unpack(archive: Path, destination: Path) -> None:
    if os.name == "nt":
        with zipfile.ZipFile(archive) as source:
            entries = [item for item in source.infolist() if Path(item.filename).name == "exasol_scheduler.exe"]
            if len(entries) != 1 or entries[0].file_size == 0:
                raise AddonFailure("Scheduler archive does not contain one engine binary")
            with source.open(entries[0]) as data, destination.open("wb") as output:
                shutil.copyfileobj(data, output)
    else:
        with tarfile.open(archive, "r:gz") as source:
            entries = [item for item in source if item.isfile() and Path(item.name).name == "exasol_scheduler"]
            if len(entries) != 1 or entries[0].size == 0:
                raise AddonFailure("Scheduler archive does not contain one engine binary")
            data = source.extractfile(entries[0])
            if data is None:
                raise AddonFailure("Scheduler engine could not be unpacked")
            with data, destination.open("wb") as output:
                shutil.copyfileobj(data, output)
        destination.chmod(0o755)


def _sql(ctx: KitContext, statement: str, *, secret: str = "") -> str:
    binary = ctx.manifest.get("components.exapump.path") or shutil.which("exapump") or \
        str(ctx.bin_dir / ("exapump.exe" if os.name == "nt" else "exapump"))
    if not Path(binary).is_file():
        raise AddonFailure("exapump is required to create the scheduler database user")
    profile = os.environ.get("EXAKIT_EXAPUMP_PROFILE", "starter-kit")
    result = subprocess.run([str(binary), "sql", "-p", profile], input=statement + "\n", text=True,
                            capture_output=True, check=False, timeout=30)
    output = (result.stdout + result.stderr).replace(secret, "[redacted]") if secret else result.stdout + result.stderr
    if result.returncode != 0:
        raise AddonFailure("Scheduler database operation failed; check exakit start and exakit logs setup")
    return output


def _ident(name: str) -> str:
    if not IDENT.fullmatch(name):
        raise AddonFailure("Scheduler database user/schema must be SQL identifiers")
    return name.upper()


def _schema_exists(ctx: KitContext, schema: str) -> bool:
    result = _sql(ctx, "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_SCHEMAS WHERE SCHEMA_NAME = "
                  f"'{schema}') THEN 'EXAKIT_SCHED_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHED_SCHEMA_MISSING' END AS STATUS")
    return "EXAKIT_SCHED_SCHEMA_PRESENT" in result


def _user(ctx: KitContext) -> tuple[str, str, bool]:
    user = _ident(os.environ.get("EXAKIT_EXASOL_SCHEDULER_USER", "scheduler_svc"))
    schema = _ident(os.environ.get("EXAKIT_EXASOL_SCHEDULER_SCHEMA", "SCHED"))
    credential = paths(ctx)[4]
    credential.parent.mkdir(parents=True, exist_ok=True)
    try:
        password = credential.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        password = ""
    if not re.fullmatch(r"[A-Za-z0-9]{24,128}", password):
        alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        password = "".join(secrets.choice(alphabet) for _ in range(40))
        credential.write_text(password + "\n", encoding="utf-8")
        if os.name != "nt":
            credential.chmod(0o600)
    present = "EXAKIT_SCHED_USER_PRESENT" in _sql(
        ctx, "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_USERS WHERE USER_NAME = "
        f"'{user}') THEN 'EXAKIT_SCHED_USER_PRESENT' ELSE 'EXAKIT_SCHED_USER_MISSING' END AS STATUS")
    _sql(ctx, f"{'ALTER' if present else 'CREATE'} USER {user} IDENTIFIED BY {password}", secret=password)
    _sql(ctx, f"GRANT CREATE SESSION TO {user}")
    bootstrap = not _schema_exists(ctx, schema)
    if bootstrap:
        _sql(ctx, f"GRANT CREATE SCHEMA TO {user}")
        _sql(ctx, f"GRANT CREATE TABLE TO {user}")
    return user, schema, bootstrap


def _write_launcher(ctx: KitContext) -> None:
    home, launcher, engine, _, credential = paths(ctx)
    python = venv_python(home / "python")
    script = ctx.root / "marketplace" / "scheduler_launcher.py"
    ctx.bin_dir.mkdir(parents=True, exist_ok=True)
    argv = [str(python), str(script), str(home), str(engine), str(ctx.manifest.path), str(credential)]
    if os.name == "nt":
        launcher.write_text("@echo off\r\n" + " ".join('"' + item.replace('"', '""') + '"' for item in argv)
                            + " %*\r\n", encoding="utf-8")
    else:
        launcher.write_text("#!/bin/sh\nexec " + " ".join(shlex.quote(item) for item in argv) + ' "$@"\n',
                            encoding="utf-8")
        launcher.chmod(0o755)


def install(ctx: KitContext) -> None:
    if not applicable(ctx):
        raise AddonFailure(applicable_reason(ctx))
    if ctx.manifest.get(f"{RECEIPT}.ownership") in ("user", "unknown") or \
       (not ctx.manifest.get(f"{RECEIPT}.version") and system_present(ctx)):
        raise AddonFailure("An external Scheduler is present; the kit leaves it under its owner's control")
    ctx.require_uv()
    version = _version(ctx)
    home, launcher, engine, _, _ = paths(ctx)
    current = installed_version(ctx)
    needs_engine = current != version or os.environ.get("EXAKIT_FORCE_COMPONENT_INSTALL") == "1"
    with tempfile.TemporaryDirectory(prefix="exakit-scheduler-", dir=ctx.home) as temp:
        staged = Path(temp) / engine.name
        if needs_engine:
            archive = Path(temp) / _asset(ctx, version)[2]
            _download(ctx, version, archive)
            _unpack(archive, staged)
            ctx.run_logged("Checking Scheduler engine", str(staged), "--help", timeout=15)
        python = venv_python(home / "python")
        if not python.is_file():
            ctx.run_logged("Creating Scheduler Python runtime", str(ctx.uv), "venv", "--python", ctx.managed_python_version,
                           str(home / "python"))
        if needs_engine:
            user, schema, bootstrap = _user(ctx)
        else:
            user = str(ctx.manifest.get(f"{RECEIPT}.db_user", "scheduler_svc"))
            schema = str(ctx.manifest.get(f"{RECEIPT}.schema", "SCHED"))
            bootstrap = not bool(ctx.manifest.get(f"{RECEIPT}.bootstrap_revoked", True))
        previous = Path(temp) / "previous-engine"
        if needs_engine:
            engine.parent.mkdir(parents=True, exist_ok=True)
            if engine.is_file():
                shutil.copy2(engine, previous)
            os.replace(staged, engine)
        try:
            _write_launcher(ctx)
            ctx.manifest.set_many({f"{RECEIPT}.version": version, f"{RECEIPT}.engine": str(engine),
                                   f"{RECEIPT}.command": str(launcher),
                                   f"{RECEIPT}.db_user": user.lower(), f"{RECEIPT}.schema": schema,
                                   f"{RECEIPT}.ownership": "kit",
                                   f"{RECEIPT}.bootstrap_revoked": not bootstrap})
        except Exception:
            if needs_engine:
                if previous.is_file():
                    os.replace(previous, engine)
                else:
                    engine.unlink(missing_ok=True)
            raise


def _service(ctx: KitContext) -> ManagedProcess:
    home, _, _, log, _ = paths(ctx)
    return ManagedProcess(home / "exasol-scheduler.pid", log, ctx.root / "marketplace" / "scheduler_launcher.py")


def _legacy_pids(ctx: KitContext) -> set[int]:
    """Recognize an older shell/PowerShell supervisor during the migration."""
    home, _, engine, _, _ = paths(ctx)
    found: set[int] = set()
    pidfile = home / "exasol-scheduler.pid"
    try:
        old = int(pidfile.read_text(encoding="utf-8").strip())
        if old > 0 and "exasol-scheduler" in _command(old).lower():
            found.add(old)
    except (OSError, ValueError):
        pass
    if os.name == "nt":
        args = ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                "Get-CimInstance Win32_Process -Filter \"Name='exasol_scheduler.exe'\" | "
                "Select-Object -ExpandProperty ProcessId"]
    else:
        args = ["pgrep", "-f", str(engine)]
    try:
        result = subprocess.run(args, capture_output=True, text=True, check=False, timeout=5)
        for line in result.stdout.splitlines():
            if line.strip().isdigit():
                pid = int(line.strip())
                if str(engine) in _command(pid):
                    found.add(pid)
    except (OSError, subprocess.TimeoutExpired):
        pass
    return found


def _running(ctx: KitContext) -> bool:
    return _service(ctx).recorded_pid() is not None or bool(_legacy_pids(ctx))


def status(ctx: KitContext) -> str:
    home, launcher, _, _, _ = paths(ctx)
    if not launcher.is_file() or not installed_version(ctx):
        return "not installed"
    if _running(ctx):
        return "running"
    marker = home / "gave-up"
    if marker.is_file():
        return "stopped (" + marker.read_text(encoding="utf-8").strip() + "; diagnose: exakit logs exasol-scheduler)"
    return "stopped"


def start(ctx: KitContext) -> None:
    if not installed_version(ctx):
        raise AddonFailure("Scheduler is not installed; run exakit marketplace exasol-scheduler")
    if _running(ctx):
        return
    home, _, engine, log, credential = paths(ctx)
    (home / "gave-up").unlink(missing_ok=True)
    service = _service(ctx)
    script = ctx.root / "marketplace" / "scheduler_launcher.py"
    command = [str(venv_python(home / "python")), str(script), str(home), str(engine),
               str(ctx.manifest.path), str(credential)]
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a", encoding="utf-8") as output:
        kwargs = ({"creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP}
                  if os.name == "nt" else {"start_new_session": True})
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                   close_fds=True, **kwargs)
    created = _creation(process.pid)
    if not created:
        process.terminate()
        raise AddonFailure("Could not verify the Scheduler supervisor process")
    service.pidfile.write_text(json.dumps({"pid": process.pid, "created": created}) + "\n", encoding="utf-8")
    time.sleep(2)
    if process.poll() is not None:
        service.pidfile.unlink(missing_ok=True)
        raise AddonFailure(f"Scheduler stopped during startup; see {log}")


def stop(ctx: KitContext) -> None:
    service = _service(ctx)
    pid = service.recorded_pid()
    if pid:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True, check=False)
        else:
            os.killpg(pid, signal.SIGTERM)
        for _ in range(25):
            if not _command(pid):
                break
            time.sleep(0.2)
    for legacy_pid in _legacy_pids(ctx):
        if legacy_pid == pid:
            continue
        try:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(legacy_pid), "/T", "/F"],
                               capture_output=True, check=False, timeout=10)
            else:
                os.kill(legacy_pid, signal.SIGTERM)
        except (OSError, subprocess.TimeoutExpired):
            pass
    service.pidfile.unlink(missing_ok=True)


def validate(ctx: KitContext) -> bool:
    if not installed_version(ctx):
        return False
    try:
        start(ctx)
        schema = _ident(str(ctx.manifest.get(f"{RECEIPT}.schema", "SCHED")))
        for _ in range(20):
            if _schema_exists(ctx, schema):
                if not ctx.manifest.get(f"{RECEIPT}.bootstrap_revoked", False):
                    user = _ident(str(ctx.manifest.get(f"{RECEIPT}.db_user", "scheduler_svc")))
                    for privilege in ("CREATE SCHEMA", "CREATE TABLE"):
                        try:
                            _sql(ctx, f"REVOKE {privilege} FROM {user}")
                        except AddonFailure:
                            pass
                    ctx.manifest.set_many({f"{RECEIPT}.bootstrap_revoked": True})
                ctx.manifest.set_many({f"{RECEIPT}.validated": True})
                return True
            time.sleep(3)
    except (AddonFailure, OSError):
        pass
    ctx.manifest.set_many({f"{RECEIPT}.validated": False})
    return False


def autostart_command(ctx: KitContext) -> list[str]:
    return [str(paths(ctx)[1])]


def log_path(ctx: KitContext) -> str:
    return str(paths(ctx)[3])


def summary(ctx: KitContext) -> str:
    return f"SQL jobs in {ctx.manifest.get(f'{RECEIPT}.schema', 'SCHED')}.SCHED_TASKS"


def update(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("Scheduler is not kit-owned; its owner manages updates")
    was_running = _running(ctx)
    changed = installed_version(ctx) != _version(ctx)
    if was_running and changed:
        stop(ctx)
    try:
        install(ctx)
        if not validate(ctx):
            raise AddonFailure("Scheduler did not validate after the update")
    except Exception:
        if was_running and changed:
            try:
                start(ctx)
            except (AddonFailure, OSError):
                pass
        elif not was_running and _running(ctx):
            try:
                stop(ctx)
            except (AddonFailure, OSError):
                pass
        raise
    if was_running and not _running(ctx):
        start(ctx)
    elif not was_running and _running(ctx):
        stop(ctx)
    ctx.manifest.set_many({"desired.exasol_scheduler": _version(ctx)})


def uninstall(ctx: KitContext, *, dry_run: bool = False) -> list[Path]:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("Scheduler is not kit-owned; it will not be removed")
    home, launcher, _, _, credential = paths(ctx)
    targets = [path for path in (home, launcher, credential) if path.exists()]
    if dry_run:
        return targets
    stop(ctx)
    for target in targets:
        if target.is_dir():
            shutil.rmtree(target)
        else:
            target.unlink(missing_ok=True)
    user = _ident(str(ctx.manifest.get(f"{RECEIPT}.db_user", "scheduler_svc")))
    try:
        _sql(ctx, f"DROP USER {user}")
    except AddonFailure:
        pass
    ctx.manifest.delete(RECEIPT, "desired.exasol_scheduler")
    return targets
