"""Where a reference dataset's CSVs come from when exakit data-load loads it, and the checks they pass first.

Shared by both twins (exakit_dataset_files in exapump.sh, Get-ExakitDatasetFiles in exapump.ps1); standard library
only, Python 3.8 or later. The download itself stays with the shells (curl, WebClient: their proxy and TLS handling);
this decides what is needed, then verifies, extracts and caches what was downloaded.

A dataset whose manifest.json has an "asset" block (tools/datasets/package.py) gets its CSVs, in this order, from:

    1. the kit copy, data/datasets/<id>/data/*.csv, when every file the manifest lists is there with its SHA-256
       (a developer checkout, an EXAKIT_LOCAL_KIT install);
    2. the cache, <cache>/<id>/<sha256>/data/*.csv, an extraction verified when it was made - and again now;
    3. the archive, downloaded by the caller: its SHA-256 must match the manifest, every member must be a plain
       data/<name>.csv the manifest lists (no link, no directory, no absolute path, no ..), and every CSV must match
       its own digest. Only then is it moved into the cache, in one rename.

A dataset without an asset block (tpch, energy, weather) loads from the kit copy as it always has.

    python3 dataset_asset.py resolve <dataset-dir> <cache-root>
        kit                                       no asset block: load <dataset-dir>/data as before
        dir<TAB><path>                            the verified CSVs are in <path>
        fetch<TAB><file><TAB><sha256><TAB><size><TAB><url>   download <file> (url: {repo} still to fill in)
    python3 dataset_asset.py install <dataset-dir> <cache-root> <archive>
        dir<TAB><path>                            verified and cached; the archive is deleted either way

Exit 0 on success; 2 for a bad command line or manifest; 3 when the archive's digest is wrong; 4 when the archive
is unsafe or its CSVs do not match the manifest. The reason is one line on stderr.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
from pathlib import Path

MEMBER = re.compile(r"^data/[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.csv$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MAX_BYTES = 4 * 1024 ** 3          # what an archive may expand to: far above any reference dataset, far below a disk
MARKER = ".verified"


class Refused(Exception):
    """Something the loader must not use; ``code`` is the exit status."""

    def __init__(self, message: str, code: int) -> None:
        super().__init__(message)
        self.code = code


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_manifest(folder: Path) -> dict:
    """manifest.json, or {} when there is none."""
    path = folder / "manifest.json"
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except ValueError as err:
        raise Refused(f"{path} cannot be read ({err})", 2) from err


def asset_of(manifest: dict, folder: Path) -> dict | None:
    """The validated asset block, or None when the dataset has none."""
    asset = manifest.get("asset")
    if asset is None:
        return None
    files = manifest.get("files") or {}
    ok = (isinstance(asset, dict) and isinstance(asset.get("file"), str) and "/" not in asset["file"]
          and "\\" not in asset["file"] and asset["file"] not in ("", ".", "..")
          and SHA256.match(str(asset.get("sha256", ""))) and isinstance(asset.get("size"), int)
          and isinstance(asset.get("url"), str) and files
          and all(MEMBER.match(name) and SHA256.match(str((entry or {}).get("sha256", ""))) for name, entry in files.items()))
    if not ok:
        raise Refused(f"{folder / 'manifest.json'}: the asset block or the file digests are malformed", 2)
    return asset


def _matches(root: Path, files: dict) -> bool:
    """Every listed CSV is under ``root`` with its digest."""
    for name, entry in files.items():
        path = root / name
        if not path.is_file() or _sha256(path) != entry["sha256"]:
            return False
    return True


def resolve(folder: Path, cache: Path) -> str:
    manifest = read_manifest(folder)
    asset = asset_of(manifest, folder)
    if asset is None:
        return "kit"
    files = manifest["files"]
    if _matches(folder, files):
        return f"dir\t{folder / 'data'}"
    if any((folder / "data").glob("*.csv")):
        print(f"{folder.name}: the CSVs in {folder / 'data'} do not match manifest.json; the release asset is used",
              file=sys.stderr)
    entry = cache / manifest.get("id", folder.name) / asset["sha256"]
    if (entry / MARKER).is_file() and _matches(entry, files):
        return f"dir\t{entry / 'data'}"
    if entry.exists():                                  # half-made or tampered with since: made again
        shutil.rmtree(entry, ignore_errors=True)
    return "\t".join(("fetch", asset["file"], asset["sha256"], str(asset["size"]), asset["url"]))


def _extract(archive: Path, into: Path, files: dict) -> None:
    """The listed CSVs out of ``archive`` into ``into``/data, written by this code (tarfile.extract is never used):
    regular members named data/<name>.csv only, each listed, none twice, all present, within MAX_BYTES."""
    (into / "data").mkdir(parents=True)
    seen, total = set(), 0
    try:
        with tarfile.open(archive, mode="r:gz") as tar:
            for member in tar:
                name = member.name
                if name.startswith("./"):
                    name = name[2:]
                if name in ("data", "data/") and member.isdir():
                    continue
                if not member.isreg() or not MEMBER.match(name) or ".." in name.split("/"):
                    raise Refused(f"the archive holds '{member.name}', which is not a plain data/<name>.csv: refused", 4)
                if name not in files or name in seen:
                    raise Refused(f"the archive holds '{name}', which the manifest does not list (or lists once): refused", 4)
                total += member.size
                if total > MAX_BYTES:
                    raise Refused("the archive expands to more than 4 GiB: refused", 4)
                source = tar.extractfile(member)
                if source is None:
                    raise Refused(f"'{name}' cannot be read from the archive", 4)
                with source, (into / name).open("xb") as target:
                    shutil.copyfileobj(source, target, 1 << 20)
                seen.add(name)
    except (tarfile.TarError, OSError, EOFError) as err:
        raise Refused(f"the archive cannot be read ({err})", 4) from err
    missing = sorted(set(files) - seen)
    if missing:
        raise Refused(f"the archive lacks {', '.join(missing)}", 4)
    wrong = [name for name, entry in sorted(files.items()) if _sha256(into / name) != entry["sha256"]]
    if wrong:
        raise Refused(f"{', '.join(wrong)} in the archive do(es) not match the manifest's SHA-256", 4)


def install(folder: Path, cache: Path, archive: Path) -> str:
    manifest = read_manifest(folder)
    asset = asset_of(manifest, folder)
    if asset is None:
        raise Refused(f"{folder.name} has no asset block in manifest.json; nothing to install", 2)
    try:
        if not archive.is_file():
            raise Refused(f"{archive} is not there", 4)
        found = _sha256(archive)
        if found != asset["sha256"]:
            raise Refused(f"{asset['file']}: SHA-256 {found} does not match the manifest's {asset['sha256']}; "
                          "the download was deleted and nothing was loaded", 3)
        home = cache / manifest.get("id", folder.name)
        home.mkdir(parents=True, exist_ok=True)
        entry = home / asset["sha256"]
        work = Path(tempfile.mkdtemp(prefix=".extract-", dir=str(home)))
        try:
            _extract(archive, work, manifest["files"])
            (work / MARKER).write_text(asset["sha256"] + "\n", encoding="ascii")
            if entry.exists():
                shutil.rmtree(entry, ignore_errors=True)
            os.replace(str(work), str(entry))
        finally:
            if work.exists():
                shutil.rmtree(work, ignore_errors=True)
    finally:
        try:
            archive.unlink()
        except OSError:
            pass
    return f"dir\t{entry / 'data'}"


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 3 and argv[0] == "resolve":
            print(resolve(Path(argv[1]), Path(argv[2])))
        elif len(argv) == 4 and argv[0] == "install":
            print(install(Path(argv[1]), Path(argv[2]), Path(argv[3])))
        else:
            print("usage: dataset_asset.py resolve <dataset-dir> <cache-root> | install <dataset-dir> <cache-root> <archive>",
                  file=sys.stderr)
            return 2
    except Refused as err:
        print(err, file=sys.stderr)
        return err.code
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
