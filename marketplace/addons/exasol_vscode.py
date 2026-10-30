"""Exasol editor extension lifecycle for VS Code and compatible forks."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import urllib.request
from pathlib import Path

from runtime import AddonFailure, KitContext

ID = "exasol-vscode"
RECEIPT = "components.exasol_vscode"
EXTENSION_ID = "exasol.exasol-vscode"
REPO = "exasol-labs/exasol-vscode"


def code_cli(ctx: KitContext) -> Path | None:
    recorded = ctx.manifest.get(f"{RECEIPT}.code_cli")
    if recorded and Path(recorded).is_file():
        return Path(recorded)
    for name in ("code", "code-insiders", "cursor", "windsurf", "codium"):
        found = shutil.which(name)
        if found:
            return Path(found)
    candidates = [
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        "~/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        "/usr/share/code/bin/code",
        "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders",
        "~/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders",
        "/usr/share/code-insiders/bin/code-insiders",
        "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
        "~/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
        "/usr/share/cursor/bin/cursor",
        "/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf",
        "~/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf",
        "/usr/share/windsurf/bin/windsurf",
        "/Applications/VSCodium.app/Contents/Resources/app/bin/codium",
        "~/Applications/VSCodium.app/Contents/Resources/app/bin/codium",
        "/usr/share/codium/bin/codium",
    ]
    return next((candidate for raw in candidates if (candidate := Path(raw).expanduser()).is_file()), None)


def _wsl_windows_cli(cli: Path) -> bool:
    return bool(os.environ.get("WSL_INTEROP") or os.environ.get("WSL_DISTRO_NAME")) and (
        str(cli).startswith("/mnt/") or cli.suffix.lower() in (".cmd", ".exe", ".bat"))


def _host_path(cli: Path, path: Path) -> str:
    if _wsl_windows_cli(cli) and shutil.which("wslpath"):
        result = subprocess.run(["wslpath", "-w", str(path)], capture_output=True, text=True, check=False)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    return str(path)


def _code_args(cli: Path, *args: str) -> list[str]:
    extdir = os.environ.get("EXAKIT_EXASOL_VSCODE_EXTDIR")
    prefix = [str(cli)]
    if extdir:
        prefix += ["--extensions-dir", _host_path(cli, Path(extdir))]
    return [*prefix, *args]


def live_version(ctx: KitContext) -> str | None:
    cli = code_cli(ctx)
    if not cli:
        return None
    try:
        result = subprocess.run(_code_args(cli, "--list-extensions", "--show-versions"),
                                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                check=False, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        name, _, version = line.strip().partition("@")
        if name.lower() == EXTENSION_ID and version:
            return version
    return None


def installed_version(ctx: KitContext) -> str | None:
    return live_version(ctx) if ctx.manifest.get(f"{RECEIPT}.version") else None


def system_present(ctx: KitContext) -> bool:
    return not ctx.manifest.get(f"{RECEIPT}.version") and bool(live_version(ctx))


def applicable(ctx: KitContext) -> bool:
    return code_cli(ctx) is not None


def _release_digest(version: str, asset_name: str) -> str | None:
    url = f"https://api.github.com/repos/{REPO}/releases/tags/v{version}"
    with urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"}),
                                timeout=20) as response:
        doc = json.load(response)
    for asset in doc.get("assets", []):
        if asset.get("name") == asset_name:
            digest = asset.get("digest", "")
            if digest.startswith("sha256:") and len(digest) == 71:
                return digest[7:]
    return None


def expected_digest(ctx: KitContext, version: str, asset_name: str) -> str | None:
    doc = ctx.versions_document()
    block = doc.get("components", {}).get(ID, {})
    if version == block.get("version"):
        digest = block.get("sha256", {}).get("vsix")
        if isinstance(digest, str) and len(digest) == 64 and all(c in "0123456789abcdef" for c in digest):
            return digest
    try:
        return _release_digest(version, asset_name)
    except (OSError, ValueError):
        return None


def _stage_for_wsl(cli: Path, source: Path) -> Path:
    if not _wsl_windows_cli(cli):
        return source
    if shutil.which("cmd.exe") and shutil.which("wslpath"):
        result = subprocess.run(["cmd.exe", "/c", "echo %TEMP%"], capture_output=True, text=True, check=False)
        if result.returncode == 0:
            converted = subprocess.run(["wslpath", "-u", result.stdout.strip()],
                                       capture_output=True, text=True, check=False)
            if converted.returncode == 0:
                folder = Path(converted.stdout.strip())
                if folder.is_dir() and os.access(folder, os.W_OK):
                    destination = folder / source.name
                    shutil.copy2(source, destination)
                    return destination
    for folder in (Path("/mnt/c/Windows/Temp"), Path("/mnt/c/Temp")):
        if folder.is_dir() and os.access(folder, os.W_OK):
            destination = folder / source.name
            shutil.copy2(source, destination)
            return destination
    raise AddonFailure("A Windows editor CLI needs a writable Windows temporary folder for the VSIX")


def install(ctx: KitContext, *, force: bool = False) -> None:
    from model import load_addons

    if ctx.manifest.get(f"{RECEIPT}.ownership") in ("user", "unknown"):
        return
    if system_present(ctx):
        return  # A user-installed extension remains the user's installation.
    cli = code_cli(ctx)
    if not cli:
        raise AddonFailure("No VS Code-compatible editor CLI was found")
    default = next(item.default_version for item in load_addons(ctx.root) if item.id == ID)
    version = ctx.target_version(ID, default)
    if live_version(ctx) != version or force:
        asset = f"exasol-vscode-{version}.vsix"
        digest = expected_digest(ctx, version, asset)
        if not digest and os.environ.get("EXAKIT_ALLOW_UNVERIFIED_EXASOL_VSCODE") != "1":
            raise AddonFailure("No trusted VSIX checksum is available; refusing the download")
        url = f"https://github.com/{REPO}/releases/download/v{version}/{asset}"
        with tempfile.TemporaryDirectory(prefix="exakit-vscode-") as temp:
            archive = Path(temp) / asset
            try:
                with urllib.request.urlopen(url, timeout=30) as response, archive.open("wb") as out:
                    if not response.url.startswith("https://"):
                        raise AddonFailure("The VSIX download redirected away from HTTPS")
                    shutil.copyfileobj(response, out)
            except OSError as error:
                raise AddonFailure(f"Could not download verified VSIX {asset}: {error}") from error
            with archive.open("rb") as downloaded:
                actual = hashlib.file_digest(downloaded, "sha256").hexdigest()
            if digest and actual != digest:
                raise AddonFailure(f"VSIX checksum mismatch for {asset}")
            staged = _stage_for_wsl(cli, archive)
            try:
                ctx.run_logged("Installing Exasol for VS Code", *_code_args(cli, "--install-extension",
                               _host_path(cli, staged), "--force"))
            finally:
                if staged != archive:
                    staged.unlink(missing_ok=True)
        if live_version(ctx) != version:
            raise AddonFailure("VS Code does not list the requested extension version after installation")
    ctx.manifest.set_many({f"{RECEIPT}.version": version, f"{RECEIPT}.extension_id": EXTENSION_ID,
                           f"{RECEIPT}.code_cli": str(cli), f"{RECEIPT}.ownership": "kit",
                           f"{RECEIPT}.validated": True})


def validate(ctx: KitContext) -> bool:
    valid = bool(live_version(ctx))
    ctx.manifest.set_many({f"{RECEIPT}.validated": valid})
    return valid


def update(ctx: KitContext) -> None:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("The extension is not kit-owned; its owner manages updates")
    install(ctx)
    ctx.manifest.set_many({"desired.exasol_vscode": ctx.manifest.get(f"{RECEIPT}.version")})


def applicable_reason(ctx: KitContext) -> str:
    return ("VS Code was not found, and neither was a compatible fork (VS Code Insiders, Cursor, "
            "VSCodium or Windsurf). Install one and put its CLI on PATH, then run: exakit marketplace")


def summary(ctx: KitContext) -> str:
    return "Exasol view in VS Code's sidebar"


def uninstall(ctx: KitContext, *, dry_run: bool = False) -> list[str]:
    if ctx.manifest.get(f"{RECEIPT}.ownership") != "kit":
        raise AddonFailure("The extension is not kit-owned; it will not be removed")
    if dry_run:
        return [EXTENSION_ID] if live_version(ctx) else []
    cli = code_cli(ctx)
    if cli and live_version(ctx):
        ctx.run_logged("Removing Exasol for VS Code", *_code_args(cli, "--uninstall-extension", EXTENSION_ID))
        if live_version(ctx):
            raise AddonFailure("VS Code still lists the extension after removal")
    ctx.manifest.delete(RECEIPT, "desired.exasol_vscode")
    return [EXTENSION_ID]
