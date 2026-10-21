"""persona_service.py - the personas, as one Python service both installers call.

The shell (persona.sh) and PowerShell (persona.ps1) halves of the kit ask this file every persona question, so the
rules live once: which personas the install question offers, what several ticked together add up to, which of the
installer's answers they fill in (an answer the user gave always wins, per variable), and which personas a dataset is
for. Standard library only, and Python 3.9 compatible: it runs on whatever Python 3 the machine has (run_python_any).

    python3 persona_service.py <kit_root> picker                 id|title|summary|default for each persona the question
                                                                 offers (default: 1 for the ones ticked to begin with)
    python3 persona_service.py <kit_root> ids                    every persona id, one per line
    python3 persona_service.py <kit_root> check <ids>            the ids in the kit's order; exit 2 naming an unknown id
    python3 persona_service.py <kit_root> title <ids>            the combined title: General + ML Engineer
    python3 persona_service.py <kit_root> value <id> <key>       one key: a string as it is, a list as a,b,c
    python3 persona_service.py <kit_root> answers <ids>          KEY=value for each answer still open (the environment
                                                                 says which are given)
    python3 persona_service.py <kit_root> dataset-hints          dataset|persona titles, for the data menu
    python3 persona_service.py <kit_root> show <id>              the lines `exakit persona show` prints

<ids> is one id or several joined by commas. Every value printed is an id, a list of ids or a title: no secrets, no
paths. Exit codes: 0 done, 2 bad input (an unknown persona or key), 1 a persona file that cannot be read.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ID = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
LISTS = ("datasets", "mcp_clients", "addons", "notebook_tools")
ANSWERS = (                       # (persona key, the installer variable it answers, variables that mean it was answered)
    ("datasets", "EXAKIT_DATASETS", ("EXAKIT_DATASETS", "EXAKIT_LOAD_SAMPLE")),
    ("mcp_clients", "EXAKIT_MCP_CLIENTS", ("EXAKIT_MCP_CLIENTS",)),
    ("addons", "EXAKIT_MARKETPLACE_ADDONS", ("EXAKIT_MARKETPLACE_ADDONS",)),
    ("notebook_tools", "EXAKIT_NOTEBOOK_FRONTENDS", ("EXAKIT_NOTEBOOK_FRONTENDS",)),
)


class BadInput(Exception):
    """An unknown persona or key: exit 2."""


def personas(root: Path) -> dict:
    """Every persona file of the kit, by id, in the order the question offers them."""
    found = {}
    for path in sorted((root / "personas").glob("*.json")):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as err:
            raise OSError(f"{path} cannot be read ({err})") from err
        if doc.get("id") != path.stem or not ID.match(path.stem):
            raise OSError(f"{path}: its id must be its file name")
        found[path.stem] = doc
    return dict(sorted(found.items(), key=lambda item: (int(item[1].get("order", 100)), item[0])))


def picked(root: Path, ids: str) -> list:
    """The personas named, in the kit's order; BadInput naming an unknown one."""
    known = personas(root)
    wanted = [i.strip() for i in ids.split(",") if i.strip()]
    unknown = [i for i in wanted if i not in known]
    if unknown or not wanted:
        raise BadInput(f"Unknown persona '{','.join(unknown) or ids}' (available: {' '.join(known)}).")
    return [known[i] for i in known if i in wanted]


def combined(docs: list, key: str) -> str:
    """What several personas say together: "all" when any says all, "none"/"skip" only when every one does, else the
    union of their lists in order. A single persona's value comes back as it is."""
    values = [doc.get(key) for doc in docs if doc.get(key) not in (None, "", [])]
    if not values:
        return ""
    if "all" in values:
        return "all"
    lists = [v for v in values if isinstance(v, list)]
    if not lists:                                    # only words: none, skip
        return str(values[0])
    seen = []
    for items in lists:
        for item in items:
            if item not in seen:
                seen.append(item)
    return ",".join(seen)


def answers(root: Path, ids: str, env: dict) -> list:
    """KEY=value lines for the answers the personas fill in: only the variables the user left unset."""
    docs = picked(root, ids)
    lines = []
    for key, variable, given in ANSWERS:
        if any(env.get(name, "") for name in given):
            continue
        if variable == "EXAKIT_MCP_CLIENTS" and env.get("EXAKIT_SKIP_MCP") == "1":
            continue                                 # the AI bridge is skipped: no clients to answer
        value = combined(docs, key)
        if key == "datasets" and value == "none":
            lines.append("EXAKIT_LOAD_SAMPLE=0")
        elif value:
            lines.append(f"{variable}={value}")
    lines.append(f"EXAKIT_PERSONA={','.join(doc['id'] for doc in docs)}")
    return lines


def value(root: Path, persona_id: str, key: str) -> str:
    """One key of one persona: a string as it is, a list joined by commas."""
    doc = picked(root, persona_id)[0]
    if key not in doc:
        return ""
    raw = doc[key]
    return ",".join(str(v) for v in raw) if isinstance(raw, list) else str(raw)


def dataset_hints(root: Path) -> list:
    """dataset|titles of the offered personas that name it (a persona naming "all" is not listed: it names everything)."""
    hints: dict = {}
    for doc in personas(root).values():
        if doc.get("picker") and isinstance(doc.get("datasets"), list):
            for ds in doc["datasets"]:
                hints.setdefault(ds, []).append(doc["title"])
    return [f"{ds}|{', '.join(titles)}" for ds, titles in hints.items()]


def show(root: Path, persona_id: str) -> list:
    """What a persona brings, as `exakit persona show` prints it."""
    doc = picked(root, persona_id)[0]
    rows = [doc["title"], doc.get("summary", ""), ""]
    for key, label in (("datasets", "Sample data"), ("addons", "Add-ons"), ("notebook_tools", "Notebook tools"), ("mcp_clients", "AI clients")):
        if key in doc:
            rows.append(f"  {label:<15} {value(root, persona_id, key) or 'none'}")
    if doc.get("first_prompt"):
        rows.append(f"  {'Start here':<15} {doc['first_prompt']}")
    return rows


def run(argv: list, env: dict) -> list:
    """The command's output lines."""
    if len(argv) < 2:
        raise BadInput("usage: persona_service.py <kit_root> <command> [args]")
    root, command, args = Path(argv[0]), argv[1], argv[2:]
    needs = {"check": 1, "title": 1, "value": 2, "answers": 1, "show": 1}
    if len(args) < needs.get(command, 0):
        raise BadInput(f"{command} needs {needs[command]} argument(s)")
    if command == "picker":
        return [f"{d['id']}|{d['title']}|{d.get('summary', '')}|{1 if d.get('default') else 0}"
                for d in personas(root).values() if d.get("picker")]
    if command == "ids":
        return list(personas(root))
    if command == "check":
        return [",".join(d["id"] for d in picked(root, args[0]))]
    if command == "title":
        return [" + ".join(d["title"] for d in picked(root, args[0]))]
    if command == "value":
        return [value(root, args[0], args[1])]
    if command == "answers":
        return answers(root, args[0], env)
    if command == "dataset-hints":
        return dataset_hints(root)
    if command == "show":
        return show(root, args[0])
    raise BadInput(f"Unknown command '{command}'")


def main() -> int:
    try:
        for line in run(sys.argv[1:], dict(os.environ)):
            print(line)
    except BadInput as err:
        print(err, file=sys.stderr)
        return 2
    except OSError as err:
        print(f"The persona files cannot be read: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
