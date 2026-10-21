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
    python3 persona_service.py <kit_root> problems               file|what is wrong, for each invalid persona file

<ids> is one id or several joined by commas. Every value printed is an id, a list of ids or a title: no secrets, no
paths. A persona file that is invalid is left out (and named on stderr) - the others still work. Exit codes: 0 done,
2 bad input (an unknown or invalid persona, a bad command), 1 `problems` found an invalid file.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ID = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
LISTS = ("datasets", "mcp_clients", "addons", "notebook_tools")
WORDS = {"datasets": ("all", "none"), "mcp_clients": ("all", "skip"), "addons": ("all", "none"), "notebook_tools": ("none",)}
EMPTY = {"datasets": "none", "mcp_clients": "skip", "addons": "none", "notebook_tools": "none"}   # what [] means
ANSWERS = (                       # (persona key, the installer variable it answers, variables that mean it was answered)
    ("datasets", "EXAKIT_DATASETS", ("EXAKIT_DATASETS",)),
    ("mcp_clients", "EXAKIT_MCP_CLIENTS", ("EXAKIT_MCP_CLIENTS",)),
    ("addons", "EXAKIT_MARKETPLACE_ADDONS", ("EXAKIT_MARKETPLACE_ADDONS",)),
    ("notebook_tools", "EXAKIT_NOTEBOOK_FRONTENDS", ("EXAKIT_NOTEBOOK_FRONTENDS",)),
)


class BadInput(Exception):
    """An unknown persona or key: exit 2."""


def problems(path: Path, doc) -> list:
    """What is wrong with one persona file; empty when it is valid. The shells read the service's lines split on | and
    newlines, so a title or summary may hold neither, and every list item must be an id."""
    if not isinstance(doc, dict):
        return ["it is not a JSON object"]
    found = []
    if not ID.match(path.stem):
        found.append("its file name must be a lowercase id (a-z, 0-9, - and _)")
    elif doc.get("id") != path.stem:
        found.append(f"its id must be its file name ('{path.stem}')")
    if doc.get("schema_version", 1) != 1:
        found.append("schema_version must be 1")
    for key in ("title", "summary"):
        if not isinstance(doc.get(key), str) or not doc[key].strip():
            found.append(f"'{key}' must be a non-empty string")
    for key in ("title", "summary", "first_prompt"):
        text = doc.get(key)
        if isinstance(text, str) and ("|" in text or "\n" in text or "\r" in text):
            found.append(f"'{key}' must be one line without '|'")
    if "order" in doc and (isinstance(doc["order"], bool) or not isinstance(doc["order"], int)):
        found.append("'order' must be a whole number")
    for key in ("picker", "default"):
        if key in doc and not isinstance(doc[key], bool):
            found.append(f"'{key}' must be true or false")
    for key, words in WORDS.items():
        if key not in doc:
            continue
        raw = doc[key]
        if isinstance(raw, str):
            if raw not in words:
                found.append(f"'{key}' must be a list of ids or one of: {', '.join(words)}")
        elif isinstance(raw, list):
            bad = [item for item in raw if not isinstance(item, str) or not ID.match(item)]
            if bad:
                found.append(f"'{key}' holds {bad[0]!r}, which is not an id")
        else:
            found.append(f"'{key}' must be a list of ids or one of: {', '.join(words)}")
    return found


def load(root: Path) -> tuple:
    """(valid personas by id in the question's order, invalid ones: file name -> what is wrong). One bad file never
    takes the others down."""
    valid, invalid = {}, {}
    for path in sorted((root / "personas").glob("*.json")):
        if path.name.startswith("."):                # editor and Finder debris: ._x.json, .#x.json
            continue
        try:
            doc = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError) as err:
            invalid[path.name] = f"not valid JSON ({err})"
            continue
        found = problems(path, doc)
        if found:
            invalid[path.name] = "; ".join(found)
        else:
            valid[path.stem] = doc
    return dict(sorted(valid.items(), key=lambda item: (item[1].get("order", 100), item[0]))), invalid


def personas(root: Path) -> dict:
    """Every valid persona of the kit, by id, in the order the question offers them."""
    return load(root)[0]


def picked(root: Path, ids: str) -> list:
    """The personas named, in the kit's order; BadInput naming an unknown or invalid one."""
    known, invalid = load(root)
    wanted = [i.strip() for i in ids.split(",") if i.strip()]
    broken = [i for i in wanted if f"{i}.json" in invalid]
    if broken:
        raise BadInput(f"The persona file personas/{broken[0]}.json is invalid: {invalid[broken[0] + '.json']}.")
    unknown = [i for i in wanted if i not in known]
    if unknown or not wanted:
        raise BadInput(f"Unknown persona '{','.join(unknown) or ids}' (available: {' '.join(known)}).")
    return [known[i] for i in known if i in wanted]


def one(root: Path, persona_id: str) -> dict:
    """Exactly one persona; BadInput for a list."""
    if "," in persona_id:
        raise BadInput("Name one persona here, not several.")
    return picked(root, persona_id)[0]


def bundled_datasets(root: Path) -> list:
    """The dataset ids the kit ships (data/datasets/<id>/dataset.conf), in their menu order."""
    found = []
    for conf in (root / "data" / "datasets").glob("*/dataset.conf"):
        keys = dict(line.split("=", 1) for line in conf.read_text(encoding="utf-8").splitlines() if "=" in line)
        order = keys.get("order", "").strip()
        found.append((int(order) if order.isdigit() else 1000, keys.get("id", conf.parent.name).strip()))
    return [ds for _, ds in sorted(found)]


def combined(docs: list, key: str) -> str:
    """What several personas say together: "all" when any says all, the nothing-word (none/skip) only when every one
    says it, else the union of their lists in order. [] is the nothing-word; a persona without the key says nothing."""
    values = [EMPTY[key] if doc.get(key) == [] else doc.get(key) for doc in docs if doc.get(key) not in (None, "")]
    if not values:
        return ""
    if "all" in values:
        return "all"
    lists = [v for v in values if isinstance(v, list)]
    if not lists:                                    # only the nothing-word
        return str(values[0])
    seen = []
    for items in lists:
        for item in items:
            if item not in seen:
                seen.append(item)
    return ",".join(seen)


def answers(root: Path, ids: str, env: dict) -> list:
    """KEY=value lines for the answers the personas fill in: only the variables the user left unset. "all" datasets
    become the kit's dataset ids (EXAKIT_DATASETS takes ids), "none" becomes EXAKIT_LOAD_SAMPLE=0."""
    docs = picked(root, ids)
    lines = []
    for key, variable, given in ANSWERS:
        if any(env.get(name, "") for name in given):
            continue
        if key == "datasets" and env.get("EXAKIT_LOAD_SAMPLE", "") in ("0", "1"):
            continue                                 # the two values the installer reads; anything else is not an answer
        if variable == "EXAKIT_MCP_CLIENTS" and env.get("EXAKIT_SKIP_MCP") == "1":
            continue                                 # the AI bridge is skipped: no clients to answer
        value = combined(docs, key)
        if key == "datasets" and value == "all":
            value = ",".join(bundled_datasets(root)) or "all"
        if key == "datasets" and value == "none":
            lines.append("EXAKIT_LOAD_SAMPLE=0")
        elif value:
            lines.append(f"{variable}={value}")
    lines.append(f"EXAKIT_PERSONA={','.join(doc['id'] for doc in docs)}")
    return lines


def value(root: Path, persona_id: str, key: str) -> str:
    """One key of one persona: a string as it is, a list joined by commas; empty when the file has no such key."""
    doc = one(root, persona_id)
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
    doc = one(root, persona_id)
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
    if command == "problems":
        return [f"{name}|{what}" for name, what in load(root)[1].items()]
    raise BadInput(f"Unknown command '{command}'")


def main() -> int:
    # UTF-8 out, whatever the console's code page: a title with a non-ASCII letter must not crash a Windows pipe.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    try:
        lines = run(sys.argv[1:], dict(os.environ))
    except BadInput as err:
        print(err, file=sys.stderr)
        return 2
    except OSError as err:
        print(f"The persona files cannot be read: {err}", file=sys.stderr)
        return 2
    if len(sys.argv) > 2 and sys.argv[2] != "problems" and Path(sys.argv[1]).is_dir():
        for name, what in load(Path(sys.argv[1]))[1].items():
            print(f"Ignored persona file personas/{name}: {what}", file=sys.stderr)
    for line in lines:
        print(line)
    return 1 if (len(sys.argv) > 2 and sys.argv[2] == "problems" and lines) else 0


if __name__ == "__main__":
    sys.exit(main())
