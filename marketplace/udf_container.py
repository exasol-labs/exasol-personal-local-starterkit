"""Version-matrix selection and verified UDF container assets."""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

from runtime import AddonFailure, KitContext


HEX = re.compile(r"^[0-9a-fA-F]{64}$")
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def _rules(root: Path):
    import sys

    sys.path.insert(0, str(root / "setup" / "udf"))
    try:
        import udf_tool

        return udf_tool
    finally:
        sys.path.pop(0)


def select(ctx: KitContext, language: str, arch: str, database_version: str) -> dict:
    if language not in ("python", "rust"):
        raise AddonFailure("UDF language must be python or rust")
    document = ctx.versions_document()
    try:
        row = _rules(ctx.root).resolve_container(document, language, arch, database_version)
    except ValueError as error:
        raise AddonFailure(str(error)) from error
    for key in ("url", "sha256", "size"):
        if key not in row:
            raise AddonFailure(f"{language} container row has no {key}")
    _asset_identity(row)
    return row


def _asset_identity(asset: dict) -> tuple[str, int, str]:
    url, digest, size = asset.get("url"), asset.get("sha256"), asset.get("size")
    parsed = urllib.parse.urlparse(url) if isinstance(url, str) else None
    if parsed and parsed.scheme == "https" and parsed.hostname and not (parsed.username or parsed.password or parsed.query or parsed.fragment):
        name = Path(parsed.path).name
    elif url is None and asset.get("bundled_path"):
        name = Path(str(asset["bundled_path"])).name
    else:
        raise AddonFailure("UDF asset needs an HTTPS release URL or a bundled path")
    if not NAME.fullmatch(name):
        raise AddonFailure("UDF asset has an unsafe file name")
    if not isinstance(digest, str) or not HEX.fullmatch(digest):
        raise AddonFailure(f"UDF asset {name} has no SHA-256 pin")
    if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
        raise AddonFailure(f"UDF asset {name} has no size pin")
    return name, size, digest.lower()


def verify(path: Path, asset: dict) -> None:
    name, size, digest = _asset_identity(asset)
    if path.stat().st_size != size:
        raise AddonFailure(f"UDF asset {name} does not match its pinned size")
    with path.open("rb") as input_file:
        actual = hashlib.file_digest(input_file, "sha256").hexdigest()
    if actual != digest:
        raise AddonFailure(f"UDF asset {name} does not match its pinned SHA-256")


def fetch(ctx: KitContext, asset: dict) -> Path:
    name, _, _ = _asset_identity(asset)
    if not isinstance(asset.get("url"), str) or not asset["url"].startswith("https://"):
        raise AddonFailure(f"UDF asset {name} has no HTTPS release URL and is not bundled")
    cache = ctx.path("EXAKIT_UDF_CONTAINER_CACHE", ctx.home / "cache" / "containers")
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / name
    if destination.is_file():
        try:
            verify(destination, asset)
            return destination
        except AddonFailure:
            destination.unlink()
    mirror = os.environ.get("EXAKIT_UDF_CONTAINERS_MIRROR", "")
    if mirror:
        if mirror.startswith("https://"):
            parsed = urllib.parse.urlparse(mirror)
            if not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
                raise AddonFailure("EXAKIT_UDF_CONTAINERS_MIRROR must be a plain HTTPS base URL")
            source = mirror.rstrip("/") + "/" + name
        elif mirror.startswith("file://"):
            parsed = urllib.parse.urlparse(mirror)
            if parsed.netloc not in ("", "localhost"):
                raise AddonFailure("EXAKIT_UDF_CONTAINERS_MIRROR file:// must name a local folder")
            source = Path(urllib.request.url2pathname(parsed.path)) / name
        elif "://" in mirror:
            raise AddonFailure("EXAKIT_UDF_CONTAINERS_MIRROR must be a folder, file:// or https:// URL")
        else:
            source = Path(mirror).expanduser() / name
    else:
        source = asset["url"]
    fd, temporary = tempfile.mkstemp(prefix=name + ".", suffix=".part", dir=cache)
    try:
        with os.fdopen(fd, "wb") as output:
            if isinstance(source, Path):
                with source.open("rb") as input_file:
                    shutil.copyfileobj(input_file, output)
            else:
                with urllib.request.urlopen(source, timeout=30) as response:
                    redirected = urllib.parse.urlparse(response.url)
                    if redirected.scheme != "https" or not redirected.hostname or redirected.username or redirected.password:
                        raise AddonFailure("UDF asset redirected away from HTTPS")
                    shutil.copyfileobj(response, output)
            output.flush()
            os.fsync(output.fileno())
        verify(Path(temporary), asset)
        os.replace(temporary, destination)
    except (OSError, ValueError) as error:
        raise AddonFailure(f"Could not fetch verified UDF asset {name}: {error}") from error
    finally:
        Path(temporary).unlink(missing_ok=True)
    return destination


def rust_smoke(ctx: KitContext, row: dict) -> Path:
    asset = row.get("smoke_asset")
    if not isinstance(asset, dict):
        raise AddonFailure("Rust smoke library is not pinned in versions.json")
    _asset_identity(asset)
    bundled = asset.get("bundled_path")
    if bundled:
        path = Path(bundled)
        if path.parts[:3] != ("udf", "rust-smoke", "prebuilt") or len(path.parts) != 4 or not NAME.fullmatch(path.name):
            raise AddonFailure("Rust smoke library has an unsafe bundled path")
        local = ctx.root / path
        if local.is_file():
            verify(local, asset)
            return local
    return fetch(ctx, asset)
