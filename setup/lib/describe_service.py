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

Exit codes: 0 ok; 2 bad arguments; 3 the table is not there; 4 the database is not reachable.

The database steps connect through pyexasol as the kit's admin user: EXAKIT_PYX_DSN, EXAKIT_PYX_USER and
EXAKIT_PYX_PWFILE (the FILE holding the password - the password itself never reaches a command line, an output or a
log). Only SELECTs run; nothing is written to the database.

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
warning line, the draft unchanged.
"""

from __future__ import annotations

import datetime as dt
import getpass
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
_ID = re.compile(r"^[a-z0-9]+([-_][a-z0-9]+)*$")


class Refused(ValueError):
    """Input the kit refuses; the message names what is wrong. Exit 2."""

    code = 2


class NotFound(Refused):
    """The table is not in the database. Exit 3."""

    code = 3


class Unreachable(RuntimeError):
    """The database could not be reached, or the connection settings are not there. Exit 4."""

    code = 4


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
        p = min(1.0, 1.2 * sample / rows) if rows else 1.0
        select = ", ".join(quoted(c["column"]) for c in columns)
        fetched = _rows(conn, f"SELECT {select} FROM {ref} WHERE RANDOM() < {p!r} LIMIT {int(sample)}")
        statements += 1
        records, profiled = _profile_rows(columns, fetched), len(fetched)
    else:
        records, used = _profile_full(conn, ref, columns, rows)
        statements += used
        profiled = rows
    return {"table": f"{schema}.{name}", "schema": schema, "name": name, "virtual": virtual, "rows": rows, "sampled": sampled,
            "sample": sample, "profiled_rows": profiled, "statements": statements, "columns": records}


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
    evidence["excluded"] = excluded
    evidence["table"] = {"rows": profile["rows"], "profiled_rows": profile["profiled_rows"], "sampled": profile["sampled"],
                         "sample": profile["sample"], "virtual": profile["virtual"], "statements": profile["statements"],
                         "columns": len(profile["columns"])}
    source = shipped_source(table, root) or (f"vs:{schema}" if profile.get("virtual") else table)
    return {"schema_version": 2, "id": slug, "fact_table": table, "source": source, "version": 1, "status": "draft",
            "owner": descriptor_owner(), "created": _now(), "drafted_by": "profile", "digest": None,
            "roles": roles, "evidence": evidence, "missing": missing}


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


# --- the command line ----------------------------------------------------------------------------------------------

USAGE = ("usage: describe_service.py draft <SCHEMA.TABLE> [--sample N] [--id <slug>] [--json] [--write <path>]\n"
         "       describe_service.py profile <SCHEMA.TABLE> [--sample N]\n"
         "       describe_service.py evidence-check <descriptor.yaml> [--sample N] [--json]")


def _options(argv: list[str], flags: tuple[str, ...], values: tuple[str, ...]) -> tuple[list[str], dict[str, Any]]:
    """Positionals and options; an unknown option, a repeated one or a missing value is refused."""
    positional: list[str] = []
    options: dict[str, Any] = {}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in flags:
            options[arg] = True
        elif arg in values:
            if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                raise Refused(f"{arg} needs a value.")
            if arg in options:
                raise Refused(f"{arg} was given twice.")
            options[arg] = argv[i + 1]
            i += 1
        elif arg.startswith("-") and arg != "-":
            raise Refused(f"Unknown option '{arg}' (supported: {', '.join(flags + values)}).")
        else:
            positional.append(arg)
        i += 1
    if "--sample" in options:
        if not re.fullmatch(r"[1-9][0-9]*", options["--sample"]):
            raise Refused(f"--sample takes the number of rows to profile (a positive integer), not '{options['--sample']}'.")
        options["--sample"] = int(options["--sample"])
    return positional, options


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
        raise Refused(f"Unknown command '{command}' (draft, profile, evidence-check).")
    except Refused as err:
        print(f"{err}\n{USAGE}" if err.code == 2 else str(err), file=sys.stderr)
        return err.code
    except Unreachable as err:
        print(str(err), file=sys.stderr)
        return err.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
