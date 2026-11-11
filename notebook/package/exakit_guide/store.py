"""Read-only views of the kit's own records that the guided cards need:

* the user's own data already in the database (approved descriptors in the
  kit's store, and uploads in the kit's default schemas that aren't described
  yet), so "Your own data" can offer them instead of asking for a path again;
* the versions of a dataset's column map, so a change can be undone;
* whether a schema name is safe (not a reserved word).

The kit keeps versions in descriptors/<SCHEMA.TABLE>/vN.yaml with `dataset:`
naming the id (its own descriptor_store helper looks in descriptors/<id>/ and
misses them), so this reads the files directly.
"""

from __future__ import annotations

import re
from pathlib import Path

KIT_DATASETS = {"amazon_sales", "fraud_transactions", "tpch", "energy", "weather"}
UPLOAD_SCHEMAS = ("STARTER_KIT", "MY_DATA")   # where exakit data-load and load_own_file put files by default


def _home() -> Path:
    from exakit_nb.descriptor_store import kit_home

    return kit_home()


def _yaml(path: Path) -> dict:
    from exakit_nb.descriptor_rules import load_yaml

    try:
        doc = load_yaml(path.read_text(encoding="utf-8"))
        return doc if isinstance(doc, dict) else {}
    except Exception:
        return {}


def _store_folders() -> list[tuple[Path, dict]]:
    root = _home() / "descriptors"
    out = []
    if root.is_dir():
        for folder in sorted(root.iterdir()):
            cur = folder / "current.yaml"
            if folder.is_dir() and cur.is_file():
                out.append((folder, _yaml(cur)))
    return out


def own_datasets(conn) -> list[dict]:
    """The user's data already in the database, newest kit records first."""
    items: list[dict] = []
    described_tables = set()
    folders = _store_folders()
    names = {folder.name.upper() for folder, _ in folders}
    for folder, doc in folders:
        ds_id = str(doc.get("dataset") or "")
        table = str((doc.get("source") or {}).get("object") or folder.name)
        described_tables.add(table.upper())
        if not ds_id or ds_id in KIT_DATASETS:
            continue
        m = re.fullmatch(r"EXAKIT_PREPARED\.(\w+?)__(\w+)__PLAIN", table, re.I)
        if m:   # The guided view's plain-name view over a table loaded with its file's own column names
            shown = f"{m.group(1)}.{m.group(2)}"
            described_tables.add(shown.upper())
            items.append({"value": f"ds:{ds_id}", "label": f"{shown} · column map approved (v{doc.get('version', '?')})", "table": table})
            continue
        if f"EXAKIT_PREPARED.{table.replace('.', '__')}__PLAIN".upper() in names:
            continue    # the raw table's own map can't be read back by the kit; its plain-name version is listed instead
        items.append({"value": f"ds:{ds_id}", "label": f"{table} · column map approved (v{doc.get('version', '?')})",
                      "table": table})
    try:
        names = ", ".join(f"'{s}'" for s in UPLOAD_SCHEMAS)
        rows = conn.execute(f"SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROW_COUNT FROM SYS.EXA_ALL_TABLES "
                            f"WHERE TABLE_SCHEMA IN ({names}) ORDER BY 1, 2").fetchall()
    except Exception:
        rows = []
    for schema, name, count in rows:
        table = f"{schema}.{name}"
        if table.upper() in described_tables:
            continue
        items.append({"value": f"tbl:{table}", "label": f"{table} · {int(count or 0):,} rows · not described yet",
                      "table": table})
    return items


def _friendly(table: str, ds_id: str) -> str:
    """A name a person reads: 'Sales pipeline (cleaned)' for EXAKIT_PREPARED.STARTER_KIT__SALES_PIPELINE__PLAIN__TYPED."""
    from .kitinfo import DATASET_TITLES

    if ds_id in DATASET_TITLES:
        return DATASET_TITLES[ds_id]
    stem = ds_id[: -len("_prepared")] if ds_id.endswith("_prepared") else None
    if stem in DATASET_TITLES:
        return DATASET_TITLES[stem] + " (cleaned)"
    schema, _, name = table.partition(".")
    parts = [p for p in (name or schema).split("__") if p.upper() not in ("PLAIN", "TYPED", "PREPARED")]
    base = (parts[-1] if parts else name or table).replace("_", " ").strip().capitalize()
    cleaned = "TYPED" in name.upper() or ds_id.endswith("_prepared")
    return base + (" (cleaned)" if cleaned else "")


def approved() -> list[dict]:
    """Every dataset with an approved column map, newest approval first: {id, label, table, version, approved_at}.
    A raw table whose map the kit can't read back (its plain-name view is approved instead) is left out."""
    folders = _store_folders()
    names = {folder.name.upper() for folder, _ in folders}
    out = []
    for folder, doc in folders:
        ds_id = str(doc.get("dataset") or "")
        table = str((doc.get("source") or {}).get("object") or folder.name)
        if not ds_id or str(doc.get("status") or "approved") != "approved":
            continue
        if f"EXAKIT_PREPARED.{table.replace('.', '__')}__PLAIN".upper() in names:
            continue
        out.append({"id": ds_id, "label": _friendly(table, ds_id), "table": table,
                    "version": doc.get("version"), "approved_at": str(doc.get("approved_at") or "")})
    return sorted(out, key=lambda x: x["approved_at"], reverse=True)


def versions(ds_id: str) -> list[dict]:
    """Every saved version of a dataset's column map: number, when, and its roles and slots."""
    for folder, doc in _store_folders():
        if str(doc.get("dataset")) != ds_id:
            continue
        out = []
        for path in folder.glob("v*.yaml"):
            m = re.fullmatch(r"v(\d+)\.yaml", path.name)
            if not m:
                continue
            d = _yaml(path)
            cols = {c: (e or {}).get("role") for c, e in (d.get("columns") or {}).items()}
            evidence = {c: str((e or {}).get("evidence") or "") for c, e in (d.get("columns") or {}).items()}
            out.append({"version": int(m.group(1)), "approved_at": d.get("approved_at"),
                        "roles": cols, "slots": dict(d.get("slots") or {}), "evidence": evidence})
        return sorted(out, key=lambda v: v["version"])
    return []


def current(ds_id: str) -> dict:
    """The kit's current record for a dataset: its table and version number ({} when there is none)."""
    for _folder, doc in _store_folders():
        if str(doc.get("dataset")) == ds_id:
            return {"table": str((doc.get("source") or {}).get("object") or ""), "version": doc.get("version")}
    return {}


def reserved(conn, name: str) -> bool:
    try:
        word = re.sub(r"[^A-Z0-9_]", "", name.upper())
        row = conn.execute(f"SELECT COUNT(*) FROM SYS.EXA_SQL_KEYWORDS WHERE RESERVED AND KEYWORD = '{word}'").fetchone()
        return bool(row and row[0])
    except Exception:
        return name.upper() in {"DATA", "ORDER", "USER", "TABLE", "SELECT", "GROUP", "STATE", "CS"}


def safe_schema(conn, wanted: str | None) -> tuple[str, str | None]:
    """A schema name the kit can create. Returns (name, note) where note says what was changed and why."""
    name = re.sub(r"_+", "_", re.sub(r"[^A-Z0-9_]", "_", (wanted or "").strip().upper())).strip("_")
    if not name:
        return "MY_DATA", None
    if not name[0].isalpha():
        name = f"T_{name}"
    if reserved(conn, name):
        return f"{name}_DATA", f"{name} is a word the database keeps for itself, so the data goes into {name}_DATA instead."
    return name, None
