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
    python3 persona_service.py <kit_root> default-datasets       the datasets a kit without a persona loads (a,b,c)

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
SERVICES = ("mlflow",)
WORDS = {"datasets": ("all", "none"), "mcp_clients": ("all", "skip"), "addons": ("all", "none"), "notebook_tools": ("none",)}
EMPTY = {"datasets": "none", "mcp_clients": "skip", "addons": "none", "notebook_tools": "none"}   # what [] means
ANSWERS = (                       # (persona key, the installer variable it answers, variables that mean it was answered)
    ("datasets", "EXAKIT_DATASETS", ("EXAKIT_DATASETS",)),
    ("mcp_clients", "EXAKIT_MCP_CLIENTS", ("EXAKIT_MCP_CLIENTS",)),
    ("addons", "EXAKIT_MARKETPLACE_ADDONS", ("EXAKIT_MARKETPLACE_ADDONS",)),
    ("notebook_tools", "EXAKIT_NOTEBOOK_FRONTENDS", ("EXAKIT_NOTEBOOK_FRONTENDS",)),
    ("udf_language", "EXAKIT_UDF_LANGUAGE", ("EXAKIT_UDF_LANGUAGE",)),
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
    for key in ("picker", "default", "visible"):
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
    if "services" in doc:
        if not isinstance(doc["services"], list) or any(item not in SERVICES for item in doc["services"]):
            found.append(f"'services' must be a list of known services: {', '.join(SERVICES)}")
    if "udf_language" in doc and doc["udf_language"] not in ("python", "rust"):
        found.append("'udf_language' must be python or rust")
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


def selectable(root: Path, ids: str, recorded_ids: str = "") -> list:
    """New selections cannot activate a hidden release definition."""
    rows = picked(root, ids)
    recorded = {item.strip() for item in recorded_ids.split(",")}
    hidden = [row["id"] for row in rows if not row.get("visible", True) and row["id"] not in recorded]
    if hidden:
        raise BadInput(f"Persona '{hidden[0]}' is disabled in personas/{hidden[0]}.json.")
    return rows


def one(root: Path, persona_id: str) -> dict:
    """Exactly one persona; BadInput for a list."""
    if "," in persona_id:
        raise BadInput("Name one persona here, not several.")
    return picked(root, persona_id)[0]


def bundled_datasets(root: Path, defaults_only: bool = False) -> list:
    """The dataset ids the kit ships (data/datasets/<id>/dataset.conf), in their menu order; with defaults_only, the
    ones a kit without a persona loads (default=yes)."""
    found = []
    for conf in (root / "data" / "datasets").glob("*/dataset.conf"):
        keys = {k.strip(): v.strip() for k, v in (line.split("=", 1) for line in conf.read_text(encoding="utf-8").splitlines() if "=" in line)}
        if defaults_only and keys.get("default", "").lower() not in ("yes", "true", "1"):
            continue
        order = keys.get("order", "")
        found.append((int(order) if order.isdigit() else 1000, keys.get("id", conf.parent.name)))
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
        value = combined(docs, key) if key in EMPTY else next((doc[key] for doc in docs if doc.get(key)), "")
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


def selected_services(root: Path, ids: str) -> list[str]:
    return list(dict.fromkeys(service for doc in picked(root, ids) for service in doc.get("services", [])))


def dataset_hints(root: Path) -> list:
    """dataset|titles of the offered personas that name it (a persona naming "all" is not listed: it names everything).

    A dataset two or more personas name says "both personas" ("all personas" when every offered one names it, "N
    personas" for more than two of them) instead of the titles: "Data Scientist, ML Engineer" is 27 columns, and in the data table's For column that pushed the
    41-column upload and external-source labels past 80 columns, where the name column yields first and both
    were cut short. The short form says the same thing and leaves the names whole."""
    hints: dict = {}
    offered = 0
    for doc in personas(root).values():
        if doc.get("picker") and doc.get("visible", True) and isinstance(doc.get("datasets"), list):
            offered += 1
            for ds in doc["datasets"]:
                hints.setdefault(ds, []).append(doc["title"])
    out = []
    for ds, titles in hints.items():
        if offered > 1 and len(titles) == offered:
            out.append(f"{ds}|{'both' if offered == 2 else 'all'} personas")
        elif len(titles) == 2:
            out.append(f"{ds}|both personas")         # two of three or more: still too wide to name them
        elif len(titles) > 2:
            out.append(f"{ds}|{len(titles)} personas")
        else:
            out.append(f"{ds}|{titles[0]}")
    return out


def dataset_titles(root: Path) -> dict:
    """id -> the short name the data menu shows for each bundled dataset: its label up to the first " (" (NEW-05)."""
    titles = {}
    for conf in (root / "data" / "datasets").glob("*/dataset.conf"):
        keys = {k.strip(): v.strip() for k, v in (line.split("=", 1) for line in conf.read_text(encoding="utf-8").splitlines()
                                                     if "=" in line)}
        label = keys.get("label", "")
        if label:
            titles[keys.get("id", conf.parent.name)] = label.split(" (", 1)[0]
    return titles


def show(root: Path, persona_id: str) -> list:
    """What a persona brings, as `exakit persona show` prints it: datasets by the names the data menu uses (NEW-05),
    add-ons and clients by the ids you type."""
    doc = one(root, persona_id)
    rows = [doc["title"], doc.get("summary", ""), ""]
    for key, label in (("datasets", "Sample data"), ("addons", "Add-ons"), ("notebook_tools", "Notebook tools"), ("mcp_clients", "AI clients"), ("services", "Services"), ("udf_language", "UDF language")):
        if key in doc:
            shown = value(root, persona_id, key) or "none"
            if key == "datasets" and isinstance(doc[key], list) and doc[key]:
                titles = dataset_titles(root)
                shown = ", ".join(titles.get(item, item) for item in doc[key])
            rows.append(f"  {label:<15} {shown}")
    if doc.get("first_prompt"):
        rows.append(f"  {'Start here':<15} {doc['first_prompt']}")
    elif "notebook" in doc.get("addons", []):
        rows.append(f"  {'Start here':<15} exakit notebook; open {persona_id}/00_quickstart.ipynb")
    return rows


# How a service a persona started is kept from starting at login, and where the manifest says it is set to start;
# anything else is stopped by its service id.
SERVICE_OFF = {"mlflow": ("The MLflow server", "exakit mlflow stop --disable", ("components", "udf_devkit", "mlflow", "enabled"))}


def kept_services(root: Path, removed: str, remaining: list, manifest: dict | None = None) -> list:
    """What `persona remove` leaves running, said: a service the removed persona started (the ML Engineer's MLflow
    server), that is set to start and that no remaining persona needs, still starts at every login - with the
    command that stops that (audit DAY-10). Its data stays either way."""
    try:
        theirs = selected_services(root, removed)
        still = set(selected_services(root, ",".join(remaining))) if remaining else set()
    except BadInput:
        return []
    lines = []
    for service in theirs:
        if service in still:
            continue
        what, command, flag = SERVICE_OFF.get(service, (f"The {service} service", f"exakit stop {service}", ()))
        node = manifest or {}
        for key in flag:
            node = node.get(key) if isinstance(node, dict) else None
        if flag and node is not True:
            continue                                 # never set to start: nothing to say
        lines.append(f"{what} it started still starts at every login (its data stays). To stop that: {command}")
    return lines


def notebooks(root: Path, persona_id: str) -> list:
    """The notebooks a persona brings, in their order, from the notebook catalog (notebook/catalog.json): what the
    notebook add-on copies into the persona's folder. Empty when the kit copy carries no catalog."""
    try:
        doc = json.loads((root / "notebook" / "catalog.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    rows = [n for n in doc.get("notebooks", []) if isinstance(n, dict) and n.get("persona") == persona_id]
    return [{"id": n.get("id"), "title": n.get("title"), "jupyter": f"{persona_id}/{n['jupyter']}" if n.get("jupyter") else None,
             "marimo": f"{persona_id}/{n['marimo']}" if n.get("marimo") else None}
            for n in sorted(rows, key=lambda n: n.get("step", 0))]


def described(root: Path, persona_id: str, recorded: list) -> dict:
    """One persona as `exakit persona show <id> --json` answers it: the same facts as the text form, lists as lists."""
    doc = one(root, persona_id)
    out = {"id": doc["id"], "title": doc["title"], "summary": doc.get("summary", ""), "recorded": doc["id"] in recorded}
    for key in ("datasets", "addons", "notebook_tools", "mcp_clients", "services", "udf_language"):
        if key in doc:
            out[key] = doc[key]
    out["notebooks"] = notebooks(root, doc["id"])
    start = show(root, persona_id)[-1].split(None, 2)
    out["start_here"] = start[2] if len(start) == 3 and start[:2] == ["Start", "here"] else None
    return out


def _manifest(home: Path) -> dict:
    try:
        doc = json.loads((home / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def run(argv: list, env: dict) -> list:
    """The command's output lines."""
    if len(argv) < 2:
        raise BadInput("usage: persona_service.py <kit_root> <command> [args]")
    root, command, args = Path(argv[0]), argv[1], argv[2:]
    needs = {"check": 1, "select": 1, "title": 1, "value": 2, "answers": 1, "show": 1, "show-json": 1, "remove": 1}
    if len(args) < needs.get(command, 0):
        raise BadInput(f"{command} needs {needs[command]} argument(s)")
    if command == "picker":
        return [f"{d['id']}|{d['title']}|{d.get('summary', '')}|{1 if d.get('default') else 0}"
                for d in personas(root).values() if d.get("picker") and d.get("visible", True)]
    if command == "ids":
        return [d["id"] for d in personas(root).values() if d.get("visible", True)]
    if command == "check":
        return [",".join(d["id"] for d in picked(root, args[0]))]
    if command == "select":
        return [",".join(d["id"] for d in selectable(root, args[0], args[1] if len(args) > 1 else ""))]
    if command == "title":
        return [" + ".join(d["title"] for d in picked(root, args[0]))]
    if command == "value":
        return [value(root, args[0], args[1])]
    if command == "answers":
        return answers(root, args[0], env)
    if command == "services":
        return selected_services(root, args[0])
    if command == "dataset-hints":
        return dataset_hints(root)
    if command == "show":
        return show(root, args[0])
    if command in ("list-json", "show-json"):
        # The recorded personas come from the kit's manifest, which the caller reads: EXAKIT_PERSONA_RECORDED.
        recorded = [i for i in env.get("EXAKIT_PERSONA_RECORDED", "").split(",") if i]
        if command == "show-json":
            return [json.dumps(described(root, args[0], recorded))]
        rows = [described(root, d["id"], recorded) for d in personas(root).values() if d.get("visible", True)]
        return [json.dumps({"personas": rows, "recorded": recorded})]
    if command == "remove":
        sys.path.insert(0, str(root / "marketplace"))
        from persona_membership import remove
        from runtime import AddonFailure

        home = Path(env.get("EXAKIT_HOME", str(Path.home() / ".exasol-starter-kit")))
        try:
            remaining, changed = remove(root, home, args[0])
        except AddonFailure as error:
            raise BadInput(str(error)) from error
        if changed:
            return [f"Persona removed: {args[0]}. Installed datasets and add-ons were kept.",
                    *kept_services(root, args[0], remaining, _manifest(home)),
                    f"Recorded personas: {','.join(remaining) or 'none'}"]
        return [f"Persona {args[0]} was not recorded; nothing changed."]
    if command == "default-datasets":
        return [",".join(bundled_datasets(root, defaults_only=True))]
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
