"""Prepare and Validate: what the data itself says is wrong with it, and any column that gives the label away.

Both are built from the descriptor alone - the key, the label and every column's role - so no column name is typed in
a notebook and the same cell runs on every dataset. Each check is one or two SQL statements, run through nb.sql (so
they are shown and logged like every other query), and each finding is one plain sentence saying what it does to a
result. Nothing is changed in the data: deciding what to do about a finding is the user's.

    findings = nb.data_checks(conn, ds)        # Prepare: repeated keys and ids, exact copies, gaps, placeholders, a rare label
    leaks = nb.leakage_check(conn, ds)         # Validate: columns whose values (almost) decide the label on their own
"""

from __future__ import annotations

import re
from typing import Any

# A value that stands for "not known" while looking like a category. Matched on the whole value, case-insensitive.
PLACEHOLDER = re.compile(r"^\s*(unknown.*|invalid.*|n/?a|none|null|nil|missing|not (available|known|set)|undefined|"
                         r"-+|\?+|tbd|#n/a)\s*$", re.IGNORECASE)
GROUPABLE = 50          # a column with at most this many values is checked value by value
PURE = 0.99             # a value whose label rate is at least this (or at most 1 - this) decides the label
RARE = 0.10             # a label rate under this (or over 1 - this) is a rare class


def _quoted(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _bare(column: str) -> str:
    return column.strip('"')


def _run(conn, statement: str):
    from . import sql
    return sql(conn, statement)


def _columns(ds) -> dict[str, dict[str, Any]]:
    """{COLUMN: entry} from the descriptor, in table order."""
    return dict(getattr(ds.descriptor, "columns", {}) or {})


def _key(ds) -> str | None:
    key = (getattr(ds.descriptor, "slots", {}) or {}).get("key")
    if key:
        return key
    return next((name for name, entry in _columns(ds).items() if entry.get("role") == "key"), None)


def _frame(rows: list[dict[str, Any]], columns: list[str]):
    import pandas as pd
    return pd.DataFrame(rows, columns=columns)


def data_checks(conn, ds, *, show: bool = True):
    """Prepare: one row per finding - CHECK, COLUMN_NAME, ROWS_AFFECTED, PCT, MEANS - for repeated keys, repeated
    identifiers, exact copies of a row, empty cells, placeholder values and a rare label. Prints each finding in one
    sentence (``show=False`` only returns them); an empty frame means the table passed every check."""
    table, columns, key = ds.fact_table, _columns(ds), _key(ds)
    label = _bare(ds.col("label")) if ds.has("label") else None
    findings: list[dict[str, Any]] = []
    names = [c for c in columns] or ([key] if key else [])
    if not names:
        return _frame([], ["CHECK", "COLUMN_NAME", "ROWS_AFFECTED", "PCT", "MEANS"])

    identifiers = [c for c, e in columns.items() if e.get("role") in ("key", "identifier")]
    counts = ", ".join([f"COUNT({_quoted(c)}) AS {_quoted('N_' + c)}" for c in names]
                       + [f"COUNT(DISTINCT {_quoted(c)}) AS {_quoted('D_' + c)}" for c in identifiers])
    totals = _run(conn, f"SELECT COUNT(*) AS N_ROWS, {counts} FROM {table}")
    n = int(totals["N_ROWS"][0] or 0)
    if n == 0:
        if show:
            print("The table is empty: nothing to check.")
        return _frame([], ["CHECK", "COLUMN_NAME", "ROWS_AFFECTED", "PCT", "MEANS"])

    def add(check: str, column: str | None, rows: int, means: str) -> None:
        findings.append({"CHECK": check, "COLUMN_NAME": column, "ROWS_AFFECTED": rows,
                         "PCT": round(100.0 * rows / n, 1), "MEANS": means})

    grain = getattr(ds.descriptor, "grain", None)
    for column in identifiers:
        unique = int(totals[f"D_{column}"][0] or 0)
        repeats = n - unique
        # Only an id that is almost one per row reads as the row's own id; one shared by many rows (a customer
        # on every purchase) repeats by design.
        if repeats > 0 and unique >= 0.9 * n:
            role = columns[column].get("role")
            add("repeated " + ("key" if role == "key" else "id"), column, repeats,
                f"{column} repeats in {repeats:,} rows. If one row should be one {column}, those rows count twice: "
                "count DISTINCT, or keep one row per value" + (f" (the descriptor's grain: {grain})" if grain else ""))
    others = [c for c in names if c != key]
    if others:
        distinct = _run(conn, f"SELECT COUNT(*) AS N FROM (SELECT DISTINCT {', '.join(_quoted(c) for c in others)} "
                              f"FROM {table})")
        copies = n - int(distinct["N"][0] or 0)
        if copies > 0:
            add("exact copies", None, copies,
                f"{copies:,} rows are exact copies of another row in every column but the key: drop them before "
                "counting anything")
    for column in names:
        empty = n - int(totals[f"N_{column}"][0] or 0)
        if empty > 0:
            add("empty cells", column, empty,
                f"{column} is empty in {empty:,} rows: averages leave those rows out and groupings put them in a "
                "group of their own")
    for column, found in placeholders(conn, ds).items():
        for value, count in found:
            add("placeholder", column, count,
                f"{column} = '{value}' in {count:,} rows looks like a category but means 'not known': "
                "treat it as empty, or say what it is")
    if label:
        rate = _run(conn, f"SELECT AVG(CAST({_quoted(label)} AS DOUBLE)) AS R FROM {table} WHERE {_quoted(label)} IS NOT NULL")
        r = float(rate["R"][0] or 0)
        if r < RARE or r > 1 - RARE:
            rare, common = (1, 0) if r < RARE else (0, 1)
            share = r if rare == 1 else 1 - r
            add("rare label", label, int(round(share * n)),
                f"{label} = {rare} in only {100 * share:.1f}% of rows: a model that always answers {common} is right "
                f"{100 * (1 - share):.1f}% of the time, so judge a model by ROC AUC or by that baseline, never by accuracy")
    frame = _frame(findings, ["CHECK", "COLUMN_NAME", "ROWS_AFFECTED", "PCT", "MEANS"])
    if show:
        if frame.empty:
            print(f"{ds.id}: no repeated keys, no copies, no empty cells, no placeholders - the table passed every check.")
        for line in frame["MEANS"]:
            print("- " + line)
    return frame


def placeholders(conn, ds) -> dict[str, list[tuple[str, int]]]:
    """{COLUMN: [(value, rows), ...]} for the values that stand for "not known" in the category and flag columns -
    only where the values can be listed (at most GROUPABLE of them). The typed view turns these into NULL."""
    table, columns = ds.fact_table, _columns(ds)
    label = _bare(ds.col("label")) if ds.has("label") else None
    found: dict[str, list[tuple[str, int]]] = {}
    for column in [c for c, e in columns.items() if e.get("role") in ("category", "flag") and c != label]:
        values = _run(conn, f"SELECT {_quoted(column)} AS VALUE_, COUNT(*) AS N FROM {table} "
                            f"GROUP BY 1 ORDER BY N DESC LIMIT {GROUPABLE + 1}")
        if len(values) > GROUPABLE:
            continue
        hits = [(str(v), int(n)) for v, n in zip(values["VALUE_"], values["N"]) if isinstance(v, str) and PLACEHOLDER.match(v)]
        if hits:
            found[column] = hits
    return found


def leakage_check(conn, ds, *, show: bool = True) -> list[str]:
    """Validate: the columns whose values (almost) decide the label on their own - each a value or values where the
    label is (nearly) always 1 or always 0, covering most rows. Such a column is usually written after the outcome
    (an order's status once it was cancelled) and makes any model look perfect; leave it out of the features. Returns
    those columns (none: the list is empty) and prints why each was flagged."""
    if not ds.has("label"):
        if show:
            print("No label role: nothing to check for a column that gives it away.")
        return []
    table, columns, key = ds.fact_table, _columns(ds), _key(ds)
    label = _bare(ds.col("label"))
    text = {_bare(c) for c in ds.text_cols()}
    candidates = [c for c, e in columns.items()
                  if c not in (label, key) and c not in text and e.get("role") not in ("key", "identifier", "text")]
    if not candidates:
        return []
    distinct = _run(conn, "SELECT " + ", ".join(f"COUNT(DISTINCT {_quoted(c)}) AS {_quoted('D_' + c)}" for c in candidates)
                    + f" FROM {table}")
    leaked: list[str] = []
    for column in candidates:
        if not (1 < int(distinct[f"D_{column}"][0] or 0) <= GROUPABLE):
            continue
        groups = _run(conn, f"SELECT {_quoted(column)} AS VALUE_, COUNT(*) AS N, AVG(CAST({_quoted(label)} AS DOUBLE)) AS R "
                            f"FROM {table} WHERE {_quoted(label)} IS NOT NULL GROUP BY 1")
        total = float(groups["N"].sum() or 0)
        positives = float((groups["N"] * groups["R"]).sum() or 0)
        if not total or not positives or positives == total:
            continue
        pure = groups[(groups["R"] >= PURE) | (groups["R"] <= 1 - PURE)]
        pure_rows = float(pure["N"].sum())
        caught = float((pure["N"] * pure["R"]).sum())      # label-1 rows that sit in a value deciding them
        if pure_rows / total >= 0.95 and caught / positives >= 0.9:
            leaked.append(column)
            if show:
                deciding = pure[pure["R"] >= PURE]["VALUE_"].astype(str).tolist()[:3]
                print(f"- {column} gives {label} away: "
                      + (f"{label} is 1 whenever {column} is {', '.join(repr(v) for v in deciding)}" if deciding
                         else f"its values split {label} almost perfectly")
                      + f". It was probably written after the outcome - leave it out of any model.")
    if show and not leaked:
        print(f"No column decides {label} on its own: nothing to leave out.")
    return leaked
