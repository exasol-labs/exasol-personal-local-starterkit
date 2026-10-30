"""JSON Tables wheel, verified ingest engine and kit-local cargo shim."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from urllib.error import HTTPError
from pathlib import Path, PurePosixPath

from runtime import AddonFailure, KitContext, venv_python

ID = "json-tables"
RECEIPT = "components.json_tables"


def paths(ctx: KitContext) -> tuple[Path, Path, Path]:
    engine = ctx.manifest.get(f"{RECEIPT}.engine") if ctx.manifest.get(f"{RECEIPT}.ownership") == "kit" else None
    return (ctx.owned_path(RECEIPT, "venv", "EXAKIT_JSON_TABLES_VENV", ctx.home / "json-tables-venv"),
            Path(engine).parent.parent if engine else ctx.path("EXAKIT_JSON_TABLES_HOME", ctx.home / "json-tables"),
            ctx.owned_path(RECEIPT, "command", "EXAKIT_JSON_TABLES_BIN", ctx.bin_dir / ("exasol-json-tables.cmd" if os.name == "nt" else "exasol-json-tables")))


def _platform() -> tuple[str, str]:
    system = platform.system().lower()
    system = "macos" if system == "darwin" else "windows" if system == "windows" else system
    arch = platform.machine().lower()
    arch = "aarch64" if arch in ("aarch64", "arm64") else "x86_64" if arch in ("x86_64", "amd64") else arch
    if system == "macos" and arch != "aarch64":
        raise AddonFailure("No prebuilt JSON Tables engine is published for Intel macOS")
    if system not in ("macos", "linux", "windows") or arch not in ("aarch64", "x86_64"):
        raise AddonFailure(f"No prebuilt JSON Tables engine is published for {system}/{arch}")
    if system == "windows" and arch != "x86_64":
        raise AddonFailure("No prebuilt JSON Tables engine is published for Windows ARM")
    return system, arch


def applicable(ctx: KitContext) -> bool:
    try:
        _platform()
        return True
    except AddonFailure:
        return False


def applicable_reason(ctx: KitContext) -> str:
    try:
        _platform()
    except AddonFailure as error:
        return str(error)
    return ""


def _engine(ctx: KitContext) -> Path:
    return paths(ctx)[1] / "libexec" / ("json_to_parquet.exe" if os.name == "nt" else "json_to_parquet")


def _shim(ctx: KitContext) -> Path:
    return paths(ctx)[1] / "shim" / ("cargo.exe" if os.name == "nt" else "cargo")


def _package_ok(ctx: KitContext) -> bool:
    python = venv_python(paths(ctx)[0])
    if not python.is_file():
        return False
    try:
        result = subprocess.run([str(python), "-c", "import exasol_json_tables"], capture_output=True,
                                check=False, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def installed_version(ctx: KitContext) -> str | None:
    version = ctx.manifest.get(f"{RECEIPT}.version")
    if not version:
        return None
    complete = _engine(ctx).is_file() and _package_ok(ctx)
    if platform.system() == "Windows":
        complete = complete and _shim(ctx).is_file()
    return version if version and complete else None


def system_present(ctx: KitContext) -> bool:
    if ctx.manifest.get(f"{RECEIPT}.version"):
        return False
    found = shutil.which("exasol-json-tables")
    if found and Path(found) != paths(ctx)[2]:
        return True
    ambient = shutil.which("python3") or shutil.which("python")
    if not ambient or Path(ambient).is_relative_to(ctx.home):
        return False
    try:
        result = subprocess.run([ambient, "-c", "import exasol_json_tables"], capture_output=True,
                                check=False, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def _release_info(ctx: KitContext, version: str) -> tuple[str, str, dict]:
    doc = ctx.versions_document()
    pinned = doc.get("components", {}).get(ID, {})
    same = version == pinned.get("version")
    tag = os.environ.get("EXAKIT_JSON_TABLES_MIRROR_TAG") or (pinned.get("release") if same else None) or f"json-tables-{version}"
    source = ctx.manifest.get("kit.source", "")
    source_repo = source.split("@", 1)[0]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", source_repo):
        source_repo = None
    repo = os.environ.get("EXAKIT_JSON_TABLES_MIRROR_REPO") or source_repo or os.environ.get("EXAKIT_KIT_REPO", "exasol-labs/exasol-personal-local-starterkit")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) or not re.fullmatch(r"[A-Za-z0-9_.-]+", tag):
        raise AddonFailure("Invalid JSON Tables release source")
    return repo, tag, pinned if same and not os.environ.get("EXAKIT_JSON_TABLES_MIRROR_TAG") else {}


def _api_assets(repo: str, tag: str) -> dict[str, dict]:
    url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    headers = {"Accept": "application/vnd.github+json"}
    if token := os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=20) as response:
            doc = json.load(response)
    except (ValueError, TypeError) as error:
        raise AddonFailure("Malformed JSON Tables release metadata") from error
    except HTTPError as error:
        if error.code == 404:
            raise AddonFailure(f"JSON Tables release {tag} was not found in {repo}; run the pkg / json-tables workflow") from error
        if error.code in (403, 429):
            raise AddonFailure("GitHub refused the JSON Tables release lookup; retry later or set GITHUB_TOKEN") from error
        raise AddonFailure(f"JSON Tables release lookup failed (HTTP {error.code})") from error
    assets = doc.get("assets") if isinstance(doc, dict) else None
    if not isinstance(assets, list):
        raise AddonFailure("Malformed JSON Tables release metadata")
    return {asset["name"]: asset for asset in assets
            if isinstance(asset, dict) and isinstance(asset.get("name"), str)}


def _asset(ctx: KitContext, repo: str, tag: str, name: str, key: str, pins: dict,
           api_assets: dict[str, dict] | None, destination: Path) -> None:
    digest = pins.get("sha256", {}).get(key)
    if not digest and api_assets:
        published = api_assets.get(name, {}).get("digest", "")
        if isinstance(published, str) and published.startswith("sha256:"):
            digest = published[7:]
    if not digest and os.environ.get("EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES") != "1":
        raise AddonFailure(
            f"No trusted checksum for JSON Tables asset {name}. Retry with exakit update json-tables; "
            f"the pin belongs in versions.json (components.json-tables.sha256.{key}). "
            "A maintainer may explicitly set EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES=1 for an unverified install"
        )
    if digest and not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise AddonFailure(f"Invalid checksum for JSON Tables asset {name}")
    url = f"https://github.com/{repo}/releases/download/{tag}/{name}"
    try:
        with urllib.request.urlopen(url, timeout=30) as response, destination.open("wb") as output:
            if not response.url.startswith("https://"):
                raise AddonFailure(f"JSON Tables asset {name} redirected away from HTTPS")
            shutil.copyfileobj(response, output)
    except OSError as error:
        destination.unlink(missing_ok=True)
        raise AddonFailure(f"Could not download JSON Tables asset {name}: {error}") from error
    if digest:
        with destination.open("rb") as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if actual != digest:
            destination.unlink(missing_ok=True)
            raise AddonFailure(f"Checksum mismatch for JSON Tables asset {name}")
        ctx.log_event(f"Checksum verified: {name} sha256:{actual}")


def _restore_package_data(ctx: KitContext, version: str) -> None:
    """Restore upstream's omitted preprocessor asset without overwriting files."""
    python = venv_python(paths(ctx)[0])
    result = subprocess.run([str(python), "-c", "import exasol_json_tables; print(exasol_json_tables.__path__[0])"],
                            capture_output=True, text=True, check=False, timeout=10)
    if result.returncode != 0:
        return
    site = Path(result.stdout.strip())
    if not site.is_dir():
        return
    url = f"https://github.com/exasol-labs/exasol-json-tables/archive/{version}.tar.gz"
    with tempfile.TemporaryDirectory(prefix="exakit-json-data-") as temp:
        archive = Path(temp) / "source.tar.gz"
        try:
            with urllib.request.urlopen(url, timeout=30) as response, archive.open("wb") as output:
                if not response.url.startswith("https://"):
                    return
                shutil.copyfileobj(response, output)
            with tarfile.open(archive, "r:gz") as source:
                anchor = "/python/exasol_json_tables/"
                for member in source:
                    if not member.isfile() or anchor not in member.name:
                        continue
                    relative = PurePosixPath(member.name.split(anchor, 1)[1])
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
            return


def _write_launchers(ctx: KitContext) -> None:
    venv, home, launcher = paths(ctx)
    shim = _shim(ctx)
    shim.parent.mkdir(parents=True, exist_ok=True)
    if os.name != "nt":
        # Upstream always invokes this one cargo command. The shim is only on
        # PATH for the kit's launcher and delegates every other call to cargo.
        engine = shlex.quote(str(_engine(ctx)))
        shim_dir = shlex.quote(str(shim.parent))
        shim.write_text("#!/bin/sh\nif [ \"$1\" = run ]; then\n"
                        "  for arg in \"$@\"; do case \"$arg\" in *json_tables_ingest*)\n"
                        "    while [ \"$1\" != -- ] && [ \"$#\" -gt 0 ]; do shift; done\n"
                        "    [ \"$#\" -gt 0 ] && shift\n"
                        f"    exec {engine} \"$@\";; esac; done\nfi\n"
                        f"old_ifs=$IFS\nIFS=:\nfor dir in $PATH; do [ \"$dir\" = {shim_dir} ] && continue; [ -x \"$dir/cargo\" ] && exec \"$dir/cargo\" \"$@\"; done\nIFS=$old_ifs\n"
                        "echo 'cargo is not installed and this is not a JSON Tables ingest call' >&2\nexit 127\n",
                        encoding="utf-8")
        shim.chmod(0o755)
    launcher.parent.mkdir(parents=True, exist_ok=True)
    cli = venv / ("Scripts/exasol-json-tables.exe" if os.name == "nt" else "bin/exasol-json-tables")
    if os.name == "nt":
        launcher.write_text(f'@echo off\r\nset "PATH={shim.parent};%PATH%"\r\n"{cli}" %*\r\n', encoding="utf-8")
    else:
        launcher.write_text("#!/bin/sh\nPATH=" + shlex.quote(str(shim.parent)) + ':"$PATH"\nexport PATH\nexec '
                            + shlex.quote(str(cli)) + ' "$@"\n', encoding="utf-8")
        launcher.chmod(0o755)


def install(ctx: KitContext) -> None:
    from model import load_addons

    if ctx.manifest.get(f"{RECEIPT}.ownership") in ("user", "unknown"):
        return
    if system_present(ctx):
        return
    ctx.require_uv()
    if not applicable(ctx):
        raise AddonFailure(applicable_reason(ctx))
    default = next(addon.default_version for addon in load_addons(ctx.root) if addon.id == ID)
    version = ctx.target_version(ID, default)
    if installed_version(ctx) == version and os.environ.get("EXAKIT_FORCE_COMPONENT_INSTALL") != "1":
        _write_launchers(ctx)
        return
    repo, tag, pins = _release_info(ctx, version)
    system, arch = _platform()
    platform_key = f"{system}-{arch}"
    engine_name = f"exasol-json-tables-ingest-{platform_key}" + (".exe" if system == "windows" else "")
    assets = None
    wheel_name = pins.get("wheel")
    required_digests = ("wheel", platform_key)
    if system == "windows":
        required_digests += ("cargo-windows-x86_64",)
    if not wheel_name or any(not pins.get("sha256", {}).get(key) for key in required_digests):
        try:
            assets = _api_assets(repo, tag)
        except OSError as error:
            raise AddonFailure(f"Cannot read JSON Tables release {repo}/{tag}: {error}") from error
        wheels = [name for name in assets if name.endswith(".whl") and name.startswith("exasol_json_tables-")]
        if not wheel_name:
            wheel_name = next(iter(sorted(wheels)), None)
    if not wheel_name:
        raise AddonFailure(f"Release {tag} has no JSON Tables wheel")
    venv, home, launcher = paths(ctx)
    python = venv_python(venv)
    if not python.is_file():
        ctx.run_logged("Creating JSON Tables environment", str(ctx.uv), "venv", "--seed", "--python", ctx.managed_python_version, str(venv))
    with tempfile.TemporaryDirectory(prefix="exakit-json-tables-") as temp:
        wheel = Path(temp) / wheel_name
        _asset(ctx, repo, tag, wheel_name, "wheel", pins, assets, wheel)
        ctx.run_logged(f"Installing JSON Tables {version}", str(ctx.uv), "pip", "install", "--python", str(python), str(wheel))
        _restore_package_data(ctx, version)
        engine = Path(temp) / engine_name
        _asset(ctx, repo, tag, engine_name, platform_key, pins, assets, engine)
        _engine(ctx).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(engine, _engine(ctx))
        if os.name != "nt":
            _engine(ctx).chmod(0o755)
        if os.name == "nt":
            shim_name = "exakit-json-tables-cargo-windows-x86_64.exe"
            shim_temp = Path(temp) / shim_name
            _asset(ctx, repo, tag, shim_name, "cargo-windows-x86_64", pins, assets, shim_temp)
            _shim(ctx).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(shim_temp, _shim(ctx))
    ctx.run_logged("Checking JSON Tables engine", str(_engine(ctx)), "--help")
    if not _package_ok(ctx):
        raise AddonFailure("The JSON Tables wheel cannot be imported after installation")
    _write_launchers(ctx)
    ctx.manifest.set_many({f"{RECEIPT}.version": version, f"{RECEIPT}.venv": str(venv),
                           f"{RECEIPT}.python": str(python), f"{RECEIPT}.engine": str(_engine(ctx)),
                           f"{RECEIPT}.command": str(launcher), f"{RECEIPT}.ownership": "kit"})


def validate(ctx: KitContext) -> bool:
    if not installed_version(ctx):
        return False
    with tempfile.TemporaryDirectory(prefix="exakit-json-check-") as temp:
        source = Path(temp) / "sample.json"
        output = Path(temp) / "out"
        source.write_text('[{"id":1,"name":"alpha"},{"id":2,"name":"beta"}]\n')
        try:
            ctx.run_logged("Checking JSON to Parquet ingest", str(_engine(ctx)), "--input", str(source),
                           "--output-dir", str(output), timeout=60)
            valid = any(output.rglob("*.parquet"))
        except AddonFailure:
            valid = False
    ctx.manifest.set_many({f"{RECEIPT}.validated": valid})
    return valid


def latest(ctx: KitContext) -> str:
    from model import load_addons

    default = next(addon.default_version for addon in load_addons(ctx.root) if addon.id == ID)
    return ctx.target_version(ID, default)


def summary(ctx: KitContext) -> str:
    return "ingest JSON: exasol-json-tables"


def log_path(ctx: KitContext) -> str:
    return str(ctx.path("EXAKIT_JSON_TABLES_LOG", ctx.home / "logs" / "json-tables.log"))


def uninstall(ctx: KitContext, *, dry_run: bool = False) -> list[Path]:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("JSON Tables is not kit-owned; it will not be removed")
    venv, home, launcher = paths(ctx)
    targets = [path for path in (venv, home, launcher) if path.exists()]
    if dry_run:
        return targets
    for path in targets:
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
    ctx.manifest.delete(RECEIPT, "desired.json_tables")
    return targets


def update(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("JSON Tables is not kit-owned; its owner manages updates")
    install(ctx)
    if not validate(ctx):
        raise AddonFailure("JSON Tables did not validate after the update")
    ctx.manifest.set_many({"desired.json_tables": ctx.manifest.get(f"{RECEIPT}.version")})
