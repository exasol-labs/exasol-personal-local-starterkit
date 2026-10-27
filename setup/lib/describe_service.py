#!/usr/bin/env python3
"""The profiler and drafter behind `exakit describe <table>` (DS-5, design 2.2), shared by setup/lib/describe.sh and
describe.ps1 so the two cannot drift, and called in-process by exakit_nb.describe(). Runs on the kit's notebook Python
(pyexasol is there); otherwise the standard library only. Self-contained on purpose: it imports nothing from the
notebook package, so it runs wherever the kit copy is.

    python describe_service.py draft <table> [--sample N] [--id <slug>] [--json] [--write <path>]
        profiles SCHEMA.TABLE and prints the draft descriptor (schema_version 2, status draft) as YAML - the layout
        exakit_nb.save_descriptor writes, so the file round-trips through the descriptor reader - or, with --json, as
        one JSON object; --write saves the YAML to <path> as well.
    python describe_service.py profile <table> [--sample N]
        prints the profile alone, as JSON (what draft scores; the test fixtures under test_data/describe are these).
    python describe_service.py evidence-check <descriptor.yaml> [--sample N] [--json]
        re-profiles the descriptor's fact table and says, role by role, whether a fresh draft proposes the columns the
        file ships (AC-DS5.1); exit 0 when every role agrees, 1 when one differs.
    python describe_service.py approve <draft.yaml|id> [--role <role>=<COLUMN> ...] [--owner <who>] [--no-comments] [--json]
        approves a draft (a file, or the latest version of <id> in the kit's store, else the descriptor the kit ships):
        validates the roles with the descriptor rules, computes the table digest and writes the next version into the
        store, then writes the roles into the table's column comments (a view for a virtual table). See APPROVE below.
    python describe_service.py show <id> [--version n] [--json]      one version's descriptor (the current one by default)
    python describe_service.py versions <id> [--json]                every version with its status, owner and digest
    python describe_service.py comments <id> [--json]                write the current version's roles into the comments again

Exit codes: 0 ok; 2 bad arguments or roles (the message names the role and the reason); 3 the table or the id is not
there; 4 the database is not reachable; 5 a version conflict (another writer took the next version number twice).

The database steps connect through pyexasol as the kit's admin user: EXAKIT_PYX_DSN, EXAKIT_PYX_USER and
EXAKIT_PYX_PWFILE (the FILE holding the password - the password itself never reaches a command line, an output or a
log). Profiling and the digest are SELECTs. Approving writes to the database only through comments: COMMENT ON COLUMN
on the described table's role columns, and for a virtual table one view in the kit's own schema, STARTER_KIT.

THE PROFILE (profile()) is a few statements, never one per column: the column list (with whether the table is
virtual), COUNT(*), one aggregate statement per batch of columns (COUNT, COUNT(DISTINCT), MIN/MAX for dates and
numbers, AVG/MAX(LENGTH) and the share of parseable dates for text) and one GROUPING SETS statement for the values of
every low-cardinality column. A virtual table, or a regular one past FULL_PROFILE_ROWS rows, is profiled on a sample
instead: COUNT(*) first, then one `SELECT ... WHERE RANDOM() < p LIMIT n` fetch whose rows are profiled here, flagged
`sampled: true`. Every identifier is quoted. The statement count is recorded in the profile and in the evidence.

THE DRAFT (draft()) is deterministic: the same profile gives the same roles, offline, with no model (AC-DS5.5). Each
role is scored per column (0..1, documented beside each scorer; data/README.md has the table); roles are assigned
in the order date, label, category, entity, text, a column taken by one role never offered to the next; the best
column takes the role, the second best is kept as its runner_up; a role whose best score is under THRESHOLD is listed
under `missing` with the reason, never guessed. All-null and constant columns are excluded first, each with its reason
under evidence.excluded. An optional model (EXAKIT_NB_MODEL + OPENAI_BASE_URL set) is asked ONCE for one line per
column from the column names and the profile's numbers - never a row - and writes `notes`; a failed call is one
warning line, the draft unchanged. A table or a role column whose name is not a plain upper-case SQL name (the reader
upper-cases what it reads and the notebooks write it into SQL unquoted) is refused at draft time with the column, the
reason and the remedy (a view with plain names); the profile itself quotes every identifier and runs on any name.

THE DIGEST (digest(), design 2.3) is sha256 over a canonical JSON document: the fact table's name, its columns with
their types in order, the row count, the digest's scope and a content hash of the role columns. The content hash is
one statement, order-independent, so two tables with the same rows in any order digest the same:

    SELECT COUNT(*) AS N, SUM(TO_NUMBER(SUBSTR(H, 1, 12), 'XXXXXXXXXXXX')) AS S0, ... S4   -- five 48-bit slices
    FROM (SELECT HASH_SHA256(COALESCE(<canonical role column>, '<null>') || CHR(31) || ...) AS H FROM <table>)

where a DATE is TO_CHAR'd as YYYY-MM-DD, a TIMESTAMP with its microseconds, and anything else CAST to VARCHAR, so the
session's date format plays no part. A regular table is hashed whole (scope full); a virtual table is hashed over its
first `sample` rows (the inner FROM is `(SELECT ... FROM <table> LIMIT n)`, scope sample): the external source is read
no further than the sample (AC-DS5.5), at the price that a change past those rows goes unseen - the row count, read
with COUNT(*), still enters the digest. Measured on the shipped datasets: 0.05 s (pharma, 5,169 rows) and 0.03 s
(banking, 6,754 rows).

APPROVE (approve()) takes a draft document (a file, the store's latest version of an id, or the shipped descriptor)
and the corrections given as roles, sets status approved, the owner (--owner, else EXAKIT_DESCRIPTOR_OWNER or the OS
user), created now and the digest, keeps the draft's evidence, notes, source and drafted_by, validates the result with
the descriptor rules (the reader's own) and checks every role column against the database, then writes
~/.exasol-starter-kit/descriptors/<id>/v<n+1>.yaml (n: the highest version in the store, 1 for a dataset the kit
ships when the store is empty, else 0; the file is created exclusively, so a version is never overwritten - a v<n+1>
that appears meanwhile makes it recompute n once, then give up with exit 5) and `current` (a temp file renamed over
it). Approving the roles the current approved version already has writes nothing and says so (unchanged). Then the
roles go into the database as column comments: `role: <role> (starter kit, descriptor <id> v<n>)` appended to the
column's existing comment (an earlier role tag replaced; a column that lost its role loses its tag). Exasol takes
comments on a view's columns only in CREATE VIEW, so a virtual table gets CREATE OR REPLACE VIEW
STARTER_KIT.<ID>_DESCRIBED (<column> COMMENT IS '...', ...) AS SELECT ... FROM <virtual table> COMMENT IS '...'. A
comment that cannot be written (no rights, a read-only source) is a warning naming the reason and the retry
(exakit describe <id> --comments); the descriptor is approved all the same.
"""

from __future__ import annotations

import datetime as dt
import getpass
import hashlib
import json
import math
import os
import re
import sys
from pathlib import Path
from typing import Any

SAMPLE = 10000                       # rows a sample profile reads (--sample)
FULL_PROFILE_ROWS = 5_000_000        # a regular table past this is profiled on a sample, like a virtual table
BATCH = 25                           # columns per aggregate statement
LOW_CARDINALITY = 50                 # up to this many distinct values, the values and their shares are profiled
TOP_K = 5                            # values shown per role in the evidence
THRESHOLD = 0.5                      # a role whose best column scores under this is missing
OWNER_VARIABLE = "EXAKIT_DESCRIPTOR_OWNER"
MODEL_VARIABLE = "EXAKIT_NB_MODEL"
SINGLE_ROLES = ("date", "label", "category", "entity")     # assignment order; text last
ROLES = SINGLE_ROLES + ("text",)
DATE_FORMATS = (("YYYY-MM-DD", "%Y-%m-%d"), ("DD.MM.YYYY", "%d.%m.%Y"), ("MM/DD/YYYY", "%m/%d/%Y"))
TIMESTAMP_FORMATS = (("YYYY-MM-DD HH24:MI:SS", "%Y-%m-%d %H:%M:%S"),)

# Name hints: a word in a column's name that says what it holds, worth a fixed bonus (or malus) on top of what the
# numbers say - never decisive on their own, since a hint without the numbers scores under THRESHOLD.
HINTS = {
    "date_event": r"(start|begin|receiv|creat|open|order|event|occur|entry|admit|book|issued|report|filed|submit)",
    "date_followup": r"(end|complet|finish|sent|clos|due|updat|modif|resolv|expir|deliver)",
    "label_outcome": r"(terminat|outcome|disput|timely|churn|default|fraud|relief|resolv|target|label|convert|cancel|return)",
    "label_state": r"(^is_|^has_|flag|status)",
    "entity": r"(^|_)(id|name|sponsor|company|customer|account|vendor|supplier|merchant|user|member|patient|provider|party|org|client)(_|$)|id$",
    "text": r"(summary|descri|criteria|text|comment|narrat|issue|response|note|remark|review|message|body|reason|complaint|detail|explan)",
}
_IDENT = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")
_PLAIN = re.compile(r"^[A-Z][A-Z0-9_]{0,127}$")       # what the descriptor reader keeps as written: a plain upper-case name
_ID = re.compile(r"^[a-z0-9]+([-_][a-z0-9]+)*$")

STORE_FOLDER = "descriptors"                          # under the kit's home: <id>/v<n>.yaml + current
CURRENT = "current"
KIT_SCHEMA = "STARTER_KIT"                            # where a virtual table's described view goes
DIGEST_SLICES = 5                                     # 48-bit slices of each row hash summed (60 of the 64 hex chars)
NULL_MARK = "<null>"
_TAG = re.compile(r"\s*\|?\s*role: [a-z]+ \(starter kit, descriptor [a-z0-9_-]+ v[0-9]+\)")
_VERSION_FILE = re.compile(r"^v([1-9][0-9]*)\.yaml$")


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


# --- identifiers and the connection --------------------------------------------------------------------------------

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


# --- the profile ---------------------------------------------------------------------------------------------------

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


def declared_width(column_type: str) -> int | None:
    """The declared length of a VARCHAR/CHAR, else None."""
    match = re.match(r"^(?:VARCHAR|CHAR)\s*\(\s*(\d+)", column_type.upper())
    return int(match.group(1)) if match else None


def _rate(part: float, whole: float) -> float:
    return round(part / whole, 4) if whole else 0.0


def _span_days(low: str | None, high: str | None) -> int | None:
    """Days between two ISO dates or timestamps as the database prints them."""
    try:
        a, b = (dt.datetime.fromisoformat(str(v)[:19]) for v in (low, high))
    except (ValueError, TypeError):
        return None
    return (b - a).days


def _parses(value: str) -> bool:
    """Whether a text value is a date in one of DATE_FORMATS or TIMESTAMP_FORMATS (the Python side of IS_DATE)."""
    text = str(value).strip()
    for _sql, fmt in DATE_FORMATS + TIMESTAMP_FORMATS:
        try:
            dt.datetime.strptime(text, fmt)
            return True
        except ValueError:
            continue
    return False


def _column_record(column: dict[str, Any], raw: dict[str, Any], profiled: int) -> dict[str, Any]:
    """One column's profile from its raw numbers: count (non-null), distinct, min, max, avg_len, max_len, parsed."""
    kind = column["kind"]
    count = int(raw.get("count") or 0)
    distinct = raw.get("distinct")
    record: dict[str, Any] = {"column": column["column"], "position": column["position"], "type": column["type"],
                              "kind": kind, "width": declared_width(column["type"]),
                              "null_rate": _rate(profiled - count, profiled) if profiled else 1.0,
                              "distinct": int(distinct) if distinct is not None else None,
                              "distinct_ratio": _rate(int(distinct), count) if distinct is not None and count else 0.0}
    record["all_null"] = count == 0
    record["constant"] = count > 0 and record["distinct"] == 1
    if kind in ("date", "timestamp", "integer", "number"):
        record["min"], record["max"] = raw.get("min"), raw.get("max")
        if kind in ("date", "timestamp"):
            record["span_days"] = _span_days(raw.get("min"), raw.get("max"))
    if kind == "text":
        record["avg_len"] = round(float(raw["avg_len"]), 1) if raw.get("avg_len") is not None else None
        record["max_len"] = int(raw["max_len"]) if raw.get("max_len") is not None else None
        record["date_parse_rate"] = _rate(float(raw.get("parsed") or 0), count) if count else 0.0
    return record


def _values_record(counts: dict[str, int]) -> tuple[list[dict[str, Any]], float | None]:
    """The non-null values with their share of the non-null rows, most frequent first (ties by value), and the
    smallest share."""
    total = sum(counts.values())
    values = [{"value": v[:200], "share": _rate(n, total)} for v, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]
    return values, (min(v["share"] for v in values) if values else None)


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


def _aggregate_sql(ref: str, batch: list[dict[str, Any]]) -> str:
    """One aggregate statement over a batch of columns: C<i>/D<i> counts, MN/MX for dates and numbers, AL/ML/P for
    text (the share of values IS_DATE/IS_TIMESTAMP accept in the common formats)."""
    parts = []
    for i, col in enumerate(batch):
        q = quoted(col["column"])
        parts.append(f"COUNT({q}) AS C{i}")
        if col["kind"] != "other":
            parts.append(f"COUNT(DISTINCT {q}) AS D{i}")
        if col["kind"] in ("date", "timestamp", "integer", "number"):
            parts.append(f"CAST(MIN({q}) AS VARCHAR(64)) AS MN{i}")
            parts.append(f"CAST(MAX({q}) AS VARCHAR(64)) AS MX{i}")
        if col["kind"] == "text":
            tests = " OR ".join([f"IS_DATE({q}, '{f}')" for f, _ in DATE_FORMATS] + [f"IS_TIMESTAMP({q}, '{f}')" for f, _ in TIMESTAMP_FORMATS])
            parts.append(f"AVG(LENGTH({q})) AS AL{i}")
            parts.append(f"MAX(LENGTH({q})) AS ML{i}")
            parts.append(f"SUM(CASE WHEN {q} IS NULL THEN 0 WHEN {tests} THEN 1 ELSE 0 END) AS P{i}")
    return f"SELECT {', '.join(parts)} FROM {ref}"


def _values_sql(ref: str, columns: list[dict[str, Any]]) -> str:
    """One GROUPING SETS statement: every low-cardinality column's values and counts in one scan."""
    sets = ", ".join(f"({quoted(c['column'])})" for c in columns)
    select = ", ".join(f"GROUPING({quoted(c['column'])}) AS G{i}, {quoted(c['column'])} AS V{i}" for i, c in enumerate(columns))
    return f"SELECT {select}, COUNT(*) AS N FROM {ref} GROUP BY GROUPING SETS ({sets})"


def _profile_full(conn, ref: str, columns: list[dict[str, Any]], rows: int) -> tuple[list[dict[str, Any]], int]:
    """The regular-table profile: aggregates per batch, then the values of the low-cardinality columns."""
    statements = 0
    records = []
    for start in range(0, len(columns), BATCH):
        batch = columns[start:start + BATCH]
        row = _rows(conn, _aggregate_sql(ref, batch))[0]
        statements += 1
        for i, col in enumerate(batch):
            raw = {"count": row.get(f"C{i}"), "distinct": row.get(f"D{i}") if col["kind"] != "other" else None,
                   "min": row.get(f"MN{i}"), "max": row.get(f"MX{i}"),
                   "avg_len": row.get(f"AL{i}"), "max_len": row.get(f"ML{i}"), "parsed": row.get(f"P{i}")}
            records.append(_column_record(col, raw, rows))
    low = [r for r in records if r["kind"] != "other" and r["distinct"] and 2 <= r["distinct"] <= LOW_CARDINALITY]
    if low:
        counts: dict[str, dict[str, int]] = {r["column"]: {} for r in low}
        for row in _rows(conn, _values_sql(ref, low)):
            for i, r in enumerate(low):
                if int(row.get(f"G{i}") or 0) == 0 and row.get(f"V{i}") is not None:
                    counts[r["column"]][str(row[f"V{i}"])] = counts[r["column"]].get(str(row[f"V{i}"]), 0) + int(row["N"])
        statements += 1
        for r in low:
            r["values"], r["min_share"] = _values_record(counts[r["column"]])
    return records, statements


def _profile_rows(columns: list[dict[str, Any]], rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The profile of fetched rows (a sample), computed here with the same numbers the aggregate statement gives."""
    profiled = len(rows)
    records = []
    for col in columns:
        values = [row.get(col["column"]) for row in rows]
        present = [v for v in values if v is not None and v != ""]
        texts = [str(v) for v in present]
        raw: dict[str, Any] = {"count": len(present), "distinct": len(set(texts)) if col["kind"] != "other" else None}
        if present and col["kind"] in ("integer", "number"):
            numbers = [float(v) for v in present]
            raw["min"], raw["max"] = _plain(min(numbers)), _plain(max(numbers))
        elif present and col["kind"] in ("date", "timestamp"):
            raw["min"], raw["max"] = min(texts), max(texts)
        if col["kind"] == "text":
            lengths = [len(t) for t in texts]
            raw["avg_len"] = sum(lengths) / len(lengths) if lengths else None
            raw["max_len"] = max(lengths) if lengths else None
            raw["parsed"] = sum(1 for t in texts if _parses(t))
        record = _column_record(col, raw, profiled)
        if record["distinct"] and 2 <= record["distinct"] <= LOW_CARDINALITY:
            counts: dict[str, int] = {}
            for t in texts:
                counts[t] = counts.get(t, 0) + 1
            record["values"], record["min_share"] = _values_record(counts)
        records.append(record)
    return records


def _plain(number: float) -> str:
    """A number as the database would print it: 5 for 5.0, else the decimal."""
    return str(int(number)) if number == int(number) else repr(number)


def profile(conn, table: str, sample: int = SAMPLE) -> dict[str, Any]:
    """The profile of SCHEMA.TABLE: rows, whether it was sampled, the statement count, and per column its type and
    kind, null_rate, distinct and distinct_ratio, min/max/span_days for dates and numbers, avg_len/max_len and
    date_parse_rate for text, and for a low-cardinality column its values with their shares. Only SELECTs run."""
    if not isinstance(sample, int) or isinstance(sample, bool) or sample < 1:
        raise Refused(f"--sample takes the number of rows to profile (a positive integer), not '{sample}'.")
    schema, name = split_table(table)
    ref = table_ref(schema, name)
    columns, virtual = _columns(conn, schema, name)
    statements = 1
    rows = int(_rows(conn, f"SELECT COUNT(*) AS N FROM {ref}")[0]["N"])
    statements += 1
    sampled = virtual or rows > FULL_PROFILE_ROWS
    if sampled:
        # A virtual table is read no further than the sample (AC-DS5.5): its first n rows, since `WHERE RANDOM() < p`
        # makes the external source hand over every row and the filter runs here. A huge regular table is local, so
        # it takes the random slice the design asks for.
        select = ", ".join(quoted(c["column"]) for c in columns)
        if virtual:
            fetched = _rows(conn, f"SELECT {select} FROM {ref} LIMIT {int(sample)}")
        else:
            p = min(1.0, 1.2 * sample / rows) if rows else 1.0
            fetched = _rows(conn, f"SELECT {select} FROM {ref} WHERE RANDOM() < {p!r} LIMIT {int(sample)}")
        statements += 1
        records, profiled = _profile_rows(columns, fetched), len(fetched)
    else:
        records, used = _profile_full(conn, ref, columns, rows)
        statements += used
        profiled = rows
    out = {"table": f"{schema}.{name}", "schema": schema, "name": name, "virtual": virtual, "rows": rows, "sampled": sampled,
           "sample": sample, "profiled_rows": profiled, "statements": statements, "columns": records}
    if sampled:
        out["sample_method"] = "first rows" if virtual else "random"
    return out


# --- the scoring ---------------------------------------------------------------------------------------------------

def _hint(kind: str, column: str) -> bool:
    return re.search(HINTS[kind], column.lower()) is not None


def score_date(c: dict[str, Any]) -> float | None:
    """date: a DATE/TIMESTAMP column scores 0.8; text with >= 95% parseable dates scores 0.7 * parse rate; a name
    that says the row's own event (start, received, created...) +0.2, one that says a follow-up (end, completion,
    sent, closed...) -0.2; 20% nulls or more -0.2. Ties: the widest span, then the earlier column."""
    if c["kind"] in ("date", "timestamp"):
        score = 0.8
    elif c["kind"] == "text" and (c.get("date_parse_rate") or 0) >= 0.95:
        score = 0.7 * c["date_parse_rate"]
    else:
        return None
    if c["null_rate"] >= 0.2:
        score -= 0.2
    if _hint("date_event", c["column"]):
        score += 0.2
    elif _hint("date_followup", c["column"]):
        score -= 0.2
    return round(score, 2)


def _binary(c: dict[str, Any]) -> bool:
    values = {v["value"].upper() for v in c.get("values", [])}
    return c["kind"] == "boolean" or bool(values) and (values <= {"0", "1"} or values <= {"TRUE", "FALSE"})


def score_label(c: dict[str, Any]) -> float | None:
    """label: BOOLEAN, or 2-3 distinct values with under 20% nulls, scores 0.5; a 0/1 or true/false column +0.1; a
    name that says an outcome (terminated, outcome, disputed, timely, churn, default...) +0.2, a state (is_, has_,
    flag, status) +0.1; balanced classes (the smallest class 5% or more) +0.2, else -0.2."""
    if not (c["kind"] == "boolean" or (c["kind"] in ("text", "integer", "number") and c["distinct"] in (2, 3) and c["null_rate"] < 0.2)):
        return None
    score = 0.5 + (0.1 if _binary(c) else 0.0)
    if _hint("label_outcome", c["column"]):
        score += 0.2
    elif _hint("label_state", c["column"]):
        score += 0.1
    score += 0.2 if (c.get("min_share") or 0) >= 0.05 else -0.2
    return round(score, 2)


def score_category(c: dict[str, Any]) -> float | None:
    """category: 3-50 distinct values that repeat (distinct ratio under 0.05) with under 20% nulls scores 0.5; under
    1% nulls +0.2; no tiny class (the smallest 1% or more) +0.2; 12 values or fewer (a chart shows them whole) +0.1.
    Ties: the earlier column (a table names its main dimensions first)."""
    if not (c["kind"] in ("text", "integer") and c["distinct"] and 3 <= c["distinct"] <= LOW_CARDINALITY
            and c["distinct_ratio"] < 0.05 and c["null_rate"] < 0.2):
        return None
    score = 0.5
    if c["null_rate"] < 0.01:
        score += 0.2
    if (c.get("min_share") or 0) >= 0.01:
        score += 0.2
    if c["distinct"] <= 12:
        score += 0.1
    return round(score, 2)


def _entity_candidate(c: dict[str, Any]) -> bool:
    return bool(c["kind"] in ("text", "integer") and c["distinct"] and c["distinct"] >= 3
                and 0.01 <= c["distinct_ratio"] <= 0.6 and c["null_rate"] < 0.05)


def score_entity(c: dict[str, Any], most_distinct: int) -> float | None:
    """entity: a text or integer column whose distinct ratio is 0.01-0.6 (it repeats, but is not one of a few values)
    with under 5% nulls scores 0.5; a name hint (id, name, sponsor, company, customer, account...) +0.2; up to +0.3 by
    distinct count relative to the most distinct candidate - the one that names the most things wins, a unique key
    (ratio 1) is no entity: it names rows."""
    if not _entity_candidate(c):
        return None
    score = 0.5 + (0.2 if _hint("entity", c["column"]) else 0.0) + 0.3 * (c["distinct"] / most_distinct if most_distinct else 0)
    return round(score, 2)


def score_text(c: dict[str, Any]) -> float | None:
    """text: free text scores by length - average 40+ and a value of 200+ characters +0.3, else average 30+ in a column
    declared 100+ wide +0.2; average 150+ +0.2 more; a name that says text (summary, description, criteria, issue,
    response, comment, note...) +0.3. A title-length column without such a name stays under the threshold."""
    if c["kind"] != "text" or not c["distinct"] or c["distinct"] < 2:
        return None
    avg, longest, width = c.get("avg_len") or 0, c.get("max_len") or 0, c.get("width") or 0
    score = 0.0
    if avg >= 40 and longest >= 200:
        score += 0.3
    elif avg >= 30 and width >= 100:
        score += 0.2
    if avg >= 150:
        score += 0.2
    if _hint("text", c["column"]):
        score += 0.3
    return round(score, 2)


MISSING_REASONS = {
    "date": "no column has a DATE/TIMESTAMP type or 95% parseable dates",
    "label": "no column has 2-3 distinct values (or BOOLEAN) with under 20% nulls",
    "category": "no column has 3-50 distinct values that repeat (distinct ratio under 0.05) with under 20% nulls",
    "entity": "no column repeats the way an entity does (distinct ratio 0.01-0.6, under 5% nulls)",
    "text": "no VARCHAR column holds free text (average length 40+ with values of 200+ characters, or a shorter text column whose name says so)",
}


def _ranked(role: str, candidates: list[dict[str, Any]]) -> list[tuple[float, dict[str, Any]]]:
    """(score, column) for every column the role's scorer accepts, best first: score, then (dates) the widest span,
    then the earlier column."""
    scored = []
    most = max((c["distinct"] for c in candidates if _entity_candidate(c)), default=0)
    scorers = {"date": score_date, "label": score_label, "category": score_category, "text": score_text}
    for c in candidates:
        score = score_entity(c, most) if role == "entity" else scorers[role](c)
        if score is not None:
            scored.append((score, c))
    scored.sort(key=lambda sc: (-sc[0], -(sc[1].get("span_days") or 0) if role == "date" else 0, sc[1]["position"]))
    return scored


EVIDENCE_KEYS = {"date": ("min", "max", "span_days", "date_parse_rate"), "label": ("min_share", "top"),
                 "category": ("min_share", "top"), "entity": ("avg_len", "max_len")}


def _summary(role: str, c: dict[str, Any], score: float) -> dict[str, Any]:
    """A column's evidence line: the numbers every role shows, then the ones that chose it for this role."""
    out: dict[str, Any] = {"column": c["column"], "type": c["type"], "null_rate": c["null_rate"], "distinct": c["distinct"],
                           "distinct_ratio": c["distinct_ratio"]}
    for key in EVIDENCE_KEYS[role]:
        value = c["values"][:TOP_K] if key == "top" else c.get(key)
        if value is not None and value != []:
            out[key] = value
    out["score"] = score
    return out


def _slug(table: str) -> str:
    """A dataset id from a table name: lower-case, runs of anything else joined by one underscore."""
    name = table.split(".", 1)[-1]
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_") or "table"


def descriptor_owner() -> str:
    """Who owns a draft: EXAKIT_DESCRIPTOR_OWNER when set, else the OS user."""
    given = os.environ.get(OWNER_VARIABLE, "").strip()
    if given:
        return given
    try:
        return getpass.getuser()
    except (OSError, KeyError, ImportError):
        return "unknown"


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def kit_root() -> Path:
    """The kit copy this service lives in (setup/lib/describe_service.py -> the root)."""
    return Path(__file__).resolve().parents[2]


def shipped_source(table: str, root: Path | None = None) -> str | None:
    """The shipped dataset whose descriptor names ``table`` as its fact table (its id), or None."""
    folder = (root or kit_root()) / "data" / "datasets"
    for path in sorted(folder.glob("*/descriptor.y*ml")) if folder.is_dir() else []:
        try:
            text = path.read_text(encoding="utf-8-sig")
        except OSError:
            continue
        fact = re.search(r"^fact_table:\s*['\"]?([A-Za-z0-9_.]+)", text, re.M)
        if fact and fact.group(1).upper() == table.upper():
            return path.parent.name
    return None


def draft(profile: dict[str, Any], table: str | None = None, id: str | None = None, *, root: Path | None = None) -> dict[str, Any]:
    """A schema_version 2 draft descriptor from a profile: version 1, status draft, the owner, created now, drafted_by
    profile, the roles the scoring assigns with their evidence (each role's numbers and runner_up, the excluded columns
    with their reasons, the profile's table facts) and the roles no column fits under ``missing``."""
    table = table or profile["table"]
    schema = table.split(".", 1)[0]
    slug = id or _slug(table)
    if not _ID.match(slug):
        raise Refused(f"--id takes a dataset id (lower-case letters and digits, joined by - or _), not '{slug}'.")
    parts = (profile.get("schema"), profile.get("name")) if profile.get("schema") else tuple(table.split(".", 1))
    if not all(_PLAIN.match(p or "") for p in parts):
        raise Refused(f"The table {table} is not named by plain upper-case SQL names, which is what the kit's descriptors and the "
                      f"notebooks' SQL take. {_plain_remedy(profile, table)}")
    excluded: dict[str, str] = {}
    candidates = []
    for c in profile["columns"]:
        if c["all_null"]:
            excluded[c["column"]] = "all values are NULL"
        elif c["constant"]:
            excluded[c["column"]] = "one value in every row (constant)"
        else:
            candidates.append(c)
    roles: dict[str, Any] = {}
    evidence: dict[str, Any] = {}
    missing: list[dict[str, str]] = []
    taken: set[str] = set()
    for role in SINGLE_ROLES:
        ranked = _ranked(role, [c for c in candidates if c["column"] not in taken])
        if ranked and ranked[0][0] >= THRESHOLD:
            score, best = ranked[0]
            taken.add(best["column"])
            roles[role] = {"table": table, "column": best["column"]}
            evidence[role] = _summary(role, best, score)
            evidence[role]["runner_up"] = {"column": ranked[1][1]["column"], "score": ranked[1][0]} if len(ranked) > 1 else None
        else:
            reason = MISSING_REASONS[role]
            if ranked:
                reason += f" (best: {ranked[0][1]['column']} at {ranked[0][0]})"
            missing.append({"role": role, "reason": reason})
    ranked = _ranked("text", [c for c in candidates if c["column"] not in taken])
    chosen = sorted([(s, c) for s, c in ranked if s >= THRESHOLD], key=lambda sc: sc[1]["position"])
    if chosen:
        roles["text"] = [{"table": table, "column": c["column"]} for _s, c in chosen]
        rest = [(s, c) for s, c in ranked if s < THRESHOLD]
        evidence["text"] = {"columns": [{"column": c["column"], "type": c["type"], "null_rate": c["null_rate"], "avg_len": c.get("avg_len"),
                                         "max_len": c.get("max_len"), "score": s} for s, c in chosen],
                            "runner_up": {"column": rest[0][1]["column"], "score": rest[0][0]} if rest else None}
    else:
        reason = MISSING_REASONS["text"] + (f" (best: {ranked[0][1]['column']} at {ranked[0][0]})" if ranked else "")
        missing.append({"role": "text", "reason": reason})
    odd = [(role, c) for role, c in _role_columns(roles) if not _PLAIN.match(c)]
    if odd:
        raise Refused("A role went to a column that is not a plain upper-case SQL name, which is what the kit's descriptors and "
                      "the notebooks' SQL take: " + ", ".join(f"{role} -> \"{c}\"" for role, c in odd) + f". {_plain_remedy(profile, table)}")
    evidence["excluded"] = excluded
    evidence["table"] = {"rows": profile["rows"], "profiled_rows": profile["profiled_rows"], "sampled": profile["sampled"],
                         "sample": profile["sample"], "virtual": profile["virtual"], "statements": profile["statements"],
                         "columns": len(profile["columns"])}
    if profile.get("sample_method"):
        evidence["table"]["sample_method"] = profile["sample_method"]
    source = shipped_source(table, root) or (f"vs:{schema}" if profile.get("virtual") else table)
    return {"schema_version": 2, "id": slug, "fact_table": table, "source": source, "version": 1, "status": "draft",
            "owner": descriptor_owner(), "created": _now(), "drafted_by": "profile", "digest": None,
            "roles": roles, "evidence": evidence, "missing": missing}


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


def _plain_remedy(profile: dict[str, Any], table: str) -> str:
    """How to describe a table whose names are not plain: a view in the kit's schema that renames them."""
    schema, name = (profile.get("schema"), profile.get("name")) if profile.get("schema") else tuple(table.split(".", 1))
    view = re.sub(r"[^A-Z0-9_]+", "_", str(name).upper()).strip("_") or "TABLE"
    renamed = []
    for c in profile.get("columns", [])[:3]:
        plain = re.sub(r"[^A-Z0-9_]+", "_", c["column"].upper()).strip("_")
        renamed.append(quoted(c["column"]) + ("" if plain == c["column"] else f" AS {plain}"))
    select = ", ".join(renamed) + (", ..." if len(profile.get("columns", [])) > 3 else "")
    return (f"Describe a view with plain names instead, for example: CREATE VIEW {KIT_SCHEMA}.{view} AS SELECT {select} "
            f"FROM {table_ref(str(schema), str(name))}; then: exakit describe {KIT_SCHEMA}.{view}")


# --- the model note ------------------------------------------------------------------------------------------------

def model_notes(doc: dict[str, Any], profile: dict[str, Any]) -> dict[str, str] | None:
    """One line per column from the user's model, when EXAKIT_NB_MODEL and OPENAI_BASE_URL are both set: ONE call
    with the column names and the profile's numbers (never a row, never a value); None without a model or when the
    call fails (one warning line on stderr). Never decisive: the roles are drafted before this is asked."""
    model, base = os.environ.get(MODEL_VARIABLE, "").strip(), os.environ.get("OPENAI_BASE_URL", "").strip()
    if not model or not base:
        return None
    facts = [{k: c.get(k) for k in ("column", "type", "null_rate", "distinct", "distinct_ratio", "avg_len", "max_len", "span_days")
              if c.get(k) is not None} for c in profile["columns"]]
    roles = {role: (ref["column"] if isinstance(ref, dict) else [r["column"] for r in ref]) for role, ref in doc["roles"].items()}
    prompt = ("Table " + doc["fact_table"] + ". For each column write one short line (under 120 characters) saying what it "
              "probably holds, from its name and these numbers only. Answer with one JSON object mapping column name to "
              "the line, nothing else.\nColumns: " + json.dumps(facts) + "\nProposed roles: " + json.dumps(roles))
    try:
        from openai import OpenAI
        client = OpenAI(api_key=os.environ.get("OPENAI_API_KEY") or "not-needed")
        answer = client.chat.completions.create(model=model, messages=[{"role": "user", "content": prompt}], temperature=0)
        text = answer.choices[0].message.content or ""
        text = text[text.find("{"):text.rfind("}") + 1]
        given = json.loads(text)
        known = {c["column"] for c in profile["columns"]}
        notes = {str(k): " ".join(str(v).split())[:200] for k, v in given.items() if str(k) in known and str(v).strip()}
        return notes or None
    except Exception as err:              # noqa: BLE001 - whatever the model or the client raised: the draft stands
        print(f"Warning: no model notes ({type(err).__name__}: {str(err).splitlines()[0][:120]}); the draft is unchanged.", file=sys.stderr)
        return None


# --- the YAML writer (the layout exakit_nb.save_descriptor writes) -----------------------------------------------

def _yaml_scalar(value: Any) -> str:
    """A value as the descriptor reader reads it back: null, true/false and numbers plain (a float always with its
    point), a plain SQL or dataset name plain, any other text quoted."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return repr(value)
    if isinstance(value, float):
        if math.isnan(value) or math.isinf(value):
            return "null"
        text = repr(value)
        if "e" in text or "." not in text:                  # 1e-05, 5.0 -> a plain decimal the reader takes as a number
            text = f"{value:.6f}".rstrip("0")
            text = text + "0" if text.endswith(".") else text
        return text
    text = str(value)
    plain = (re.fullmatch(r"[A-Za-z0-9_.-]+", text) and text not in ("null", "~", "true", "false", "True", "False", "TRUE", "FALSE", "Null", "NULL")
             and not re.fullmatch(r"[-+]?[0-9]+(\.[0-9]+([eE][-+]?[0-9]+)?)?", text))      # "0" stays the text "0"
    return text if plain else json.dumps(text)


def _yaml_flow(value: Any) -> str:
    if isinstance(value, dict):
        return "{" + ", ".join(f"{_yaml_scalar(k)}: {_yaml_flow(v)}" for k, v in value.items()) + "}"
    if isinstance(value, (list, tuple)):
        return "[" + ", ".join(_yaml_flow(v) for v in value) + "]"
    return _yaml_scalar(value)


def _yaml_block(key: str, value: Any, indent: str = "") -> list[str]:
    if isinstance(value, dict) and value:
        lines = [f"{indent}{_yaml_scalar(key)}:"]
        for k, v in value.items():
            if isinstance(v, dict) and len(v) > 4 and all(not isinstance(x, (dict, list, tuple)) for x in v.values()):
                lines += _yaml_block(k, v, indent + "  ")
            else:
                lines.append(f"{indent}  {_yaml_scalar(k)}: {_yaml_flow(v)}")
        return lines
    if isinstance(value, (list, tuple)) and value:
        return [f"{indent}{_yaml_scalar(key)}:"] + [f"{indent}  - {_yaml_flow(item)}" for item in value]
    return [f"{indent}{_yaml_scalar(key)}: {_yaml_flow(value)}"]


def to_yaml(doc: dict[str, Any], about: str = "") -> str:
    """The draft as YAML in the kit's descriptor layout (exakit_nb.save_descriptor's), read back by the descriptor
    reader unchanged."""
    def ref(item: dict[str, Any]) -> str:
        return f"{{table: {_yaml_scalar(item['table'])}, column: {_yaml_scalar(item['column'])}}}"

    about = about or f"Which column of {doc['fact_table']} plays which role; drafted by exakit describe."
    lines = [f"# {about}",
             f"schema_version: {doc['schema_version']}", f"id: {_yaml_scalar(doc['id'])}", f"fact_table: {_yaml_scalar(doc['fact_table'])}"]
    if doc.get("source"):
        lines.append(f"source: {_yaml_scalar(doc['source'])}")
    lines += [f"{key}: {_yaml_scalar(doc.get(key))}" for key in ("version", "status", "owner", "created", "drafted_by", "digest")]
    lines.append("roles:")
    for role, value in doc["roles"].items():
        if isinstance(value, list):
            lines.append(f"  {role}:")
            lines += [f"    - {ref(item)}" for item in value]
        else:
            lines.append(f"  {role}: {ref(value)}")
    for key in ("evidence", "notes", "missing"):
        if key in doc and doc[key] is not None:
            lines += _yaml_block(key, doc[key])
    return "\n".join(lines) + "\n"


# --- the descriptor reader, for evidence-check ---------------------------------------------------------------------

def _rules():
    """The descriptor rules module: the kit copy's tools/descriptor_rules.py (the notebook package's twin)."""
    folder = kit_root() / "tools"
    if folder.is_dir() and str(folder) not in sys.path:
        sys.path.insert(0, str(folder))
    try:
        import descriptor_rules
        return descriptor_rules
    except ImportError:
        from exakit_nb import descriptor_rules      # type: ignore[no-redef]
        return descriptor_rules


def shipped_roles(descriptor) -> dict[str, Any]:
    """{role: column | [columns]} of a parsed descriptor, the shape draft()'s roles compare against."""
    out: dict[str, Any] = {}
    for role, refs in descriptor.roles.items():
        out[role] = [r.column for r in refs] if role == "text" else refs[0].column
    return out


def draft_roles(doc: dict[str, Any]) -> dict[str, Any]:
    """{role: column | [columns]} of a draft document."""
    return {role: ([r["column"] for r in ref] if isinstance(ref, list) else ref["column"]) for role, ref in doc["roles"].items()}


def evidence_check(conn, path: Path, sample: int = SAMPLE) -> dict[str, Any]:
    """Re-profile a descriptor's fact table and compare a fresh draft's roles with the file's, role by role."""
    rules = _rules()
    descriptor = rules.read_descriptor(path)
    fresh = draft(profile(conn, descriptor.fact_table, sample), descriptor.fact_table, descriptor.id)
    shipped, drafted = shipped_roles(descriptor), draft_roles(fresh)
    roles = {role: {"shipped": shipped.get(role), "draft": drafted.get(role), "same": shipped.get(role) == drafted.get(role)}
             for role in ROLES if role in shipped or role in drafted}
    return {"ok": all(r["same"] for r in roles.values()), "descriptor": str(path), "fact_table": descriptor.fact_table,
            "roles": roles, "evidence": fresh["evidence"]}


# --- the kit's descriptor store ------------------------------------------------------------------------------------

def store_home() -> Path:
    """The kit's home: EXAKIT_HOME when set, else ~/.exasol-starter-kit (the notebook package's descriptor_store agrees)."""
    given = os.environ.get("EXAKIT_HOME")
    return Path(given).expanduser() if given else Path.home() / ".exasol-starter-kit"


def store_dir(id: str) -> Path:
    """``<kit home>/descriptors/<id>``; an id that is no dataset id is refused, so no path is built from it."""
    if not isinstance(id, str) or not _ID.match(id):
        raise Refused(f"'{id}' is not a dataset id (lower-case letters and digits, joined by - or _).")
    return store_home() / STORE_FOLDER / id


def store_versions(id: str) -> list[int]:
    """Every version number stored for ``id`` (the v<n>.yaml files), ascending."""
    folder = store_dir(id)
    if not folder.is_dir():
        return []
    return sorted(int(m.group(1)) for p in folder.iterdir() if p.is_file() and (m := _VERSION_FILE.match(p.name)))


def store_current(id: str) -> int | None:
    """The number in ``current``, or None."""
    try:
        text = (store_dir(id) / CURRENT).read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return int(text) if re.fullmatch(r"[1-9][0-9]*", text) else None


def shipped_descriptor(id: str, root: Path | None = None) -> Path | None:
    """The descriptor the kit ships for a dataset id (data/datasets/<id>/descriptor.yaml), or None."""
    if not _ID.match(id or ""):
        return None
    folder = (root or kit_root()) / "data" / "datasets" / id
    return next((folder / name for name in ("descriptor.yaml", "descriptor.yml", "descriptor.json") if (folder / name).is_file()), None)


def read_document(path: Path) -> dict[str, Any]:
    """A descriptor file as the document it holds (YAML through the reader's own subset, or JSON), not yet validated."""
    rules = _rules()
    try:
        text = Path(path).read_text(encoding="utf-8-sig")
        doc = json.loads(text) if text.lstrip().startswith("{") else rules.load_yaml(text)
    except (OSError, ValueError) as err:
        raise Refused(f"The descriptor {path} cannot be read ({err}).") from err
    if not isinstance(doc, dict):
        raise Refused(f"The descriptor {path} is not a mapping of keys to values.")
    return doc


def versions(id: str, root: Path | None = None) -> list[dict[str, Any]]:
    """Every version of ``id`` the kit knows, ascending: the store's v<n>.yaml files and, as version 1 when the store
    has no v1, the descriptor the kit ships; each with its status, owner, created, digest, path and whether it is
    the current one. NotFound when there is none at all."""
    rules = _rules()
    current = store_current(id)
    found: dict[int, tuple[Path, str]] = {n: (store_dir(id) / f"v{n}.yaml", "store") for n in store_versions(id)}
    shipped = shipped_descriptor(id, root)
    if shipped is not None and 1 not in found:
        found[1] = (shipped, "shipped")
    if not found:
        raise NotFound(f"No descriptor '{id}': nothing approved in the kit's store ({store_dir(id)}) and no dataset the kit ships "
                       "by that id. Draft one with: exakit describe SCHEMA.TABLE --id " + id)
    out = []
    for n in sorted(found):
        path, origin = found[n]
        entry: dict[str, Any] = {"version": n, "path": str(path), "origin": origin, "current": n == current if current else origin == "shipped"}
        try:
            d = rules.read_descriptor(path)
            entry.update(status=d.status, owner=d.owner, created=d.created, digest=d.digest, drafted_by=d.drafted_by)
        except rules.BadInput as err:
            entry.update(status="invalid", problem=str(err))
        out.append(entry)
    return out


def show(id: str, version: int | None = None, root: Path | None = None) -> dict[str, Any]:
    """One version's descriptor: its text, document and record; the current version (or the only one) by default."""
    known = versions(id, root)
    if version is None:
        entry = next((e for e in known if e["current"]), known[-1])
    else:
        entry = next((e for e in known if e["version"] == version), None)
        if entry is None:
            raise NotFound(f"No version {version} of '{id}' (the versions are {', '.join(str(e['version']) for e in known)}).")
    path = Path(entry["path"])
    return dict(entry, text=path.read_text(encoding="utf-8-sig"), document=read_document(path))


# --- the table digest ----------------------------------------------------------------------------------------------

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


# --- approve -------------------------------------------------------------------------------------------------------

def parse_role(text: str) -> tuple[str, list[str]]:
    """``role=COLUMN`` (text: ``text=A,B``) as (role, columns); anything else is refused naming the role."""
    match = re.fullmatch(r"\s*([a-z]+)\s*=\s*(.+?)\s*", text or "")
    if not match or match.group(1) not in ROLES:
        raise Refused(f"--role takes role=COLUMN with the role one of {', '.join(ROLES)} (text takes A,B,...), not '{text}'.")
    role, columns = match.group(1), [c.strip() for c in match.group(2).split(",") if c.strip()]
    if role in SINGLE_ROLES and len(columns) != 1:
        raise Refused(f"The '{role}' role takes exactly one column, not '{match.group(2)}'.")
    for c in columns:
        if not _PLAIN.match(c.upper()) or not _IDENT.match(c):
            raise Refused(f"The '{role}' role: '{c}' is not a plain SQL column name (letters, digits and _, starting with a letter).")
    return role, [c.upper() for c in columns]


def _with_roles(doc: dict[str, Any], roles: dict[str, list[str]]) -> dict[str, Any]:
    """The document with the roles given set by the user (each leaving ``missing``, its evidence marked set_by user)."""
    out = json.loads(json.dumps(doc))
    table = out["fact_table"]
    out.setdefault("roles", {})
    evidence = out.get("evidence") if isinstance(out.get("evidence"), dict) else {}
    for role, columns in roles.items():
        refs = [{"table": table, "column": c} for c in columns]
        out["roles"][role] = refs if role == "text" else refs[0]
        chosen = evidence.get(role) if isinstance(evidence.get(role), dict) else {}
        evidence[role] = dict(chosen, set_by="user", column=columns[0] if role != "text" else chosen.get("column"))
        if role == "text":
            evidence[role]["columns"] = [{"column": c} for c in columns]
        out["missing"] = [m for m in (out.get("missing") or []) if not (isinstance(m, dict) and m.get("role") == role)]
    if evidence:
        out["evidence"] = evidence
    return out


def resolve_draft(what: str, root: Path | None = None) -> tuple[dict[str, Any], str]:
    """The document to approve and where it came from: a file path ("file"), else the latest version of the id in
    the store ("store"), else the descriptor the kit ships ("shipped"); NotFound names the three places."""
    path = Path(what).expanduser()
    if path.is_file():
        return read_document(path), "file"
    if not _ID.match(what or ""):
        raise Refused(f"Name a draft file or a dataset id (lower-case letters and digits, joined by - or _), not '{what}'.")
    stored = store_versions(what)
    if stored:
        return read_document(store_dir(what) / f"v{stored[-1]}.yaml"), "store"
    shipped = shipped_descriptor(what, root)
    if shipped is not None:
        return read_document(shipped), "shipped"
    raise NotFound(f"No descriptor '{what}': not a file, nothing in the kit's store ({store_dir(what)}) and no dataset the kit "
                   f"ships by that id. Draft one with: exakit describe SCHEMA.TABLE --id {what} --write <path>")


def next_version(id: str, root: Path | None = None) -> int:
    """n + 1: n the highest version in the store, 1 when the kit ships the id and the store is empty, else 0."""
    stored = store_versions(id)
    if stored:
        return stored[-1] + 1
    return 2 if shipped_descriptor(id, root) is not None else 1


def _write_version(id: str, doc: dict[str, Any], about: str, root: Path | None = None) -> tuple[int, Path]:
    """v<n+1>.yaml created exclusively (never over an existing version) and ``current`` renamed into place; a number
    taken meanwhile is recomputed once, then Conflict."""
    folder = store_dir(id)
    folder.parent.mkdir(parents=True, exist_ok=True)
    try:
        folder.parent.chmod(0o700)
    except OSError:
        pass
    folder.mkdir(parents=True, exist_ok=True)
    for attempt in range(2):
        number = next_version(id, root)
        doc["version"] = number
        path = folder / f"v{number}.yaml"
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            if attempt:
                raise Conflict(f"Version {number} of '{id}' was written by someone else twice in a row ({path}); "
                               "approve again when the other approve is done.")
            continue
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(to_yaml(doc, about))
        temp = folder / f".{CURRENT}.{os.getpid()}.tmp"
        temp.write_text(f"{number}\n", encoding="utf-8")
        os.replace(temp, folder / CURRENT)
        return number, path
    raise Conflict(f"Could not take a version number for '{id}'.")      # not reached


def approve(conn, doc: dict[str, Any], *, roles: dict[str, list[str]] | None = None, owner: str | None = None,
            comments: bool = True, sample: int = SAMPLE, root: Path | None = None) -> dict[str, Any]:
    """Approve ``doc`` (see APPROVE in the module doc): the result names the id, version, path, digest and scope,
    ``unchanged`` when the current approved version already has these roles, and under ``comments`` what was written
    to the database and the warnings for what was not."""
    rules = _rules()
    doc = _with_roles(doc, roles or {})
    doc["status"] = "approved"
    doc["owner"] = owner or descriptor_owner()
    doc["created"] = _now()
    doc["drafted_by"] = doc.get("drafted_by") or "user"
    doc["schema_version"] = 2
    doc.setdefault("version", 1)
    doc.setdefault("digest", None)
    if doc.get("source") and not isinstance(doc["source"], str):
        doc["source"] = str(doc["source"])
    problems = rules.validate_descriptor(doc)
    if problems:
        raise Refused("The descriptor cannot be approved: " + "; ".join(problems) + ".")
    id = doc["id"]
    wanted = draft_roles(doc)
    current = store_current(id)
    if current is not None and (store_dir(id) / f"v{current}.yaml").is_file():
        have = read_document(store_dir(id) / f"v{current}.yaml")
        if have.get("status") == "approved" and draft_roles(have) == wanted:
            return {"id": id, "version": current, "path": str(store_dir(id) / f"v{current}.yaml"), "unchanged": True,
                    "digest": have.get("digest"), "message": f"v{current} is already approved with these roles"}
    measured = digest(conn, doc["fact_table"], wanted, sample)
    doc["digest"] = measured["digest"]
    table_facts = doc.setdefault("evidence", {}).setdefault("table", {})
    if isinstance(table_facts, dict):
        table_facts["digest_scope"] = measured["scope"]
        table_facts["rows"] = measured["rows"]
    number, path = _write_version(id, doc, f"Which column of {doc['fact_table']} plays which role; approved by exakit describe.", root)
    result: dict[str, Any] = {"id": id, "version": number, "path": str(path), "unchanged": False, "digest": measured["digest"],
                              "scope": measured["scope"], "rows": measured["rows"], "owner": doc["owner"], "roles": wanted,
                              "statements": measured["statements"]}
    if comments:
        result["comments"] = write_comments(conn, doc, measured["columns"], measured["virtual"])
    else:
        result["comments"] = {"written": [], "warnings": [], "skipped": True}
    return result


# --- the comment write-back ----------------------------------------------------------------------------------------

def _literal(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def role_tag(role: str, id: str, version: int) -> str:
    return f"role: {role} (starter kit, descriptor {id} v{version})"


def _tagged(existing: str | None, tag: str | None) -> str | None:
    """A column's comment with the kit's role tag: the existing text (an earlier tag removed) and the tag after a
    ' | '; None when nothing is left to write."""
    base = _TAG.sub("", existing or "").strip()
    if tag:
        return f"{base} | {tag}" if base else tag
    return base or None


def _existing_comments(conn, schema: str, name: str) -> dict[str, str | None]:
    sql = ("SELECT COLUMN_NAME, COLUMN_COMMENT FROM EXA_ALL_COLUMNS "
           f"WHERE COLUMN_SCHEMA = '{schema.replace(chr(39), chr(39) * 2)}' AND COLUMN_TABLE = '{name.replace(chr(39), chr(39) * 2)}'")
    return {str(r["COLUMN_NAME"]): r.get("COLUMN_COMMENT") for r in _rows(conn, sql)}


def write_comments(conn, doc: dict[str, Any], columns: list[dict[str, Any]], virtual: bool) -> dict[str, Any]:
    """The roles into the database: COMMENT ON COLUMN per role column of a regular table (a column that lost its
    role loses its tag), or for a virtual table CREATE OR REPLACE VIEW STARTER_KIT.<ID>_DESCRIBED with the comments
    on its columns. Every statement that fails is one warning naming the reason; nothing raises."""
    id, version = doc["id"], int(doc["version"])
    schema, name = split_table(doc["fact_table"])
    tags = {c: role_tag(role, id, version) for role, c in _role_columns(doc.get("roles") or {})}
    written: list[str] = []
    warnings: list[str] = []
    retry = f"roles not written to column comments; retry with: exakit describe {id} --comments"

    def run(sql: str) -> bool:
        try:
            conn.execute(sql)
        except Exception as err:            # noqa: BLE001 - whatever the database said: the descriptor stays approved
            warnings.append(f"{_first_line(err)} ({sql[:60]}...); {retry}")
            return False
        written.append(sql)
        return True

    if virtual:
        view = re.sub(r"[^A-Z0-9_]+", "_", id.upper()).strip("_") + "_DESCRIBED"
        parts = [quoted(c["column"]) + (f" COMMENT IS {_literal(tags[c['column']])}" if c["column"] in tags else "") for c in columns]
        about = (f"starter kit: descriptor {id} v{version} of the virtual table {schema}.{name}; roles: "
                 + ", ".join(f"{role}={c}" for role, c in _role_columns(doc.get("roles") or {})))
        if run(f"CREATE SCHEMA IF NOT EXISTS {quoted(KIT_SCHEMA)}"):
            run(f"CREATE OR REPLACE VIEW {quoted(KIT_SCHEMA)}.{quoted(view)} ({', '.join(parts)}) AS SELECT "
                f"{', '.join(quoted(c['column']) for c in columns)} FROM {table_ref(schema, name)} COMMENT IS {_literal(about)}")
        return {"written": written, "warnings": warnings, "view": f"{KIT_SCHEMA}.{view}"}
    try:
        existing = _existing_comments(conn, schema, name)
    except Exception as err:                # noqa: BLE001
        existing = {}
        warnings.append(f"the existing comments could not be read ({_first_line(err)}); writing the role tags alone")
    for c in columns:
        column = c["column"]
        before, after = existing.get(column), _tagged(existing.get(column), tags.get(column))
        if column in tags or (before and _TAG.search(before)):
            run(f"COMMENT ON COLUMN {table_ref(schema, name)}.{quoted(column)} IS {_literal(after or '')}")
    return {"written": written, "warnings": warnings}


def _first_line(err: BaseException) -> str:
    text = str(err).strip()
    match = re.search(r"message\s*=>\s*(.+)", text)
    line = (match.group(1) if match else text).splitlines()[0] if text else type(err).__name__
    return line.strip()[:200]


def comments(conn, id: str, root: Path | None = None) -> dict[str, Any]:
    """Write the current approved version's roles into the comments again (after a failed write-back)."""
    entry = show(id, None, root)
    doc = entry["document"]
    if doc.get("status") != "approved":
        raise Refused(f"v{entry['version']} of '{id}' is a draft; approve it first: exakit describe {id} --approve")
    schema, name = split_table(doc["fact_table"])
    columns, virtual = _columns(conn, schema, name)
    return dict(write_comments(conn, doc, columns, virtual), id=id, version=entry["version"])


# --- the command line ----------------------------------------------------------------------------------------------

USAGE = ("usage: describe_service.py draft <SCHEMA.TABLE> [--sample N] [--id <slug>] [--json] [--write <path>]\n"
         "       describe_service.py profile <SCHEMA.TABLE> [--sample N]\n"
         "       describe_service.py evidence-check <descriptor.yaml> [--sample N] [--json]\n"
         "       describe_service.py approve <draft.yaml|id> [--role <role>=<COLUMN> ...] [--owner <who>] [--no-comments] [--json]\n"
         "       describe_service.py show <id> [--version n] [--json]\n"
         "       describe_service.py versions <id> [--json]\n"
         "       describe_service.py comments <id> [--json]")


def _options(argv: list[str], flags: tuple[str, ...], values: tuple[str, ...],
             repeated: tuple[str, ...] = ()) -> tuple[list[str], dict[str, Any]]:
    """Positionals and options; an unknown option, a repeated one (unless listed under ``repeated``, collected as a
    list) or a missing value is refused."""
    positional: list[str] = []
    options: dict[str, Any] = {}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in flags:
            options[arg] = True
        elif arg in values or arg in repeated:
            if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                raise Refused(f"{arg} needs a value.")
            if arg in repeated:
                options.setdefault(arg, []).append(argv[i + 1])
            elif arg in options:
                raise Refused(f"{arg} was given twice.")
            else:
                options[arg] = argv[i + 1]
            i += 1
        elif arg.startswith("-") and arg != "-":
            raise Refused(f"Unknown option '{arg}' (supported: {', '.join(flags + values + repeated)}).")
        else:
            positional.append(arg)
        i += 1
    if "--sample" in options:
        if not re.fullmatch(r"[1-9][0-9]*", options["--sample"]):
            raise Refused(f"--sample takes the number of rows to profile (a positive integer), not '{options['--sample']}'.")
        options["--sample"] = int(options["--sample"])
    if "--version" in options:
        if not re.fullmatch(r"[1-9][0-9]*", options["--version"]):
            raise Refused(f"--version takes a version number (a positive integer), not '{options['--version']}'.")
        options["--version"] = int(options["--version"])
    return positional, options


def _approve_lines(result: dict[str, Any]) -> list[str]:
    if result.get("unchanged"):
        return [result["message"]]
    lines = [f"Approved {result['id']} v{result['version']} (owner {result['owner']}, digest {result['digest'][:19]}..., "
             f"{result['scope']} scope over {result['rows']} rows): {result['path']}"]
    for role, column in result["roles"].items():
        lines.append(f"  {role:9} {', '.join(column) if isinstance(column, list) else column}")
    lines += _comment_lines(result["comments"])
    return lines


def _comment_lines(done: dict[str, Any]) -> list[str]:
    lines = []
    if done.get("skipped"):
        lines.append("Column comments not written (--no-comments).")
    elif done.get("view"):
        lines.append(f"Roles written as column comments on the view {done['view']}.")
    elif done.get("written"):
        lines.append(f"Roles written as column comments ({len(done['written'])} columns).")
    for warning in done.get("warnings", []):
        lines.append(f"Warning: {warning}")
    return lines


def main(argv: list[str]) -> int:
    try:
        if not argv:
            raise Refused("Name what to do.")
        if argv[0] in ("-h", "--help"):
            print(USAGE)
            return 0
        command, rest = argv[0], argv[1:]
        if command == "draft":
            positional, options = _options(rest, ("--json",), ("--sample", "--id", "--write"))
            if len(positional) != 1:
                raise Refused("Name one table: describe_service.py draft SCHEMA.TABLE [--sample N] [--id slug] [--json] [--write path]")
            split_table(positional[0])
            if "--id" in options and not _ID.match(options["--id"]):
                raise Refused(f"--id takes a dataset id (lower-case letters and digits, joined by - or _), not '{options['--id']}'.")
            conn = connect()
            try:
                prof = profile(conn, positional[0], options.get("--sample", SAMPLE))
            finally:
                conn.close()
            doc = draft(prof, prof["table"], options.get("--id"))
            notes = model_notes(doc, prof)
            if notes:
                doc["notes"] = notes
            text = to_yaml(doc)
            if "--write" in options:
                target = Path(options["--write"]).expanduser()
                target.write_text(text, encoding="utf-8")
            if options.get("--json"):
                print(json.dumps(doc, indent=2))
            else:
                sys.stdout.write(text)
            return 0
        if command == "profile":
            positional, options = _options(rest, (), ("--sample",))
            if len(positional) != 1:
                raise Refused("Name one table: describe_service.py profile SCHEMA.TABLE [--sample N]")
            split_table(positional[0])
            conn = connect()
            try:
                prof = profile(conn, positional[0], options.get("--sample", SAMPLE))
            finally:
                conn.close()
            print(json.dumps(prof, indent=2))
            return 0
        if command == "evidence-check":
            positional, options = _options(rest, ("--json",), ("--sample",))
            if len(positional) != 1:
                raise Refused("Name one descriptor file: describe_service.py evidence-check <descriptor.yaml> [--sample N] [--json]")
            path = Path(positional[0]).expanduser()
            if not path.is_file():
                raise Refused(f"No descriptor file at {path}.")
            conn = connect()
            try:
                result = evidence_check(conn, path, options.get("--sample", SAMPLE))
            finally:
                conn.close()
            if options.get("--json"):
                print(json.dumps(result, indent=2))
            else:
                for role, r in result["roles"].items():
                    print(f"  {'ok  ' if r['same'] else 'DIFF'} {role:9} shipped {r['shipped']}  draft {r['draft']}")
                print(f"{'Every role agrees' if result['ok'] else 'A role differs'}: {result['fact_table']} "
                      f"({result['evidence']['table']['statements']} statements)")
            return 0 if result["ok"] else 1
        if command == "approve":
            positional, options = _options(rest, ("--json", "--no-comments"), ("--owner", "--sample"), ("--role",))
            if len(positional) != 1:
                raise Refused("Name one draft file or dataset id: describe_service.py approve <draft.yaml|id> [--role role=COLUMN ...] [--owner who] [--no-comments] [--json]")
            given: dict[str, list[str]] = {}
            for text in options.get("--role", []):
                role, columns = parse_role(text)
                if role in given:
                    raise Refused(f"--role {role}= was given twice.")
                given[role] = columns
            if "--owner" in options and not options["--owner"].strip():
                raise Refused("--owner needs a name.")
            doc, _origin = resolve_draft(positional[0])
            conn = connect()
            try:
                result = approve(conn, doc, roles=given, owner=options.get("--owner"), comments="--no-comments" not in options,
                                 sample=options.get("--sample", SAMPLE))
            finally:
                conn.close()
            if options.get("--json"):
                print(json.dumps(result, indent=2))
            else:
                print("\n".join(_approve_lines(result)))
            return 0
        if command in ("show", "versions", "comments"):
            positional, options = _options(rest, ("--json",), ("--version",) if command == "show" else ())
            if len(positional) != 1 or not _ID.match(positional[0]):
                raise Refused(f"Name one dataset id (lower-case letters and digits, joined by - or _): describe_service.py {command} <id>"
                              + (" [--version n]" if command == "show" else "") + " [--json]")
            id = positional[0]
            if command == "versions":
                found = versions(id)
                if options.get("--json"):
                    print(json.dumps(found, indent=2))
                else:
                    for e in found:
                        mark = "*" if e["current"] else " "
                        print(f"{mark} v{e['version']:<3} {e.get('status', '?'):9} owner {e.get('owner', '?')}  created {e.get('created') or '-'}  "
                              f"digest {(e.get('digest') or 'null')[:19]}  {e['origin']}: {e['path']}")
                return 0
            if command == "show":
                entry = show(id, options.get("--version"))
                if options.get("--json"):
                    print(json.dumps({k: v for k, v in entry.items() if k != "text"}, indent=2))
                else:
                    sys.stdout.write(entry["text"])
                return 0
            conn = connect()
            try:
                result = comments(conn, id)
            finally:
                conn.close()
            if options.get("--json"):
                print(json.dumps(result, indent=2))
            else:
                print("\n".join([f"{result['id']} v{result['version']}:"] + (_comment_lines(result) or ["nothing to write"])))
            return 0
        raise Refused(f"Unknown command '{command}' (draft, profile, evidence-check, approve, show, versions, comments).")
    except Refused as err:
        print(f"{err}\n{USAGE}" if err.code == 2 else str(err), file=sys.stderr)
        return err.code
    except (Unreachable, Conflict) as err:
        print(str(err), file=sys.stderr)
        return err.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
