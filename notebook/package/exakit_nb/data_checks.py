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

# The values that stand for "not known" while looking like a category: matched on the whole value, ignoring case and
# the blanks around it. "word*" matches anything starting with the word; "-" and "?" match a run of them. The
# notebook's cells pass their own list (PLACEHOLDER_VALUES), so a person can add or remove one.
PLACEHOLDER_VALUES = ["unknown*", "invalid*", "n/a", "na", "none", "null", "nil", "missing", "not available",
                      "not known", "not set", "undefined", "-", "?", "tbd", "#n/a"]


def placeholder_pattern(values: list[str] | None = None) -> "re.Pattern[str]":
    """The regular expression a list of placeholder values stands for (PLACEHOLDER_VALUES by default)."""
    parts = []
    for value in values if values is not None else PLACEHOLDER_VALUES:
        value = str(value).strip()
        if not value:
            continue
        if set(value) <= {"-"}:
            parts.append("-+")
        elif set(value) <= {"?"}:
            parts.append(r"\?+")
        elif value.endswith("*"):
            parts.append(re.escape(value[:-1]) + ".*")
        else:
            parts.append(re.escape(value))
    return re.compile(r"^\s*(" + "|".join(parts or ["(?!)"]) + r")\s*$", re.IGNORECASE)


PLACEHOLDER = placeholder_pattern()
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


def data_checks(conn, ds, *, show: bool = True, placeholder_values: list[str] | None = None, rare: float = RARE):
    """Prepare: one row per finding - CHECK, COLUMN_NAME, ROWS_AFFECTED, PCT, MEANS - for repeated keys, repeated
    identifiers, exact copies of a row, empty cells, placeholder values and a rare label. Prints each finding in one
    sentence (``show=False`` only returns them); an empty frame means the table passed every check.
    ``placeholder_values`` is the list of values that mean "not known" (PLACEHOLDER_VALUES by default); ``rare`` the
    target rate under which a target counts as rare (0.10)."""
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
    for column, found in placeholders(conn, ds, values=placeholder_values).items():
        for value, count in found:
            add("placeholder", column, count,
                f"{column} = '{value}' in {count:,} rows looks like a category but means 'not known': "
                "treat it as empty, or say what it is")
    if label:
        rate = _run(conn, f"SELECT AVG(CAST({_quoted(label)} AS DOUBLE)) AS R FROM {table} WHERE {_quoted(label)} IS NOT NULL")
        r = float(rate["R"][0] or 0)
        if r < rare or r > 1 - rare:
            rare_value, common = (1, 0) if r < rare else (0, 1)
            share = r if rare_value == 1 else 1 - r
            add("rare label", label, int(round(share * n)),
                f"{label} = {rare_value} in only {100 * share:.1f}% of rows: a model that always answers {common} is right "
                f"{100 * (1 - share):.1f}% of the time, so judge a model by ROC AUC or by that baseline, never by accuracy")
    frame = _frame(findings, ["CHECK", "COLUMN_NAME", "ROWS_AFFECTED", "PCT", "MEANS"])
    if show:
        if frame.empty:
            print(f"{ds.id}: no repeated keys, no copies, no empty cells, no placeholders - the table passed every check.")
        for line in frame["MEANS"]:
            print("- " + line)
    return frame


def _grouped(conn, table: str, columns: list[str], rate: str | None = None, where: str = "") -> dict[str, Any]:
    """Each column's value counts from ONE statement (GROUPING SETS), not one query a column: {COLUMN: frame of
    VALUE_, N and, with ``rate``, R = AVG(rate)}. The values are read as text; a NULL value is a group of its own."""
    if not columns:
        return {}
    select = ", ".join(f"GROUPING({_quoted(c)}) AS G{i}, CAST({_quoted(c)} AS VARCHAR(2000)) AS V{i}"
                       for i, c in enumerate(columns))
    average = f", AVG(CAST({_quoted(rate)} AS DOUBLE)) AS R" if rate else ""
    frame = _run(conn, f"SELECT {select}, COUNT(*) AS N{average} FROM {table}{where} "
                       f"GROUP BY GROUPING SETS ({', '.join(f'({_quoted(c)})' for c in columns)})")
    out: dict[str, Any] = {}
    for i, column in enumerate(columns):
        part = frame[frame[f"G{i}"].astype(int) == 0]
        keep = {"VALUE_": part[f"V{i}"], "N": part["N"].astype(float)}
        if rate:
            keep["R"] = part["R"].astype(float)
        import pandas as pd

        out[column] = pd.DataFrame(keep).sort_values("N", ascending=False).reset_index(drop=True)
    return out


def placeholders(conn, ds, values: list[str] | None = None) -> dict[str, list[tuple[str, int]]]:
    """{COLUMN: [(value, rows), ...]} for the values that stand for "not known" in the category and flag columns -
    only where the values can be listed (at most GROUPABLE of them). The typed view turns these into NULL."""
    table, columns = ds.fact_table, _columns(ds)
    label = _bare(ds.col("label")) if ds.has("label") else None
    found: dict[str, list[tuple[str, int]]] = {}
    pattern = PLACEHOLDER if values is None else placeholder_pattern(values)
    wanted = [c for c, e in columns.items() if e.get("role") in ("category", "flag") and c != label]
    if not wanted:
        return found
    # Two statements for every column together: how many values each has, then the values of the ones that can be
    # listed - not one query a column.
    distinct = _run(conn, "SELECT " + ", ".join(f"APPROXIMATE_COUNT_DISTINCT({_quoted(c)}) AS {_quoted('D_' + c)}"
                                                for c in wanted) + f" FROM {table}")
    few = [c for c in wanted if int(distinct[f"D_{c}"][0] or 0) <= GROUPABLE * 2]
    for column, counted in _grouped(conn, table, few).items():
        if len(counted) > GROUPABLE:
            continue
        hits = [(str(v), int(n)) for v, n in zip(counted["VALUE_"], counted["N"]) if isinstance(v, str) and pattern.match(v)]
        if hits:
            found[column] = hits
    return found


def leakage_check(conn, ds, *, show: bool = True, pure: float = PURE) -> list[str]:
    """Validate: the columns whose values (almost) decide the label on their own - each a value or values where the
    label is (nearly) always 1 or always 0, covering most rows. Such a column is usually written after the outcome
    (an order's status once it was cancelled) and makes any model look perfect; leave it out of the features. Returns
    those columns (none: the list is empty) and prints why each was flagged."""
    if not ds.has("label"):
        if show:
            print("No target: nothing to check for a column that gives it away.")
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
    groupable = [c for c in candidates if 1 < int(distinct[f"D_{c}"][0] or 0) <= GROUPABLE]
    # Every groupable column's rate of the label per value, in ONE statement (GROUPING SETS), not one query a column.
    for column, groups in _grouped(conn, table, groupable, rate=label, where=f" WHERE {_quoted(label)} IS NOT NULL").items():
        total = float(groups["N"].sum() or 0)
        positives = float((groups["N"] * groups["R"]).sum() or 0)
        if not total or not positives or positives == total:
            continue
        deciders = groups[(groups["R"] >= pure) | (groups["R"] <= 1 - pure)]
        pure_rows = float(deciders["N"].sum())
        caught = float((deciders["N"] * deciders["R"]).sum())      # label-1 rows that sit in a value deciding them
        if pure_rows / total >= 0.95 and caught / positives >= 0.9:
            leaked.append(column)
            if show:
                deciding = deciders[deciders["R"] >= pure]["VALUE_"].astype(str).tolist()[:3]
                print(f"- {column} gives {label} away: "
                      + (f"{label} is 1 whenever {column} is {', '.join(repr(v) for v in deciding)}" if deciding
                         else f"its values split {label} almost perfectly")
                      + f". It was probably written after the outcome - leave it out of any model.")
    if show and not leaked:
        print(f"No column decides {label} on its own: nothing to leave out.")
    return leaked
