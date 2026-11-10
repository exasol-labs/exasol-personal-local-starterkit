"""Edit a deployment's saved sidecar definitions (Exasol Personal 2.4.0+ sidecars.yaml).

The launcher keeps each local deployment's sidecars in <deployment>/sidecars.yaml
(mode 0600) and accepts edits to it; `exasol start` reconciles a running
deployment with what is saved. The kit edits it for the sidecars it runs:

    sidecar_definition.py literal-env <sidecars.yaml> <name> NAME=@<file> [NAME=<value> ...]
        Make the named env entries literal values; @<file> reads the value from
        a file (a password stays off every command line). Prints "changed" or
        "unchanged"; exit 2 when the sidecar is not saved there.
    sidecar_definition.py put <sidecars.yaml> <name> <definition.json>
        Save <name> as the definition in the JSON file (container, endpoints,
        enabled). An env entry {"name": N, "valueFile": <path>} becomes a
        literal value read from that file, so the JSON never holds a secret.
        Prints "changed" or "unchanged".
    sidecar_definition.py drop <sidecars.yaml> <name>
        Remove <name>. Prints "changed" or "unchanged".

Needs PyYAML: the kit runs this as `uv run --no-project --with PyYAML==<pin>`.
No value is ever printed.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

import yaml


def _load(path: Path) -> dict:
    if not path.exists():
        return {"version": 1, "sidecars": {}}
    document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(document, dict):
        raise SystemExit(f"{path} is not a sidecar document")
    document.setdefault("version", 1)
    if not isinstance(document.get("sidecars"), dict):
        document["sidecars"] = {}
    return document


def _save(path: Path, document: dict) -> None:
    text = yaml.safe_dump(document, sort_keys=False, default_flow_style=False)
    handle, temporary = tempfile.mkstemp(prefix=".sidecars.", dir=str(path.parent))
    try:
        os.chmod(temporary, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as output:
            output.write(text)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def literal_env(path: Path, name: str, assignments: list[str]) -> bool:
    document = _load(path)
    sidecar = document["sidecars"].get(name)
    if not isinstance(sidecar, dict) or not isinstance(sidecar.get("container"), dict):
        raise LookupError(name)
    env = sidecar["container"].setdefault("env", [])
    changed = False
    for assignment in assignments:
        variable, _, raw = assignment.partition("=")
        value = Path(raw[1:]).read_text(encoding="utf-8").strip() if raw.startswith("@") else raw
        wanted = {"name": variable, "value": value}
        for index, entry in enumerate(env):
            if isinstance(entry, dict) and entry.get("name") == variable:
                if entry != wanted:
                    env[index] = wanted
                    changed = True
                break
        else:
            env.append(wanted)
            changed = True
    if changed:
        _save(path, document)
    return changed


def put(path: Path, name: str, definition: dict) -> bool:
    for entry in (definition.get("container") or {}).get("env") or []:
        if isinstance(entry, dict) and "valueFile" in entry:
            entry["value"] = Path(entry.pop("valueFile")).read_text(encoding="utf-8").strip()
    document = _load(path)
    if document["sidecars"].get(name) == definition:
        return False
    document["sidecars"][name] = definition
    _save(path, document)
    return True


def drop(path: Path, name: str) -> bool:
    document = _load(path)
    if name not in document["sidecars"]:
        return False
    del document["sidecars"][name]
    _save(path, document)
    return True


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    command, path, name = argv[0], Path(argv[1]), argv[2]
    try:
        if command == "literal-env":
            changed = literal_env(path, name, argv[3:])
        elif command == "put" and len(argv) == 4:
            changed = put(path, name, json.loads(Path(argv[3]).read_text(encoding="utf-8")))
        elif command == "drop":
            changed = drop(path, name)
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except LookupError:
        print(f"sidecar '{name}' is not saved in {path}", file=sys.stderr)
        return 2
    print("changed" if changed else "unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
