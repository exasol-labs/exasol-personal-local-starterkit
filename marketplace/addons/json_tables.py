"""JSON Tables wheel, verified ingest engine and kit-local cargo shim.

JSON queries on a wrapper surface (`exasol-json-tables wrap install`, `ingest-and-wrap`) work in every session of
every user with no setup: the kit builds JSON Tables' own rewriter for the wrappers installed in this database and
registers it as a module of the kit's SQL preprocessor framework (setup/preprocessor/modules/json-tables), after
install and update and after every wrap the kit's launcher runs; it retires it before uninstall. A declined or
absent framework skips the module (the add-on is installed either way) and its verify pass registers it later.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import time
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from urllib.error import HTTPError
from pathlib import Path, PurePosixPath

import kit_telemetry
import preprocessor_modules
from runtime import cmd_file_bytes, AddonFailure, KitContext, cmd_quote, venv_python, host_machine, open_url, probe
from runtime import glibc_floor_reason

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
    arch = host_machine().lower()
    arch = "aarch64" if arch in ("aarch64", "arm64") else "x86_64" if arch in ("x86_64", "amd64") else arch
    if system == "macos" and arch != "aarch64":
        raise AddonFailure("No prebuilt JSON Tables engine is published for Intel macOS")
    if system not in ("macos", "linux", "windows") or arch not in ("aarch64", "x86_64"):
        raise AddonFailure(f"No prebuilt JSON Tables engine is published for {system}/{arch}")
    if system == "windows" and arch != "x86_64":
        raise AddonFailure("No prebuilt JSON Tables engine is published for Windows ARM")
    return system, arch


def applicable(ctx: KitContext) -> bool:
    return not applicable_reason(ctx)


def applicable_reason(ctx: KitContext) -> str:
    try:
        system, arch = _platform()
    except AddonFailure as error:
        return str(error)
    if system == "linux":
        # The Linux engine is linked against the build machine's glibc (WSL included): an older one cannot load it.
        why = glibc_floor_reason(ctx.pinned_document(), ID, f"{system}-{arch}")
        if why:
            return f"The prebuilt JSON Tables engine {why}"
    return ""


def _generator(ctx: KitContext) -> Path:
    return ctx.root / "setup" / "preprocessor" / "modules" / ID / "generate.py"


def _exapump_profile() -> str:
    return os.environ.get("EXAKIT_EXAPUMP_PROFILE", "starter-kit")


def register_module(ctx: KitContext) -> str:
    """Build JSON Tables' module for the wrappers in this database and register it, so JSON queries work in every
    session. Never fatal: a build that fails, or a declined or absent framework, is logged and the add-on stays
    installed; the framework's verify pass (every installer run and `exakit update`) tries again."""
    framework = ctx.manifest.get("components.preprocessor") or {}
    if framework.get("state") != "active" or framework.get("declined"):
        return "skipped"                           # nothing to build for: the framework's own pass registers it
    python = venv_python(paths(ctx)[0])
    with tempfile.TemporaryDirectory(prefix="exakit-json-tables-module-") as temp:
        out = Path(temp) / "json_tables.sql"
        argv = [str(python), str(_generator(ctx)), "--home", str(ctx.home), "--exapump",
                preprocessor_modules.exapump_path(ctx), "--profile", _exapump_profile(), str(out)]
        try:
            done = subprocess.run(argv, capture_output=True, text=True, timeout=preprocessor_modules.TIMEOUT,
                                  check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            ctx.log_event(f"JSON Tables: the SQL preprocessor module was not built ({error})")
            return "failed"
        if done.returncode != 0 or not out.is_file():
            reason = (done.stderr.strip().splitlines() or [f"exit {done.returncode}"])[-1]
            ctx.log_event(f"JSON Tables: the SQL preprocessor module was not built: {reason}")
            return "failed"
        note = (done.stdout.strip().splitlines() or [""])[-1]
        status, message = preprocessor_modules.register(ctx, ID, artifact=out, note=note or None)
    if status != "ok" and message:
        ctx.log_event(f"JSON Tables: {message}")
    return status


def json_sql_active(ctx: KitContext) -> bool:
    """The framework recorded the module as registered (setup/preprocessor/manage.py)."""
    return bool(ctx.manifest.get(f"components.preprocessor.modules.{ID}.version"))


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
    return version if _assets_complete(ctx) else None


def needs_update(ctx: KitContext) -> bool:
    """Installed, but the launcher on disk is one an earlier kit wrote: `exakit update` rewrites it. Never "not
    installed" for that - the 0.2.5 launcher made a kit update skip the add-on and report it absent."""
    return bool(installed_version(ctx)) and not _launchers_current(ctx)


def _assets_complete(ctx: KitContext) -> bool:
    """The engine, the package and (on Windows) the cargo shim are in place: nothing to download again."""
    complete = _engine(ctx).is_file() and _package_ok(ctx)
    if platform.system() == "Windows":
        complete = complete and _shim(ctx).is_file()
    return complete


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
    doc = ctx.pinned_document()                # the kit copy's own pins, never the fetched document (SEC-13)
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
        with open_url(urllib.request.Request(url, headers=headers), timeout=20) as response:
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


PUBLIC_REPO = "exasol-labs/exasol-personal-local-starterkit"


def _api_asset_url(repo: str, tag: str, name: str, headers: dict[str, str]) -> str:
    """The API URL of one release asset, found with the token: a private repository's only download route."""
    request = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/tags/{tag}",
                                     headers={**headers, "Accept": "application/vnd.github+json"})
    with open_url(request, timeout=20) as response:
        doc = json.load(response)
    url = next((a.get("url", "") for a in doc.get("assets", []) if isinstance(a, dict) and a.get("name") == name), "")
    if not url.startswith(f"https://api.github.com/repos/{repo}/releases/assets/"):
        raise AddonFailure(f"JSON Tables release {tag} in {repo} has no asset {name}")
    return url


PHASE_FILE = "EXAKIT_PROGRESS_PHASE_FILE"     # the running progress bar's label: data-load's bar, both shells
_CHUNK = 1 << 16


def _what(key: str) -> str:
    return "the JSON Tables package" if key == "wheel" else "the JSON engine"


def _show_phase(text: str) -> None:
    """Put ``text`` on the bar that is running, if one is. The shell's bar reads its label from the file named by
    EXAKIT_PROGRESS_PHASE_FILE: bash keeps a state record there (``a|b|c|d|label``, only the label changes), the
    PowerShell bar a plain line. No file: nothing (the install's own lines say what it does)."""
    path = os.environ.get(PHASE_FILE)
    if not path:
        return
    try:
        current = Path(path).read_text(encoding="utf-8").strip()
        parts = current.split("|")
        line = "|".join(parts[:4] + [text]) if len(parts) >= 5 else text
        Path(path).write_text(line + "\n", encoding="utf-8")
    except OSError:
        pass


def _copy_with_progress(response, output, what: str) -> None:
    """Copy a download, saying how far it is - "downloading the JSON engine, 6 of 15 MB" - at most twice a
    second, so a slow line reads as progress rather than a hang. Without a known size it counts what arrived."""
    try:
        total = int(response.headers.get("Content-Length") or 0)
    except (TypeError, ValueError, AttributeError):
        total = 0
    done, shown = 0, 0.0
    while True:
        block = response.read(_CHUNK)
        if not block:
            break
        output.write(block)
        done += len(block)
        now = time.monotonic()
        if now - shown >= 0.5:
            shown = now
            mb = done / 1e6
            _show_phase(f"downloading {what}, {mb:.0f} of {total / 1e6:.0f} MB" if total
                        else f"downloading {what}, {mb:.0f} MB")
    if total and total >= 1e6:
        _show_phase(f"downloading {what}, {total / 1e6:.0f} of {total / 1e6:.0f} MB")



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
    # Where the asset may come from, in order. With a pinned checksum any copy is as good as the original, so the
    # public kit repository's copy comes FIRST: one plain download. Then the kit's own repository; a PRIVATE one
    # answers its releases/download link with 404 even to a token, so with GITHUB_TOKEN (or GH_TOKEN) the asset is
    # fetched through the API, as the datasets are (_exakit_dataset_fetch_token). Measured on an install, that API
    # path cost about 30 s of the add-on's 39; the public copy takes about 1 s.
    attempts: list[tuple[str, dict[str, str]]] = []
    if digest and repo != PUBLIC_REPO:
        attempts.append((f"https://github.com/{PUBLIC_REPO}/releases/download/{tag}/{name}", {}))
    attempts.append((f"https://github.com/{repo}/releases/download/{tag}/{name}", {}))
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        attempts.append((f"api:{repo}:{tag}", {"Authorization": f"Bearer {token}"}))
    last: Exception | None = None
    for url, headers in attempts:
        try:
            if url.startswith("api:"):
                url = _api_asset_url(repo, tag, name, headers)
                headers = {**headers, "Accept": "application/octet-stream"}
            with open_url(urllib.request.Request(url, headers=headers), timeout=30) as response, \
                    destination.open("wb") as output:
                if not response.url.startswith("https://"):
                    raise AddonFailure(f"JSON Tables asset {name} redirected away from HTTPS")
                _copy_with_progress(response, output, _what(key))
            last = None
            break
        except (OSError, AddonFailure) as error:
            destination.unlink(missing_ok=True)
            last = error
    if last is not None:
        hint = "" if token else " (a private kit repository needs GITHUB_TOKEN)"
        raise AddonFailure(f"Could not download JSON Tables asset {name}: {last}{hint}") from last
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
    result = probe([str(python), "-c", "import exasol_json_tables; print(exasol_json_tables.__path__[0])"])
    if result is None:
        ctx.activity("JSON Tables' first import did not answer in time; its package data is checked at the next update")
        return
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


def _launcher_files(ctx: KitContext) -> dict[Path, bytes]:
    """What the kit's launcher (and, off Windows, its cargo shim) must hold, byte for byte. Written by
    _write_launchers; a file on disk that differs is stale (installed_version) and the next update rewrites it."""
    venv, home, launcher = paths(ctx)
    shim = _shim(ctx)
    files: dict[Path, bytes] = {}
    if os.name != "nt":
        # Upstream always invokes this one cargo command. The shim is only on
        # PATH for the kit's launcher and delegates every other call to cargo.
        engine = shlex.quote(str(_engine(ctx)))
        shim_dir = shlex.quote(str(shim.parent))
        files[shim] = ("#!/bin/sh\nif [ \"$1\" = run ]; then\n"
                       "  for arg in \"$@\"; do case \"$arg\" in *json_tables_ingest*)\n"
                       "    while [ \"$1\" != -- ] && [ \"$#\" -gt 0 ]; do shift; done\n"
                       "    [ \"$#\" -gt 0 ] && shift\n"
                       f"    exec {engine} \"$@\";; esac; done\nfi\n"
                       f"old_ifs=$IFS\nIFS=:\nfor dir in $PATH; do [ \"$dir\" = {shim_dir} ] && continue; [ -x \"$dir/cargo\" ] && exec \"$dir/cargo\" \"$@\"; done\nIFS=$old_ifs\n"
                       "echo 'cargo is not installed and this is not a JSON Tables ingest call' >&2\nexit 127\n"
                       ).encode("utf-8")
    cli = venv / ("Scripts/exasol-json-tables.exe" if os.name == "nt" else "bin/exasol-json-tables")
    # The ingest CLI connects with pyexasol: its usage telemetry stays off
    # unless the user set the variable (kit_telemetry.py).
    variable, value = kit_telemetry.VARIABLE, kit_telemetry.VALUE
    # A wrap that installs a wrapper surface (wrap install, wrap deploy, ingest-and-wrap) changes what JSON queries
    # the database can answer, so after one succeeds the launcher rebuilds the kit's JSON Tables module and
    # registers it (generate.py --register): the new wrapper works in every session at once, with no ALTER SESSION.
    # Its one line goes to stderr, the CLI's output (--json included) is untouched, and the CLI's exit code is
    # the launcher's. A --help run changes nothing, so it registers nothing.
    python = venv_python(venv)
    register = [python, _generator(ctx), "--register", "--home", ctx.home]
    if os.name == "nt":
        # The Windows cargo shim (setup/shim/json-tables-cargo) finds the engine only through
        # EXAKIT_JSON_TABLES_ENGINE (or a sibling named exasol-json-tables-ingest.exe, which the kit does not
        # place): without it every ingest exited 127. The POSIX shim above carries the engine's path itself.
        files[launcher] = cmd_file_bytes(
            "@echo off\r\nsetlocal\r\nset " + cmd_quote(f"PATH={shim.parent};").rstrip('"') + '%PATH%"\r\n'
            + "set " + cmd_quote(f"EXAKIT_JSON_TABLES_ENGINE={_engine(ctx)}") + "\r\n"
            + f'if not defined {variable} set "{variable}={value}"\r\n'
            + f"{cmd_quote(cli)} %*\r\n"
            + 'set "EXAKIT_JT_RC=%ERRORLEVEL%"\r\n'
            + 'if not "%EXAKIT_JT_RC%"=="0" exit /b %EXAKIT_JT_RC%\r\n'
            + 'if /i "%~2"=="-h" exit /b 0\r\nif /i "%~2"=="--help" exit /b 0\r\n'
            + 'if /i "%~3"=="-h" exit /b 0\r\nif /i "%~3"=="--help" exit /b 0\r\n'
            + 'if /i "%~1"=="ingest-and-wrap" goto exakit_register\r\n'
            + 'if /i not "%~1"=="wrap" exit /b 0\r\n'
            + 'if /i "%~2"=="install" goto exakit_register\r\n'
            + 'if /i "%~2"=="deploy" goto exakit_register\r\n'
            + "exit /b 0\r\n"
            + ":exakit_register\r\n"
            + " ".join(cmd_quote(item) for item in register) + " 1>&2\r\n"
            + "exit /b 0\r\n")
    else:
        quoted = " ".join(shlex.quote(str(item)) for item in register)
        files[launcher] = ("#!/bin/sh\nPATH=" + shlex.quote(str(shim.parent)) + ':"$PATH"\nexport PATH\n'
                           f': "${{{variable}={value}}}"\nexport {variable}\n'
                           'case "$1 ${2:-} ${3:-}" in\n'
                           '    *" -h"|*" -h "*|*" --help"|*" --help "*) exakit_register=0 ;;\n'
                           '    "ingest-and-wrap "*|"wrap install "*|"wrap deploy "*) exakit_register=1 ;;\n'
                           '    *) exakit_register=0 ;;\n'
                           'esac\n'
                           'if [ "$exakit_register" = 0 ]; then\n'
                           "    exec " + shlex.quote(str(cli)) + ' "$@"\n'
                           'fi\n'
                           + shlex.quote(str(cli)) + ' "$@"\n'
                           'exakit_rc=$?\n'
                           'if [ "$exakit_rc" -eq 0 ]; then\n'
                           f"    {quoted} >&2 || :\n"
                           'fi\n'
                           'exit "$exakit_rc"\n').encode("utf-8")
    return files


def _write_launchers(ctx: KitContext) -> None:
    for path, content in _launcher_files(ctx).items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        if os.name != "nt":
            path.chmod(0o755)


def _launchers_current(ctx: KitContext) -> bool:
    """The launcher on disk is the one this kit writes. One an earlier kit wrote (0.2.5's Windows launcher had no
    EXAKIT_JSON_TABLES_ENGINE, so every ingest failed) is not: the add-on then reads as installed and in need of an
    update (needs_update), so `exakit update`, the kit's update and the data load's offer all reach install(), which
    rewrites it."""
    try:
        return all(path.read_bytes() == content for path, content in _launcher_files(ctx).items())
    except OSError:
        return False


# install() fetches files and builds under this add-on's own folders, and writes its receipt through the
# locked manifest: apply.py may run it beside other parallel-safe add-ons (the steps after it stay serial).
PARALLEL_INSTALL = True


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
    if ctx.manifest.get(f"{RECEIPT}.version") == version and _assets_complete(ctx) \
            and os.environ.get("EXAKIT_FORCE_COMPONENT_INSTALL") != "1":
        _write_launchers(ctx)                      # the repair: a launcher an earlier kit wrote is rewritten
        register_module(ctx)
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
        ctx.run_logged(f"Installing JSON Tables {version}", str(ctx.uv), "pip", "install", "--compile-bytecode",
                       "--python", str(python), str(wheel))
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
    register_module(ctx)


def validate(ctx: KitContext) -> bool:
    """One tiny real ingest through the kit's own launcher - the launcher, the cargo shim and the engine together,
    as a user's ingest runs - so a launcher that cannot reach the engine is never reported installed."""
    if not installed_version(ctx):
        return False
    with tempfile.TemporaryDirectory(prefix="exakit-json-check-") as temp:
        source = Path(temp) / "sample.json"
        output = Path(temp) / "out"
        source.write_text('[{"id":1,"name":"alpha","tags":["a","b"]},{"id":2,"name":"beta","tags":[]}]\n')
        launcher = paths(ctx)[2]
        try:
            ctx.run_logged("Checking a JSON ingest through the kit's launcher", str(launcher), "ingest", "--input",
                           str(source), "--output-dir", str(output), timeout=120, cwd=temp)
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
    framework = ctx.manifest.get("components.preprocessor") or {}
    # A slot left to the user's own preprocessor (declined) keeps the modules record but runs none of it.
    if json_sql_active(ctx) and framework.get("state") == "active" and not framework.get("declined"):
        return "ingest JSON: exasol-json-tables; JSON queries on its wrappers work in every session, no setup"
    return "ingest JSON: exasol-json-tables"


def log_path(ctx: KitContext) -> str:
    return str(ctx.path("EXAKIT_JSON_TABLES_LOG", ctx.home / "logs" / "json-tables.log"))


def uninstall(ctx: KitContext, *, dry_run: bool = False) -> list[Path]:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("JSON Tables is not kit-owned; it will not be removed")
    venv, home, launcher = paths(ctx)
    targets = [path for path in (venv, home, launcher) if path.exists()]
    if dry_run:
        # The module retirement below changes the database: the preview names it.
        module = ["JSON queries stop working in every session (the SQL preprocessor's JSON Tables module is switched "
                  "off); your wrapper schemas and their data stay"] if json_sql_active(ctx) else []
        return module + targets
    # The module goes first: nothing may rewrite JSON queries for an add-on that is gone. The wrapper schemas are
    # the user's data and stay. A registered module whose retire failed leaves its rule live, so nothing is removed and
    # it is said.
    registered = json_sql_active(ctx)
    status, message = preprocessor_modules.retire(ctx, ID)
    if status == "failed" and registered:
        raise AddonFailure(f"{message}; nothing was removed. Retry with: exakit uninstall {ID}")
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
