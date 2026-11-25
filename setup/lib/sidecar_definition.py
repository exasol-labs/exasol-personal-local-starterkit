"""Edit a deployment's saved sidecar definitions (Exasol Personal 2.4.0+ sidecars.yaml).

The launcher keeps each local deployment's sidecars in <deployment>/sidecars.yaml
(mode 0600) and accepts edits to it; `exasol start` reconciles a running
deployment with what is saved. The kit edits it for the sidecars it runs:

    sidecar_definition.py literal-env <sidecars.yaml> <name> NAME=@<file> [NAME=<value> ...]
        Make the named env entries literal values; @<file> reads the value from
        a file (a password stays off every command line). Prints "changed" or
        "unchanged"; exit 2 when the sidecar is not saved there.
    sidecar_definition.py put <sidecars.yaml> <name> <definition.json> [--keep-foreign]
        Save <name> as the definition in the JSON file (container, endpoints,
        enabled). An env entry {"name": N, "valueFile": <path>} becomes a
        literal value read from that file, so the JSON never holds a secret.
        Prints "changed" or "unchanged". With --keep-foreign (the caller has
        no record of writing <name> there), a <name> already saved with
        another definition is the user's own: it is kept as it is, "foreign"
        is printed and the exit code is 3.
    sidecar_definition.py drop <sidecars.yaml> <name>
        Remove <name>. Prints "changed" or "unchanged".
    sidecar_definition.py is-kits <sidecars.yaml> <name> <login> <host port>
        Exit 0 when <name> is saved there as the kit writes it: EXA_USER is
        the literal <login> (the kit's read-only login) and a port of its
        container is published on <host port>. Exit 1 otherwise (another
        login, one taken from the deployment's secret, another port, nothing
        saved, no file). Prints nothing. A kit before 0.3.1 kept no record of
        the folder it wrote its sidecar in: this is its proof.

Needs PyYAML: the kit runs this as `uv run --no-project --with PyYAML==<pin>`.
No value is ever printed: a failure is one stderr line naming the error's
kind and where it is, never the text around it (sidecars.yaml holds the
password as a literal value, and PyYAML's own messages quote the document).

The JSON and the value files are read as utf-8-sig: Windows PowerShell 5.1
writes UTF-8 with a BOM, and json.loads refuses one.
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
        value = Path(raw[1:]).read_text(encoding="utf-8-sig").strip() if raw.startswith("@") else raw
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


class Foreign(Exception):
    """A sidecar of that name is saved, and the kit did not write it."""


def put(path: Path, name: str, definition: dict, keep_foreign: bool = False) -> bool:
    for entry in (definition.get("container") or {}).get("env") or []:
        if isinstance(entry, dict) and "valueFile" in entry:
            entry["value"] = Path(entry.pop("valueFile")).read_text(encoding="utf-8-sig").strip()
    document = _load(path)
    if document["sidecars"].get(name) == definition:
        return False
    # THE USER'S OWN SIDECAR OF THAT NAME (OWN-04): a deployment the kit
    # adopted can carry the launcher's own MCP server, set up by its user. It
    # is never replaced by the kit's.
    if keep_foreign and name in document["sidecars"]:
        raise Foreign(name)
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


def is_kits(path: Path, name: str, login: str, host_port: str) -> bool:
    """The saved <name> signs in as <login> (a literal EXA_USER) and publishes
    a port on <host_port>: the definition the kit writes. A sidecar of the
    user's own (the launcher's catalog entry signs in with the deployment's
    own user, from its secret) is not."""
    if not path.exists():
        return False
    sidecar = _load(path)["sidecars"].get(name)
    container = sidecar.get("container") if isinstance(sidecar, dict) else None
    if not isinstance(container, dict):
        return False
    signs_in = any(isinstance(entry, dict) and entry.get("name") == "EXA_USER" and "valueFrom" not in entry
                   and isinstance(entry.get("value"), str) and entry["value"] == login
                   for entry in container.get("env") or [])
    publishes = any(isinstance(port, dict) and str(port.get("hostPort")) == host_port
                    for port in container.get("ports") or [])
    return signs_in and publishes


def _describe(error: Exception) -> str:
    """The error's kind and position, without the text it was reading: a YAML
    error's str() carries a snippet of sidecars.yaml, which holds a password."""
    kind = type(error).__name__
    if isinstance(error, json.JSONDecodeError):
        return f"{kind}: {error.msg} (line {error.lineno}, column {error.colno})"
    if isinstance(error, yaml.MarkedYAMLError) and error.problem_mark is not None:
        mark = error.problem_mark
        return f"{kind} at line {mark.line + 1}, column {mark.column + 1}"
    if isinstance(error, OSError):
        return f"{kind}: {error.strerror} ({error.filename})"
    return kind


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    command, path, name = argv[0], Path(argv[1]), argv[2]
    if command == "is-kits":
        if len(argv) != 5:
            print(__doc__, file=sys.stderr)
            return 2
        try:
            return 0 if is_kits(path, name, argv[3], argv[4]) else 1
        except Exception as error:  # noqa: BLE001 - one safe line instead of a traceback
            print(f"sidecar_definition.py {command} failed: {_describe(error)}", file=sys.stderr)
            return 1
    try:
        if command == "literal-env":
            changed = literal_env(path, name, argv[3:])
        elif command == "put" and (len(argv) == 4 or (len(argv) == 5 and argv[4] == "--keep-foreign")):
            changed = put(path, name, json.loads(Path(argv[3]).read_text(encoding="utf-8-sig")),
                          keep_foreign=len(argv) == 5)
        elif command == "drop":
            changed = drop(path, name)
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Foreign:
        print("foreign")
        return 3
    except LookupError:
        print(f"sidecar '{name}' is not saved in {path}", file=sys.stderr)
        return 2
    except Exception as error:  # noqa: BLE001 - one safe line instead of a traceback
        print(f"sidecar_definition.py {command} failed: {_describe(error)}", file=sys.stderr)
        return 1
    print("changed" if changed else "unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
