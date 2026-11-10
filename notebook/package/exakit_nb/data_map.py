"""One semantic map of everything the database holds, wherever it came from.

    data = nb.data_map(connection)      # sample datasets, your loaded files and folders, connected sources
    data                                # one table per origin: rows, columns, column map, roles; then the links
    data.tables                         # one row per table (a DataFrame)
    data.columns                        # one row per column, with its approved role when there is one
    data.links                          # joins across tables and origins: declared, found, or a shared key name

Three origins, one view:

- **sample**: a dataset the kit ships (``exakit data-load amazon_sales``);
- **local**: your own file or folder (``exakit data-load <path>``, the quickstart's MY_DATA cell);
- **source**: a connected external source, read live through its virtual schema (``exakit connect``).

Roles come from the approved column maps (EXAKIT_SEMANTIC.<SCHEMA>__<TABLE>, one column comment per role) and the
links from approved schema maps (EXAKIT_SEMANTIC.<SCHEMA>__RELATIONS). Columns that share a key-like name across
two tables are listed as possible links: a lead to check, never a join made for you. Only metadata is read.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from html import escape
from pathlib import Path
from typing import Any

__all__ = ["DataMap", "data_map"]

SEMANTIC = "EXAKIT_SEMANTIC"
KIT_SCHEMAS = ("SYS", "EXA_STATISTICS", "PREPROC")      # the kit's and the database's own; EXAKIT_* too
ORIGINS = {"sample": "Sample data", "local": "Your data", "source": "External source"}
ORDER = ("source", "local", "sample")
KEYISH = re.compile(r"(^ID$|_ID$|_KEY$|_CODE$|_NO$|_NUMBER$|^SKU$|^ASIN$|^EMAIL$)")
SLOT_ROLES = ("key", "time", "measure", "category", "flag", "text", "identifier", "other")
_NUMERIC = ("DECIMAL", "DOUBLE", "INTEGER", "BIGINT", "SMALLINT", "NUMERIC", "FLOAT", "REAL")
_COLOURS = {"source": "#7c3aed", "local": "#0f766e", "sample": "#b45309"}


def _sql(conn, statement: str):
    from . import sql

    return sql(conn, statement)


def _records(frame) -> list[dict[str, Any]]:
    """Rows of a DataFrame (or of the tests' dict of columns) as dicts."""
    if hasattr(frame, "to_dict") and hasattr(frame, "columns") and not isinstance(frame, dict):
        return frame.to_dict("records")
    keys = list(frame)
    return [dict(zip(keys, values)) for values in zip(*(frame[k] for k in keys))]


def _read_map(path: Path) -> tuple[str | None, dict[str, str], dict[str, Any]]:
    """(SCHEMA.TABLE, {column: role}, slots) of a descriptor file; (None, {}, {}) when it cannot be read."""
    from .descriptor_rules import load_yaml

    try:
        doc = load_yaml(path.read_text(encoding="utf-8"))
    except Exception:
        return None, {}, {}
    if not isinstance(doc, dict):
        return None, {}, {}
    source = doc.get("source")
    table = source.get("object") if isinstance(source, dict) else doc.get("fact_table")
    columns = doc.get("columns") if isinstance(doc.get("columns"), dict) else {}
    roles = {str(c): str(e.get("role")) for c, e in columns.items() if isinstance(e, dict) and e.get("role")}
    slots = doc.get("slots") if isinstance(doc.get("slots"), dict) else {}
    return (str(table).upper() if table else None), roles, slots


def _sample_maps() -> tuple[set[str], dict[str, tuple[dict[str, str], dict[str, Any]]]]:
    """The schemas of the datasets the kit ships (dataset.conf), and their shipped column maps by table."""
    from ._kit import setting

    folder = setting("EXAKIT_NB_DATASETS")
    schemas: set[str] = set()
    maps: dict[str, tuple[dict[str, str], dict[str, Any]]] = {}
    if not folder or not Path(folder).is_dir():
        return schemas, maps
    for conf in Path(folder).glob("*/dataset.conf"):
        match = re.search(r"^schema=([A-Za-z_][A-Za-z0-9_]*)", conf.read_text(encoding="utf-8", errors="replace"), re.M)
        if match:
            schemas.add(match.group(1).upper())
    for path in Path(folder).glob("*/descriptor.yaml"):
        table, roles, slots = _read_map(path)
        if table:
            schemas.add(table.split(".")[0])
            maps[table] = (roles, slots)
    return schemas, maps


def _store_map(table: str) -> tuple[str | None, dict[str, str], dict[str, Any]]:
    """(approved | draft | None, roles, slots) from the kit's descriptor store for SCHEMA.TABLE."""
    from .descriptor_store import kit_home

    folder = kit_home() / "descriptors" / table
    for state, name in (("approved", "current.yaml"), ("draft", "draft.yaml")):
        if (folder / name).is_file():
            _, roles, slots = _read_map(folder / name)
            return state, roles, slots
    return None, {}, {}


def _kind(type_name: str) -> str:
    upper = str(type_name or "").upper()
    if upper.startswith(_NUMERIC):
        return "number"
    if upper.startswith(("DATE", "TIMESTAMP")):
        return "time"
    return "text" if upper.startswith(("VARCHAR", "CHAR")) else upper.split("(")[0].lower() or "?"


@dataclass
class DataMap:
    """What data_map found: tables, columns and links, each a list of dicts; DataFrames through the properties."""

    table_rows: list[dict[str, Any]] = field(default_factory=list)
    column_rows: list[dict[str, Any]] = field(default_factory=list)
    link_rows: list[dict[str, Any]] = field(default_factory=list)

    @staticmethod
    def _frame(rows: list[dict[str, Any]]):
        import pandas as pd

        return pd.DataFrame(rows)

    @property
    def tables(self):
        return self._frame(self.table_rows)

    @property
    def columns(self):
        return self._frame(self.column_rows)

    @property
    def links(self):
        return self._frame(self.link_rows)

    def table(self, name: str) -> dict[str, Any]:
        """One table's row, by SCHEMA.TABLE (any case)."""
        for row in self.table_rows:
            if row["table"].upper() == str(name).upper():
                return row
        raise KeyError(f"{name} is not in the map. Tables: {', '.join(r['table'] for r in self.table_rows)}")

    def roles(self, name: str) -> dict[str, str]:
        """{column: role} of one table's approved column map; empty when it has none yet."""
        return {c["column"]: c["role"] for c in self.column_rows if c["table"].upper() == str(name).upper() and c["role"]}

    def _grouped(self) -> list[tuple[str, list[dict[str, Any]]]]:
        return [(origin, [r for r in self.table_rows if r["origin"] == origin]) for origin in ORDER
                if any(r["origin"] == origin for r in self.table_rows)]

    def __str__(self) -> str:
        if not self.table_rows:
            return "No data yet: load a sample, your own file or folder, or connect a source."
        lines = []
        for origin, rows in self._grouped():
            lines.append(f"{ORIGINS[origin]} ({len(rows)} table{'s' if len(rows) != 1 else ''})")
            for r in rows:
                lines.append(f"  {r['table']:<40} {r['rows_shown']:>12}  {r['columns']:>3} cols  {r['map']:<14} {r['summary']}")
        if self.link_rows:
            lines.append("Links")
            for link in self.link_rows:
                lines.append(f"  {link['from_table']}.{link['from_column']} -> {link['to_table']}.{link['to_column']}"
                             f"  ({link['kind']}; {link['origins']})")
        lines.append(_NEXT)
        return "\n".join(lines)

    __repr__ = __str__

    def _repr_html_(self) -> str:
        if not self.table_rows:
            return f"<p>{escape(str(self))}</p>"
        css = ("<style>.exk-map{border-collapse:collapse;font-size:13px;margin:4px 0 12px}"
               ".exk-map th,.exk-map td{padding:4px 10px;border-bottom:1px solid rgba(127,127,127,.25);text-align:left;"
               "vertical-align:top}.exk-map td.n{text-align:right;font-variant-numeric:tabular-nums}"
               ".exk-tag{display:inline-block;padding:1px 7px;border-radius:9px;color:#fff;font-size:11px}"
               ".exk-role{display:inline-block;margin:1px 4px 1px 0;padding:0 5px;border:1px solid rgba(127,127,127,.4);"
               "border-radius:4px;font-size:11px}.exk-dim{opacity:.65}</style>")
        parts = [css, "<h4>Your data, by origin</h4>", "<table class='exk-map'><tr><th>Origin</th><th>Table</th>"
                 "<th>Rows</th><th>Cols</th><th>Column map</th><th>Roles</th></tr>"]
        for origin, rows in self._grouped():
            for i, r in enumerate(rows):
                tag = (f"<span class='exk-tag' style='background:{_COLOURS[origin]}'>{escape(ORIGINS[origin])}</span>"
                       if i == 0 else "")
                parts.append(f"<tr><td>{tag}</td><td><code>{escape(r['table'])}</code></td>"
                             f"<td class='n'>{escape(r['rows_shown'])}</td><td class='n'>{r['columns']}</td>"
                             f"<td>{escape(r['map'])}</td><td>{_roles_html(r)}</td></tr>")
        parts.append("</table>")
        if self.link_rows:
            parts.append("<h4>Links across tables</h4><table class='exk-map'><tr><th>From</th><th>To</th>"
                         "<th>Kind</th><th>Origins</th></tr>")
            for link in self.link_rows:
                parts.append(f"<tr><td><code>{escape(link['from_table'])}.{escape(link['from_column'])}</code></td>"
                             f"<td><code>{escape(link['to_table'])}.{escape(link['to_column'])}</code></td>"
                             f"<td>{escape(link['kind'])}</td><td>{escape(link['origins'])}</td></tr>")
            parts.append("</table>")
        parts.append(f"<p class='exk-dim'>{escape(_NEXT)}</p>")
        return "".join(parts)


_NEXT = ('Next: set the table to work on, e.g. SOURCE = "VS_SALES.ORDERS" or MY_DATA, and approve its column map. '
         '"possible" links share a key-like name only: check them before a join.')


def _roles_html(row: dict[str, Any]) -> str:
    if not row["role_counts"]:
        return f"<span class='exk-dim'>{escape(row['summary'])}</span>"
    named = "".join(f"<span class='exk-role'>{escape(role)} <b>{escape(column)}</b></span>"
                    for role, column in row["named_roles"])
    counted = "".join(f"<span class='exk-role'>{n} {escape(role)}</span>" for role, n in row["role_counts"].items()
                      if role not in ("key", "time"))
    return named + counted


def _summary(roles: dict[str, str], slots: dict[str, Any] | None = None
             ) -> tuple[str, list[tuple[str, str]], dict[str, int]]:
    """A table's roles in one line: the key, time and target columns by name, then a count per other role."""
    named = [(role, column) for column, role in roles.items() if role in ("key", "time")]
    target = (slots or {}).get("target")
    if target:
        named.append(("target", str(target)))
    counts: dict[str, int] = {}
    for role in roles.values():
        counts[role] = counts.get(role, 0) + 1
    counts = {r: counts[r] for r in SLOT_ROLES if r in counts}
    text = ", ".join([f"{role} {column}" for role, column in named] +
                     [f"{n} {role}" for role, n in counts.items() if role not in ("key", "time")])
    return text, named, counts


def data_map(conn, *, include_kit: bool = False) -> DataMap:
    """The semantic map of the database: every table by origin (sample, local, source) with its rows, columns,
    column-map state and roles, then the links between tables - declared, found by an approved schema map, or a
    shared key-like column name across two tables (marked possible). Reads metadata only; returns a DataMap that
    shows itself as a table in a notebook. ``include_kit`` keeps the kit's own schemas in."""
    tables = _records(_sql(conn, """SELECT T.TABLE_SCHEMA, T.TABLE_NAME, T.TABLE_ROW_COUNT, T.TABLE_COMMENT,
       S.SCHEMA_IS_VIRTUAL
FROM SYS.EXA_ALL_TABLES T
JOIN SYS.EXA_SCHEMAS S ON S.SCHEMA_NAME = T.TABLE_SCHEMA
ORDER BY T.TABLE_SCHEMA, T.TABLE_NAME"""))
    columns = _records(_sql(conn, """SELECT COLUMN_SCHEMA, COLUMN_TABLE, COLUMN_NAME, COLUMN_TYPE
FROM SYS.EXA_ALL_COLUMNS
WHERE COLUMN_OBJECT_TYPE = 'TABLE'
ORDER BY COLUMN_SCHEMA, COLUMN_TABLE, COLUMN_ORDINAL_POSITION"""))
    semantic = _records(_sql(conn, f"""SELECT V.VIEW_NAME, V.VIEW_COMMENT, C.COLUMN_NAME, C.COLUMN_COMMENT
FROM SYS.EXA_ALL_VIEWS V
JOIN SYS.EXA_ALL_COLUMNS C ON C.COLUMN_SCHEMA = V.VIEW_SCHEMA AND C.COLUMN_TABLE = V.VIEW_NAME
WHERE V.VIEW_SCHEMA = '{SEMANTIC}'"""))
    samples, shipped = _sample_maps()

    def kept(schema: str) -> bool:
        upper = schema.upper()
        return include_kit or not (upper.startswith("EXAKIT") or upper in KIT_SCHEMAS)

    # roles per SCHEMA.TABLE from the approved column maps, and the relation views
    roles: dict[str, dict[str, str]] = {}
    versions: dict[str, str] = {}
    relation_views: set[str] = set()
    for row in semantic:
        view, about = str(row["VIEW_NAME"]), str(row.get("VIEW_COMMENT") or "")
        if view.endswith("__RELATIONS"):
            relation_views.add(view)
            continue
        source = re.search(r"source=([^;\s]+)", about)
        table = source.group(1).upper() if source else view.replace("__", ".", 1)
        version = re.search(r"descriptor=(v\d+)", about)
        if version:
            versions[table] = version.group(1)
        role = re.match(r"role=([a-z_]+)", str(row.get("COLUMN_COMMENT") or ""))
        if role:
            roles.setdefault(table, {})[str(row["COLUMN_NAME"])] = role.group(1)

    by_table: dict[str, list[dict[str, Any]]] = {}
    for row in columns:
        by_table.setdefault(f"{row['COLUMN_SCHEMA']}.{row['COLUMN_TABLE']}".upper(), []).append(row)

    found = DataMap()
    origin_of: dict[str, str] = {}
    for row in tables:
        schema = str(row["TABLE_SCHEMA"])
        if not kept(schema):
            continue
        table = f"{schema}.{row['TABLE_NAME']}"
        virtual = row.get("SCHEMA_IS_VIRTUAL") in (True, "TRUE", "true", 1)
        origin = "source" if virtual else ("sample" if schema.upper() in samples else "local")
        origin_of[table.upper()] = origin
        mapped, slots = roles.get(table.upper(), {}), {}
        state, stored, stored_slots = _store_map(table)
        if mapped:
            shown_map = f"approved {versions.get(table.upper(), '')}".strip()
            slots = stored_slots
        elif stored:
            mapped, slots = stored, stored_slots
            shown_map = "approved, not published" if state == "approved" else "draft"
        elif table.upper() in shipped:
            mapped, slots = shipped[table.upper()]
            shown_map = "shipped"
        else:
            shown_map = "none yet"
        summary, named, counts = _summary(mapped, slots)
        count = row.get("TABLE_ROW_COUNT")
        rows_shown = "live" if virtual else (f"{int(count):,}" if count is not None else "?")
        found.table_rows.append({"origin": origin, "origin_label": ORIGINS[origin], "table": table,
                                 "rows": None if virtual or count is None else int(count), "rows_shown": rows_shown,
                                 "columns": len(by_table.get(table.upper(), [])), "map": shown_map,
                                 "summary": summary or "approve its column map to see roles",
                                 "named_roles": named, "role_counts": counts,
                                 "target": (slots or {}).get("target")})
        for col in by_table.get(table.upper(), []):
            name = str(col["COLUMN_NAME"])
            found.column_rows.append({"origin": origin, "table": table, "column": name,
                                      "type": str(col["COLUMN_TYPE"]), "kind": _kind(col["COLUMN_TYPE"]),
                                      "role": mapped.get(name)})

    seen: set[tuple[str, str, str, str]] = set()
    for view in sorted(relation_views):
        try:
            links = _records(_sql(conn, f'SELECT FROM_TABLE, FROM_COLUMN, TO_TABLE, TO_COLUMN, KIND FROM "{SEMANTIC}"."{view}"'))
        except Exception:                                  # a relation view that cannot be read is left out
            continue
        for link in links:
            key = (str(link["FROM_TABLE"]).upper(), str(link["FROM_COLUMN"]), str(link["TO_TABLE"]).upper(), str(link["TO_COLUMN"]))
            if key in seen:
                continue
            seen.add(key)
            found.link_rows.append(_link(key, str(link.get("KIND") or "found"), origin_of))
    found.link_rows.extend(_shared_keys(found.column_rows, origin_of, seen))
    return found


def _link(key: tuple[str, str, str, str], kind: str, origin_of: dict[str, str]) -> dict[str, str]:
    a, b = origin_of.get(key[0], "local"), origin_of.get(key[2], "local")
    return {"from_table": key[0], "from_column": key[1], "to_table": key[2], "to_column": key[3], "kind": kind,
            "origins": ORIGINS[a] if a == b else f"{ORIGINS[a]} + {ORIGINS[b]}"}


def _shared_keys(columns: list[dict[str, Any]], origin_of: dict[str, str],
                 seen: set[tuple[str, str, str, str]]) -> list[dict[str, str]]:
    """A key-like column name (or a column whose approved role is key or identifier) in two tables of different
    schemas, of the same kind (number with number, text with text): a possible link. Pairs across origins first."""
    groups: dict[str, list[dict[str, Any]]] = {}
    for col in columns:
        name = col["column"].upper()
        if KEYISH.search(name) or col["role"] in ("key", "identifier"):
            groups.setdefault(name, []).append(col)
    found = []
    for name, cols in groups.items():
        for i, a in enumerate(cols):
            for b in cols[i + 1:]:
                if a["table"].split(".")[0] == b["table"].split(".")[0] or a["kind"] != b["kind"]:
                    continue
                key = (a["table"].upper(), a["column"], b["table"].upper(), b["column"])
                if key in seen or (key[2], key[3], key[0], key[1]) in seen:
                    continue
                seen.add(key)
                found.append(_link(key, "possible (same name)", origin_of))
    found.sort(key=lambda link: ("+" not in link["origins"], link["from_table"], link["from_column"]))
    return found[:50]
