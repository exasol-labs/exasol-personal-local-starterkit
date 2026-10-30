"""BucketFS path mapping for local UDF files and model artifacts."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from runtime import AddonFailure


@dataclass(frozen=True)
class Bucket:
    directory: Path
    udf_root: str
    mapping: str
    created: bool


def locate(deployment: Path, *, create: bool = True) -> Bucket:
    exa = deployment / "local" / "runtime" / "exa"
    bucketfs = exa / "bucketfs"
    if not exa.is_dir() or not bucketfs.is_dir():
        raise AddonFailure(f"The deployment has no BucketFS folder at {bucketfs}; check exakit status")
    directory = bucketfs / "bfsdefault" / "default"
    udf_root = "/buckets/bfsdefault/default"
    mapping = "default"
    config = exa / "bucketfs.conf"
    if config.is_file():
        selected = None
        external = False
        for raw in config.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 3 and parts[1:3] == ["bfsdefault", "default"]:
                selected = parts
                break
            if len(parts) >= 2 and parts[1] != "__builtin__":
                external = True
        if selected is None and external:
            raise AddonFailure(f"{config} maps no bucket bfsdefault/default; check exakit status")
        if selected:
            inside = selected[0]
            if not inside.startswith("/exa/"):
                raise AddonFailure(f"{config} keeps the bucket at {inside}, outside the deployment's exa folder")
            directory = exa / inside[len("/exa/"):]
            if len(selected) >= 4 and selected[3].startswith("/"):
                udf_root = selected[3]
            mapping = "bucketfs.conf"
    # A crafted config or an existing symlink cannot redirect writes outside
    # the deployment, even though the old shell mapper accepted /exa/../ paths.
    if not directory.resolve().is_relative_to(exa.resolve()):
        raise AddonFailure(f"BucketFS path {directory} leaves the deployment's exa folder")
    created = not directory.is_dir()
    if create and created:
        directory.mkdir(parents=True, mode=0o755, exist_ok=True)
        directory.chmod(0o755)
    return Bucket(directory, udf_root, mapping, created)
