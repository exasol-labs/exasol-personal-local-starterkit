"""The persona record in the kit's manifest: the one Python writer of it, and `exakit persona remove`.

The record is ``persona.id`` (the ids joined by commas, in the kit's order), ``persona.source`` (install or add)
and ``persona.requested_at``; a removal adds ``updated_at``. Writing is idempotent: when the ids do not change
nothing is written, so a second ``exakit persona add`` or a re-run of the installer with the same EXAKIT_PERSONA
leaves the manifest byte for byte as it was. Membership is recorded; the datasets, add-ons and notebooks a persona
brought are never deleted here.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from runtime import AddonFailure, Manifest


ID = re.compile(r"^[a-z0-9][a-z0-9_-]*$")


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ids(value: object) -> list[str]:
    return [item.strip() for item in str(value or "").split(",") if item.strip()]


def home_dir() -> Path:
    return Path(os.environ.get("EXAKIT_HOME", str(Path.home() / ".exasol-starter-kit"))).expanduser()


def record(home: Path, ids: str, source: str = "install") -> tuple[str, bool]:
    """Record ``ids`` (comma-joined, already in the kit's order and already merged by the caller when adding)
    as the kit's personas. Replaces what was recorded; writes nothing when that is already the record, keeping
    its source and time. An empty ``ids`` clears the record. Returns (the ids recorded, whether anything changed)."""
    wanted = _ids(ids)
    for item in wanted:
        if not ID.fullmatch(item):
            raise AddonFailure(f"invalid persona id: {item}")
    manifest = Manifest(home / "manifest.json")
    with manifest.edit() as doc:
        node = doc.get("persona") if isinstance(doc.get("persona"), dict) else {}
        if _ids(node.get("id")) == wanted:
            return ",".join(wanted), False
        doc["persona"] = {**node, "id": ",".join(wanted), "source": source, "requested_at": _now()}
    return ",".join(wanted), True


def remove(root: Path, home: Path, persona_id: str) -> tuple[list[str], bool]:
    """Take one persona off the record. A persona that is not recorded changes nothing (and writes nothing)."""
    if not ID.fullmatch(persona_id):
        raise AddonFailure(f"invalid persona id: {persona_id}")
    path = root / "personas" / f"{persona_id}.json"
    manifest = Manifest(home / "manifest.json")
    with manifest.edit() as doc:
        node = doc.get("persona") if isinstance(doc.get("persona"), dict) else {}
        recorded = _ids(node.get("id"))
        if not path.is_file() and persona_id not in recorded:
            raise AddonFailure(f"unknown persona: {persona_id}")
        changed = persona_id in recorded
        remaining = [item for item in recorded if item != persona_id]
        if changed:
            doc["persona"] = {**node, "id": ",".join(remaining), "updated_at": _now()}
    return remaining, changed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("record", "remove"))
    parser.add_argument("ids", help="a persona id, or several joined by commas (record)")
    parser.add_argument("--source", default="install", help="record: install or add")
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parent.parent
    try:
        if args.action == "record":
            ids, changed = record(home_dir(), args.ids, args.source)
            print(f"Recorded personas: {ids or 'none'}" + ("" if changed else " (unchanged)"))
            return 0
        remaining, changed = remove(root, home_dir(), args.ids)
    except AddonFailure as error:
        print(f"persona: {error}", file=sys.stderr)
        return 2
    if changed:
        print(f"Persona removed: {args.ids}. Installed datasets and add-ons were kept.")
    else:
        print(f"Persona {args.ids} was not recorded; nothing changed.")
    print("Recorded personas: " + (",".join(remaining) or "none"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
