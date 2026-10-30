"""UDF Devkit lifecycle for the marketplace and the direct UDF commands.

The Exasol launcher still owns container installation. This module owns the
selection, verification, restart, smoke and receipt decisions on every host.
"""

from __future__ import annotations

import json
import os
import platform
import re
import shutil
import socket
import ssl
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable

from runtime import AddonFailure, KitContext, venv_executable, venv_python
from udf_bucket import locate
from udf_container import fetch, rust_smoke, select, verify

ID = "udf-devkit"
RECEIPT = "components.udf_devkit"
PYTHON = "PYTHON3"
ML = "PYTHON3_ML"
RUST = "RUST"
SCHEMA = "EXAKIT_UDF"


class UdfFailure(AddonFailure):
    def __init__(self, message: str, code: int = 5, step: str = "install", remedy: str | None = None):
        super().__init__(message)
        self.code, self.step, self.remedy = code, step, remedy


def latest(ctx: KitContext) -> str:
    return ctx.target_version(ID, "0.1.0")


def installed_version(ctx: KitContext) -> str | None:
    return ctx.manifest.get(f"{RECEIPT}.version")


def _home(ctx: KitContext) -> Path:
    return ctx.owned_path(RECEIPT, "home", "EXAKIT_UDF_DEVKIT_HOME", ctx.home / "udf-devkit")


def _deployment(ctx: KitContext) -> Path:
    path = ctx.manifest.get("runtime.deployment_dir") or os.environ.get("EXAKIT_PERSONAL_DEPLOY_DIR")
    if not path:
        raise UdfFailure("No Exasol Personal deployment is recorded.", step="select-container", remedy="exakit status")
    return Path(path)


def _launcher(ctx: KitContext) -> str:
    recorded = ctx.manifest.get("components.personal.ownership_path")
    candidates = [recorded, os.environ.get("EXAKIT_PERSONAL_BIN"),
                  str(ctx.bin_dir / ("exasol.exe" if os.name == "nt" else "exasol")), shutil.which("exasol")]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(candidate)
    raise UdfFailure("The Exasol Personal launcher is missing.", remedy="exakit update personal")


def _tool_python(ctx: KitContext) -> Path:
    recorded = ctx.manifest.get("components.pyexasol.python")
    if isinstance(recorded, str) and Path(recorded).is_file():
        return Path(recorded)
    raise UdfFailure("The kit's pyexasol environment is missing.", remedy="exakit update pyexasol")


def _tool(ctx: KitContext, *args: str, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    env = {**os.environ, "EXAKIT_PYX_DSN": str(ctx.manifest.get("runtime.dsn") or ""),
           "EXAKIT_PYX_USER": str(ctx.manifest.get("runtime.user") or "sys"),
           "EXAKIT_PYX_PWFILE": str(ctx.manifest.get("runtime.password_file") or "")}
    try:
        return subprocess.run([str(_tool_python(ctx)), str(ctx.root / "setup/udf/udf_tool.py"), *args],
                              capture_output=True, text=True, check=False, env=env, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise UdfFailure("The UDF database helper did not finish; see exakit logs.", remedy="exakit status") from error


def _database_ready(ctx: KitContext) -> bool:
    dsn = ctx.manifest.get("runtime.dsn")
    try:
        host, port = str(dsn).rsplit(":", 1)
        secure = ssl.create_default_context()
        secure.check_hostname = False
        secure.verify_mode = ssl.CERT_NONE
        with socket.create_connection((host, int(port)), timeout=3) as connection:
            with secure.wrap_socket(connection, server_hostname="localhost"):
                return True
    except (OSError, TypeError, ValueError, ssl.SSLError):
        return False


def _ready(ctx: KitContext, step: str) -> None:
    if not _database_ready(ctx):
        raise UdfFailure("The database is not running.", step=step, remedy="exakit start")
    _launcher_supported(ctx, step)


def _launcher_supported(ctx: KitContext, step: str) -> None:
    launcher = _launcher(ctx)
    try:
        probe = subprocess.run([launcher, "version"], capture_output=True, text=True, check=False, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise UdfFailure("The Exasol launcher did not answer.", step=step, remedy="exakit update personal") from error
    version = re.search(r"\d+\.\d+(?:\.\d+)?", probe.stdout + probe.stderr)
    if probe.returncode or not version:
        raise UdfFailure("The Exasol launcher did not report a version.", step=step, remedy="exakit update personal")
    from udf_container import _rules

    rules = _rules(ctx.root)
    if not rules.at_least(version.group(), "2.3.0"):
        raise UdfFailure(f"Exasol launcher {version.group()} is older than 2.3.0.", step=step,
                         remedy="exakit update personal")


def _arch(ctx: KitContext) -> str:
    from udf_container import _rules

    try:
        return _rules(ctx.root).database_arch(platform.machine(), platform.system(),
                                              os.environ.get("EXAKIT_UDF_ARCH", ""))
    except ValueError as error:
        raise UdfFailure(str(error), 4, "select-container") from error


def _row(ctx: KitContext, language: str) -> dict:
    result = _tool(ctx, "dbversion")
    if result.returncode or not result.stdout.strip():
        raise UdfFailure("The database version is not known.", step="select-container", remedy="exakit status")
    try:
        row = select(ctx, language, _arch(ctx), result.stdout.strip())
    except AddonFailure as error:
        raise UdfFailure(str(error), 4, "select-container", "exakit update") from error
    ctx.activity(f"Container for {language} on {row['arch']}: {Path(row['url']).name}")
    return row


def _slc(ctx: KitContext, *args: str) -> subprocess.CompletedProcess[str]:
    command = [_launcher(ctx), "slc", *args, "--deployment-dir", str(_deployment(ctx))]
    try:
        return subprocess.run(command, capture_output=True, text=True, check=False, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise UdfFailure("The launcher did not answer the UDF container query.", remedy="exakit status") from error


def _aliases(ctx: KitContext) -> set[str]:
    result = _slc(ctx, "list", "--json")
    if result.returncode:
        raise UdfFailure("The launcher could not list UDF containers.", remedy="exakit logs")
    from udf_container import _rules

    try:
        return set(_rules(ctx.root).installed_aliases(json.loads(result.stdout)))
    except (ValueError, TypeError) as error:
        raise UdfFailure("The launcher returned an invalid container list.", remedy="exakit logs") from error


def _kit_command(ctx: KitContext, *args: str) -> subprocess.CompletedProcess[str]:
    if os.name == "nt":
        shell = shutil.which("pwsh") or shutil.which("powershell")
        if not shell:
            raise UdfFailure("PowerShell is missing; the kit cannot manage running services.")
        command = [shell, "-NoProfile", "-File", str(ctx.root / "setup/exakit.ps1"), *args]
    else:
        command = [str(ctx.root / "setup/exakit"), *args]
    return subprocess.run(command, capture_output=True, text=True, check=False, timeout=35)


def _restart(ctx: KitContext, commands: list[list[str]], *, yes: bool, reason: str,
             action: Callable[[], None] | None = None) -> None:
    if not yes and sys.stdin.isatty() and sys.stdout.isatty():
        reply = input(f"{reason} restarts the database. Continue? [Y/n] ").strip().lower()
        if reply not in ("", "y", "yes"):
            raise UdfFailure("The install was not confirmed; nothing changed.", 5, "install")
    running: list[str] = []
    snapshot = _kit_command(ctx, "status", "--json")
    if snapshot.returncode == 0:
        try:
            services = json.loads(snapshot.stdout).get("services") or {}
            running = [service for service, state in services.items()
                       if service != "database" and state == "running"]
        except (ValueError, AttributeError):
            pass
    for service in running:
        stopped = _kit_command(ctx, "stop", service)
        if stopped.returncode:
            raise UdfFailure(f"Could not stop {service} before the database restart.", 5, "install",
                             f"exakit stop {service}")
    try:
        for argv in commands:
            ctx.run_logged(reason, _launcher(ctx), "slc", *argv, "--deployment-dir", str(_deployment(ctx)),
                           timeout=int(os.environ.get("EXAKIT_UDF_INSTALL_TIMEOUT", "3600")))
        if action is not None:
            action()
    except AddonFailure as error:
        raise UdfFailure(str(error), 6, "install", "exakit logs") from error
    finally:
        deadline = time.monotonic() + int(os.environ.get("EXAKIT_PERSONAL_READY_TIMEOUT", "600"))
        while time.monotonic() < deadline and not _database_ready(ctx):
            time.sleep(3)
        for service in running:
            started = _kit_command(ctx, "start", service)
            if started.returncode:
                ctx.activity(f"{service} did not restart; run exakit start {service}")
    if not _database_ready(ctx):
        raise UdfFailure("The database did not return after the UDF container restart.", 5, "restart",
                         "exakit status")


def _record_language(ctx: KitContext, language: str) -> None:
    old = ctx.manifest.get(f"{RECEIPT}.languages") or ""
    names = list(dict.fromkeys([part for part in old.split(",") if part] + [language]))
    ctx.manifest.set_many({f"{RECEIPT}.languages": ",".join(names)})


def _smoke(ctx: KitContext, alias: str, pins: list[str] = ()) -> list[dict]:
    ctx.activity(f"Checking packages and UDF execution in {alias}")
    result = _tool(ctx, "smoke", alias, SCHEMA, *pins)
    if result.returncode:
        code = 3 if result.returncode == 3 else 7
        ctx.manifest.set_many({f"{RECEIPT}.validated": False})
        raise UdfFailure(f"The smoke UDF on {alias} did not pass: {result.stderr.strip() or 'no output'}",
                         code, "smoke", "exakit udf-use default")
    ctx.manifest.set_many({f"{RECEIPT}.validated": True})
    return [dict(zip(("package", "version"), line.split(" ", 1))) for line in result.stdout.splitlines() if " " in line]


def setup_python(ctx: KitContext, *, force: bool = False, yes: bool = False) -> tuple[dict | None, list[dict]]:
    _ready(ctx, "install")
    if force or PYTHON not in _aliases(ctx):
        _restart(ctx, [["install", PYTHON, "--auto-approve"]], yes=yes,
                 reason=f"Installing the official {PYTHON} container")
    smoke = _smoke(ctx, PYTHON)
    _record_language(ctx, "python")
    ctx.manifest.set_many({f"{RECEIPT}.python_alias": PYTHON})
    return None, smoke


def _prepare_ml(ctx: KitContext, original: Path, row: dict) -> Path:
    target = original.with_name(original.name.removesuffix(".tar.gz") + f"-{ML}.tar.gz")
    ctx.run_logged("Preparing the Python ML runtime", sys.executable, str(ctx.root / "setup/udf/slc_archive.py"),
                   str(original), str(target), ML, row["sha256"], timeout=120)
    if not target.is_file():
        raise UdfFailure("Could not prepare the isolated ML container.", 5, "verify", "exakit logs")
    return target


def setup_default(ctx: KitContext, *, yes: bool = False, install: bool = True) -> tuple[dict, list[dict]]:
    _ready(ctx, "select-container")
    row = _row(ctx, "python")
    pins = [f"{name}=={version}" for name, version in row.get("packages", {}).items()]
    if install or ML not in _aliases(ctx):
        try:
            ctx.activity(f"Downloading Python ML container ({row['size'] // 1_000_000} MB)")
            archive = fetch(ctx, row)
            ctx.activity("Verifying Python ML container checksum")
            source = _prepare_ml(ctx, archive, row)
        except AddonFailure as error:
            raise UdfFailure(str(error), 4 if "pinned" in str(error) or "SHA-256" in str(error) else 5,
                             "verify" if "pinned" in str(error) or "SHA-256" in str(error) else "download",
                             "exakit udf-use default") from error
        verb = "update" if ML in _aliases(ctx) else "install"
        _restart(ctx, [["custom", verb, "--source", str(source), "--alias", ML,
                        "--language", "python", "--auto-approve"]], yes=yes,
                 reason=f"Installing the container as {ML}")
        ctx.manifest.set_many({f"{RECEIPT}.containers.{ML}": row["url"]})
    smoke = _smoke(ctx, ML, pins)
    _record_language(ctx, "python")
    ctx.manifest.set_many({f"{RECEIPT}.python_alias": ML})
    return row, smoke


def _rust_smoke(ctx: KitContext, row: dict, library: Path, *, yes: bool) -> list[dict]:
    asset = row["smoke_asset"]
    expected = asset["sha256"]
    path = ""
    try:
        bucket = locate(_deployment(ctx))
        destination = bucket.directory / "udf/libexakit_smoke.so"
        destination.parent.mkdir(parents=True, exist_ok=True)
        part = destination.with_suffix(".so.part")
        shutil.copyfile(library, part)
        verify(part, asset)
        os.replace(part, destination)
        candidate = f"{bucket.udf_root}/udf/libexakit_smoke.so"
        probe = _tool(ctx, "bucket-file", candidate, expected)
        if probe.returncode == 0:
            path = candidate
    except (AddonFailure, OSError):
        pass
    if not path:
        ctx.activity("The shared bucket is unavailable; packaging the Rust smoke library")
        # The helper validates the retained overlay and preserves its libraries.
        try:
            check = subprocess.run([sys.executable, str(ctx.root / "setup/udf/rust_container.py"), "check",
                                    str(library), expected, str(ctx.versions_path()), row["arch"],
                                    str(ctx.home), "", ""], capture_output=True, check=False, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise UdfFailure("The Rust smoke overlay check did not finish.", 5, "smoke",
                             "exakit status") from error
        if check.returncode:
            def overlay() -> None:
                try:
                    deployed = subprocess.run([sys.executable, str(ctx.root / "setup/udf/rust_container.py"),
                                               str(library), expected, str(ctx.versions_path()), row["arch"],
                                               str(ctx.home), _launcher(ctx), str(_deployment(ctx))],
                                              capture_output=True, check=False, timeout=3600)
                except (OSError, subprocess.TimeoutExpired) as error:
                    raise UdfFailure("The Rust smoke overlay did not finish.", 6, "install",
                                     "exakit logs") from error
                if deployed.returncode:
                    raise UdfFailure("The Rust smoke container fallback did not finish.", 6, "install",
                                     "exakit udf-setup --language rust --yes")
            _restart(ctx, [], yes=yes, reason="Preparing the Rust smoke container", action=overlay)
        path = f"/opt/exakit/udf/{library.name}"
    ctx.activity("Checking the Rust smoke UDF")
    result = _tool(ctx, "smoke-rust", RUST, "STARTER_KIT", path,
                   str(row.get("runtime", {}).get("rustc", "")),
                   str(row.get("crates", {}).get("exasol-udf-sdk", "")))
    if result.returncode:
        ctx.manifest.set_many({f"{RECEIPT}.rust.validated": False, f"{RECEIPT}.validated": False})
        raise UdfFailure(f"The Rust smoke UDF did not pass: {result.stderr.strip() or 'no output'}",
                         7, "smoke", "exakit udf-setup --language rust")
    lines = [dict(zip(("package", "version"), line.split(" ", 1))) for line in result.stdout.splitlines() if " " in line]
    observed = {line["package"]: line["version"] for line in lines}
    ctx.manifest.set_many({f"{RECEIPT}.rust.validated": True,
                           f"{RECEIPT}.rust.rustc": observed.get("rustc", ""),
                           f"{RECEIPT}.rust.sdk": observed.get("sdk", ""),
                           f"{RECEIPT}.validated": True})
    return lines


def setup_rust(ctx: KitContext, *, force: bool = False, yes: bool = False) -> tuple[dict, list[dict], list[dict]]:
    _ready(ctx, "select-container")
    row = _row(ctx, "rust")
    asset = row.get("smoke_asset")
    smoke_pinned = (isinstance(asset, dict) and isinstance(asset.get("sha256"), str)
                    and re.fullmatch(r"[0-9a-fA-F]{64}", asset["sha256"])
                    and isinstance(asset.get("size"), int) and asset["size"] > 0)
    library: Path | None = None
    try:
        ctx.activity(f"Downloading Rust container ({row['size'] // 1_000_000} MB)")
        archive = fetch(ctx, row)
        if smoke_pinned:
            ctx.activity("Verifying Rust container and smoke library")
            try:
                library = rust_smoke(ctx, row)
            except AddonFailure as error:
                if "not bundled" not in str(error):
                    raise
    except AddonFailure as error:
        raise UdfFailure(str(error), 4 if "SHA-256" in str(error) or "pinned" in str(error) else 5,
                         "verify" if "SHA-256" in str(error) or "pinned" in str(error) else "download",
                         "exakit udf-setup --language rust") from error
    aliases = _aliases(ctx)
    python_alias = next((alias for alias in (PYTHON, ML, "PYTHON3_CUSTOM") if alias in aliases), None)
    rust_action = "kept"
    commands: list[list[str]] = []
    if RUST not in aliases or force:
        rust_action = "installed"
        if python_alias is None:
            commands.append(["custom", "update" if RUST in aliases else "install", "--source", str(archive),
                             "--alias", RUST, "--language", "rust", "--auto-approve", "--no-restart"])
        else:
            commands.append(["custom", "update" if RUST in aliases else "install", "--source", str(archive),
                             "--alias", RUST, "--language", "rust", "--auto-approve"])
    if python_alias is None:
        commands.append(["install", PYTHON, "--auto-approve"])
        python_alias = PYTHON
    if commands:
        _restart(ctx, commands, yes=yes, reason="Installing the Rust and Python UDF containers")
        ctx.manifest.set_many({f"{RECEIPT}.containers.{RUST}": row["url"]})
    python_smoke = _smoke(ctx, python_alias)
    _record_language(ctx, "python")
    ctx.manifest.set_many({f"{RECEIPT}.python_alias": python_alias})
    _record_language(ctx, "rust")
    if library is None:
        ctx.manifest.set_many({f"{RECEIPT}.rust.validated": False, f"{RECEIPT}.validated": False})
        raise UdfFailure(f"The Rust smoke UDF library for {row['arch']} is not pinned or bundled; "
                         f"the {RUST} container is installed but not proven.", 7, "smoke", "exakit update")
    rust_lines = _rust_smoke(ctx, row, library, yes=yes)
    steps = [{"language": "rust", "alias": RUST, "step": "install", "action": rust_action},
             {"language": "python", "alias": python_alias, "step": "install",
              "action": "kept" if python_alias in aliases else "installed"}]
    return row, rust_lines, steps


def install_tarball(ctx: KitContext, source: Path, alias: str, language: str, *, yes: bool,
                    packages: list[str] | None = None, origin: str | None = None) -> list[dict]:
    _ready(ctx, "install")
    verb = "update" if alias in _aliases(ctx) else "install"
    if language == "rust" and alias == RUST:
        helper = ctx.root / "setup/udf/rust_container.py"
        ctx.run_logged("Invalidating the previous Rust overlay", sys.executable, str(helper), "invalidate", str(ctx.home))
    _restart(ctx, [["custom", verb, "--source", str(source), "--alias", alias,
                    "--language", language, "--auto-approve"]], yes=yes,
             reason=f"Installing the container as {alias}")
    if language == "rust":
        ctx.manifest.set_many({f"{RECEIPT}.validated": False})
        smoke: list[dict] = []
    else:
        smoke = _smoke(ctx, alias, packages or [])
    ctx.manifest.set_many({f"{RECEIPT}.containers.{alias}": origin or str(source)})
    _record_language(ctx, language)
    return smoke


def _engine(ctx: KitContext) -> dict[str, str]:
    env = dict(os.environ)
    docker = shutil.which("docker")
    if docker:
        try:
            if subprocess.run([docker, "info"], capture_output=True, check=False, timeout=20).returncode == 0:
                return env
        except (OSError, subprocess.TimeoutExpired):
            pass
    podman = shutil.which("podman")
    if podman:
        try:
            if subprocess.run([podman, "info"], capture_output=True, check=False, timeout=20).returncode == 0:
                if env.get("DOCKER_HOST"):
                    return env
                if os.name == "nt":
                    pipe = subprocess.run([podman, "machine", "inspect", "--format",
                                           "{{.ConnectionInfo.PodmanPipe.Path}}"],
                                          capture_output=True, text=True, check=False, timeout=20)
                    name = pipe.stdout.strip()
                    if pipe.returncode == 0 and name.startswith("\\\\.\\pipe\\") and len(name) > 9:
                        env["DOCKER_HOST"] = "npipe:////./pipe/" + name[9:]
                        return env
                for args in (["machine", "inspect", "--format", "{{.ConnectionInfo.PodmanSocket.Path}}"],
                             ["info", "--format", "{{.Host.RemoteSocket.Path}}"]):
                    probe = subprocess.run([podman, *args], capture_output=True, text=True,
                                           check=False, timeout=20)
                    socket_path = probe.stdout.strip().removeprefix("unix://")
                    if probe.returncode == 0 and socket_path and Path(socket_path).is_socket():
                        env["DOCKER_HOST"] = "unix://" + socket_path
                        return env
                raise UdfFailure("Podman has no Docker-compatible API socket.", 5, "install")
        except (OSError, subprocess.TimeoutExpired):
            pass
    raise UdfFailure("A running Docker or Podman engine is needed to build a UDF container.", 5, "install")


def build(ctx: KitContext, requirements: Path, alias: str, *, yes: bool) -> list[dict]:
    from udf_container import _rules
    from addons import notebook

    try:
        pins = _rules(ctx.root).pinned(_rules(ctx.root).requirements(requirements.read_text(encoding="utf-8")))
        alias = _rules(ctx.root).identifier(alias, "The container alias")
    except (OSError, ValueError) as error:
        raise UdfFailure(str(error), 2, "select-container") from error
    if not notebook.installed_version(ctx):
        raise UdfFailure("The notebook add-on is needed for container build tooling.", 5, "install",
                         "exakit marketplace notebook")
    _ready(ctx, "install")
    env = _engine(ctx)
    work = _home(ctx) / "build"
    work.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(work).free < 25 * 1024**3:
        raise UdfFailure("Building a container needs about 25 GB free.", 5, "install")
    ctx.require_uv()
    version = notebook.installed_version(ctx)
    python = venv_python(notebook.paths(ctx)[0])
    ctx.run_logged("Adding UDF build tooling to the notebook environment", str(ctx.uv), "pip", "install",
                   "--python", str(python),
                   f"exasol-notebook-connector[bucketfs,ibis,pyexasol,sqlalchemy,notebook-dependencies,slc]=={version}")
    notebook._write_store(ctx)
    master = notebook._credential(ctx, "notebook_store_master_password")
    env.update({"EXAKIT_UDF_BUILD": json.dumps({"work_dir": str(work), "name": "kit_custom",
                                                 "flavor": "template-Exasol-all-python-3.12",
                                                 "packages": pins}),
                "SCS_FILE": str(notebook.paths(ctx)[1] / "connection.scs"),
                "SCS_MASTER_PASSWORD": master.read_text(encoding="utf-8").strip()})
    try:
        result = subprocess.run([str(python), str(ctx.root / "setup/udf/udf_tool.py"), "build"],
                                capture_output=True, text=True, check=False, timeout=7200, env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise UdfFailure("The UDF container build did not finish; see exakit logs.", 5, "install",
                         "exakit logs") from error
    if result.returncode:
        raise UdfFailure("The UDF container build failed; see exakit logs.", 5, "install", "exakit logs")
    try:
        tarball = Path(json.loads(result.stdout.splitlines()[-1])["tarball"])
    except (IndexError, ValueError, KeyError) as error:
        raise UdfFailure("The container build did not report its tarball.", 5, "install") from error
    if not tarball.is_file():
        raise UdfFailure("The container build tarball is missing.", 5, "install")
    return install_tarball(ctx, tarball, alias, "python", yes=yes,
                           packages=[name for name, _ in pins], origin=str(requirements))


def install(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.ownership") in ("user", "unknown"):
        return
    language = os.environ.get("EXAKIT_UDF_LANGUAGE", "python")
    if language not in ("python", "rust"):
        raise UdfFailure(f"The UDF language must be python or rust, not {language!r}.", 2, "select-container")
    _launcher_supported(ctx, "select-container")
    version = latest(ctx)
    ctx.manifest.set_many({f"{RECEIPT}.version": version, f"{RECEIPT}.schema": SCHEMA,
                           f"{RECEIPT}.home": str(_home(ctx)), f"{RECEIPT}.ownership": "kit"})
    if not _database_ready(ctx):
        ctx.activity(f"Start the database, then set up {language} UDFs with: exakit udf-setup --language {language}")
        return
    try:
        if language == "rust":
            setup_rust(ctx, yes=True)
        else:
            setup_python(ctx, yes=True)
        setup_default(ctx, yes=True, install=False)
    except UdfFailure:
        ctx.manifest.set_many({f"{RECEIPT}.validated": False})
        raise


def validate(ctx: KitContext) -> bool:
    if not _database_ready(ctx):
        return True
    try:
        aliases = _aliases(ctx)
        if PYTHON in aliases:
            _smoke(ctx, PYTHON)
        if ML in aliases:
            setup_default(ctx, install=False)
        if RUST in aliases:
            row = _row(ctx, "rust")
            _rust_smoke(ctx, row, rust_smoke(ctx, row), yes=False)
        return bool(aliases & {PYTHON, ML, RUST})
    except (AddonFailure, OSError):
        ctx.manifest.set_many({f"{RECEIPT}.validated": False})
        return False


def update(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("UDF Devkit is not kit-owned; its owner manages updates")
    target = latest(ctx)
    ctx.manifest.set_many({f"{RECEIPT}.version": target, "desired.udf_devkit": target})
    ctx.activity(f"The prebuilt container {target} is available; install it with: exakit udf-use default")


def summary(ctx: KitContext) -> str:
    if ctx.manifest.get(f"{RECEIPT}.validated") is not True:
        return "Runtime setup pending: exakit udf-setup"
    languages = ctx.manifest.get(f"{RECEIPT}.languages") or ""
    return f"Python/ML ready: {ML}; Rust UDFs: alias {RUST}" if "rust" in languages.split(",") else \
           f"Python/ML ready: {ML}; help: exakit help udf-devkit"


def _mlflow(ctx: KitContext, *args: str) -> subprocess.CompletedProcess[str]:
    from addons.notebook import paths

    notebook_python = venv_python(paths(ctx)[0])
    python = notebook_python if notebook_python.is_file() else Path(sys.executable)
    return subprocess.run([str(python), str(ctx.root / "setup/lib/mlflow_service.py"), *args],
                          capture_output=True, text=True, check=False, timeout=45,
                          env={**os.environ, "EXAKIT_HOME": str(ctx.home)})


def status(ctx: KitContext) -> str:
    result = _mlflow(ctx, "status", "--json")
    try:
        state = json.loads(result.stdout).get("status")
    except ValueError:
        state = None
    if state == "stopped" and ctx.manifest.get(f"{RECEIPT}.mlflow.enabled") is not True:
        return "stopped (not enabled: exakit mlflow start)"
    return state if state in ("running", "stopped") else "unknown"


def start(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.mlflow.enabled") is not True:
        return
    from addons.notebook import paths

    venv = paths(ctx)[0]
    executable = venv_executable(venv, "mlflow")
    if venv_python(venv).is_file():
        result = _mlflow(ctx, "start", "--executable", str(executable))
        if result.returncode:
            raise AddonFailure("MLflow did not start; see exakit logs setup")


def stop(ctx: KitContext) -> None:
    _mlflow(ctx, "stop", "--json")


def url(ctx: KitContext) -> str:
    return _mlflow(ctx, "url").stdout.strip()


def log_path(ctx: KitContext) -> list[str]:
    return [f"udf-devkit-mlflow|MLflow server|{ctx.home / 'mlflow/server.log'}"]


def uninstall(ctx: KitContext, *, dry_run: bool = False) -> list[Path]:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("UDF Devkit is not kit-owned; it will not be removed")
    home = _home(ctx)
    if not home.resolve().is_relative_to(ctx.home.resolve()):
        raise AddonFailure("The UDF Devkit home is outside the kit home; refusing removal")
    if dry_run:
        return [home] if home.exists() else []
    stop(ctx)
    if home.is_dir():
        shutil.rmtree(home)
    ctx.manifest.delete(RECEIPT, "desired.udf_devkit")
    ctx.activity("UDF containers and model files remain in the database deployment")
    return [home]
