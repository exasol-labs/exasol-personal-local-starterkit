"""A whole schema as one descriptor: its tables and the links between them (the multi-table half of the semantic
layer). A table's descriptor says what each of its columns is; the schema map says how the tables fit together, so a
question that needs orders AND customers is answered from an approved join, not a guessed one.

    draft(run, "TPCH")             every table (rows, key) and every link found, each with its evidence
    approve(run, execute, doc)     the next version in the store, and the links published for agents
    joined_sql(doc, "ORDERS")      the main table with every table its links reach (many-to-one), as one SELECT

How a link is found, most certain first:
    1. a FOREIGN KEY the database declares (EXA_ALL_CONSTRAINT_COLUMNS);
    2. a column that names another table's single-column key - the same name once a short table prefix is taken off
       (O_CUSTKEY and C_CUSTKEY), or <TABLE>_ID against ID - AND whose every non-empty value is in that key (at most
       0.1% missing): checked with one LEFT JOIN each, so a name match alone never makes a link.
A table's key is its declared PRIMARY KEY, else the first column named like a key (ID, ..._ID, ...KEY) that is unique
and never empty. Links are many-to-one: the key side is unique, so joining along them never multiplies rows.

The store keeps one folder per schema beside the tables' folders: ~/.exasol-starter-kit/descriptors/<SCHEMA>/ with
v<n>.json (never rewritten), current.json and draft.json. Approving publishes the links as a view any read-only client
can query, EXAKIT_SEMANTIC.<SCHEMA>__RELATIONS (FROM_TABLE, FROM_COLUMN, TO_TABLE, TO_COLUMN, KIND, EVIDENCE); the
user's own schema and tables are never commented or altered.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any, Callable

from . import publish as publishing
from . import store

FORMAT = 1
SCHEMA = publishing.SCHEMA                     # EXAKIT_SEMANTIC
PREPARED = "EXAKIT_PREPARED"                    # where a joined view is created
MAX_ORPHANS = 0.001                             # a link may miss at most this share of its values
MAX_DEPTH = 3                                   # how far a joined view follows links from the main table
_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_KEYISH = re.compile(r"(^ID$|_ID$|KEY$)", re.IGNORECASE)
_PREFIX = re.compile(r"^[A-Z]{1,3}_(?=.)")

Run = Callable[[str], list[dict[str, Any]]]


def _q(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _lit(text: str) -> str:
    return "'" + str(text).replace("'", "''") + "'"


def schema_name(schema: str) -> str:
    """The schema as the database names it (unquoted names are upper case); BadInput-like ValueError otherwise."""
    name = str(schema).strip().strip('"')
    if not _NAME.match(name):
        raise ValueError(f"'{schema}' is not a schema name")
    return name.upper()


def _kind(column_type: str) -> str:
    upper = str(column_type).upper()
    if upper.startswith(("DECIMAL", "DOUBLE", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "FLOAT", "NUMBER")):
        return "number"
    if upper.startswith(("VARCHAR", "CHAR")):
        return "text"
    return upper.split("(")[0].split(" ")[0].lower()


def _stem(column: str) -> str:
    """The name without a short table prefix: C_CUSTKEY and O_CUSTKEY both CUSTKEY; CUSTOMER_ID stays."""
    return _PREFIX.sub("", column.upper())


def _singular(table: str) -> str:
    upper = table.upper()
    if upper.endswith("IES"):
        return upper[:-3] + "Y"
    return upper[:-1] if upper.endswith("S") and not upper.endswith("SS") else upper


# --- surveying the schema --------------------------------------------------------------------------------------------

def tables(run: Run, schema: str) -> dict[str, dict[str, Any]]:
    """{TABLE: {rows, columns: [{column, type}], key: [..], key_evidence}} for every table of ``schema``."""
    schema = schema_name(schema)
    found: dict[str, dict[str, Any]] = {}
    for row in run("SELECT COLUMN_TABLE AS T, COLUMN_NAME AS C, COLUMN_TYPE AS Y FROM SYS.EXA_ALL_COLUMNS "
                   f"WHERE COLUMN_SCHEMA = {_lit(schema)} AND COLUMN_OBJECT_TYPE = 'TABLE' "
                   "ORDER BY COLUMN_TABLE, COLUMN_ORDINAL_POSITION"):
        found.setdefault(str(row["T"]), {"columns": []})["columns"].append({"column": str(row["C"]), "type": str(row["Y"])})
    if not found:
        raise LookupError(f"The schema {schema} has no tables (or does not exist).")
    declared = _constraints(run, schema)
    counts = run(" UNION ALL ".join(f"SELECT {_lit(t)} AS T, COUNT(*) AS N FROM {_q(schema)}.{_q(t)}" for t in found))
    for row in counts:
        found[str(row["T"])]["rows"] = int(row["N"] or 0)
    for table, info in found.items():
        primary = [c for c, kind in declared.get(table, {}).get("keys", []) if kind == "PRIMARY KEY"]
        if primary:
            info["key"], info["key_evidence"] = primary, "declared primary key"
            continue
        info["key"], info["key_evidence"] = _unique_key(run, schema, table, info), None
        if info["key"]:
            info["key_evidence"] = f"{info['key'][0]} is unique and never empty"
        else:
            info["key_evidence"] = "no unique, never empty column named like a key"
    return found


def _constraints(run: Run, schema: str) -> dict[str, dict[str, list]]:
    """{TABLE: {keys: [(column, type)], references: [(column, ref table, ref column)]}} as the database declares."""
    found: dict[str, dict[str, list]] = {}
    for row in run("SELECT CONSTRAINT_TABLE AS T, CONSTRAINT_TYPE AS K, COLUMN_NAME AS C, REFERENCED_TABLE AS RT, "
                   "REFERENCED_COLUMN AS RC FROM SYS.EXA_ALL_CONSTRAINT_COLUMNS "
                   f"WHERE CONSTRAINT_SCHEMA = {_lit(schema)} ORDER BY CONSTRAINT_TABLE, CONSTRAINT_NAME, ORDINAL_POSITION"):
        entry = found.setdefault(str(row["T"]), {"keys": [], "references": []})
        entry["keys"].append((str(row["C"]), str(row["K"])))
        if str(row["K"]) == "FOREIGN KEY" and row.get("RT"):
            entry["references"].append((str(row["C"]), str(row["RT"]), str(row["RC"])))
    return found


def _unique_key(run: Run, schema: str, table: str, info: dict[str, Any]) -> list[str]:
    candidates = [c["column"] for c in info["columns"] if _KEYISH.search(c["column"])][:6]
    if not candidates or not info.get("rows"):
        return []
    parts = [f"COUNT(DISTINCT {_q(c)}) AS {_q('D_' + c)}, COUNT({_q(c)}) AS {_q('N_' + c)}" for c in candidates]
    row = run(f"SELECT {', '.join(parts)} FROM {_q(schema)}.{_q(table)}")[0]
    for column in candidates:
        if int(row[f"D_{column}"] or 0) == info["rows"] == int(row[f"N_{column}"] or 0):
            return [column]
    return []


def relations(run: Run, schema: str, found: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    """Every many-to-one link, declared or found, each {from, to, kind, evidence, confidence}."""
    schema = schema_name(schema)
    links: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for table, entry in _constraints(run, schema).items():
        for column, ref_table, ref_column in entry["references"]:
            links.append({"from": f"{table}.{column}", "to": f"{ref_table}.{ref_column}", "kind": "many-to-one",
                          "evidence": "declared foreign key", "confidence": "high"})
            seen.add((table, column))
    keys = {t: (info["key"][0], info["columns"]) for t, info in found.items() if len(info.get("key") or []) == 1}
    for table, info in found.items():
        own_key = info.get("key") or []
        for col in info["columns"]:
            column = col["column"]
            if (table, column) in seen or (len(own_key) == 1 and column == own_key[0]):
                continue
            targets = []
            for other, (key, other_columns) in keys.items():
                if other == table:
                    continue
                key_type = next(c["type"] for c in other_columns if c["column"] == key)
                if _kind(key_type) != _kind(col["type"]):
                    continue
                named = (_stem(column) == _stem(key) or column.upper() == key.upper()
                         or (key.upper() == "ID" and column.upper() in (f"{other.upper()}_ID", f"{_singular(other)}_ID")))
                if named:
                    targets.append((other, key))
            for other, key in targets:
                check = run(f"SELECT COUNT(*) AS N, SUM(CASE WHEN T.{_q(key)} IS NULL THEN 1 ELSE 0 END) AS MISSING "
                            f"FROM {_q(schema)}.{_q(table)} S LEFT JOIN {_q(schema)}.{_q(other)} T "
                            f"ON S.{_q(column)} = T.{_q(key)} WHERE S.{_q(column)} IS NOT NULL")[0]
                total, missing = int(check["N"] or 0), int(check["MISSING"] or 0)
                if total and missing <= MAX_ORPHANS * total:
                    found_share = "every value" if not missing else f"{total - missing:,} of {total:,} values"
                    links.append({"from": f"{table}.{column}", "to": f"{other}.{key}", "kind": "many-to-one",
                                  "evidence": f"{column} names {other}'s key {key}; {found_share} found in {other}",
                                  "confidence": "high" if not missing else "medium"})
                    break                                     # one target per column: the first that holds
    return links


def draft(run: Run, schema: str, home: Path | None = None) -> dict[str, Any]:
    """The schema map as found now: the next version, a draft (kept in the store as draft.json)."""
    schema = schema_name(schema)
    found = tables(run, schema)
    doc = {"schema_descriptor": FORMAT, "schema": schema, "version": max(versions(schema, home) or [0]) + 1,
           "status": "draft", "tables": {t: {k: v for k, v in info.items() if k != "columns"} | {
               "columns": [c["column"] for c in info["columns"]]} for t, info in found.items()},
           "relations": relations(run, schema, found)}
    write(schema, "draft.json", doc, home)
    return doc


def check(doc: dict[str, Any]) -> list[str]:
    """What makes a schema map wrong: a link from or to a table or column it does not list."""
    problems = []
    tables_ = doc.get("tables") or {}
    for link in doc.get("relations") or []:
        for side in ("from", "to"):
            table, _, column = str(link.get(side, "")).partition(".")
            if table not in tables_ or column not in (tables_[table].get("columns") or []):
                problems.append(f"the link {link.get('from')} -> {link.get('to')} names {link.get(side)}, which the schema does not have")
    return problems


# --- the store ---------------------------------------------------------------------------------------------------------

def folder(schema: str, home: Path | None = None) -> Path:
    return (home or store.kit_home()) / store.FOLDER / schema_name(schema)


def write(schema: str, name: str, doc: dict[str, Any], home: Path | None = None, *, exclusive: bool = False) -> Path:
    where = folder(schema, home)
    where.mkdir(parents=True, exist_ok=True)
    text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
    path = where / name
    if exclusive:
        try:
            with path.open("x", encoding="utf-8") as handle:
                handle.write(text)
        except FileExistsError as err:
            raise store.VersionTaken(f"{schema} v{doc['version']} was written by someone else meanwhile") from err
    else:
        handle, temp = tempfile.mkstemp(dir=where, prefix=".schema-", suffix=".json")
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(text)
        os.replace(temp, path)
    if os.name != "nt":
        path.chmod(0o600)
    return path


def read(schema: str, name: str, home: Path | None = None) -> dict[str, Any] | None:
    path = folder(schema, home) / name
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None


def versions(schema: str, home: Path | None = None) -> list[int]:
    where = folder(schema, home)
    if not where.is_dir():
        return []
    return sorted(int(m.group(1)) for m in (re.match(r"^v([1-9][0-9]*)\.json$", p.name) for p in where.iterdir()) if m)


def current(schema: str, home: Path | None = None) -> dict[str, Any] | None:
    return read(schema, "current.json", home)


# --- approving and publishing --------------------------------------------------------------------------------------------

def _same(a: dict[str, Any], b: dict[str, Any]) -> bool:
    key = lambda links: sorted((l["from"], l["to"]) for l in links or [])
    return key(a.get("relations")) == key(b.get("relations")) and set(a.get("tables") or {}) == set(b.get("tables") or {})


def approve(run: Run, execute: Callable[[str], Any], doc: dict[str, Any], *, owner: str, reader: str | None = None,
            publish: bool = True, home: Path | None = None, now: dt.datetime | None = None) -> dict[str, Any]:
    """The next version, approved (unchanged when the current one already says this), and the links published."""
    schema = schema_name(doc["schema"])
    wrong = check(doc)
    if wrong:
        raise ValueError("The schema map cannot be approved: " + "; ".join(wrong))
    approved = current(schema, home)
    if approved and _same(approved, doc):
        path = folder(schema, home) / f"v{approved['version']}.json"
        return {"status": "unchanged", "schema": schema, "version": approved["version"], "path": str(path),
                "message": f"{schema} v{approved['version']} already says this; nothing was written. It is stored at {path}"}
    version = max(versions(schema, home) or [0]) + 1
    stamp = (now or dt.datetime.now(dt.timezone.utc)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    final = {**doc, "version": version, "status": "approved", "owner": owner, "approved_at": stamp}
    path = write(schema, f"v{version}.json", final, home, exclusive=True)
    write(schema, "current.json", final, home)
    (folder(schema, home) / "draft.json").unlink(missing_ok=True)
    result: dict[str, Any] = {"status": "approved", "schema": schema, "version": version, "owner": owner,
                              "path": str(path), "relations": len(final["relations"])}
    if publish:
        try:
            for sql in statements(final, reader):
                execute(sql)
            result["published"] = f"{SCHEMA}.{schema}__RELATIONS"
        except Exception as err:                      # the approval stands; say why it is not published
            result["status"], result["reason"] = "approved, not published", f"{type(err).__name__}: {err}"
    return result


def statements(doc: dict[str, Any], reader: str | None) -> list[str]:
    """The view that publishes an approved schema map's links (one row per link), and its grant."""
    schema = schema_name(doc["schema"])
    view = f"{SCHEMA}.{_q(f'{schema}__RELATIONS')}"
    rows = []
    for link in doc.get("relations") or []:
        ft, _, fc = link["from"].partition(".")
        tt, _, tc = link["to"].partition(".")
        rows.append(f"SELECT {_lit(ft)}, {_lit(fc)}, {_lit(tt)}, {_lit(tc)}, {_lit(link['kind'])}, "
                    f"{_lit(str(link['evidence'])[:500])} FROM DUAL")
    body = "\nUNION ALL ".join(rows) if rows else "SELECT '', '', '', '', '', '' FROM DUAL WHERE FALSE"
    about = f"schema={schema}; schema map v{doc['version']}; one row per approved link between its tables"
    found = [f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}",
             f"CREATE OR REPLACE VIEW {view} (FROM_TABLE, FROM_COLUMN, TO_TABLE, TO_COLUMN, KIND, EVIDENCE) AS\n{body}\n"
             f"COMMENT IS {_lit(about)}"]
    if reader:
        found.append(f"GRANT SELECT ON {view} TO {_q(reader)}")
    return found


# --- one wide view along the links ---------------------------------------------------------------------------------------

def joined_sql(doc: dict[str, Any], main: str, depth: int = MAX_DEPTH) -> dict[str, Any]:
    """The main table with every table its links reach (many-to-one, up to ``depth`` steps), as {view, sql, joins:
    [{table, on, via, path}], columns}. A table reached along two paths is joined once per path - an order line's
    supplier's country and its customer's country are two different countries - and then its columns are named after
    the path (SUPPLIER_NATION_N_NAME, ORDERS_CUSTOMER_NATION_N_NAME); a table reached once keeps its column names
    unless another table has the same one. A joined table's key is left out: the side it came from holds it."""
    schema = schema_name(doc["schema"])
    main = main.split(".")[-1].strip('"').upper()
    tables_ = doc["tables"]
    if main not in tables_:
        raise LookupError(f"{schema} has no table {main} (it has: {', '.join(tables_)}).")
    joins: list[dict[str, Any]] = []
    frontier = [("T0", main, [main])]                       # (alias, table, the tables from the main one to it)
    for _ in range(depth):
        following = []
        for alias, table, path in frontier:
            for link in doc.get("relations") or []:
                ft, _, fc = link["from"].partition(".")
                tt, _, tc = link["to"].partition(".")
                if ft != table or tt in path:               # never back along the path it came by
                    continue
                child = f"T{len(joins) + 1}"
                joins.append({"table": tt, "alias": child, "on": f"{alias}.{_q(fc)} = {child}.{_q(tc)}",
                              "via": link["from"], "key": tc, "path": path[1:] + [tt]})
                following.append((child, tt, path + [tt]))
        frontier = following
    reached: dict[str, int] = {}
    for join in joins:
        reached[join["table"]] = reached.get(join["table"], 0) + 1
    names: dict[str, int] = {}
    for column in tables_[main]["columns"]:
        names[column] = names.get(column, 0) + 1
    for join in joins:
        if reached[join["table"]] == 1:
            for column in tables_[join["table"]]["columns"]:
                names[column] = names.get(column, 0) + 1
    select = [f"T0.{_q(c)}" for c in tables_[main]["columns"]]
    columns = list(tables_[main]["columns"])
    for join in joins:
        table = join["table"]
        for column in tables_[table]["columns"]:
            if column == join["key"]:
                continue
            if reached[table] > 1:
                name = "_".join(join["path"]) + f"_{column}"
            else:
                name = column if names.get(column, 0) == 1 else f"{table}_{column}"
            select.append(f"{join['alias']}.{_q(column)} AS {_q(name)}")
            columns.append(name)
    sql = (f"SELECT {', '.join(select)}\nFROM {_q(schema)}.{_q(main)} T0"
           + "".join(f"\nLEFT JOIN {_q(schema)}.{_q(j['table'])} {j['alias']} ON {j['on']}" for j in joins))
    view = f"{PREPARED}.{_q(f'{schema}__{main}__JOINED')}"
    return {"view": view, "sql": sql, "joins": joins, "columns": columns, "main": f"{schema}.{main}"}
