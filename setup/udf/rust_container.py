"""Verified Rust SLC overlays for deployments without a shared bucket directory.

Keep the pinned runtime intact, add only kit-managed libraries under /opt/exakit,
and replace the RUST container through the launcher's supported update command.
No archive is extracted and no credentials enter a tarball or launcher argument.
"""
from __future__ import annotations

import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath

LIBRARY_ROOT = "opt/exakit/udf"


def bucket_visible(conn, path: str, expected: str) -> bool:
    """Prove the host copy is readable with the same digest inside a UDF."""
    if not re.fullmatch(r"/buckets/[A-Za-z0-9_./-]+", path) or ".." in PurePosixPath(path).parts:
        raise ValueError("The Rust bucket path is invalid.")
    conn.execute("CREATE SCHEMA IF NOT EXISTS EXAKIT_UDF")
    conn.execute('''CREATE OR REPLACE PYTHON3 SCALAR SCRIPT EXAKIT_UDF.RUST_FILE_SHA(p VARCHAR(2000))
RETURNS VARCHAR(64) AS
import hashlib
def run(ctx):
    try:
        value = hashlib.sha256()
        with open(ctx.p, 'rb') as source:
            for block in iter(lambda: source.read(1048576), b''):
                value.update(block)
        return value.hexdigest()
    except OSError:
        return None
''')
    rows = conn.execute(f"SELECT EXAKIT_UDF.RUST_FILE_SHA('{path}') AS SHA256").fetchall()
    if not rows:
        return False
    return (rows[0].get("SHA256") if isinstance(rows[0], dict) else rows[0][0]) == expected


def current_receipt(home: Path, row: dict) -> dict:
    """A verified retained overlay, or an empty record; never triggers an update."""
    state = home / "rust-udfs/.container"
    try:
        record = json.loads((state / "installed.json").read_text())
        if not isinstance(record, dict) or not isinstance(record.get("libraries"), dict):
            return {}
        if (record.get("active", True) is not True or record.get("base_sha256") != row["sha256"] or
                digest(state / "rust-with-libraries.tar.gz") != record.get("container_sha256")):
            return {}
        return record
    except (OSError, ValueError, TypeError):
        return {}


def installed_library(home: Path, row: dict, name: str, expected: str) -> dict:
    record = current_receipt(home, row)
    entry = record.get("libraries", {}).get(name)
    if isinstance(entry, dict) and entry.get("sha256") == expected:
        library = home / "rust-udfs/.container" / (expected + ".so")
        if library.is_file() and digest(library) == expected:
            return record
    return {}


def invalidate(home: Path) -> None:
    """A base-container replacement deactivates the overlay, keeping its libraries."""
    path = home / "rust-udfs/.container/installed.json"
    if not path.is_file():
        return
    record = json.loads(path.read_text())
    record["active"] = False
    part = path.with_suffix(".part")
    part.write_text(json.dumps(record, indent=2) + "\n")
    os.replace(part, path)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def source_archive(home: Path, row: dict) -> Path:
    """Use the pinned cached archive, or a verified mirror/download of that asset."""
    cache = home / "cache/containers"
    name = Path(urllib.parse.urlsplit(row["url"]).path).name
    target = cache / name
    expected, size = row["sha256"], row["size"]
    if target.is_file() and target.stat().st_size == size and digest(target) == expected:
        return target
    mirror = os.environ.get("EXAKIT_UDF_CONTAINERS_MIRROR", "")
    address = row["url"]
    local = None
    if mirror:
        if mirror.startswith("https://"):
            address = mirror.rstrip("/") + "/" + name
        elif mirror.startswith("file://"):
            local = Path(urllib.request.url2pathname(urllib.parse.urlsplit(mirror).path)) / name
        elif "://" not in mirror:
            local = Path(mirror).expanduser() / name
        else:
            raise ValueError("The container mirror must be a folder, file:// or https:// URL.")
    parsed = urllib.parse.urlsplit(address)
    if parsed.scheme != "https" or parsed.username or parsed.password:
        raise ValueError("Container downloads require HTTPS without credentials in the URL.")
    cache.mkdir(parents=True, exist_ok=True)
    part = None
    try:
        with tempfile.NamedTemporaryFile(dir=cache, prefix=".rust-source-", delete=False) as output:
            part = Path(output.name)
            incoming = local.open("rb") if local else urllib.request.urlopen(address, timeout=30)
            with incoming:
                total = 0
                while block := incoming.read(1024 * 1024):
                    total += len(block)
                    if total > size:
                        raise ValueError("The Rust container exceeds its pinned size.")
                    output.write(block)
        if part.stat().st_size != size or digest(part) != expected:
            raise ValueError("The Rust container does not match its pinned size and SHA-256.")
        os.replace(part, target)
        return target
    finally:
        if part is not None:
            part.unlink(missing_ok=True)


def pack(source: Path, target: Path, expected: str, libraries: dict[str, Path]) -> None:
    """Stream the pinned runtime unchanged and append verified library payloads."""
    if digest(source) != expected:
        raise ValueError("The source Rust container does not match its pinned SHA-256.")
    if source.resolve() == target.resolve():
        raise ValueError("The pinned Rust container must not be overwritten.")
    for name, path in libraries.items():
        if PurePosixPath(name).name != name or not name.startswith("lib") or not name.endswith(".so"):
            raise ValueError("A packaged Rust library must have a plain lib<name>.so filename.")
        if not path.is_file():
            raise ValueError("A previously deployed Rust library is missing; the container was not replaced.")
    needed = source.stat().st_size * 2 + sum(p.stat().st_size for p in libraries.values()) + 64 * 1024**2
    if shutil.disk_usage(target.parent).free < needed:
        raise ValueError("Not enough disk space to prepare the Rust container fallback.")
    part = target.with_suffix(target.suffix + ".part")
    try:
        with tarfile.open(source, "r|gz") as incoming, part.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=1) as compressed:
                with tarfile.open(fileobj=compressed, mode="w|") as output:
                    for member in incoming:
                        path = PurePosixPath(member.name)
                        if path.is_absolute() or ".." in path.parts:
                            raise ValueError("The Rust container has an unsafe archive member.")
                        if path == PurePosixPath(LIBRARY_ROOT) or PurePosixPath(LIBRARY_ROOT) in path.parents:
                            raise ValueError("The pinned container already uses the kit's library directory.")
                        output.addfile(member, incoming.extractfile(member) if member.isfile() else None)
                    for name, path in sorted(libraries.items()):
                        member = tarfile.TarInfo(f"{LIBRARY_ROOT}/{name}")
                        member.mode = 0o644
                        member.size = path.stat().st_size
                        with path.open("rb") as handle:
                            output.addfile(member, handle)
        os.replace(part, target)
    finally:
        part.unlink(missing_ok=True)


def install(home: Path, row: dict, library: Path, expected: str, launcher: str, deployment: Path) -> dict:
    """Preserve earlier libraries, update RUST, then record the successful overlay."""
    if not launcher or not Path(launcher).is_file() or not deployment.is_dir():
        raise ValueError("The launcher or deployment directory is unavailable; run exakit status.")
    if digest(library) != expected:
        raise ValueError("The Rust library changed before packaging; rebuild it.")
    state = home / "rust-udfs" / ".container"
    state.mkdir(parents=True, exist_ok=True)
    lock = state / "update.lock"
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise ValueError("A Rust container update is already in progress; retry after it finishes.") from error
    try:
        receipt = state / "installed.json"
        recorded = json.loads(receipt.read_text()) if receipt.is_file() else {}
        libraries = {}
        records = dict(recorded.get("libraries", {}))
        for name, entry in records.items():
            if not re.fullmatch(r"[0-9a-f]{64}", str(entry.get("sha256", ""))):
                raise ValueError("A previous Rust library receipt is invalid; the container was not replaced.")
            path = state / (entry["sha256"] + ".so")
            if not path.is_file() or digest(path) != entry["sha256"]:
                raise ValueError("A previously deployed Rust library failed verification; the container was not replaced.")
            libraries[name] = path
        saved = state / (expected + ".so")
        if not saved.is_file() or digest(saved) != expected:
            part = saved.with_suffix(".part")
            try:
                shutil.copyfile(library, part)
                if digest(part) != expected:
                    raise ValueError("The Rust library changed while being copied.")
                os.replace(part, saved)
            finally:
                part.unlink(missing_ok=True)
        libraries[library.name] = saved
        records[library.name] = {"sha256": expected}
        source = source_archive(home, row)
        archive = state / "rust-with-libraries.tar.gz"
        pack(source, archive, row["sha256"], libraries)
        completed = subprocess.run([launcher, "slc", "custom", "update", "--source", str(archive),
            "--alias", "RUST", "--language", "rust", "--deployment-dir", str(deployment),
            "--auto-approve"], capture_output=True, text=True, check=False)
        if completed.returncode:
            # Launcher output may carry machine connection details: keep it out
            # of notebook/CLI output, and never claim a successful deployment.
            raise ValueError("The launcher could not update the RUST container; run exakit logs and exakit status.")
        result = {"schema_version": 1, "active": True, "base_sha256": row["sha256"], "container_sha256": digest(archive),
                  "libraries": records, "database_restart_requested": True}
        part = receipt.with_suffix(".part")
        part.write_text(json.dumps(result, indent=2) + "\n")
        os.replace(part, receipt)
        return result
    finally:
        lock.rmdir()


def main(argv: list[str]) -> int:
    """Internal smoke fallback shared by the two installers (no SQL credentials)."""
    if len(argv) == 2 and argv[0] == "invalidate":
        try:
            invalidate(Path(argv[1]))
            return 0
        except (OSError, ValueError, TypeError):
            print("Could not deactivate the retained Rust overlay record.", file=sys.stderr)
            return 6
    check = bool(argv and argv[0] == "check")
    if check:
        argv = argv[1:]
    if len(argv) != 7:
        print("Expected LIBRARY SHA256 VERSIONS ARCH KIT_HOME LAUNCHER DEPLOYMENT.", file=sys.stderr)
        return 2
    library, expected, versions, arch, home, launcher, deployment = argv
    try:
        rows = json.loads(Path(versions).read_text())["components"]["udf-devkit"]["containers"]
        matches = [row for row in rows if row.get("language") == "rust" and row.get("arch") == arch]
        if len(matches) != 1:
            raise ValueError("There is no unique pinned Rust container for this architecture.")
        if check:
            return 0 if installed_library(Path(home), matches[0], Path(library).name, expected) else 1
        print(json.dumps(install(Path(home), matches[0], Path(library), expected, launcher, Path(deployment))))
        return 0
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError):
        print("The Rust smoke container fallback failed; check exakit status, disk space and the container mirror.", file=sys.stderr)
        return 6


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
