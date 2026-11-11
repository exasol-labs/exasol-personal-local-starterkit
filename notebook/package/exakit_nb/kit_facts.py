"""What the kit has, read live: datasets, connectors, add-ons, AI clients, components, notebooks and personas.

    nb.sample_datasets()          # the kit's sample datasets: id, label, description, schema, loaded
    nb.connectors()               # the kinds of external source exakit connect takes
    nb.addons()                   # the marketplace's add-ons and their state
    nb.ai_clients()               # the AI clients the kit knows, and which are connected to the database
    nb.components()               # the kit's parts, their versions and pending updates
    nb.notebooks("data-scientist")   # a persona's notebooks, in order
    nb.persona_plan()             # what this kit's personas bring that is still missing

Nothing here is a list typed into the notebook package: each answer is the kit's own - an `exakit ... --json`
command, or a file of the kit copy these notebooks run with (data/datasets/*/dataset.conf, notebook/catalog.json,
personas/*.json, mcp/adapters). The guided view's cards read the same functions, so a card and a cell agree.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from ._kit import setting

__all__ = ["addons", "ai_clients", "components", "connectors", "notebooks", "persona_plan", "personas",
           "sample_datasets"]


def _kit_root() -> Path | None:
    """The kit copy these notebooks run with (the kernel's EXAKIT_NB_KIT), else the checkout this package sits in."""
    kit = setting("EXAKIT_NB_KIT")
    for root in ([Path(kit)] if kit else []) + [Path(__file__).resolve().parents[3]]:
        if (root / "versions.json").is_file():
            return root
    return None


def _datasets_dir() -> Path | None:
    folder = setting("EXAKIT_NB_DATASETS")
    if folder and Path(folder).is_dir():
        return Path(folder)
    root = _kit_root()
    return root / "data" / "datasets" if root and (root / "data" / "datasets").is_dir() else None


def _json(*args: str) -> dict[str, Any]:
    from .kit_commands import kit_json

    return kit_json(*args, "--json")


def _conf(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, _, value = line.partition("=")
            out[key.strip()] = value.strip()
    return out


def sample_datasets(*, loaded: list[str] | None = None) -> list[dict[str, Any]]:
    """Every sample dataset this kit ships, in the kit's order: {id, label, description, schema, default, loaded,
    described} - described: it ships a column map, so nb.load_sample opens it ready to use.
    ``loaded`` (ids) marks the ones in the database; by default the kit's status says which."""
    folder = _datasets_dir()
    if folder is None:
        return []
    if loaded is None:
        try:
            from .kit_commands import kit_status

            loaded = list(kit_status().get("datasets_loaded") or [])
        except Exception:
            loaded = []
    rows = []
    for conf in sorted(folder.glob("*/dataset.conf")):
        c = _conf(conf)
        did = c.get("id") or conf.parent.name
        rows.append({"id": did, "label": c.get("label") or did, "description": c.get("description", ""),
                     "schema": c.get("schema", ""), "default": c.get("default") == "yes",
                     "order": int(c.get("order") or 999), "loaded": did in loaded,
                     "described": (conf.parent / "descriptor.yaml").is_file()})
    return sorted(rows, key=lambda r: (r["order"], r["id"]))


def connectors() -> list[dict[str, Any]]:
    """The kinds of external source `exakit connect` takes, as its own menu lists them (the kit's source engine,
    ``catalog``): {id, name, summary, aliases, tier, status, version, gate} - ``version`` the adapter the kit pins,
    ``gate`` why one is not available yet (empty when it is)."""
    from .sources import source_engine

    rows = source_engine("catalog").get("connectors", [])
    return [{**{k: r.get(k) for k in ("id", "name", "summary", "aliases", "tier", "status", "version")},
             "gate": r.get("gate") or ""} for r in rows]


def loaded_files() -> list[dict[str, Any]]:
    """The files `exakit data-load` put into the database, as the kit records them (its load receipts): one row per
    table, the latest load - {table, rows, file, loaded_at}. A kit dataset (sample_datasets) is not a file here."""
    from datetime import datetime, timezone

    from ._kit import _home

    home = _home()
    path = home / "cache" / "load-receipts.tsv" if home else None
    if not path or not path.is_file():
        return []
    latest: dict[str, dict[str, Any]] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.split("\t")
        if len(parts) < 6 or "." not in parts[0]:
            continue
        table, _, _, rows, at, name = parts[:6]
        stamp = int(at) if at.isdigit() else 0
        if table in latest and latest[table]["_at"] > stamp:
            continue
        latest[table] = {"table": table, "rows": int(rows) if rows.isdigit() else None, "file": name,
                         "loaded_at": datetime.fromtimestamp(stamp, timezone.utc).isoformat() if stamp else None,
                         "_at": stamp}
    rows_out = sorted(latest.values(), key=lambda r: -r["_at"])
    return [{k: v for k, v in r.items() if k != "_at"} for r in rows_out]


def connector_inputs(connector: str) -> dict[str, Any]:
    """What `exakit connect <connector>` asks, from the kit's source engine (``inputs``: what its connect form reads,
    in the form's order). The connector may be named by id or alias. Returns {id, name, status, gate, name_input,
    inputs, forms, access, tips}: ``name_input`` is the form's first question (the source's name); each of ``inputs``
    is {name, label, kind, required, default, choices, secret, file, hint, prompt, draft} - ``secret`` a password or
    key (never a cell's text), ``file`` a path to a file, ``hint`` the lines the form says above the question.
    ``forms`` are the connection-string shapes it reads (``url=``), ``access`` and ``tips`` what its source card says."""
    from .sources import source_engine

    answer = source_engine("inputs", str(connector or "").strip().lower())
    fields = [{**f, "hint": list(f.get("hint") or []), "prompt": f.get("prompt") or "", "draft": f.get("draft") or "",
               "file": f["kind"] in ("ca-file", "secret-file")} for f in answer["inputs"]]
    root = _kit_root()
    # The connection-string forms, the access the reader needs and the tips: the connector's own definition, read
    # where the shell reads them (its paste hint and its source card).
    doc = json.loads((root / "setup" / "virtual-schemas" / "connectors" / answer["connector"] / "connector.json")
                     .read_text(encoding="utf-8"))
    return {"id": answer["connector"], "name": answer["name"], "status": answer.get("status") or "",
            "gate": answer.get("gate") or "",
            "name_input": next((f for f in fields if f["kind"] == "source-name"), None),
            "inputs": [f for f in fields if f["kind"] != "source-name"],
            "forms": list((doc.get("paste") or {}).get("forms") or []),
            "access": doc.get("access") or "", "tips": list(doc.get("tips") or [])}


def addons() -> list[dict[str, Any]]:
    """The marketplace's add-ons as `exakit marketplace --list --json` reports them: {id, name, about, status,
    installed, version, url}, and `offered`: False for one the kit's catalog does not offer yet (its
    marketplace/catalog.json says "visible": false, so no marketplace screen lists it)."""
    rows = _json("marketplace", "--list").get("addons", [])
    hidden: set[str] = set()
    root = _kit_root()
    try:
        catalog = json.loads((root / "marketplace" / "catalog.json").read_text(encoding="utf-8")) if root else {}
        hidden = {str(r.get("id")) for r in catalog.get("addons", []) if isinstance(r, dict) and r.get("visible") is False}
    except (OSError, ValueError):
        pass
    return [{**{k: r.get(k) for k in ("id", "name", "about", "status", "installed", "version", "url")},
             "offered": r.get("id") not in hidden} for r in rows]


# An adapter names itself either in its methods or in the arguments it hands its base class (mcp/adapters).
_ADAPTER_ID = re.compile(r'def adapter_id\(self\)[^:]*:\s*return "([^"]+)"|adapter_id_value="([^"]+)"')
_DISPLAY = re.compile(r'def display_name\(self\)[^:]*:\s*return "([^"]+)"|display_name_value="([^"]+)"')


def _client_names() -> dict[str, str]:
    root = _kit_root()
    names: dict[str, str] = {}
    for path in sorted((root / "mcp" / "adapters").glob("*.py")) if root else []:
        text = path.read_text(encoding="utf-8")
        found, shown = _ADAPTER_ID.search(text), _DISPLAY.search(text)
        if found and shown:
            names[found.group(1) or found.group(2)] = shown.group(1) or shown.group(2)
    return names


def ai_clients() -> list[dict[str, Any]]:
    """The AI clients the kit can connect to the database (its MCP adapters), each {id, name, connected}, with
    connected from `exakit mcp-status --json`."""
    try:
        status = _json("mcp-status")
    except Exception:
        status = {}
    connected = {a.get("client") for a in status.get("artifacts") or []
                 if a.get("client") and not a.get("removed_at") and a.get("kind") == "client_config"}
    names = _client_names()
    ids = list(names) + sorted(connected - set(names))
    return [{"id": cid, "name": names.get(cid, cid), "connected": cid in connected} for cid in ids]


def components() -> list[dict[str, Any]]:
    """The kit's parts as `exakit version --json` reports them: {id, installed, available, status, add_on,
    ownership, remedy}, with a status of current, ahead, update_available, available (an add-on not installed) or
    missing; ``available`` is the version the kit would install or update to."""
    rows = _json("version").get("components", [])
    return [{"id": r.get("component"), "installed": r.get("installed_label") or r.get("installed"),
             "available": r.get("advertised"), "status": r.get("status"), "add_on": bool(r.get("addon")),
             "ownership": r.get("ownership"), "remedy": r.get("remedy")} for r in rows]


def notebooks(persona: str | None = None) -> list[dict[str, Any]]:
    """The kit's notebooks in order ({id, persona, step, title, summary, file}), from its notebook catalog; only
    ``persona``'s when given. ``file`` is the path under the notebooks folder (starter-kit-notebooks/...)."""
    root = _kit_root()
    path = root / "notebook" / "catalog.json" if root else None
    if not path or not path.is_file():
        return []
    doc = json.loads(path.read_text(encoding="utf-8"))
    folder = (doc.get("folders") or {}).get("jupyter", "")
    rows = [{"id": n.get("id"), "persona": n.get("persona"), "step": n.get("step"), "title": n.get("title"),
             "summary": n.get("summary", ""), "file": "/".join(x for x in (folder, n.get("persona"), n.get("jupyter")) if x)}
            for n in doc.get("notebooks", []) if persona is None or n.get("persona") == persona]
    return sorted(rows, key=lambda r: (r["persona"] or "", r["step"] if r["step"] is not None else 99))


def personas() -> list[dict[str, Any]]:
    """The kit's personas (personas/*.json): {id, title, summary, datasets, addons, visible}."""
    root = _kit_root()
    rows = []
    for path in sorted((root / "personas").glob("*.json")) if root else []:
        doc = json.loads(path.read_text(encoding="utf-8"))
        rows.append({"id": doc.get("id", path.stem), "title": doc.get("title", path.stem), "summary": doc.get("summary", ""),
                     "datasets": doc.get("datasets"), "addons": doc.get("addons"), "visible": doc.get("visible", True),
                     "order": doc.get("order", 999)})
    return sorted(rows, key=lambda r: (r["order"], r["id"]))


def persona_plan(persona: str | None = None) -> dict[str, Any]:
    """What a persona (this kit's, when not named) brings that is still missing here: `exakit persona plan --json`
    - {persona, datasets{loaded, pending}, addons{installed, pending, unavailable}, nothing_pending}."""
    return _json("persona", "plan", *([persona] if persona else []))
