"""Manage recorded persona membership without deleting shared resources."""

from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from runtime import AddonFailure, Manifest


ID = re.compile(r"^[a-z0-9][a-z0-9_-]*$")


def remove(root: Path, home: Path, persona_id: str) -> tuple[list[str], bool]:
    if not ID.fullmatch(persona_id):
        raise AddonFailure(f"invalid persona id: {persona_id}")
    path = root / "personas" / f"{persona_id}.json"
    manifest = Manifest(home / "manifest.json")
    with manifest.edit() as doc:
        node = doc.setdefault("persona", {})
        recorded = [item.strip() for item in str(node.get("id", "")).split(",") if item.strip()]
        if not path.is_file() and persona_id not in recorded:
            raise AddonFailure(f"unknown persona: {persona_id}")
        changed = persona_id in recorded
        remaining = [item for item in recorded if item != persona_id]
        if changed:
            node["id"] = ",".join(remaining)
            node["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return remaining, changed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("persona_id")
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parent.parent
    home = Path(os.environ.get("EXAKIT_HOME", str(Path.home() / ".exasol-starter-kit"))).expanduser()
    try:
        remaining, changed = remove(root, home, args.persona_id)
    except AddonFailure as error:
        print(f"persona: {error}", file=sys.stderr)
        return 1
    if changed:
        print(f"Persona removed: {args.persona_id}. Installed datasets and add-ons were kept.")
    else:
        print(f"Persona {args.persona_id} was not recorded; nothing changed.")
    if remaining:
        print("Recorded personas: " + ",".join(remaining))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
