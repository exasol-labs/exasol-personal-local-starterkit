"""Prepare a verified standard Python SLC with an isolated kit alias.

Only build_info/language_definitions.json changes. The archive is streamed,
never extracted. The original remains intact and the cached derivative carries
both its original and output SHA-256 digests.
"""
from __future__ import annotations

import copy
import gzip
import hashlib
import io
import json
import re
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath

METADATA = "build_info/language_definitions.json"


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        result = hashlib.sha256()
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
        return result.hexdigest()


def prepare(source: Path, target: Path, alias: str, expected: str) -> Path:
    if not re.fullmatch(r"[A-Z][A-Z0-9_]{0,127}", alias):
        raise ValueError("The isolated container alias must be an uppercase SQL identifier.")
    if source.resolve() == target.resolve():
        raise ValueError("The original container must not be overwritten.")
    if digest(source) != expected:
        raise ValueError("The source container does not match its pinned SHA-256.")
    record = target.with_suffix(target.suffix + ".json")
    identity = {"schema_version": 1, "source_sha256": expected, "alias": alias}
    try:
        cached = json.loads(record.read_text())
        if all(cached.get(k) == v for k, v in identity.items()) and digest(target) == cached["sha256"]:
            return target
    except (OSError, ValueError, KeyError):
        pass
    # Streaming needs only the compressed output plus a little headroom.
    if shutil.disk_usage(target.parent).free < source.stat().st_size * 2 + 256 * 1024**2:
        raise ValueError("Not enough disk space to prepare the isolated ML container.")
    part = target.with_suffix(target.suffix + ".part")
    found = False
    try:
        with tarfile.open(source, "r|gz") as incoming, part.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=1, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w|") as outgoing:
                    for member in incoming:
                        stream = incoming.extractfile(member) if member.isfile() else None
                        if str(PurePosixPath(member.name)) == METADATA:
                            if found or not member.isfile() or member.size > 1024 * 1024:
                                raise ValueError("The container has invalid or duplicate language definitions.")
                            doc = json.load(stream)
                            definitions = doc.get("language_definitions", [])
                            if len(definitions) != 1 or not isinstance(definitions[0], dict):
                                raise ValueError("Expected a single Python language definition in the ML container.")
                            definition = definitions[0]
                            if not any(p.get("key") == "lang" and p.get("value") == "python"
                                       for p in definition.get("parameters", [])):
                                raise ValueError("The ML container does not declare the Python language.")
                            definition["aliases"] = [alias]
                            body = (json.dumps(doc, indent=2) + "\n").encode()
                            member = copy.copy(member)
                            member.size = len(body)
                            stream = io.BytesIO(body)
                            found = True
                        outgoing.addfile(member, stream)
        if not found:
            raise ValueError("The ML container has no language definitions to isolate.")
        result = {**identity, "sha256": digest(part), "size": part.stat().st_size}
        part.replace(target)
        record.write_text(json.dumps(result, indent=2) + "\n")
        return target
    finally:
        part.unlink(missing_ok=True)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("slc_archive.py SOURCE TARGET ALIAS SOURCE_SHA256", file=sys.stderr)
        return 2
    try:
        print(prepare(Path(argv[0]), Path(argv[1]), argv[2], argv[3]))
        return 0
    except (OSError, ValueError, tarfile.TarError) as error:
        print(f"Cannot prepare the isolated ML container: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
