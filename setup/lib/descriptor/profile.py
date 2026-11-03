"""Step 2 of the descriptor plan: one profiling pass per table, in SQL, on the database (profile()), and the same
numbers computed here from rows already read (profile_rows(), for files and for tests without a database).

The shape comes from EXA_ALL_COLUMNS in COLUMN_ORDINAL_POSITION order; schema_digest is the SHA-256 of its
NAME:TYPE lines and is how everything downstream knows the table has not changed since approval. A local table is
profiled in full. A virtual table is read through (SELECT * FROM <table> LIMIT 10000): a prefix, not a sample, and
the evidence says "first 10,000 rows". A profile over 30 seconds is flagged slow with its timings; there is no
sampling option.

The statements: one per batch of 40 columns (COUNT(*), and per column COUNT, APPROXIMATE_COUNT_DISTINCT, MIN/MAX
for numbers and dates, and for strings AVG(LENGTH) plus one count per pattern), then three follow-ups and nothing
else: the values of every non-sensitive column with 50 or fewer approximate distinct values (top 20 kept, with
exact counts), an exact COUNT(DISTINCT) for null-free columns within 5% of the row count, and MIN/MAX through
TO_DATE for date strings. Exasol's REGEXP_LIKE must match the whole value, so the patterns carry no ^ or $ and a
date pattern ends in .*. Sensitive columns keep counts only: no values and no ranges leave the database for them.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import re
import time
from typing import Any, Callable, Iterable

BATCH = 40
VIRTUAL_ROWS = 10_000
TOP_VALUES = 20
VALUES_DISTINCT = 50
EXACT_WITHIN = 0.05
SLOW_SECONDS = 30.0

# One regular expression per pattern; REGEXP_LIKE and re.fullmatch read them the same way.
PATTERNS = {
    "iso": r"\d{4}-\d{2}-\d{2}.*",
    "dotted": r"\d{2}\.\d{2}\.\d{4}.*",
    "slash": r"\d{1,2}/\d{1,2}/\d{4}.*",
    "slash_first_over_12": r"(1[3-9]|[23]\d)/\d{1,2}/\d{4}.*",
    "slash_second_over_12": r"\d{1,2}/(1[3-9]|[23]\d)/\d{4}.*",
    "email": r"[^@\s]+@[^@\s]+\.[^@\s]+",
    # seven to fifteen digits, a + or a separator, and not a date written with separators
    "phone": r"(?=(?:\D*\d){7,15}\D*$)(?=.*[ ()+.-])(?!\d{1,4}[./-]\d{1,2}[./-]\d{1,4}(?:\D.*)?$)\+?[0-9 ()./-]+",
    "iban": r"[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}",
    "postcode": r"\d{5}",
}
SENSITIVE = ("email", "phone", "iban", "postcode")
DATE_FORMATS = {"iso": ("YYYY-MM-DD", "%Y-%m-%d", 10), "dotted": ("DD.MM.YYYY", "%d.%m.%Y", 10)}
_COMPILED = {name: re.compile(pattern, re.ASCII) for name, pattern in PATTERNS.items()}


def quoted(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def literal(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def column_kind(column_type: str) -> str:
    """string, integer, decimal, double, date, timestamp, boolean or other, from the SQL type."""
    upper = column_type.upper()
    if upper.startswith(("VARCHAR", "CHAR")):
        return "string"
    if upper.startswith("DATE"):
        return "date"
    if upper.startswith("TIMESTAMP"):
        return "timestamp"
    if upper.startswith("BOOLEAN"):
        return "boolean"
    if upper.startswith(("DOUBLE", "FLOAT")):
        return "double"
    if upper.startswith("DECIMAL"):
        scale = re.search(r",\s*(\d+)\s*\)", upper)
        return "decimal" if scale and int(scale.group(1)) > 0 else "integer"
    return "other"


_DEFAULT_TIMESTAMP = re.compile(r"^TIMESTAMP\(3\)", re.I)


def schema_digest(columns: list[dict[str, Any]]) -> str:
    """sha256 of the NAME:TYPE lines, in table order. TIMESTAMP(3) is written TIMESTAMP: it is the same type (3 is
    the default precision), and the database reports it with the precision while a CREATE TABLE and a shipped
    descriptor name it without - a digest of the spelling would call every such table changed."""
    text = "".join(f"{c['column']}:{_DEFAULT_TIMESTAMP.sub('TIMESTAMP', str(c['type']))}\n" for c in columns)
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


# --- on the database -----------------------------------------------------------------------------------------------

def _rows(conn, sql: str) -> list[dict[str, Any]]:
    statement = conn.execute(sql)
    rows = statement.fetchall()
    if rows and not isinstance(rows[0], dict):
        names = statement.column_names()
        rows = [dict(zip(names, row)) for row in rows]
    return [{str(k).upper(): v for k, v in row.items()} for row in rows]


def _shape(run: Callable[[str], list[dict[str, Any]]], schema: str, table: str) -> tuple[list[dict[str, Any]], bool]:
    rows = run("SELECT c.COLUMN_NAME, c.COLUMN_TYPE, CASE WHEN v.TABLE_NAME IS NULL THEN 0 ELSE 1 END AS IS_VIRTUAL "
               "FROM EXA_ALL_COLUMNS c LEFT JOIN EXA_ALL_VIRTUAL_TABLES v "
               "ON v.TABLE_SCHEMA = c.COLUMN_SCHEMA AND v.TABLE_NAME = c.COLUMN_TABLE "
               f"WHERE c.COLUMN_SCHEMA = {literal(schema)} AND c.COLUMN_TABLE = {literal(table)} "
               "ORDER BY c.COLUMN_ORDINAL_POSITION")
    if not rows:
        raise LookupError(f"No table {schema}.{table} in the database")
    columns = [{"column": str(r["COLUMN_NAME"]), "type": str(r["COLUMN_TYPE"]), "kind": column_kind(str(r["COLUMN_TYPE"]))}
               for r in rows]
    return columns, any(int(r["IS_VIRTUAL"] or 0) for r in rows)


def _batch_sql(source: str, batch: list[dict[str, Any]], offset: int) -> str:
    parts = ["COUNT(*) AS N"]
    for i, column in enumerate(batch, offset):
        q, kind = quoted(column["column"]), column["kind"]
        parts.append(f"COUNT({q}) AS NN{i}")
        if kind != "other":
            parts.append(f"APPROXIMATE_COUNT_DISTINCT({q}) AS ND{i}")
        if kind in ("integer", "decimal", "double", "date", "timestamp"):
            parts += [f"CAST(MIN({q}) AS VARCHAR(100)) AS MN{i}", f"CAST(MAX({q}) AS VARCHAR(100)) AS MX{i}"]
        if kind == "string":
            parts.append(f"AVG(LENGTH({q})) AS LEN{i}")
            parts += [f"SUM(CASE WHEN {q} REGEXP_LIKE {literal(p)} THEN 1 ELSE 0 END) AS P{i}_{name.upper()}"
                      for name, p in PATTERNS.items()]
    return f"SELECT {', '.join(parts)} FROM {source}"


def _values_sql(source: str, columns: list[dict[str, Any]]) -> str:
    select = ", ".join(f"GROUPING({quoted(c['column'])}) AS G{i}, CAST({quoted(c['column'])} AS VARCHAR(2000)) AS V{i}"
                       for i, c in enumerate(columns))
    sets = ", ".join(f"({quoted(c['column'])})" for c in columns)
    return f"SELECT {select}, COUNT(*) AS N FROM {source} GROUP BY GROUPING SETS ({sets})"


def _date_expression(q: str, pattern: str) -> str | None:
    if pattern in DATE_FORMATS:
        sql_format, _, width = DATE_FORMATS[pattern]
        return f"CASE WHEN {q} REGEXP_LIKE {literal(PATTERNS[pattern])} THEN TO_DATE(SUBSTR({q}, 1, {width}), {literal(sql_format)}) END"
    return None


def profile(conn, table: str, *, run: Callable[[str], list[dict[str, Any]]] | None = None) -> dict[str, Any]:
    """The profile of SCHEMA.TABLE: source, columns (in table order) and the statements with their timings."""
    schema, name = (part.strip().strip('"') for part in table.split(".", 1))
    statements: list[dict[str, Any]] = []

    def timed(sql: str) -> list[dict[str, Any]]:
        started = time.monotonic()
        rows = run(sql) if run else _rows(conn, sql)
        statements.append({"sql": sql, "seconds": round(time.monotonic() - started, 3)})
        return rows

    columns, virtual = _shape(timed, schema, name)
    ref = f"{quoted(schema)}.{quoted(name)}"
    source = f"(SELECT * FROM {ref} LIMIT {VIRTUAL_ROWS})" if virtual else ref
    rows = 0
    for start in range(0, len(columns), BATCH):
        answer = timed(_batch_sql(source, columns[start:start + BATCH], start))[0]
        rows = int(answer["N"] or 0)
        for i, column in enumerate(columns[start:start + BATCH], start):
            _read_batch(column, answer, i, rows)
    _follow_ups(timed, source, columns, rows)
    return _finish(columns, rows, virtual, f"{schema}.{name}", statements)


def _read_batch(column: dict[str, Any], answer: dict[str, Any], i: int, rows: int) -> None:
    column["rows"], column["non_null"] = rows, int(answer.get(f"NN{i}") or 0)
    column["approx_distinct"] = int(answer.get(f"ND{i}") or 0)
    if answer.get(f"MN{i}") is not None:
        column["min"], column["max"] = str(answer[f"MN{i}"]), str(answer[f"MX{i}"])
    if column["kind"] == "string":
        column["avg_length"] = round(float(answer.get(f"LEN{i}") or 0), 1)
        column["patterns"] = {p: int(answer.get(f"P{i}_{p.upper()}") or 0) for p in PATTERNS}


def _sensitive(column: dict[str, Any]) -> bool:
    from .roles import sensitivity
    return sensitivity(column) is not None


def _follow_ups(timed, source: str, columns: list[dict[str, Any]], rows: int) -> None:
    few = [c for c in columns if c["kind"] != "other" and c["approx_distinct"] <= VALUES_DISTINCT and not _sensitive(c)]
    if few:
        counts: dict[int, dict[str, int]] = {i: {} for i in range(len(few))}
        for row in timed(_values_sql(source, few)):
            for i in range(len(few)):
                if int(row[f"G{i}"]) == 0 and row[f"V{i}"] is not None:
                    counts[i][str(row[f"V{i}"])] = int(row["N"])
        for i, column in enumerate(few):
            _keep_values(column, counts[i])
    near = [c for c in columns if c["kind"] in ("integer", "string") and rows and c["non_null"] == rows
            and "exact_distinct" not in c and c["approx_distinct"] >= rows * (1 - EXACT_WITHIN)]
    if near:
        answer = timed("SELECT " + ", ".join(f"COUNT(DISTINCT {quoted(c['column'])}) AS D{i}" for i, c in enumerate(near))
                       + f" FROM {source}")[0]
        for i, column in enumerate(near):
            column["exact_distinct"] = int(answer[f"D{i}"])
    dated = [(c, p) for c in columns for p in _date_string(c) if _date_expression(quoted(c["column"]), p)]
    if dated:
        parts = []
        for i, (column, pattern) in enumerate(dated):
            expression = _date_expression(quoted(column["column"]), pattern)
            parts += [f"CAST(MIN({expression}) AS VARCHAR(20)) AS MN{i}", f"CAST(MAX({expression}) AS VARCHAR(20)) AS MX{i}"]
        answer = timed(f"SELECT {', '.join(parts)} FROM {source}")[0]
        for i, (column, _) in enumerate(dated):
            column["min"], column["max"] = answer[f"MN{i}"], answer[f"MX{i}"]


def _keep_values(column: dict[str, Any], counts: dict[str, int]) -> None:
    ordered = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    column["exact_distinct"] = len(ordered)
    column["top"] = [[value, count] for value, count in ordered[:TOP_VALUES]]


def _date_string(column: dict[str, Any]) -> list[str]:
    """The date pattern a string column holds in 98% of its values, as a one-item list, else empty."""
    from .roles import DATE_SHARE
    if column["kind"] != "string" or not column.get("non_null"):
        return []
    best = max(("iso", "dotted", "slash"), key=lambda p: column["patterns"].get(p, 0))
    return [best] if column["patterns"].get(best, 0) >= DATE_SHARE * column["non_null"] else []


def _finish(columns: list[dict[str, Any]], rows: int, virtual: bool, table: str, statements: list[dict[str, Any]]) -> dict[str, Any]:
    for column in columns:
        if _sensitive(column):                     # counts only for a sensitive column
            for key in ("top", "min", "max"):
                column.pop(key, None)
    seconds = round(sum(s["seconds"] for s in statements), 3)
    found = {"source": {"kind": "virtual" if virtual else "local", "object": table, "schema_digest": schema_digest(columns),
                        "profiled_rows": rows},
             "columns": columns, "statements": statements, "seconds": seconds}
    if virtual:
        found["source"]["prefix"] = f"first {VIRTUAL_ROWS:,} rows"
    if seconds > SLOW_SECONDS:
        found["slow"] = f"the profile took {seconds:.1f} s (over {SLOW_SECONDS:.0f} s): raise it, do not add sampling"
    return found


# --- from rows already read ----------------------------------------------------------------------------------------

def _python_value(kind: str, value: Any) -> Any:
    if value is None or value == "":
        return None
    if kind in ("integer",):
        return int(value)
    if kind in ("decimal", "double"):
        return float(value)
    if kind == "date":
        return value if isinstance(value, dt.date) else dt.date.fromisoformat(str(value)[:10])
    if kind == "timestamp":
        return value if isinstance(value, dt.datetime) else dt.datetime.fromisoformat(str(value))
    if kind == "boolean":
        return value if isinstance(value, bool) else str(value).lower() in ("true", "1", "yes")
    return str(value)


def profile_rows(columns: list[tuple[str, str]], rows: Iterable[Iterable[Any]], table: str, *, virtual: bool = False) -> dict[str, Any]:
    """The same profile from (name, SQL type) columns and their rows: what profile() gives for a table holding them
    (distinct counts exact, so approx_distinct equals exact_distinct here)."""
    shape = [{"column": name, "type": column_type, "kind": column_kind(column_type)} for name, column_type in columns]
    values: list[list[Any]] = [[] for _ in shape]
    count = 0
    for row in rows:
        if virtual and count >= VIRTUAL_ROWS:
            break
        count += 1
        for i, value in enumerate(row):
            values[i].append(_python_value(shape[i]["kind"], value))
    for column, items in zip(shape, values):
        present = [v for v in items if v is not None]
        distinct = len(set(present))
        column.update({"rows": count, "non_null": len(present), "approx_distinct": distinct})
        if column["kind"] in ("integer", "decimal", "double", "date", "timestamp") and present:
            column["min"], column["max"] = str(min(present)), str(max(present))
        if column["kind"] == "string":
            column["avg_length"] = round(sum(len(v) for v in present) / len(present), 1) if present else 0.0
            column["patterns"] = {p: sum(1 for v in present if _COMPILED[p].fullmatch(v)) for p in PATTERNS}
        if column["kind"] != "other" and distinct <= VALUES_DISTINCT and not _sensitive(column):
            counts: dict[str, int] = {}
            for v in present:
                key = _sql_text(v)
                counts[key] = counts.get(key, 0) + 1
            _keep_values(column, counts)
        elif column["kind"] in ("integer", "string") and count and len(present) == count and distinct >= count * (1 - EXACT_WITHIN):
            column["exact_distinct"] = distinct
        for pattern in _date_string(column):
            fmt = DATE_FORMATS.get(pattern)
            if fmt:
                parsed = [dt.datetime.strptime(v[:fmt[2]], fmt[1]).date() for v in present if _COMPILED[pattern].fullmatch(v)]
                column["min"], column["max"] = str(min(parsed)), str(max(parsed))
    return _finish(shape, count, virtual, table, [])


def _sql_text(value: Any) -> str:
    """A value as CAST(... AS VARCHAR) shows it, near enough for the top values."""
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)
