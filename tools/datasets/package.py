"""Package a reference dataset's CSVs as the release asset exakit data-load downloads, and record it in the manifest.

The CSVs stay in git, where they can be reviewed, but the kit archive users install leaves them out (.gitattributes,
export-ignore): exakit data-load fetches them as one archive per dataset, checks its SHA-256 against manifest.json,
then checks every CSV against its own digest (data/README.md, "How a reference dataset reaches the database").

    python3 tools/datasets/package.py                      # every reference dataset (each folder with a manifest.json)
    python3 tools/datasets/package.py pharma_trials        # one; --dist DIR writes the archives there (default: dist/)

The archive is <id>-<snapshot>.tar.gz and is DETERMINISTIC: the same CSVs give the same bytes, so the digest in the
manifest is reproducible and a rebuild that changes nothing changes nothing. The members are data/<name>.csv, sorted,
regular files only, with a fixed mtime (the snapshot date), mode 0644, uid/gid 0 and no user or group names; the
gzip header carries no name and mtime 0. ``tar_sha256`` is the digest of the uncompressed tar stream: it depends on
the CSVs alone, not on the zlib that compressed them, so tools/dataset_check.py can prove offline that the asset in
the manifest is the one these CSVs make. The asset block written into manifest.json:

    "asset": {"file": "<id>-<snapshot>.tar.gz", "sha256": ..., "size": ..., "tar_sha256": ...,
              "url": "https://github.com/{repo}/releases/download/datasets-<id>-<snapshot>/<file>"}

{repo} is filled in at load time (EXAKIT_DATASETS_REPO, else the repository the kit was installed from). Upload the
archive to that release tag - the tag is per dataset and snapshot, so a new snapshot is a new release and an old kit
keeps finding the archive its manifest names.

Exit 0 when every archive was written, 1 when a dataset cannot be packaged (its manifest does not match its CSVs),
2 for a bad command line.
"""

from __future__ import annotations

import datetime as dt
import gzip
import hashlib
import io
import json
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATASETS = ROOT / "data" / "datasets"
DIST = ROOT / "dist"
URL = "https://github.com/{repo}/releases/download/datasets-%(id)s-%(snapshot)s/%(file)s"


def csv_paths(folder: Path) -> list[Path]:
    """The dataset's CSVs, in archive order."""
    return sorted((folder / "data").glob("*.csv"), key=lambda p: p.name)


def tar_bytes(folder: Path, snapshot: str) -> bytes:
    """The uncompressed tar stream of data/*.csv: same CSVs, same bytes."""
    mtime = int(dt.datetime.combine(dt.date.fromisoformat(snapshot), dt.time(), dt.timezone.utc).timestamp())
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for path in csv_paths(folder):
            data = path.read_bytes()
            info = tarfile.TarInfo(f"data/{path.name}")
            info.size, info.mtime, info.mode = len(data), mtime, 0o644
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.type = tarfile.REGTYPE
            tar.addfile(info, io.BytesIO(data))
    return out.getvalue()


def gzip_bytes(raw: bytes) -> bytes:
    """``raw`` gzipped with no file name and mtime 0 in the header."""
    out = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=out, compresslevel=9, mtime=0) as handle:
        handle.write(raw)
    return out.getvalue()


def asset_name(manifest: dict) -> str:
    return f"{manifest['id']}-{manifest['snapshot']}.tar.gz"


def asset_url(manifest: dict) -> str:
    """The download URL template for the dataset's asset ({repo} left for the loader)."""
    return URL % {"id": manifest["id"], "snapshot": manifest["snapshot"], "file": asset_name(manifest)}


def file_digests(folder: Path) -> dict[str, str]:
    """{data/<name>.csv: sha256} of the CSVs on disk."""
    return {f"data/{p.name}": hashlib.sha256(p.read_bytes()).hexdigest() for p in csv_paths(folder)}


def package(folder: Path, dist: Path) -> dict:
    """Write dist/<id>-<snapshot>.tar.gz and the manifest's asset block; the block. ValueError when the manifest's
    files do not match the CSVs (rebuild or run tools/dataset_check.py --manifest first) or it has no snapshot."""
    path = folder / "manifest.json"
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if not manifest.get("snapshot"):
        raise ValueError(f"{folder.name}: manifest.json has no snapshot date")
    listed = {name: entry.get("sha256") for name, entry in (manifest.get("files") or {}).items()}
    if not listed or listed != file_digests(folder):
        raise ValueError(f"{folder.name}: manifest.json files do not match data/*.csv - "
                         f"run: python3 tools/dataset_check.py data/datasets/{folder.name} --manifest")
    raw = tar_bytes(folder, manifest["snapshot"])
    packed = gzip_bytes(raw)
    dist.mkdir(parents=True, exist_ok=True)
    (dist / asset_name(manifest)).write_bytes(packed)
    asset = {"file": asset_name(manifest), "sha256": hashlib.sha256(packed).hexdigest(), "size": len(packed),
             "tar_sha256": hashlib.sha256(raw).hexdigest(), "url": asset_url(manifest)}
    ordered = {}
    for key, value in manifest.items():                 # the asset block sits before files, which it describes
        if key == "asset":
            continue
        if key == "files":
            ordered["asset"] = asset
        ordered[key] = value
    ordered.setdefault("asset", asset)
    path.write_text(json.dumps(ordered, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return asset


def reference_folders() -> list[Path]:
    """Every dataset folder with a manifest.json: the reference datasets, which ship as release assets."""
    return sorted(p.parent for p in DATASETS.glob("*/manifest.json"))


def main(argv: list[str]) -> int:
    dist, names, args = DIST, [], iter(argv)
    for arg in args:
        if arg == "--dist":
            dist = Path(next(args, "") or ".").resolve()
        elif arg.startswith("-"):
            print(f"unknown option {arg}\n\n{__doc__}")
            return 2
        else:
            names.append(arg)
    folders = [DATASETS / n for n in names] if names else reference_folders()
    missing = [f.name for f in folders if not (f / "manifest.json").is_file()]
    if missing:
        print(f"not a reference dataset (no manifest.json): {', '.join(missing)}")
        return 2
    status = 0
    for folder in folders:
        try:
            asset = package(folder, dist)
        except ValueError as err:
            print(err)
            status = 1
            continue
        print(f"{folder.name}: {dist / asset['file']}  {asset['size']} bytes  sha256 {asset['sha256']}")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
