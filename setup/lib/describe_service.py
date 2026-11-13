#!/usr/bin/env python3
"""The service behind `exakit describe` (DS-2, DS-5), shared by setup/lib/describe.sh and describe.ps1 so the two
cannot drift, and by exakit_nb.describe() in a notebook. It drives the role-per-column descriptor in
setup/lib/descriptor: roles.py (one of eight roles per column), profile.py (one profiling pass in SQL), draft.py (a
deterministic draft), flow.py (describe and approve, versioned in the kit's store), publish.py and semantic_model.py
(the approved roles and links as an Exasol Semantic Views model, the add-on installed when the database lacks it).
Runs on the kit's notebook Python (pyexasol is there); otherwise the standard library only.

    python describe_service.py draft <SCHEMA.TABLE> [--id <dataset id>] [--json] [--write <path>] [--force]
        the approved descriptor when the table still matches it, else a fresh draft (kept in the store as draft.yaml
        until it is approved); YAML, or one JSON object with --json. --sample is accepted and ignored: a local table is
        profiled in full, a virtual one over its first 10,000 rows.
    python describe_service.py approve <dataset id | SCHEMA.TABLE | draft.yaml> [--role <slot>=<COLUMN> ...]
                                       [--set <COLUMN>=<role> ...] [--owner <who>] [--no-comments] [--json]
        approves the table's latest draft with the corrections given: --role sets a slot (key, time, text, target,
        category, entity; date and label still name time and target; slot=- empties it), --set gives a column a role. Writes
        v<n+1>.yaml and current.yaml, then rebuilds the schema's semantic model (--no-comments skips it).
    python describe_service.py show <id | SCHEMA.TABLE> [--version n] [--json]   one version (the current one)
    python describe_service.py versions <id | SCHEMA.TABLE> [--json]             every version with its owner
    python describe_service.py comments <id | SCHEMA.TABLE> [--json]             rebuild its schema's model again
    python describe_service.py profile <SCHEMA.TABLE>                            the profile alone, as JSON
    python describe_service.py schema <SCHEMA> [--json]
        the whole schema as one map: every table (rows, key) and every many-to-one link between them, declared or
        found (a column naming another table's key whose every value is in it), each with its evidence; kept in the
        store as draft.json until it is approved.
    python describe_service.py schema-approve <SCHEMA> [--link <T.COL>=<T.KEY> ...] [--unlink <T.COL> ...]
                                                       [--owner <who>] [--no-comments] [--json]
        approves the schema's draft with the corrections given (--link adds a link, --unlink removes one): writes
        v<n+1>.json and current.json, then rebuilds the schema's semantic model with the links as relationships.
    python describe_service.py model <NAME> --table <SCHEMA.TABLE> ... [--link <S.T.COL>=<S.T.KEY> ...] [--ai]
                                            [--description <text>] [--dry-run] [--json]
        a semantic model over tables of any schemas - sample data, loaded files, external sources - from their approved
        column maps, each schema's approved links and the links given; --ai lets the user's model propose business
        names, synonyms and metrics (each checked before use); --dry-run says what it would publish.
        --schemas A,B,C takes every approved table of those schemas; --find-links finds the links between the
        schemas from their values and uses the ones the data backs (the doubtful ones are only named).
    python describe_service.py links <A,B,C> [--ai] [--link <S.T.COL>=<S.T.KEY> ...] [--json]
        the links between tables of different schemas, each with its evidence; --link checks a pair you (or an agent)
        have in mind against the data; nothing is written.
    python describe_service.py refresh <NAME> [--json]     rebuild a model the kit published, with what was approved since
    python describe_service.py models [--json]             every semantic model in the database

Exit codes: 0 ok; 2 bad arguments or roles (the message names the column, the slot and the reason); 3 the table or
the descriptor is not there; 4 the database is not reachable; 5 another writer took the version number.

The database steps connect through pyexasol as the kit's admin user: EXAKIT_PYX_DSN, EXAKIT_PYX_USER and
EXAKIT_PYX_PWFILE (the FILE holding the password - the password itself never reaches a command line, an output or a
log). EXAKIT_MCP_READER names the read-only user the published model is granted to. Profiling is SELECTs; approving
writes to the database only the semantic model (Semantic Views' own catalog and its SEM_<MODEL> schema) - the user's
own tables are never commented or altered.

digest() is the content hash of a descriptor's role columns that a training handoff records (unchanged from the
kit's earlier describe service): one order-independent statement over the role columns, the table's first rows only
for a virtual table.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from descriptor import draft as drafting, flow, profile as profiling, publish as publishing, store  # noqa: E402
from descriptor import schema as schema_map  # noqa: E402

SAMPLE = 10000                       # rows of a virtual table the content digest reads
DIGEST_SLICES = 5                    # 48-bit slices of each row hash summed (60 of the 64 hex chars)
NULL_MARK = "<null>"
READER_VARIABLE = "EXAKIT_MCP_READER"
SLOT_NAMES = {"key": "key", "time": "time", "date": "time", "text": "text", "target": "target", "label": "target",
              "category": "category", "entity": "entity"}

class Refused(ValueError):
    """Input the kit refuses; the message names what is wrong. Exit 2."""

    code = 2


class NotFound(Refused):
    """The table (or the descriptor id) is not there. Exit 3."""

    code = 3


class Unreachable(RuntimeError):
    """The database could not be reached, or the connection settings are not there. Exit 4."""

    code = 4


class Conflict(RuntimeError):
    """The next version number was taken twice while approving. Exit 5."""

    code = 5


def quoted(name: str) -> str:
    """``name`` as a quoted SQL identifier (a quote inside doubled), whatever it holds."""
    return '"' + name.replace('"', '""') + '"'


def split_table(table: str) -> tuple[str, str]:
    """(schema, name) of ``SCHEMA.TABLE``: a plain part is upper-cased, a quoted part ("order data"."my table") kept
    as written; anything else is refused."""
    match = re.match(r'^\s*("(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*("(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)\s*$', table or "")
    if not match:
        raise Refused(f"Name the table as SCHEMA.TABLE (quote a part that is not a plain name: \"my schema\".\"order data\"), not '{table}'.")

    def part(text: str) -> str:
        return text[1:-1].replace('""', '"') if text.startswith('"') else text.upper()

    return part(match.group(1)), part(match.group(2))


def table_ref(schema: str, name: str) -> str:
    """``"SCHEMA"."TABLE"`` for SQL."""
    return f"{quoted(schema)}.{quoted(name)}"


def connect():
    """A pyexasol connection from EXAKIT_PYX_DSN / EXAKIT_PYX_USER / EXAKIT_PYX_PWFILE; Unreachable names what is
    missing or why the connection failed, never the password."""
    dsn, user, pwfile = (os.environ.get(k, "") for k in ("EXAKIT_PYX_DSN", "EXAKIT_PYX_USER", "EXAKIT_PYX_PWFILE"))
    if not dsn or not pwfile:
        raise Unreachable("No database connection settings (the kit's manifest has no runtime); check with: exakit status")
    try:
        password = Path(pwfile).read_text(encoding="utf-8").strip()
    except OSError as err:
        raise Unreachable(f"The admin credential file cannot be read ({err.strerror}); repair with: exakit repair-runtime") from err
    # pyexasol's usage telemetry stays off unless the user set the variable (marketplace/kit_telemetry.py).
    os.environ.setdefault("EXASOL_TELEMETRY_DISABLE", "1")
    try:
        import pyexasol
    except ImportError as err:
        raise Unreachable("pyexasol is not installed in this Python; run through the kit: exakit describe <table>") from err
    import ssl
    kw = dict(dsn=dsn, user=user or "sys", password=password, fetch_dict=True)
    try:
        return pyexasol.connect(encryption=True, websocket_sslopt={"cert_reqs": ssl.CERT_NONE}, **kw)
    except Exception:
        try:
            return pyexasol.connect(encryption=False, **kw)
        except Exception as err:
            raise Unreachable(f"The database at {dsn} is not reachable ({type(err).__name__}); start it with: exakit start") from err


def _rows(conn, sql: str) -> list[dict[str, Any]]:
    """The rows of one statement as dicts, whether the connection fetches dicts or tuples."""
    statement = conn.execute(sql)
    rows = statement.fetchall()
    if rows and not isinstance(rows[0], dict):
        names = statement.column_names()
        rows = [dict(zip(names, row)) for row in rows]
    return rows


def column_kind(column_type: str) -> str:
    """What a column holds, from its SQL type: text, integer, number, date, timestamp, boolean or other."""
    upper = column_type.upper()
    if upper.startswith(("VARCHAR", "CHAR")):
        return "text"
    if upper.startswith("DATE"):
        return "date"
    if upper.startswith("TIMESTAMP"):
        return "timestamp"
    if upper.startswith("BOOLEAN"):
        return "boolean"
    if upper.startswith("DECIMAL"):
        return "integer" if re.search(r",\s*0\s*\)", upper) else "number"
    if upper.startswith(("DOUBLE", "FLOAT")):
        return "number"
    return "other"


def _columns(conn, schema: str, name: str) -> tuple[list[dict[str, Any]], bool]:
    """The table's columns in order, and whether it is a virtual table; NotFound when there is no such table."""
    sql = ("SELECT c.COLUMN_NAME, c.COLUMN_TYPE, c.COLUMN_ORDINAL_POSITION, "
           "CASE WHEN v.TABLE_NAME IS NULL THEN 0 ELSE 1 END AS IS_VIRTUAL "
           "FROM EXA_ALL_COLUMNS c LEFT JOIN EXA_ALL_VIRTUAL_TABLES v "
           "ON v.TABLE_SCHEMA = c.COLUMN_SCHEMA AND v.TABLE_NAME = c.COLUMN_TABLE "
           f"WHERE c.COLUMN_SCHEMA = '{schema.replace(chr(39), chr(39) * 2)}' AND c.COLUMN_TABLE = '{name.replace(chr(39), chr(39) * 2)}' "
           "ORDER BY c.COLUMN_ORDINAL_POSITION")
    rows = _rows(conn, sql)
    if not rows:
        raise NotFound(f"No table {schema}.{name} in the database (its schema and table name, as the database spells them; "
                       "list them with: exakit sql \"SELECT TABLE_SCHEMA, TABLE_NAME FROM EXA_ALL_TABLES\")")
    columns = [{"column": str(r["COLUMN_NAME"]), "type": str(r["COLUMN_TYPE"]), "position": int(r["COLUMN_ORDINAL_POSITION"]),
                "kind": column_kind(str(r["COLUMN_TYPE"]))} for r in rows]
    return columns, any(int(r["IS_VIRTUAL"] or 0) for r in rows)


def _role_columns(roles: dict[str, Any]) -> list[tuple[str, str]]:
    """(role, column) for every role column in role order: entity, category, date, label, then the text columns."""
    out = []
    for role in ("entity", "category", "date", "label", "text"):
        ref = roles.get(role)
        if ref is None:
            continue
        for item in (ref if isinstance(ref, list) else [ref]):
            out.append((role, item["column"] if isinstance(item, dict) else str(item)))
    return out


def _canonical(col: dict[str, Any]) -> str:
    """A column as text the way every session prints it: dates by TO_CHAR, the rest by CAST."""
    q = quoted(col["column"])
    if col["kind"] == "date":
        return f"TO_CHAR({q}, 'YYYY-MM-DD')"
    if col["kind"] == "timestamp":
        return f"TO_CHAR({q}, 'YYYY-MM-DD HH24:MI:SS.FF6')"
    return f"CAST({q} AS VARCHAR(2000000))"


def digest_sql(ref: str, columns: list[dict[str, Any]], limit: int | None = None) -> str:
    """The order-independent content hash statement over ``columns`` (see THE DIGEST in the module doc); with
    ``limit``, over the table's first ``limit`` rows only."""
    hashed = " || CHR(31) || ".join(f"COALESCE({_canonical(c)}, '{NULL_MARK}')" for c in columns)
    sums = ", ".join(f"SUM(TO_NUMBER(SUBSTR(H, {1 + 12 * i}, 12), 'XXXXXXXXXXXX')) AS S{i}" for i in range(DIGEST_SLICES))
    inner = f"(SELECT {', '.join(quoted(c['column']) for c in columns)} FROM {ref} LIMIT {int(limit)})" if limit else ref
    return f"SELECT COUNT(*) AS N, {sums} FROM (SELECT HASH_SHA256({hashed}) AS H FROM {inner})"


def digest(conn, table: str, roles: dict[str, Any], sample: int = SAMPLE) -> dict[str, Any]:
    """The table digest for ``roles`` ({role: column | [columns]}, the draft's shape, or {role: {table, column}}):
    ``digest`` (sha256:...), ``scope`` (full, or sample for a virtual table hashed over its first ``sample`` rows),
    ``rows``, ``hashed_rows``, ``statements`` and the ``sql`` of the content hash. A role column the table lacks is
    refused naming the role; a table that is not there is NotFound."""
    schema, name = split_table(table)
    ref = table_ref(schema, name)
    columns, virtual = _columns(conn, schema, name)
    by_name = {c["column"]: c for c in columns}
    wanted = _role_columns(roles)
    lacking = [(role, c) for role, c in wanted if c not in by_name]
    if lacking:
        raise Refused(f"{schema}.{name} has no column " + ", ".join(f"{c} (the {role} role)" for role, c in lacking)
                      + f"; it has: {', '.join(by_name)}.")
    if not wanted:
        raise Refused("No role names a column, so there is nothing to digest.")
    hashed = [by_name[c] for _role, c in wanted]
    statements = 1
    if virtual:
        rows = int(_rows(conn, f"SELECT COUNT(*) AS N FROM {ref}")[0]["N"])
        statements += 1
        sql = digest_sql(ref, hashed, sample)
    else:
        sql = digest_sql(ref, hashed)
    row = _rows(conn, sql)[0]
    statements += 1
    if not virtual:
        rows = int(row["N"])
    content = [int(row.get(f"S{i}") or 0) for i in range(DIGEST_SLICES)]
    scope = "sample" if virtual else "full"
    canonical = {"table": f"{schema}.{name}", "columns": [[c["column"], c["type"]] for c in columns], "rows": rows,
                 "scope": scope, "role_columns": [c["column"] for c in hashed], "hashed_rows": int(row["N"]), "content": content}
    value = "sha256:" + hashlib.sha256(json.dumps(canonical, separators=(",", ":"), sort_keys=True).encode("utf-8")).hexdigest()
    return {"digest": value, "scope": scope, "rows": rows, "hashed_rows": int(row["N"]), "sample": sample if virtual else None,
            "virtual": virtual, "statements": statements, "sql": sql, "columns": columns}


# --- describe and approve --------------------------------------------------------------------------------------------

def kit_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _rules():
    for folder in (kit_root() / "tools", kit_root() / "notebook" / "package"):
        if str(folder) not in sys.path:
            sys.path.append(str(folder))
    try:
        import descriptor_rules
    except ImportError:
        from exakit_nb import descriptor_rules          # type: ignore[no-redef]
    return descriptor_rules


def resolve(name: str, root: Path | None = None) -> str:
    """The table a command means: SCHEMA.TABLE as given, else a dataset id's - its approved descriptor in the store,
    else the descriptor the kit ships."""
    if "." in name and not name.endswith((".yaml", ".yml", ".json")):
        return flow.table_name(name)
    rules = _rules()
    stored = _stored(name)
    if stored is not None:
        return stored
    shipped = rules.descriptor_file((root or kit_root()) / "data" / "datasets" / name)
    if shipped is not None:
        return rules.read_descriptor(shipped).fact_table
    raise NotFound(f"No descriptor '{name}': not approved in the kit's store and not a dataset the kit ships "
                   "(describe its table first: exakit describe SCHEMA.TABLE).")


def _stored(dataset: str) -> str | None:
    root = store.kit_home() / store.FOLDER
    if not root.is_dir():
        return None
    for folder in sorted(root.iterdir()):
        for name in (store.CURRENT, store.DRAFT):
            path = folder / name
            if path.is_file() and re.search(rf'^dataset:\s*"?{re.escape(dataset)}"?\s*$', path.read_text(encoding="utf-8"), re.M):
                return folder.name
    return None


def adopt_shipped(table: str, root: Path | None = None) -> int | None:
    """A table the kit ships, with nothing in the kit's store yet: its shipped approved descriptor becomes the store's
    current version, so a review starts on the approved roles (the target among them, which is never drafted) and an
    approval builds on it instead of replacing it. The version adopted, or None."""
    table = flow.table_name(table)
    if store.current(table) is not None or store.versions(table):
        return None
    datasets = (root or kit_root()) / "data" / "datasets"
    for folder in sorted(datasets.iterdir()) if datasets.is_dir() else ():
        path = _rules().descriptor_file(folder)
        if path is None:
            continue
        try:
            doc = flow.load(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if doc.get("status") == "approved" and flow.table_name(str((doc.get("source") or {}).get("object", ""))) == table:
            text = drafting.to_yaml(doc)
            store.write_version(table, int(doc.get("version") or 1), text)
            store.replace_current(table, text)
            stale = store.folder(table) / store.DRAFT          # drafted before the approved roles were in the store
            if stale.is_file():
                stale.unlink()
            return int(doc.get("version") or 1)
    return None


def describe(conn, table: str, dataset: str | None = None, force: bool = False) -> dict[str, Any]:
    """flow.describe over the connection: {status, doc, profile, changed, previous}."""
    adopt_shipped(table)
    try:
        return flow.describe(lambda sql: _rows(conn, sql), table, dataset=dataset, force=force)
    except LookupError as err:
        raise NotFound(str(err)) from err


def _correct(doc: dict[str, Any], roles: list[str], sets: list[str]) -> dict[str, Any]:
    """The draft with --set COLUMN=role and --role slot=COLUMN applied; a slot set loses its empty-slot reason."""
    for item in sets:
        column, _, role = item.partition("=")
        if column not in doc["columns"]:
            raise Refused(f"--set names {column}, which is not a column of {doc['source']['object']} (it has: {', '.join(doc['columns'])}).")
        if role not in _rules().COLUMN_ROLES:
            raise Refused(f"--set {item}: the roles are {', '.join(_rules().COLUMN_ROLES)}.")
        doc["columns"][column] = dict(doc["columns"][column], role=role, confidence="high", evidence="set by hand")
    slots = {}
    for item in roles:
        name, _, column = item.partition("=")
        if name not in SLOT_NAMES:
            raise Refused(f"--role {item}: the slots are key, time, text, target, category and entity.")
        column = column.split(",")[0].strip()
        if column in ("", "-"):                                  # slot=- leaves it empty on purpose
            slots[SLOT_NAMES[name]] = None
        else:
            slots[SLOT_NAMES[name]] = column.upper() if column.upper() in doc["columns"] else column
    return drafting.with_slots(doc, **slots) if slots else doc


def load_draft(target: str) -> dict[str, Any]:
    """A draft to approve: a draft file, else the latest draft of the table (or of a dataset id's table)."""
    path = Path(target).expanduser()
    if path.is_file():
        return flow.load(path.read_text(encoding="utf-8"))
    table = resolve(target)
    adopt_shipped(table)
    text = store.draft(table) or store.current(table)
    if text is None:
        raise NotFound(f"Nothing to approve for {table}: describe it first (exakit describe {table}).")
    return flow.load(text)


def approve(conn, target: str, roles: list[str] | None = None, sets: list[str] | None = None, owner: str | None = None,
            publish: bool = True, log=None) -> dict[str, Any]:
    return approve_document(conn, _correct(load_draft(target), roles or [], sets or []), owner, publish, log)


def approve_document(conn, doc: dict[str, Any], owner: str | None = None, publish: bool = True, log=None) -> dict[str, Any]:
    """flow.approve for a draft held in memory (a notebook's, with its corrections); the exit-code exceptions."""
    try:
        return flow.approve(lambda sql: _rows(conn, sql), conn.execute, doc, owner=owner, reader=os.environ.get(READER_VARIABLE),
                            publish=publish, log=log)
    except store.VersionTaken as err:
        raise Conflict(str(err)) from err
    except LookupError as err:
        raise NotFound(str(err)) from err
    except ValueError as err:
        raise Refused(str(err)) from err


def versions(target: str) -> list[dict[str, Any]]:
    table = resolve(target)
    found = []
    for number in store.versions(table):
        doc = flow.load(store.read(table, number))
        found.append({"version": number, "status": doc.get("status"), "owner": doc.get("owner"), "approved_at": doc.get("approved_at"),
                      "digest": doc["source"].get("schema_digest"), "path": str(store.folder(table) / f"v{number}.yaml")})
    return found


def show(target: str, version: int | None = None) -> dict[str, Any]:
    table = resolve(target)
    if version is None:
        text = store.current(table)
        if text is None:
            shipped = _rules().descriptor_file(kit_root() / "data" / "datasets" / target) if "." not in target else None
            if shipped is None:
                raise NotFound(f"Nothing is approved for {table} yet.")
            return {"path": str(shipped), "text": shipped.read_text(encoding="utf-8"), "version": 1}
        return {"path": str(store.folder(table) / store.CURRENT), "text": text, "version": flow.load(text)["version"]}
    if version not in store.versions(table):
        raise NotFound(f"No version {version} of {table} (the versions are {', '.join(map(str, store.versions(table))) or 'none'}).")
    return {"path": str(store.folder(table) / f"v{version}.yaml"), "text": store.read(table, version), "version": version}


def comments(conn, target: str) -> dict[str, Any]:
    table = resolve(target)
    text = store.current(table)
    if text is None:
        raise NotFound(f"Nothing is approved for {table} yet: approve it first (exakit describe {target} --approve).")
    return publishing.publish(conn.execute, lambda sql: _rows(conn, sql), flow.load(text), os.environ.get(READER_VARIABLE))


# --- the whole schema ------------------------------------------------------------------------------------------------

def describe_schema(conn, schema: str) -> dict[str, Any]:
    """{status: draft, doc, approved: the current approved version or None}: the schema as found now."""
    try:
        doc = schema_map.draft(lambda sql: _rows(conn, sql), schema)
    except LookupError as err:
        raise NotFound(str(err)) from err
    except ValueError as err:
        raise Refused(str(err)) from err
    approved = schema_map.current(doc["schema"])
    return {"status": "draft", "doc": doc, "approved": approved["version"] if approved else None}


def edit_links(doc: dict[str, Any], links: list[str] | None = None, unlinks: list[str] | None = None) -> dict[str, Any]:
    """The schema map with links added (``T.COL=T.KEY``) and removed (``T.COL``), each marked as the user's."""
    doc = json.loads(json.dumps(doc))
    for spec in unlinks or []:
        name = spec.strip().upper()
        if not any(l["from"].upper() == name for l in doc["relations"]):
            raise Refused(f"There is no link from {spec} to remove (the links are from: "
                          f"{', '.join(l['from'] for l in doc['relations']) or 'none'}).")
        doc["relations"] = [l for l in doc["relations"] if l["from"].upper() != name]
    for spec in links or []:
        source, sep, target = spec.partition("=")
        if not sep or "." not in source or "." not in target:
            raise Refused(f"--link takes TABLE.COLUMN=TABLE.KEY, not '{spec}'.")
        source, target = source.strip().upper(), target.strip().upper()
        doc["relations"] = [l for l in doc["relations"] if l["from"].upper() != source]
        doc["relations"].append({"from": source, "to": target, "kind": "many-to-one", "evidence": "set by you",
                                 "confidence": "high"})
    problems = schema_map.check(doc)
    if problems:
        raise Refused("; ".join(problems))
    return doc


def approve_schema(conn, schema: str, links: list[str] | None = None, unlinks: list[str] | None = None,
                   owner: str | None = None, publish: bool = True, doc: dict[str, Any] | None = None) -> dict[str, Any]:
    """Approve the schema's draft (or ``doc``, a notebook's) with the corrections given."""
    try:
        name = schema_map.schema_name(schema)
    except ValueError as err:
        raise Refused(str(err)) from err
    doc = doc or schema_map.read(name, "draft.json")
    if doc is None:
        raise NotFound(f"There is no draft of {name}: describe it first (exakit describe --schema {name}).")
    try:
        return schema_map.approve(lambda sql: _rows(conn, sql), conn.execute, edit_links(doc, links, unlinks),
                                  owner=flow.owner_name(owner), reader=os.environ.get(READER_VARIABLE), publish=publish)
    except store.VersionTaken as err:
        raise Conflict(str(err)) from err
    except ValueError as err:
        raise Refused(str(err)) from err


def schema_text(doc: dict[str, Any]) -> str:
    """The schema map for a terminal: its tables, then its links with their evidence."""
    tables, links = len(doc["tables"]), len(doc["relations"])
    lines = [f"{doc['schema']} - {doc['status']} schema map v{doc['version']}: {tables} table{'s' * (tables != 1)}, "
             f"{links} link{'s' * (links != 1)}"]
    for table, info in doc["tables"].items():
        key = ", ".join(info.get("key") or []) or "none"
        lines.append(f"  {table:<24} {int(info.get('rows') or 0):>12,} rows   key {key} ({info.get('key_evidence')})")
    for link in doc["relations"]:
        lines.append(f"  {link['from']} -> {link['to']}   ({link['evidence']})")
    return "\n".join(lines)


def model_notes(doc: dict[str, Any], profile: dict[str, Any]) -> dict[str, str] | None:
    """Step 7, optional: one line per column from the user's model, when EXAKIT_MODEL_ID and EXAKIT_PROVIDER_BASE_URL
    are both set. ONE call with each column's name, type, role, evidence and top values - never a row, never a
    sensitive column - answered as strict JSON; anything that does not parse is dropped with one warning line. A note
    never decides a role: the roles are drafted before this is asked, and the notes only fill each column's ``note``."""
    if not os.environ.get("EXAKIT_MODEL_ID", "").strip() or not os.environ.get("EXAKIT_PROVIDER_BASE_URL", "").strip():
        return None
    entries = doc.get("columns") or {}
    facts = []
    for column in profile.get("columns", []):
        entry = entries.get(column["column"], {})
        if entry.get("sensitive"):
            continue
        facts.append({k: v for k, v in (("column", column["column"]), ("type", column.get("type")), ("role", entry.get("role")),
                                          ("evidence", entry.get("evidence")), ("top", [t[0] for t in column.get("top", [])][:5]))
                      if v})
    table = (doc.get("source") or {}).get("object") or doc.get("fact_table")
    prompt = (f"Table {table}. For each column write one short line (under 120 characters) saying what it probably holds, "
              "from these facts only. Answer with one JSON object mapping column name to the line, nothing else.\n"
              f"Columns: {json.dumps(facts, ensure_ascii=False)}")
    config = None
    try:
        folder = kit_root() / "notebook" / "package"
        if folder.is_dir() and str(folder) not in sys.path:
            sys.path.insert(0, str(folder))
        from exakit_nb.model_config import create_client, resolve, sampling
        config = resolve()
        answer = create_client(config).chat.completions.create(model=config.model_id, **sampling(),
                                                              messages=[{"role": "user", "content": prompt}])
        given = json.loads(answer.choices[0].message.content or "")
        allowed = {f["column"] for f in facts}
        notes = {str(k): " ".join(str(v).split())[:200] for k, v in given.items() if str(k) in allowed and str(v).strip()}
        return notes or None
    except Exception as err:              # noqa: BLE001 - whatever the model or the client raised: the draft stands
        message = config.redact(str(err)) if config else str(err)
        print(f"Warning: no model notes ({type(err).__name__}: {(message.splitlines() or ['request failed'])[0][:120]}); "
              "the draft is unchanged.", file=sys.stderr)
        return None


def _chat(prompt: str) -> str:
    """One answer from the user's own model (EXAKIT_MODEL_ID and EXAKIT_PROVIDER_BASE_URL), as text."""
    folder = kit_root() / "notebook" / "package"
    if folder.is_dir() and str(folder) not in sys.path:
        sys.path.insert(0, str(folder))
    from exakit_nb.model_config import create_client, resolve, sampling
    config = resolve()
    try:
        answer = create_client(config).chat.completions.create(model=config.model_id, **sampling(),
                                                              messages=[{"role": "user", "content": prompt}])
    except Exception as err:                   # the key never reaches a message
        raise RuntimeError(config.redact(str(err)) if config else str(err)) from None
    return answer.choices[0].message.content or ""


def semantic_ai(spec: dict[str, Any], chat=None) -> dict[str, Any]:
    """The user's model proposes the semantic fields: business names, comments and synonyms for every dimension,
    fact and metric, and the metrics people will ask for. One call, metadata only (names, types, grains, column notes,
    a category's top values; never a row, never a sensitive column). Every proposed metric is checked (ai_accept)
    before it is offered. {labels, extra, refused, error}: with no model configured, nothing but the reason."""
    from descriptor import semantic_model as sm

    if chat is None:
        if not os.environ.get("EXAKIT_MODEL_ID", "").strip() or not os.environ.get("EXAKIT_PROVIDER_BASE_URL", "").strip():
            return {"labels": {}, "extra": [], "refused": [], "error": "no model is configured (EXAKIT_MODEL_ID and "
                    "EXAKIT_PROVIDER_BASE_URL); the model keeps the names the column maps give"}
        chat = _chat
    prompt = sm.AI_INSTRUCTIONS + "\n\nModel: " + json.dumps(sm.ai_facts(spec), ensure_ascii=False, default=str)
    try:
        text = chat(prompt).strip()
        if text.startswith("```"):
            text = text.strip("`").split("\n", 1)[1] if "\n" in text else text
            text = text.rsplit("```", 1)[0]
        answer = json.loads(text[text.find("{"):text.rfind("}") + 1])
    except Exception as err:                   # noqa: BLE001 - whatever the model answered, the model stands
        return {"labels": {}, "extra": [], "refused": [],
                "error": f"the model's answer was not used ({type(err).__name__}: {str(err).splitlines()[0][:160] if str(err) else ''})"}
    labels, extra, refused = sm.ai_accept(spec, answer if isinstance(answer, dict) else {})
    return {"labels": labels, "extra": extra, "refused": refused, "error": None}


def semantic_model(conn, name: str, tables: list[str], links: list | None = None, *, ai: bool = False,
                   dry_run: bool = False, description: str | None = None, chat=None, progress=None,
                   schemas: list[str] | None = None, discover: bool = False,
                   table_notes: dict[str, str] | None = None) -> dict[str, Any]:
    """A semantic model over tables of any schemas (sample data, loaded files, external sources), built from their
    approved column maps and the links given as ``S.T.COL=S.T.KEY`` (with each schema's approved links too). A link
    may also be a dict as find_links returns it ({"from", "to", ...its evidence}) with an optional "note" in a
    person's words: its evidence and the note are stored in the model with it. ``table_notes`` ({SCHEMA.TABLE: text})
    says what a table is; the model keeps it as that entity's description. With ``ai`` the user's model proposes the
    fields first. ``dry_run`` builds the spec and says what it would publish."""
    from descriptor import semantic_model as sm

    names = []
    for table in tables:
        schema, object_name = split_table(table)
        names.append(f"{schema}.{object_name}")
    skipped: list[str] = []
    wanted = [schema_map.schema_name(s) for s in schemas or []]
    if wanted:
        # whole schemas: every table of them with an approved column map (the rest are named, never guessed)
        approved, _keys, _roles, _notes = _approved_in(wanted)
        names += [t for t in sorted(approved) if t not in names]
        from descriptor import links as linking
        every, _virtual = linking.columns(lambda sql: _rows(conn, sql), wanted)
        skipped = sorted(t for t in every if t not in approved)
    if not names:
        raise Refused("Nothing to model: name tables (--table SCHEMA.TABLE) or schemas (--schemas A,B) that have "
                      "approved column maps. Approve one with: exakit describe SCHEMA.TABLE --approve")
    joins = []
    for spec in links or []:
        if isinstance(spec, dict):
            source, target = str(spec.get("from") or "").strip().upper(), str(spec.get("to") or "").strip().upper()
            if source.count(".") != 2 or target.count(".") != 2:
                raise Refused(f"A link names SCHEMA.TABLE.COLUMN on both sides, not '{source}' and '{target}'.")
            evidence = {k: spec[k] for k in ("proposed_by", "found", "checked", "share", "key_evidence", "from_live",
                                             "to_live", "evidence_text", "rows", "confidence") if k in spec}
            evidence.setdefault("proposed_by", "you")
            note = " ".join(str(spec.get("note") or "").split())[:300]
            if note:
                evidence["note"] = note
            elif "evidence_text" not in evidence:
                evidence["note"] = "given by a person"
            joins.append({"from": source, "to": target, "evidence": evidence})
            continue
        source, sep, target = spec.partition("=")
        if not sep or source.count(".") != 2 or target.count(".") != 2:
            raise Refused(f"--link takes SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY, not '{spec}'.")
        joins.append({"from": source.strip().upper(), "to": target.strip().upper(),
                      "evidence": {"proposed_by": "you", "note": "given with --link"}})
    discovered: dict[str, Any] | None = None
    model_schemas = sorted({n.split(".", 1)[0] for n in names})
    if discover and len(model_schemas) > 1:
        # links across the sources, from the values: the ones the data backs are used, the doubtful ones only named
        discovered = find_links(conn, model_schemas, ai=ai, chat=chat, progress=progress)
        for link in discovered["links"]:
            inside = link["from"].rsplit(".", 1)[0] in names and link["to"].rsplit(".", 1)[0] in names
            if inside and link["confidence"] == "high" and not any(j["from"] == link["from"] for j in joins):
                joins.append({"from": link["from"], "to": link["to"],
                              "evidence": {k: link[k] for k in ("proposed_by", "found", "checked", "share", "key_evidence",
                                                                "from_live", "to_live", "evidence_text", "rows")
                                           if k in link}})
    for schema in sorted({n.split(".", 1)[0] for n in names}):
        for link in publishing.schema_links(schema):
            if link["from"].rsplit(".", 1)[0] in names and link["to"].rsplit(".", 1)[0] in names \
                    and not any(j["from"] == link["from"] for j in joins):
                joins.append(link)
    rows = lambda sql: _rows(conn, sql)
    try:
        spec = publishing.build_model(rows, names, joins, name, description=description)
    except sm.ModelRefused as err:
        raise Refused(str(err)) from err
    said = {str(t).upper(): " ".join(str(text or "").split())[:400] for t, text in (table_notes or {}).items()}
    for entity in spec["entities"]:
        about = said.get(f"{entity['schema']}.{entity['table']}".upper())
        if about:
            entity["description"] = about + (" (an external source, read live)" if entity.get("virtual") else "")
    proposal = semantic_ai(spec, chat) if ai else {"labels": {}, "extra": [], "refused": [], "error": None}
    if proposal["labels"]:
        publishing.apply_labels(spec, proposal["labels"])
    for table in skipped:
        spec["notes"].append(f"{table} has no approved column map, so it is not in the model: exakit describe {table}")
    for link in (discovered or {}).get("links") or []:
        if link["confidence"] != "high" and not any(j["from"] == link["from"] for j in joins):
            spec["notes"].append(f"possible link, not used until you confirm it: --link {link['from']}={link['to']} "
                                 f"({link['found']} of {link['checked']} sampled values match; plain numbers match by chance)")
    for part in (discovered or {}).get("partial") or []:
        spec["notes"].append(f"partial match, not a link: {part['from']} ~ {part['to']} ({part['share']:.0%} of sampled values)")
    found: dict[str, Any] = {"model": spec["model"], "published_schema": spec["published_schema"], "spec": spec,
                             "summary": sm.summary(spec), "ai": {k: proposal[k] for k in ("refused", "error")},
                             "links": [{"from": j["from"], "to": j["to"], "evidence": j.get("evidence")} for j in joins],
                             "proposed_metrics": [ddl for _view, ddl in proposal["extra"]]}
    if dry_run:
        found["status"] = "dry run"
        return found
    inputs = {"tables": names, "links": joins, "name": name, "description": description, "table_notes": said,
              "labels": proposal["labels"], "extra": proposal["extra"]}
    try:
        result = publishing.publish_model(conn.execute, rows, spec, inputs, reader=os.environ.get(READER_VARIABLE),
                                          extra=proposal["extra"], progress=progress)
    except sm.ModelRefused as err:
        raise Refused(str(err)) from err
    found.update(result, status="published")
    return found


def _approved_in(schemas: list[str]) -> tuple[dict[str, dict[str, Any]], dict[str, str], dict[str, str], dict[str, str]]:
    """(approved column maps by table, their keys, every column's role, every column's note) for these schemas."""
    docs: dict[str, dict[str, Any]] = {}
    for schema in schemas:
        docs.update(publishing.approved_tables(schema))
    keys, roles, notes = {}, {}, {}
    for table, doc in docs.items():
        key = (doc.get("slots") or {}).get("key")
        if key:
            keys[f"{table}.{key}"] = "the approved column map's key"
        for column, entry in (doc.get("columns") or {}).items():
            roles[f"{table}.{column}"] = str(entry.get("role") or "")
            if entry.get("note") and not entry.get("sensitive"):
                notes[f"{table}.{column}"] = str(entry["note"])
    return docs, keys, roles, notes


def find_links(conn, schemas: list[str], *, ai: bool = False, chat=None, progress=None,
               check: list[str] | None = None, tables: list[str] | None = None) -> dict[str, Any]:
    """The links between tables of different schemas (sample data, loaded files, external sources), found from their
    values and each shown with its evidence (descriptor/links.py). With ``ai`` the user's model proposes more pairs
    from names, types and notes only; each is checked against the data like any other. ``check`` is pairs someone
    already has in mind (``S.T.COL=S.T.KEY``: an agent's reading of what the columns mean, or yours): they are checked
    the same way and come back with their evidence, or under ``rejected`` with what the data showed. ``tables``
    (SCHEMA.TABLE) keeps the search to a selection of tables - and then two tables of one schema are compared too.
    Nothing is written."""
    from descriptor import links as linking

    selection = None
    if tables:
        selection = []
        for table in tables:
            schema, object_name = split_table(table)
            selection.append(f"{schema}.{object_name}")
        if len(set(selection)) < 2:
            raise Refused("Name at least two tables to find the links between them.")
        schemas = sorted({t.split(".", 1)[0] for t in selection})
    names = []
    for schema in schemas:
        try:
            names.append(schema_map.schema_name(schema))
        except ValueError as err:
            raise Refused(str(err)) from err
    if len(names) < 2 and selection is None:
        raise Refused("Name at least two schemas to find the links between them: exakit describe --links A,B[,C...]")
    rows = lambda sql: _rows(conn, sql)
    _docs, keys, roles, notes = _approved_in(names)
    proposals, ai_note = [], None
    asked = []
    for pair in check or []:
        source, sep, target = pair.partition("=")
        if not sep or source.count(".") != 2 or target.count(".") != 2:
            raise Refused(f"--link takes SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY, not '{pair}'.")
        asked.append((source.strip().upper(), target.strip().upper()))
    proposals += asked
    if ai:
        if chat is None and not (os.environ.get("EXAKIT_MODEL_ID", "").strip() and os.environ.get("EXAKIT_PROVIDER_BASE_URL", "").strip()):
            ai_note = "no model is configured, so only the values were used"
        else:
            try:
                shown, _virtual = linking.columns(rows, names)
                if selection is not None:
                    shown = {t: cols for t, cols in shown.items() if t.upper() in {x.upper() for x in selection}}
                asked_for = linking.AI_INSTRUCTIONS if selection is None else linking.AI_INSTRUCTIONS.replace(
                    "in ANOTHER schema", "in ANOTHER table (of the same schema or of another one)").replace(
                    "tables of different data sources", "tables, of one data source or of several,")
                text = (chat or _chat)(asked_for + "\n\nTables: "
                                       + json.dumps(linking.ai_facts(shown, notes), ensure_ascii=False)).strip()
                proposals += linking.ai_pairs(json.loads(text[text.find("{"):text.rfind("}") + 1]), shown,
                                              same_schema=selection is not None)
                ai_note = f"the model proposed {len(proposals) - len(asked)} pair(s); each was checked against the data"
            except Exception as err:               # noqa: BLE001 - the search by values stands
                ai_note = f"the model's proposal was not used ({type(err).__name__})"
    found = linking.find(rows, names, approved_keys=keys, roles=roles, proposals=proposals, progress=progress,
                         only=selection, same_schema=selection is not None)
    found["ai"] = ai_note
    for link in found["links"]:
        link["evidence_text"] = linking.evidence_text(link)
    kept = {(l["from"], l["to"]) for l in found["links"]}
    found["rejected"] = [{"from": a, "to": b, "why": "the data does not back it: too few of its values are in that "
                          "column, the two columns are of different kinds, or the target is not unique"}
                         for a, b in asked if (a, b) not in kept]
    return found


def links_text(found: dict[str, Any]) -> str:
    lines = [f"Links across {', '.join(found['schemas'])}: {len(found['links'])} found "
             f"({found['checked']} pairs checked with {found['statements']} bounded statements"
             + (f"; {found['not_checked']} more were not checked" if found["not_checked"] else "") + ")."]
    if found.get("ai"):
        lines.append(f"AI: {found['ai']}.")
    for link in found["links"]:
        lines.append(f"  [{link['confidence']}] {link['evidence_text']}")
        lines.append(f"      use it: --link {link['from']}={link['to']}")
    for part in found.get("partial") or []:
        lines.append(f"  [partial] {part['from']} ~ {part['to']}: {part['found']} of {part['checked']} sampled values match "
                     f"({part['share']:.0%}). Not a link: look at the spellings before joining on it.")
    for item in found.get("rejected") or []:
        lines.append(f"  [rejected] {item['from']} -> {item['to']}: {item['why']}.")
    if not found["links"] and not found.get("partial"):
        lines.append("  No column of one schema points at a key of another. Give a link yourself with --link if you know one.")
    return "\n".join(lines)


def refresh_model(conn, name: str) -> dict[str, Any]:
    """Rebuild a semantic model the kit published, with the column maps and links approved since."""
    from descriptor import semantic_model as sm

    try:
        return publishing.refresh(conn.execute, lambda sql: _rows(conn, sql), name, os.environ.get(READER_VARIABLE))
    except sm.ModelRefused as err:
        raise NotFound(str(err)) from err


def list_models(conn) -> list[dict[str, Any]]:
    from descriptor import semantic_model as sm

    found = sm.models(lambda sql: _rows(conn, sql))
    for model in found:
        model["refreshable"] = publishing.kept(model["model"]) is not None
    return found


def with_notes(doc: dict[str, Any], notes: dict[str, str] | None) -> dict[str, Any]:
    for column, note in (notes or {}).items():
        doc["columns"][column] = dict(doc["columns"][column], note=note)
    return doc


def _workflow_log():
    """The notebook package's workflow logger (a line only while a workflow is active), or None without it."""
    try:
        folder = kit_root() / "notebook" / "package"
        if folder.is_dir() and str(folder) not in sys.path:
            sys.path.insert(0, str(folder))
        from exakit_nb.workflow import log_event
        return log_event
    except ImportError:
        return None


# --- the command line ------------------------------------------------------------------------------------------------

def _options(args: list[str]) -> tuple[list[str], dict[str, Any]]:
    words, opts = [], {"role": [], "set": [], "link": [], "unlink": [], "table": []}
    flags = {"--json": "json", "--no-comments": "no_comments", "--force": "force", "--ai": "ai", "--dry-run": "dry_run",
             "--find-links": "find_links"}
    valued = {"--sample": "sample", "--id": "id", "--write": "write", "--owner": "owner", "--version": "version",
              "--role": "role", "--set": "set", "--link": "link", "--unlink": "unlink", "--table": "table",
              "--description": "description", "--schemas": "schemas"}
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in flags:
            opts[flags[arg]] = True
        elif arg in valued:
            if i + 1 >= len(args):
                raise Refused(f"{arg} needs a value.")
            key = valued[arg]
            if key in ("role", "set", "link", "unlink", "table"):
                opts[key].append(args[i + 1])
            else:
                opts[key] = args[i + 1]
            i += 1
        elif arg.startswith("-"):
            raise Refused(f"Unknown option '{arg}'.")
        else:
            words.append(arg)
        i += 1
    return words, opts


def _emit(result: Any, as_json: bool, text: str | None = None) -> None:
    print(json.dumps(result, indent=2, ensure_ascii=False, default=str) if as_json else (text if text is not None else result))


def _run(command: str, words: list[str], opts: dict[str, Any]) -> None:
    target = words[0]
    if command in ("draft", "profile"):
        conn = connect()
        try:
            if command == "profile":
                _emit(profiling.profile(None, flow.table_name(target), run=lambda sql: _rows(conn, sql)), True)
                return
            found = describe(conn, target, opts.get("id"), bool(opts.get("force")))
        finally:
            conn.close()
        if found["status"] == "draft":
            with_notes(found["doc"], model_notes(found["doc"], found["profile"]))
            log = _workflow_log()
            if log:
                log("describe.draft", descriptor_id=found["doc"]["dataset"], table=found["doc"]["source"]["object"],
                    version=found["doc"]["version"], slots=found["doc"]["slots"])
        text = drafting.to_yaml(found["doc"])
        if opts.get("write"):
            Path(opts["write"]).expanduser().write_text(text, encoding="utf-8")
        _emit({k: found[k] for k in ("status", "doc", "changed", "previous")}, bool(opts.get("json")), text.rstrip("\n"))
    elif command == "approve":
        conn = connect()
        try:
            result = approve(conn, target, opts["role"], opts["set"], opts.get("owner"), not opts.get("no_comments"),
                             log=_workflow_log())
        finally:
            conn.close()
        line = result.get("message") or (f"{result['status'].capitalize()}: {result['table']} v{result['version']} "
                                         f"(owner {result['owner']}), {result['path']}"
                                         + (f"; published as {result['published']}" if result.get("published") else "")
                                         + (f"; not published: {result['reason']}" if result.get("reason") else ""))
        line += "".join(f"\nWarning: {w}" for w in result.get("warnings") or [])
        _emit(result, bool(opts.get("json")), line)
    elif command == "show":
        found = show(target, int(opts["version"]) if opts.get("version") else None)
        _emit(found, bool(opts.get("json")), found["text"].rstrip("\n"))
    elif command == "versions":
        found = versions(target)
        _emit(found, bool(opts.get("json")), "\n".join(f"v{v['version']}  {v['status']}  {v['owner']}  {v['approved_at']}" for v in found) or "no versions")
    elif command == "schema":
        conn = connect()
        try:
            found = describe_schema(conn, target)
        finally:
            conn.close()
        _emit(found, bool(opts.get("json")), schema_text(found["doc"]))
    elif command == "schema-approve":
        conn = connect()
        try:
            result = approve_schema(conn, target, opts["link"], opts["unlink"], opts.get("owner"), not opts.get("no_comments"))
        finally:
            conn.close()
        line = result.get("message") or (f"{result['status'].capitalize()}: {result['schema']} v{result['version']} "
                                         f"({result['relations']} links, owner {result['owner']}), {result['path']}"
                                         + (f"; published as {result['published']}" if result.get("published") else "")
                                         + (f"; not published: {result['reason']}" if result.get("reason") else ""))
        _emit(result, bool(opts.get("json")), line)
    elif command == "comments":
        conn = connect()
        try:
            found = comments(conn, target)
        finally:
            conn.close()
        _emit(found, bool(opts.get("json")), f"Published {found['view']}" + _counts(found))
    elif command == "model":
        conn = connect()
        try:
            found = semantic_model(conn, target, opts["table"], opts["link"], ai=bool(opts.get("ai")),
                                   schemas=[w for w in str(opts.get("schemas") or "").split(",") if w.strip()],
                                   discover=bool(opts.get("find_links")),
                                   dry_run=bool(opts.get("dry_run")), description=opts.get("description"),
                                   progress=lambda line: print(line, file=sys.stderr, flush=True))
        finally:
            conn.close()
        _emit({k: v for k, v in found.items() if k != "spec"} if not opts.get("json") else found, bool(opts.get("json")),
              _model_text(found))
    elif command == "links":
        conn = connect()
        try:
            found = find_links(conn, [w for w in target.split(",") if w.strip()], ai=bool(opts.get("ai")),
                               check=opts["link"],
                               progress=lambda line: print(line, file=sys.stderr, flush=True))
        finally:
            conn.close()
        _emit(found, bool(opts.get("json")), links_text(found))
    elif command == "refresh":
        conn = connect()
        try:
            found = refresh_model(conn, target)
        finally:
            conn.close()
        _emit(found, bool(opts.get("json")), f"Refreshed {found['view']}" + _counts(found))
    elif command == "models":
        conn = connect()
        try:
            found = list_models(conn)
        finally:
            conn.close()
        _emit(found, bool(opts.get("json")), "\n".join(
            f"{m['model']:<24} {m['published_schema']:<28} {'kit' if m['kit'] else 'not the kit'}"
            f"{', refresh: exakit describe --model ' + m['model'] + ' --refresh' if m['refreshable'] else ''}  {m['description']}"
            for m in found) or "No semantic models yet (or Semantic Views is not installed).")
    else:
        raise Refused(f"Unknown command '{command}' (draft, approve, show, versions, comments, profile, schema, "
                      "schema-approve, model, links, refresh, models).")


def _counts(found: dict[str, Any]) -> str:
    counts = found.get("counts") or {}
    text = (f": {counts.get('views', 0)} views, {counts.get('dimensions', 0)} dimensions, {counts.get('metrics', 0)} metrics"
            if counts else "")
    return text + "".join(f"\nNote: {n}" for n in found.get("notes") or []) + "".join(
        f"\nWarning: {w}" for w in found.get("warnings") or [])


def _model_text(found: dict[str, Any]) -> str:
    lines = [found["summary"]]
    if found.get("ai", {}).get("error"):
        lines.append(f"AI: {found['ai']['error']}")
    for ddl in found.get("proposed_metrics") or []:
        lines.append("AI proposed: " + " ".join(ddl.split())[:220])
    for refused in found.get("ai", {}).get("refused") or []:
        lines.append(f"AI proposal refused: {refused}")
    if found["status"] == "dry run":
        lines.append("Dry run: nothing was written. Publish it without --dry-run.")
    else:
        lines.append(f"Published {', '.join(found.get('views') or [])}" + _counts(found)
                     + f"\nQuery it: SELECT * FROM SEMANTIC_AGENT.METRICS WHERE MODEL_NAME = '{found['model']}'")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    try:
        words, opts = _options(argv[1:])
        if argv[0] == "models":
            words = words or ["-"]
        if len(words) != 1:
            raise Refused("Name one table, dataset id or draft file.")
        _run(argv[0], words, opts)
    except (Refused, Unreachable, Conflict) as err:
        print(f"{err}", file=sys.stderr)
        return err.code
    except RuntimeError as err:                    # Semantic Views did not install, or the product refused the model
        print(f"{err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
