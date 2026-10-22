"""The rules behind `exakit model put | list`, shared by setup/lib/udf-devkit.sh and udf-devkit.ps1 so the two cannot
drift: which name a model file gets in the bucket directory, its digest, when an existing file may be replaced, and
what the kit's record says about each file. Standard library only (any Python 3.9 or later); no database, no network.

    python model_tool.py put <file> <bucket dir> <udf root> <replace 0|1>
        copies <file> to <bucket dir>/models/<its name>; the kit's record of the models (a JSON object, possibly {})
        comes on stdin. Prints three lines: copied|replaced|unchanged, the answer as one JSON object
        {"name", "path", "sha256", "size", "replaced"}, and the record to store back.
        Exit 5 when a file of that name with a DIFFERENT digest is there and <replace> is 0 (nothing is copied),
        exit 2 for input it refuses; the reason on stderr.
    python model_tool.py list <bucket dir> <udf root>
        the files under <bucket dir>/models, each with its digest held against the record (stdin), as one JSON object
        {"bucket_dir", "udf_root", "models": [{"name", "path", "sha256", "size", "recorded_sha256", "status"}],
         "missing"}; status is ok, changed (the digest differs from the record) or unrecorded.

The record is components.udf_devkit.models in the kit's manifest: per name the sha256, size, the /buckets path and when
it was put. Nothing about the database or a credential is read or written here.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

MODELS = "models"                                  # the folder inside the bucket every model lands in
_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$")
_PART = ".part"                                    # a copy in progress; never listed, never a model


class Refused(ValueError):
    """Input the kit refuses; the message names what is wrong. Exit 2."""

    code = 2


class NotConfirmed(Refused):
    """A different file of the same name is there and --replace was not given. Exit 5, like every unconfirmed step."""

    code = 5


def model_name(source: str) -> str:
    """The name a model file keeps in the bucket: its own file name, plain enough for a /buckets path in SQL."""
    name = os.path.basename(source.replace("\\", "/").rstrip("/"))
    if not _NAME.match(name) or name.endswith(_PART):
        raise Refused(f"'{name}' cannot be a model name in the bucket: use letters, digits, '.', '_' and '-' "
                      "(for example churn_model.pkl); rename the file and put it again.")
    return name


def digest(path: Path) -> tuple[str, int]:
    """(sha256 hex, size in bytes) of a file, read in blocks."""
    sha, size = hashlib.sha256(), 0
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            sha.update(block)
            size += len(block)
    return sha.hexdigest(), size


def read_record(text: str) -> dict:
    """The kit's record of the models; anything that is not a JSON object reads as an empty record."""
    try:
        record = json.loads(text) if text.strip() else {}
    except ValueError:
        return {}
    return record if isinstance(record, dict) else {}


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def put(source: str, bucket_dir: str, udf_root: str, replace: bool, record: dict) -> tuple[str, dict, dict]:
    """Copy ``source`` into the bucket's models folder: (what happened, the answer, the record to store)."""
    src = Path(source).expanduser()
    if not src.is_file():
        raise Refused(f"{source} is not a file.")
    name = model_name(str(src))
    folder = Path(bucket_dir) / MODELS
    dest = folder / name
    path = f"{udf_root.rstrip('/')}/{MODELS}/{name}"
    sha, size = digest(src)
    action = "copied"
    if dest.is_file():
        there, _ = digest(dest)
        if there == sha:
            action = "unchanged"
        elif not replace:
            raise NotConfirmed(f"{path} already holds a different file (sha256 {there[:12]}..., this one is "
                               f"{sha[:12]}...). Nothing was copied; --replace overwrites it.")
        else:
            action = "replaced"
    if action != "unchanged":
        folder.mkdir(parents=True, exist_ok=True)
        part = dest.with_name(dest.name + _PART)
        try:
            shutil.copyfile(src, part)
            os.replace(part, dest)
        finally:
            if part.exists():
                part.unlink()
        if digest(dest)[0] != sha:
            raise OSError(f"the copy at {dest} does not match {source}; put it again")
    previous = record.get(name) if isinstance(record.get(name), dict) else {}
    updated = dict(record)
    updated[name] = {"sha256": sha, "size": size, "path": path,
                     "put_at": previous.get("put_at") if action == "unchanged" and previous.get("sha256") == sha
                     else _now()}
    answer = {"name": name, "path": path, "sha256": sha, "size": size, "replaced": action == "replaced"}
    return action, answer, updated


def listing(bucket_dir: str, udf_root: str, record: dict) -> dict:
    """What is in the bucket's models folder, each file's digest held against the record."""
    folder = Path(bucket_dir) / MODELS
    models = []
    if folder.is_dir():
        for path in sorted(p for p in folder.rglob("*") if p.is_file() and not p.name.endswith(_PART)):
            name = path.relative_to(folder).as_posix()
            sha, size = digest(path)
            known = record.get(name) if isinstance(record.get(name), dict) else None
            recorded = known.get("sha256") if known else None
            status = "unrecorded" if not recorded else ("ok" if recorded == sha else "changed")
            models.append({"name": name, "path": f"{udf_root.rstrip('/')}/{MODELS}/{name}", "sha256": sha,
                           "size": size, "recorded_sha256": recorded, "status": status})
    present = {m["name"] for m in models}
    return {"bucket_dir": str(bucket_dir), "udf_root": udf_root.rstrip("/"), "models": models,
            "missing": sorted(name for name in record if name not in present)}


def main(argv: list[str]) -> int:
    command, args = (argv[0], argv[1:]) if argv else ("", [])
    try:
        if command == "put" and len(args) == 4:
            action, answer, updated = put(args[0], args[1], args[2], args[3] == "1", read_record(sys.stdin.read()))
            print(action)
            print(json.dumps(answer))
            print(json.dumps(updated, sort_keys=True))
            return 0
        if command == "list" and len(args) == 2:
            print(json.dumps(listing(args[0], args[1], read_record(sys.stdin.read()))))
            return 0
    except Refused as err:
        print(str(err), file=sys.stderr)
        return err.code
    except OSError as err:
        print(f"{err.__class__.__name__}: {err}", file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
