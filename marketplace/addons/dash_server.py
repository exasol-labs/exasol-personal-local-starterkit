"""Dash Server add-on: package, localhost service, browser and MCP probes."""

from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path, PurePosixPath

from process import ManagedProcess, port_open
from runtime import AddonFailure, KitContext, venv_executable, venv_python

ID = "dash-server"
RECEIPT = "components.dash_server"


def paths(ctx: KitContext) -> tuple[Path, Path, Path]:
    instance = ctx.manifest.get(f"{RECEIPT}.instance") if ctx.manifest.get(f"{RECEIPT}.ownership") == "kit" else None
    return (ctx.owned_path(RECEIPT, "venv", "EXAKIT_DASH_SERVER_VENV", ctx.home / "dash-server-venv"),
            Path(instance).parent if instance else ctx.path("EXAKIT_DASH_SERVER_HOME", ctx.home / "dash-server"),
            ctx.owned_path(RECEIPT, "command", "EXAKIT_DASH_SERVER_BIN", ctx.bin_dir / ("dash-server.cmd" if os.name == "nt" else "dash-server")))


def _port(ctx: KitContext) -> int:
    raw = os.environ.get("EXAKIT_DASH_SERVER_PORT") or ctx.manifest.get(f"{RECEIPT}.port", 5100)
    try:
        port = int(raw)
    except (ValueError, TypeError) as error:
        raise AddonFailure(f"invalid dash-server port: {raw}") from error
    if not 1 <= port <= 65535:
        raise AddonFailure(f"invalid dash-server port: {raw}")
    return port


def _service(ctx: KitContext) -> ManagedProcess:
    venv, home, _ = paths(ctx)
    return ManagedProcess(home / "dash-server.pid", ctx.home / "logs" / "dash-server.log", venv)


def _launch_command(ctx: KitContext) -> list[str]:
    return [str(venv_python(paths(ctx)[0])), str(ctx.root / "marketplace" / "dash_launcher.py")]


def _release_url(version: str) -> str:
    return f"https://github.com/exasol-labs/dash-server/archive/refs/tags/v{version}.tar.gz"


def package_version(ctx: KitContext) -> str | None:
    python = venv_python(paths(ctx)[0])
    if not python.is_file():
        return None
    try:
        result = subprocess.run([str(python), "-c", "from importlib.metadata import version; print(version('dash-server'))"],
                                capture_output=True, text=True, check=False, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def installed_version(ctx: KitContext) -> str | None:
    return package_version(ctx) if ctx.manifest.get(f"{RECEIPT}.version") else None


def _settle_port(ctx: KitContext) -> int:
    port = _port(ctx)
    service = _service(ctx)
    if service.status(port) == "stopped" or service.status(port) == "running":
        return port
    if os.environ.get("EXAKIT_DASH_SERVER_PORT"):
        raise AddonFailure(f"Port {port} is in use; set EXAKIT_DASH_SERVER_PORT to a free port")
    for candidate in range(port + 1, min(port + 21, 65536)):
        if service.status(candidate) == "stopped":
            ctx.activity(f"Port {port} is busy; dash-server will use {candidate}")
            return candidate
    raise AddonFailure(f"No free dash-server port found from {port} through {min(port + 20, 65535)}")


def _restore_templates(ctx: KitContext, version: str) -> None:
    """Repair package data missing from the upstream 0.1.x source build."""
    python = venv_python(paths(ctx)[0])
    result = subprocess.run([str(python), "-c", "import dash_server; print(dash_server.__path__[0])"],
                            capture_output=True, text=True, check=False, timeout=10)
    if result.returncode != 0:
        return
    site = Path(result.stdout.strip())
    if not site.is_dir():
        return
    with tempfile.TemporaryDirectory(prefix="exakit-dash-data-") as temp:
        archive = Path(temp) / "source.tar.gz"
        try:
            with urllib.request.urlopen(_release_url(version), timeout=30) as response, archive.open("wb") as output:
                if not response.url.startswith("https://"):
                    return
                shutil.copyfileobj(response, output)
            with tarfile.open(archive, "r:gz") as source:
                prefix = f"dash-server-{version}/src/dash_server/"
                for member in source:
                    if not member.isfile() or not member.name.startswith(prefix):
                        continue
                    relative = PurePosixPath(member.name.removeprefix(prefix))
                    if relative.suffix == ".py" or not relative.parts or any(part in ("", ".", "..") for part in relative.parts):
                        continue
                    target = site.joinpath(*relative.parts)
                    if target.exists():
                        continue
                    source_file = source.extractfile(member)
                    if source_file is None:
                        continue
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source_file, target.open("xb") as output:
                        shutil.copyfileobj(source_file, output)
        except (OSError, tarfile.TarError):
            # The repair is best effort; validate() separately probes the UI.
            return


def _write_launcher(ctx: KitContext) -> Path:
    venv, _, launcher = paths(ctx)
    script = ctx.root / "marketplace" / "dash_launcher.py"
    ctx.bin_dir.mkdir(parents=True, exist_ok=True)
    if os.name == "nt":
        launcher.write_text(f'@echo off\r\n"{venv_python(venv)}" "{script}" %*\r\n', encoding="utf-8")
    else:
        launcher.write_text("#!/bin/sh\nexec " + shlex.quote(str(venv_python(venv))) + " "
                            + shlex.quote(str(script)) + ' "$@"\n', encoding="utf-8")
        launcher.chmod(0o755)
    return launcher


def install(ctx: KitContext) -> None:
    from model import load_addons

    if ctx.manifest.get(f"{RECEIPT}.ownership") in ("user", "unknown"):
        return
    ctx.require_uv()
    default = next(addon.default_version for addon in load_addons(ctx.root) if addon.id == ID)
    version = ctx.target_version(ID, default)
    venv, home, _ = paths(ctx)
    port = _settle_port(ctx)
    python = venv_python(venv)
    if package_version(ctx) != version or os.environ.get("EXAKIT_FORCE_COMPONENT_INSTALL") == "1":
        if not python.is_file():
            ctx.run_logged("Creating Dash Server environment", str(ctx.uv), "venv", "--seed", "--python", ctx.managed_python_version, str(venv))
        else:
            probe = subprocess.run([str(python), "-m", "pip", "--version"], capture_output=True, check=False)
            if probe.returncode != 0:
                ctx.run_logged("Seeding Dash Server pip", str(ctx.uv), "pip", "install", "--python", str(python), "pip")
        ctx.run_logged(f"Installing Dash Server {version}", str(ctx.uv), "pip", "install", "--python", str(python),
                       _release_url(version))
        if package_version(ctx) != version:
            raise AddonFailure("Dash Server did not report the requested version after installation")
        _restore_templates(ctx, version)
    home.joinpath("instance").mkdir(parents=True, exist_ok=True)
    launcher = _write_launcher(ctx)
    ctx.manifest.set_many({f"{RECEIPT}.version": version, f"{RECEIPT}.venv": str(venv),
                           f"{RECEIPT}.python": str(python), f"{RECEIPT}.command": str(launcher),
                           f"{RECEIPT}.port": port, f"{RECEIPT}.instance": str(home / "instance"),
                           f"{RECEIPT}.ownership": "kit"})


def _http(port: int, path: str, *, browser: bool) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as response:
            code = response.status
    except urllib.error.HTTPError as error:
        code = error.code
    except OSError:
        return False
    return 200 <= code < (400 if browser else 500)


def validate(ctx: KitContext) -> bool:
    venv, _, _ = paths(ctx)
    python = venv_python(venv)
    if not python.is_file():
        return False
    result = subprocess.run([str(python), "-c", "import dash_server"], capture_output=True, check=False, timeout=15)
    if result.returncode != 0:
        ctx.manifest.set_many({f"{RECEIPT}.validated": False})
        return False
    port = _port(ctx)
    service = _service(ctx)
    was_running = service.status(port) == "running"
    try:
        if not was_running:
            service.start(_launch_command(ctx), port)
        ok = _http(port, "/mcp", browser=False)
        browser = _http(port, "/", browser=True) if ok else False
        if was_running and ok and not browser:
            service.stop(port)
            service.start(_launch_command(ctx), port)
            ok = _http(port, "/mcp", browser=False)
            browser = _http(port, "/", browser=True) if ok else False
        ctx.manifest.set_many({f"{RECEIPT}.validated": ok, f"{RECEIPT}.ui_validated": browser})
        return ok
    except AddonFailure:
        ctx.manifest.set_many({f"{RECEIPT}.validated": False})
        return False
    finally:
        if not was_running:
            service.stop(port)


def status(ctx: KitContext) -> str:
    if not installed_version(ctx):
        return "not installed"
    return _service(ctx).status(_port(ctx))


def start(ctx: KitContext) -> str:
    if not installed_version(ctx):
        raise AddonFailure("Dash Server is not installed; run exakit marketplace dash-server")
    if status(ctx) == "running":
        return "Dash Server is already running"
    port = _port(ctx)
    _service(ctx).start(_launch_command(ctx), port)
    if not _http(port, "/mcp", browser=False):
        raise AddonFailure(f"Dash Server started but /mcp does not answer on port {port}")
    ctx.manifest.set_many({f"{RECEIPT}.port": port})
    return f"Dash Server is running at {url(ctx)}"


def stop(ctx: KitContext) -> str:
    if status(ctx) == "stopped":
        return "Dash Server is already stopped"
    _service(ctx).stop(_port(ctx))
    return "Dash Server stopped"


def url(ctx: KitContext) -> str:
    return f"http://127.0.0.1:{_port(ctx)}"


def summary(ctx: KitContext) -> str:
    return f"dashboards: {url(ctx)}"


def log_path(ctx: KitContext) -> str:
    return str(_service(ctx).log)


def autostart_command(ctx: KitContext) -> list[str]:
    return [str(paths(ctx)[2]), "--host", "127.0.0.1", "--port", str(_port(ctx))]


def uninstall(ctx: KitContext, *, dry_run: bool = False) -> list[Path]:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("Dash Server is not kit-owned; it will not be removed")
    venv, home, launcher = paths(ctx)
    targets = [venv, launcher, home / "dash-server.pid"]
    if dry_run:
        return [target for target in targets if target.exists()]
    stop(ctx)
    if venv.exists():
        shutil.rmtree(venv)
    launcher.unlink(missing_ok=True)
    (home / "dash-server.pid").unlink(missing_ok=True)
    # The instance is the user's dashboard repository and secrets: keep it.
    ctx.manifest.delete(RECEIPT, "desired.dash_server")
    return targets


def update(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("Dash Server is not kit-owned; its owner manages updates")
    was_running = status(ctx) == "running"
    if was_running:
        stop(ctx)
    try:
        install(ctx)
        if not validate(ctx):
            raise AddonFailure("Dash Server did not validate after the update")
    except Exception:
        if was_running:
            try:
                start(ctx)
            except (AddonFailure, OSError):
                pass
        raise
    if was_running:
        start(ctx)
    ctx.manifest.set_many({"desired.dash_server": ctx.manifest.get(f"{RECEIPT}.version")})
