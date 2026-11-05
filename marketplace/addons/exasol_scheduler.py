"""Verified Exasol Scheduler install with a dedicated, least privilege user."""

from __future__ import annotations

import contextlib
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
from runtime import AddonFailure, KitContext, cmd_quote, venv_python, write_private, host_machine

ID = "exasol-scheduler"
RECEIPT = "components.exasol_scheduler"
REPO = "exasol-labs/exasol-scheduler"
HEX = re.compile(r"^[0-9a-f]{64}$")
IDENT = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")


# --- the engine as an Exasol Personal sidecar (launcher 2.4.0+) ---------------
# Where versions.json pins a scheduler image by digest (components.exasol-
# scheduler.image) and the launcher has sidecars, the engine runs as the
# deployment's `exasol-scheduler` sidecar: started, stopped and destroyed with
# the database, nothing on the host to supervise. Connected as scheduler_svc,
# never SYS: the definition is the kit's, written whole into the deployment's
# sidecars.yaml (the password read from the credential file by the editor) and
# applied by `exasol start`. Every exakit command stays the same; an install
# keeps the backend it was made with (components.exasol_scheduler.backend), and
# EXAKIT_EXASOL_SCHEDULER_BACKEND=host keeps the native engine.
SIDECAR = ID
SIDECAR_PYYAML = os.environ.get("EXAKIT_SIDECAR_PYYAML", "PyYAML==6.0.3")


def _sidecar_image(ctx: KitContext) -> str | None:
    image = ctx.versions_document().get("components", {}).get(ID, {}).get("image")
    return image if isinstance(image, str) and "@sha256:" in image else None


def _launcher(ctx: KitContext) -> str | None:
    for candidate in (ctx.manifest.get("components.personal.ownership_path"), os.environ.get("EXAKIT_PERSONAL_BIN"),
                      str(ctx.bin_dir / ("exasol.exe" if os.name == "nt" else "exasol")), shutil.which("exasol")):
        if candidate and Path(candidate).is_file():
            return str(candidate)
    return None


def _deployment(ctx: KitContext) -> Path | None:
    raw = os.environ.get("EXAKIT_PERSONAL_DEPLOY_DIR") or ctx.manifest.get("runtime.deployment_dir")
    return Path(str(raw)) if raw and Path(str(raw)).is_dir() else None


def _launch(ctx: KitContext, *args: str, timeout: int = 300) -> subprocess.CompletedProcess:
    launcher = _launcher(ctx)
    if not launcher:
        raise AddonFailure("The Exasol Personal launcher is missing; repair with: exakit update personal")
    return subprocess.run([launcher, *args], capture_output=True, text=True, check=False, timeout=timeout)


def _sidecar_mode(ctx: KitContext) -> bool:
    recorded = ctx.manifest.get(f"{RECEIPT}.backend")
    if recorded in ("sidecar", "host"):
        return recorded == "sidecar"
    if os.environ.get("EXAKIT_EXASOL_SCHEDULER_BACKEND") == "host" or not _sidecar_image(ctx):
        return False
    if ctx.manifest.get("runtime.type") != "personal" or not _deployment(ctx) or not _launcher(ctx):
        return False
    try:
        help_text = _launch(ctx, "--help", timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return False
    return bool(re.search(r"(?m)^\s*sidecar(\s|,|$)", help_text))


def _sidecar_definition(ctx: KitContext, user: str, schema: str) -> dict:
    def ref(key: str) -> dict:
        return {"secretKeyRef": {"name": "exasol-database", "key": key}}
    return {"enabled": True, "container": {
        "image": _sidecar_image(ctx), "imagePullPolicy": "IfNotPresent", "restartPolicy": "Always",
        "env": [{"name": "EXA_HOST", "valueFrom": ref("host")}, {"name": "EXA_PORT", "valueFrom": ref("port")},
                {"name": "EXA_USER", "value": user}, {"name": "EXA_PASSWORD", "valueFile": str(paths(ctx)[4])},
                {"name": "EXA_SCHEMA", "value": schema}, {"name": "EXA_TLS", "value": "true"},
                {"name": "EXA_VALIDATE_SERVER_CERT", "value": "false"},
                {"name": "EXASOL_TELEMETRY_DISABLE", "value": "1"}]}}


def _edit_sidecars(ctx: KitContext, *args: str) -> str:
    deployment = _deployment(ctx)
    if deployment is None:
        raise AddonFailure("The Exasol Personal deployment was not found; check exakit status")
    command = [str(ctx.require_uv()), "run", "--no-project", "--quiet", "--with", SIDECAR_PYYAML, "python",
               str(ctx.root / "setup" / "lib" / "sidecar_definition.py"), args[0],
               str(deployment / "sidecars.yaml"), SIDECAR, *args[1:]]
    result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=300)
    if result.returncode != 0:
        raise AddonFailure("The scheduler sidecar definition could not be written; see exakit logs setup")
    return result.stdout.strip()


def _sidecar_status(ctx: KitContext) -> dict:
    try:
        result = _launch(ctx, "sidecar", "status", SIDECAR, "--json", timeout=60)
        doc = json.loads(result.stdout or "{}")
    except (AddonFailure, OSError, ValueError, subprocess.TimeoutExpired):
        return {}
    if isinstance(doc, list):
        doc = doc[0] if doc else {}
    return doc if isinstance(doc, dict) else {}


def _sidecar_put(ctx: KitContext, user: str, schema: str) -> None:
    with tempfile.TemporaryDirectory(prefix="exakit-scheduler-sidecar-") as temp:
        definition = Path(temp) / "definition.json"
        definition.write_text(json.dumps(_sidecar_definition(ctx, user, schema)), encoding="utf-8")
        changed = _edit_sidecars(ctx, "put", str(definition)) == "changed"
    if changed or not _sidecar_status(ctx).get("running"):
        # Reconciles a running deployment: only this container is (re)created.
        if _launch(ctx, "start").returncode != 0:
            raise AddonFailure("exasol start did not apply the scheduler sidecar; see exakit logs setup")


def _install_sidecar(ctx: KitContext) -> None:
    user, schema, bootstrap = _user(ctx)
    _sidecar_put(ctx, user, schema)
    tag = str(_sidecar_image(ctx)).split("@")[0].rsplit(":", 1)[-1].removeprefix("v")
    ctx.manifest.set_many({f"{RECEIPT}.version": tag, f"{RECEIPT}.backend": "sidecar",
                           f"{RECEIPT}.image": _sidecar_image(ctx), f"{RECEIPT}.db_user": user.lower(),
                           f"{RECEIPT}.schema": schema, f"{RECEIPT}.ownership": "kit",
                           f"{RECEIPT}.bootstrap_revoked": not bootstrap})


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
    arch = host_machine().lower()
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
    return f"no prebuilt scheduler binary is published for {platform.system()}/{host_machine()}"


def installed_version(ctx: KitContext) -> str | None:
    if ctx.manifest.get(f"{RECEIPT}.backend") == "sidecar":
        version = ctx.manifest.get(f"{RECEIPT}.version")
        return str(version).removeprefix("v") if version else None
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
    if user in ("SYS", str(ctx.manifest.get("runtime.user", "sys")).upper()):
        raise AddonFailure("Scheduler must use a dedicated database user, separate from the kit administrator")
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
        write_private(credential, password + "\n")
    present = "EXAKIT_SCHED_USER_PRESENT" in _sql(
        ctx, "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_USERS WHERE USER_NAME = "
        f"'{user}') THEN 'EXAKIT_SCHED_USER_PRESENT' ELSE 'EXAKIT_SCHED_USER_MISSING' END AS STATUS")
    _sql(ctx, f'{"ALTER" if present else "CREATE"} USER {user} IDENTIFIED BY "{password}"', secret=password)
    _sql(ctx, f"GRANT CREATE SESSION TO {user}")
    bootstrap = not _schema_exists(ctx, schema)
    if bootstrap:
        _sql(ctx, f"GRANT CREATE SCHEMA TO {user}")
        _sql(ctx, f"GRANT CREATE TABLE TO {user}")
    else:
        _sql(ctx, f"GRANT USAGE ON SCHEMA {schema} TO {user}")
        _sql(ctx, f"GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA {schema} TO {user}")
    return user, schema, bootstrap


def _write_launcher(ctx: KitContext) -> None:
    home, launcher, engine, _, credential = paths(ctx)
    python = venv_python(home / "python")
    script = ctx.root / "marketplace" / "scheduler_launcher.py"
    ctx.bin_dir.mkdir(parents=True, exist_ok=True)
    argv = [str(python), str(script), str(home), str(engine), str(ctx.manifest.path), str(credential)]
    if os.name == "nt":
        launcher.write_text("@echo off\r\n" + " ".join(cmd_quote(item) for item in argv) + " %*\r\n", encoding="utf-8")
    else:
        launcher.write_text("#!/bin/sh\nexec " + " ".join(shlex.quote(item) for item in argv) + ' "$@"\n',
                            encoding="utf-8")
        launcher.chmod(0o755)


def _ensure_python(ctx: KitContext) -> Path:
    python = venv_python(paths(ctx)[0] / "python")
    if not python.is_file():
        uv = ctx.require_uv()
        ctx.run_logged("Creating Scheduler Python runtime", str(uv), "venv", "--python",
                       ctx.managed_python_version, str(paths(ctx)[0] / "python"))
    return python


def install(ctx: KitContext) -> None:
    if not applicable(ctx):
        raise AddonFailure(applicable_reason(ctx))
    if ctx.manifest.get(f"{RECEIPT}.ownership") in ("user", "unknown") or \
       (not ctx.manifest.get(f"{RECEIPT}.version") and system_present(ctx)):
        raise AddonFailure("An external Scheduler is present; the kit leaves it under its owner's control")
    if _sidecar_mode(ctx):
        _install_sidecar(ctx)
        return
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
        _ensure_python(ctx)
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
    # PID creation time plus the private service home survives kit source updates.
    return ManagedProcess(home / "exasol-scheduler.pid", log, home)


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
    if ctx.manifest.get(f"{RECEIPT}.backend") == "sidecar":
        return bool(_sidecar_status(ctx).get("running"))
    return _service(ctx).recorded_pid() is not None or bool(_legacy_pids(ctx))


def status(ctx: KitContext) -> str:
    if ctx.manifest.get(f"{RECEIPT}.backend") == "sidecar":
        if not installed_version(ctx):
            return "not installed"
        state = _sidecar_status(ctx)
        if state.get("running"):
            return "running"
        reason = state.get("error") or state.get("healthError")
        return f"stopped ({reason}; diagnose: exasol sidecar status {SIDECAR})" if reason else "stopped"
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
    if ctx.manifest.get(f"{RECEIPT}.backend") == "sidecar":
        # Re-enabling keeps the saved definition (the scheduler user, the image).
        if _launch(ctx, "sidecar", "enable", SIDECAR).returncode != 0:
            raise AddonFailure(f"The scheduler sidecar did not start; diagnose: exasol sidecar status {SIDECAR}")
        return
    home, _, engine, log, credential = paths(ctx)
    python = venv_python(home / "python")
    if not python.is_file():
        if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
            raise AddonFailure("Scheduler is not kit-owned; its owner must repair the missing Python runtime")
        python = _ensure_python(ctx)
    if ctx.manifest.get(f"{RECEIPT}.ownership") == "kit":
        _write_launcher(ctx)
    (home / "gave-up").unlink(missing_ok=True)
    service = _service(ctx)
    script = ctx.root / "marketplace" / "scheduler_launcher.py"
    command = [str(python), str(script), str(home), str(engine),
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
    if ctx.manifest.get(f"{RECEIPT}.backend") == "sidecar":
        # Disable keeps the definition, so the next start brings back the same one.
        _launch(ctx, "sidecar", "disable", SIDECAR)
        return
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


def autostart_command(ctx: KitContext) -> list[str] | None:
    if ctx.manifest.get(f"{RECEIPT}.backend") == "sidecar":
        return None                     # a sidecar comes back with the database
    return [str(paths(ctx)[1])]


def log_path(ctx: KitContext) -> str:
    return str(paths(ctx)[3])


def summary(ctx: KitContext) -> str:
    return f"SQL jobs in {ctx.manifest.get(f'{RECEIPT}.schema', 'SCHED')}.SCHED_TASKS"


def update(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("Scheduler is not kit-owned; its owner manages updates")
    if ctx.manifest.get(f"{RECEIPT}.backend") == "sidecar":
        # The new image goes into the definition; exasol start recreates that container.
        _sidecar_put(ctx, str(ctx.manifest.get(f"{RECEIPT}.db_user", "scheduler_svc")),
                     str(ctx.manifest.get(f"{RECEIPT}.schema", "SCHED")))
        tag = str(_sidecar_image(ctx)).split("@")[0].rsplit(":", 1)[-1].removeprefix("v")
        ctx.manifest.set_many({f"{RECEIPT}.version": tag, f"{RECEIPT}.image": _sidecar_image(ctx),
                               "desired.exasol_scheduler": tag})
        if not validate(ctx):
            raise AddonFailure("Scheduler did not validate after the update")
        return
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
    if ctx.manifest.get(f"{RECEIPT}.backend") == "sidecar" and _deployment(ctx) is not None:
        _launch(ctx, "sidecar", "disable", SIDECAR, "--remove")
    user = _ident(str(ctx.manifest.get(f"{RECEIPT}.db_user", "scheduler_svc")))
    schema = _ident(str(ctx.manifest.get(f"{RECEIPT}.schema", "SCHED")))
    owner = str(ctx.manifest.get("runtime.user", "sys"))
    if user in ("SYS", owner.upper()):
        raise AddonFailure("Scheduler must use a dedicated database user; the administrator will not be removed")
    stop(ctx)
    others = _sql(ctx, "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_SCHEMAS "
                  f"WHERE SCHEMA_OWNER = '{user}' AND SCHEMA_NAME <> '{schema}') "
                  "THEN 'EXAKIT_SCHED_OTHER_SCHEMAS' ELSE 'EXAKIT_SCHED_NO_OTHER_SCHEMAS' END AS STATUS")
    if "EXAKIT_SCHED_OTHER_SCHEMAS" in others:
        raise AddonFailure("Scheduler owns other schemas; transfer them before retrying removal")
    owned = _sql(ctx, "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_SCHEMAS "
                 f"WHERE SCHEMA_OWNER = '{user}' AND SCHEMA_NAME = '{schema}') "
                 "THEN 'EXAKIT_SCHED_OWNS_SCHEMA' ELSE 'EXAKIT_SCHED_SCHEMA_NOT_OWNED' END AS STATUS")
    if "EXAKIT_SCHED_OWNS_SCHEMA" in owned:
        quoted_owner = '"' + owner.replace('"', '""') + '"'
        _sql(ctx, f"ALTER SCHEMA {schema} CHANGE OWNER {quoted_owner}")
    _sql(ctx, f"DROP USER IF EXISTS {user}")
    for target in targets:
        if target.is_dir():
            shutil.rmtree(target)
        else:
            target.unlink(missing_ok=True)
    # Install creates the credentials folder when the kit's own passwords live elsewhere; an empty one is ours.
    with contextlib.suppress(OSError):
        credential.parent.rmdir()
    ctx.manifest.delete(RECEIPT, "desired.exasol_scheduler")
    return targets
