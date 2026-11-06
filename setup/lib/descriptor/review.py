"""Step 4's second look: what the approver is about to sign, checked against the data before anything is written.

The descriptor rules (tools/descriptor_rules.py) check the document: every column a role, a slot's column the right
role, no sensitive column grouped. This checks the table and the review itself, with at most three SELECTs:

Refused - the approval stops, the message says what to change:
    the key slot's column has a null or a repeated value in the table now (one COUNT statement);
    the target slot's column holds other than exactly two values (a yes/no outcome: 0/1, true/false, two labels).
Warned - the approval goes through and says so, in its result and the workflow log:
    a column gives the target away: values where the target is (nearly) always one way cover 95% of rows and catch
    90% of the target's rarer value - usually written after the outcome (an order's STATUS once it was cancelled),
    the same rule as the Explore notebook's leakage check; one GROUPING SETS statement over the columns with at most
    50 values;
    roles drafted at low confidence that nobody changed: approving them is a decision, and the approver is shown
    which ones they took on trust.
"""

from __future__ import annotations

from typing import Any, Callable

Run = Callable[[str], list[dict[str, Any]]]
PURE = 0.99                      # a value is "one way" when the target is this share one value
COVERS = 0.95                    # those values cover this share of rows
CATCHES = 0.90                   # and hold this share of the rarer target value
GROUPABLE = 50                   # a column with more values is not checked for leakage
SET_BY = ("set by you", "set by hand")


def _q(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _lit(text: str) -> str:
    return "'" + str(text).replace("'", "''") + "'"


def _source(doc: dict[str, Any]) -> str:
    schema, name = doc["source"]["object"].split(".", 1)
    return f"{_q(schema)}.{_q(name)}"


def unreviewed(doc: dict[str, Any]) -> list[str]:
    """The columns drafted at low confidence whose role nobody set: 'COLUMN (role: evidence)'."""
    return [f"{name} ({entry['role']}: {entry.get('evidence', '')})" for name, entry in (doc.get("columns") or {}).items()
            if entry.get("confidence") == "low" and not str(entry.get("evidence", "")).startswith(SET_BY)]


def refusals(run: Run, doc: dict[str, Any]) -> list[str]:
    """What the table says against the slots: a key that is not unique now, a target that is not two-valued."""
    slots, found = doc.get("slots") or {}, []
    source = _source(doc)
    key, target = slots.get("key"), slots.get("target")
    if key or target:
        parts = ["COUNT(*) AS N"]
        if key:
            parts += [f"COUNT({_q(key)}) AS KN", f"COUNT(DISTINCT {_q(key)}) AS KD"]
        if target:
            parts += [f"COUNT(DISTINCT {_q(target)}) AS TD"]
        row = run(f"SELECT {', '.join(parts)} FROM {source}")[0]
        rows = int(row["N"] or 0)
        if key and rows:
            present, distinct = int(row["KN"] or 0), int(row["KD"] or 0)
            if present < rows:
                found.append(f"slots.key: {key} is empty in {rows - present:,} of {rows:,} rows; a key names every row - "
                             f"pick a column with a value in each, or leave the key empty (--role key=-)")
            elif distinct < rows:
                found.append(f"slots.key: {key} repeats ({distinct:,} values in {rows:,} rows); a key names one row - "
                             f"pick a unique column, or leave the key empty (--role key=-)")
        if target and int(row["TD"] or 0) != 2:
            found.append(f"slots.target: {target} holds {int(row['TD'] or 0):,} values; a target is a yes/no outcome with "
                         f"exactly two (0/1, true/false, two labels) - pick one, or leave it empty (--role target=-)")
    return found


def leaks(run: Run, doc: dict[str, Any]) -> list[str]:
    """The columns that give the target away, each with the values that do: 'STATUS gives CANCELLED away: ...'."""
    target = (doc.get("slots") or {}).get("target")
    if not target:
        return []
    source = _source(doc)
    values = run(f"SELECT CAST({_q(target)} AS VARCHAR(2000)) AS V, COUNT(*) AS N FROM {source} "
                 f"WHERE {_q(target)} IS NOT NULL GROUP BY 1 ORDER BY 2, 1")
    if len(values) != 2:
        return []
    rare = values[0]["V"]                                   # the rarer value is what a model is asked to find
    taken = {v for k, v in (doc.get("slots") or {}).items() if v and k != "category" and k != "entity"}
    candidates = [c for c, e in (doc.get("columns") or {}).items()
                  if c not in taken and e.get("role") in ("category", "flag", "other")]
    if not candidates:
        return []
    select = ", ".join(f"GROUPING({_q(c)}) AS G{i}, CAST({_q(c)} AS VARCHAR(2000)) AS V{i}" for i, c in enumerate(candidates))
    sets = ", ".join(f"({_q(c)})" for c in candidates)
    hit = f"CASE WHEN CAST({_q(target)} AS VARCHAR(2000)) = {_lit(rare)} THEN 1 ELSE 0 END"
    rows = run(f"SELECT {select}, COUNT(*) AS N, SUM({hit}) AS H FROM {source} WHERE {_q(target)} IS NOT NULL "
               f"GROUP BY GROUPING SETS ({sets})")
    groups: dict[int, list[tuple[Any, int, int]]] = {i: [] for i in range(len(candidates))}
    for row in rows:
        for i in range(len(candidates)):
            if int(row[f"G{i}"]) == 0:
                groups[i].append((row[f"V{i}"], int(row["N"]), int(row["H"] or 0)))
    found = []
    for i, column in enumerate(candidates):
        values_ = groups[i]
        if not 1 < len(values_) <= GROUPABLE:
            continue
        total = sum(n for _, n, _ in values_)
        rare_rows = sum(h for _, _, h in values_)
        if not total or not rare_rows or rare_rows == total:
            continue
        pure = [(v, n, h) for v, n, h in values_ if h / n >= PURE or h / n <= 1 - PURE]
        if sum(n for _, n, _ in pure) / total >= COVERS and sum(h for _, _, h in pure) / rare_rows >= CATCHES:
            deciding = [repr(v) for v, n, h in pure if h / n >= PURE][:3]
            found.append(f"{column} gives {target} away: {target} is {rare!r} whenever {column} is {', '.join(deciding)}"
                         if deciding else f"{column} gives {target} away: its values split {target} almost perfectly")
    return found


def review(run: Run, doc: dict[str, Any]) -> dict[str, list[str]]:
    """{refused, leaks, unreviewed} for a descriptor about to be approved; leaks are only looked for when nothing is
    refused (a target with three values has no 'rarer value')."""
    refused = refusals(run, doc)
    return {"refused": refused, "leaks": [] if refused else leaks(run, doc), "unreviewed": unreviewed(doc)}
