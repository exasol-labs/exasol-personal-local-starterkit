"""Links between tables of different sources, found from their values - not from their names, not from declared keys.

A schema map (schema.py) finds the links inside one schema. Across schemas - a sample dataset, your loaded files, and
any number of external sources - the same customer may be CUST_NO in one and CUSTOMER_ID in another, with no foreign
key anywhere. This module finds such a link from what the columns hold:

    1. Keys: per table, the columns whose every value is present and different (a declared primary key, an approved
       column map's key, or measured: COUNT = COUNT(col) and the distinct count equal to it).
    2. Candidates: every column of another table that could point at a key - an integer or a short text, with at
       least MIN_VALUES different values - whose range and lengths fit inside the key's.
    3. Evidence: up to SAMPLE distinct values of the candidate are read once; each surviving key is asked how many of
       them it holds: SELECT COUNT(DISTINCT key) FROM table WHERE key IN (the values). A link is proposed when at
       least MIN_SHARE of them are found. The key is then confirmed unique with an exact count.

Numbers need more than that. A key that is simply 1, 2, 3 ... N holds every small number, so a meter id, a quantity
or a day count would all "match" it (measured: 18 false links on a database with six schemas before this rule). So
an integer column is only a candidate when its values span at least MIN_SPAN of the key's range AND something says
the two belong together: names at least MIN_ALIKE alike, an approved column map calling it a key or an identifier
(never a measure), or a pair a model or a person proposed. Even then a number link is marked "low": the data can
refute it (values missing from the key) but never confirm it, so it goes into a model only when a person says so. Text values (codes, names, states) carry their own evidence; a text
column only partly contained by its different values (PARTIAL to MIN_SHARE) is then counted by rows, when the key is
small enough to list (SMALL_KEY): 11 misspelt state names among 47 are 23% of the values but 21 of 128,975 rows. At
most MAX_ORPHANS of the rows missing makes it a link, and the values that do not match are part of its evidence;
more than that stays a partial match to clean, never a link.

Every statement is bounded, so a huge table or a live external source costs the same as a small one:
    one aggregate per table (row count, and per column: values present, approximate distinct count, min, max,
    shortest and longest), pushed down to the source for a virtual table;
    one SELECT DISTINCT ... LIMIT SAMPLE per candidate column;
    one COUNT with an IN list of at most SAMPLE values per checked pair (pushed down as a filter);
    at most MAX_CHECKS pairs, the most likely first (the rest are counted and reported, never silently skipped).

Nothing is written. An AI model may propose pairs (names, types and notes only); each is checked the same way and
proposed only when the values agree.
"""

from __future__ import annotations

import re
from difflib import SequenceMatcher
from typing import Any, Callable, Iterable

SAMPLE = 500            # distinct values read from a candidate column
MIN_VALUES = 20         # fewer different values than this cannot show a link (a flag or a code list matches anything)
MIN_SHARE = 0.9         # share of the sampled values the key must hold
MAX_CHECKS = 400        # pairs checked against the database in one search
MIN_SPAN = 0.5          # an integer pointer must span at least this share of the key's range (see fits())
MIN_ALIKE = 0.5         # ... and its name must be this alike to the key's, unless a person or a model named the pair
PARTIAL = 0.5           # a text column this much contained is looked at by rows; below MAX_ORPHANS missing: a link
MAX_ORPHANS = 0.001     # a link may miss at most this share of its rows (the schema map's own rule)
MAX_LENGTH = 200        # a text longer than this is prose, not a key or a pointer to one
SMALL_KEY = 2000        # a key with at most this many values is compared by rows (its values fit in one statement)
_INTEGER = ("DECIMAL", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "NUMBER", "NUMERIC")
_TEXT = ("VARCHAR", "CHAR")
_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

Run = Callable[[str], list[dict[str, Any]]]


def _q(name: str) -> str:
    return '"' + str(name).replace('"', '""') + '"'


def _lit(value: Any) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def kind(column_type: str) -> str | None:
    """"int" or "text" for a column that can hold a key; None for a measure, a date or a flag."""
    text = str(column_type or "").upper()
    if text.startswith(_INTEGER):
        match = re.search(r"\(\s*\d+\s*,\s*(\d+)\s*\)", text)
        return "int" if not match or match.group(1) == "0" else None
    if text.startswith(_TEXT):
        return "text"         # whatever size was declared (a loaded file's columns are VARCHAR(2000000)): see MAX_LENGTH
    return None


def _stem(name: str) -> str:
    return re.sub(r"(^[A-Z]{1,3}_)|(_?(ID|KEY|NO|NR|NUM|NUMBER|CODE|REF))$", "", name.upper())


def similarity(a: str, b: str) -> float:
    """How alike two column names are, 0 to 1 (a tie-breaker and an ordering, never a reason for a link)."""
    return SequenceMatcher(None, _stem(a), _stem(b)).ratio()


def columns(run: Run, schemas: Iterable[str]) -> tuple[dict[str, list[dict[str, Any]]], set[str]]:
    """({SCHEMA.TABLE: [{name, type, kind}]}, the virtual schemas among them)."""
    names = [str(s).upper() for s in schemas]
    if not names or any(not _NAME.match(s) for s in names):
        raise ValueError("Name the schemas as plain names (letters, digits and _).")
    where = ", ".join(_lit(s) for s in names)
    tables: dict[str, list[dict[str, Any]]] = {}
    for row in run("SELECT COLUMN_SCHEMA, COLUMN_TABLE, COLUMN_NAME, COLUMN_TYPE FROM SYS.EXA_ALL_COLUMNS "
                   f"WHERE COLUMN_SCHEMA IN ({where}) AND COLUMN_OBJECT_TYPE IN ('TABLE', 'VIEW') "
                   "ORDER BY COLUMN_SCHEMA, COLUMN_TABLE, COLUMN_ORDINAL_POSITION"):
        tables.setdefault(f"{row['COLUMN_SCHEMA']}.{row['COLUMN_TABLE']}", []).append(
            {"name": str(row["COLUMN_NAME"]), "type": str(row["COLUMN_TYPE"]), "kind": kind(str(row["COLUMN_TYPE"]))})
    virtual = {str(r["SCHEMA_NAME"]) for r in run(
        f"SELECT SCHEMA_NAME FROM SYS.EXA_SCHEMAS WHERE SCHEMA_IS_VIRTUAL AND SCHEMA_NAME IN ({where})")}
    return tables, virtual


def declared_keys(run: Run, schemas: Iterable[str]) -> dict[str, str]:
    """{SCHEMA.TABLE.COLUMN: "declared primary key"} for single-column primary keys the database declares."""
    where = ", ".join(_lit(str(s).upper()) for s in schemas)
    found: dict[str, list[str]] = {}
    try:
        rows = run("SELECT CONSTRAINT_SCHEMA, CONSTRAINT_TABLE, CONSTRAINT_NAME, COLUMN_NAME FROM SYS.EXA_ALL_CONSTRAINT_COLUMNS "
                   f"WHERE CONSTRAINT_TYPE = 'PRIMARY KEY' AND CONSTRAINT_SCHEMA IN ({where})")
    except Exception:
        return {}
    for row in rows:
        found.setdefault(f"{row['CONSTRAINT_SCHEMA']}.{row['CONSTRAINT_TABLE']}", []).append(str(row["COLUMN_NAME"]))
    return {f"{t}.{cols[0]}": "declared primary key" for t, cols in found.items() if len(cols) == 1}


def statistics(run: Run, table: str, cols: list[dict[str, Any]]) -> dict[str, Any]:
    """One aggregate over the table: its rows and, per key-able column, values present, approximate distinct count,
    min and max (an integer) or shortest and longest (a text)."""
    schema, name = table.split(".", 1)
    usable = [c for c in cols if c["kind"]]
    if not usable:
        return {"rows": 0, "columns": {}}
    parts = ["COUNT(*) AS N_"]
    for i, c in enumerate(usable):
        col = _q(c["name"])
        parts.append(f"COUNT({col}) AS P{i}")
        parts.append(f"APPROXIMATE_COUNT_DISTINCT({col}) AS D{i}")
        if c["kind"] == "int":
            parts += [f"MIN({col}) AS A{i}", f"MAX({col}) AS B{i}"]
        else:
            parts += [f"MIN(LENGTH({col})) AS A{i}", f"MAX(LENGTH({col})) AS B{i}"]
    row = run(f"SELECT {', '.join(parts)} FROM {_q(schema)}.{_q(name)}")[0]
    out: dict[str, Any] = {"rows": int(row.get("N_") or 0), "columns": {}}
    for i, c in enumerate(usable):
        out["columns"][c["name"]] = {"kind": c["kind"], "present": int(row.get(f"P{i}") or 0),
                                     "distinct": int(row.get(f"D{i}") or 0), "low": row.get(f"A{i}"), "high": row.get(f"B{i}")}
    return out


def _num(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def sample(run: Run, column: str) -> list[Any]:
    """Up to SAMPLE distinct non-empty values of SCHEMA.TABLE.COLUMN (one bounded statement)."""
    schema, table, name = column.split(".", 2)
    rows = run(f"SELECT DISTINCT {_q(name)} AS V FROM {_q(schema)}.{_q(table)} WHERE {_q(name)} IS NOT NULL LIMIT {SAMPLE}")
    return [r["V"] for r in rows if r.get("V") is not None and str(r["V"]).strip() != ""]


def contained(run: Run, key: str, values: list[Any], kind_: str) -> int:
    """How many of the values the key column holds (one COUNT with an IN list: a filter a source runs itself)."""
    schema, table, name = key.split(".", 2)
    if not values:
        return 0
    if kind_ == "int":
        listed = ", ".join(str(int(float(v))) for v in values)
    else:
        listed = ", ".join(_lit(v) for v in values)
    row = run(f"SELECT COUNT(DISTINCT {_q(name)}) AS F FROM {_q(schema)}.{_q(table)} WHERE {_q(name)} IN ({listed})")
    return int(row[0].get("F") or 0) if row else 0


def row_coverage(run: Run, column: str, key: str) -> dict[str, Any] | None:
    """How many rows of the column have a value the key holds, and the commonest values that do not: three bounded
    statements (the key's values, one count, one top-5). None when the key has too many values to list."""
    kschema, ktable, kname = key.split(".", 2)
    schema, table, name = column.split(".", 2)
    held = [r["V"] for r in run(f"SELECT DISTINCT {_q(kname)} AS V FROM {_q(kschema)}.{_q(ktable)} "
                                f"WHERE {_q(kname)} IS NOT NULL LIMIT {SMALL_KEY + 1}")]
    if not held or len(held) > SMALL_KEY:
        return None
    listed = ", ".join(_lit(v) for v in held)
    col, source = _q(name), f"{_q(schema)}.{_q(table)}"
    row = run(f"SELECT COUNT({col}) AS N, SUM(CASE WHEN {col} IN ({listed}) THEN 1 ELSE 0 END) AS M FROM {source}")[0]
    n, m = int(row.get("N") or 0), int(row.get("M") or 0)
    odd = run(f"SELECT {col} AS V, COUNT(*) AS N FROM {source} WHERE {col} IS NOT NULL AND {col} NOT IN ({listed}) "
              f"GROUP BY {col} ORDER BY 2 DESC LIMIT 5") if n > m else []
    return {"rows": n, "matched": m, "unmatched": n - m, "unmatched_values": [str(r["V"]) for r in odd]}


def unique_exactly(run: Run, key: str) -> bool:
    schema, table, name = key.split(".", 2)
    row = run(f"SELECT COUNT(*) AS N, COUNT({_q(name)}) AS P, COUNT(DISTINCT {_q(name)}) AS D "
              f"FROM {_q(schema)}.{_q(table)}")[0]
    n, p, d = int(row.get("N") or 0), int(row.get("P") or 0), int(row.get("D") or 0)
    return n > 0 and n == p == d


def find(run: Run, schemas: Iterable[str], *, approved_keys: dict[str, str] | None = None,
         roles: dict[str, str] | None = None,
         proposals: list[tuple[str, str]] | None = None, max_checks: int = MAX_CHECKS,
         progress: Callable[[str], None] | None = None) -> dict[str, Any]:
    """The links between tables of different schemas among ``schemas``, each with its evidence.

    ``approved_keys`` ({SCHEMA.TABLE.COLUMN: why}) are keys a person approved; ``roles`` ({SCHEMA.TABLE.COLUMN: role})
    the approved column maps' roles (a measure is never a pointer; a key or identifier may be one); ``proposals`` are (from, to) pairs an AI
    model suggested, checked the same way and kept only when the values agree. Returns {links, partial, checked,
    not_checked, keys, statements}: ``links`` many-to-one, at most one per column; ``partial`` text columns only partly
    contained in a key (a spelling or case difference to look at; never joined)."""
    say = progress or (lambda _line: None)
    sent = [0]

    def counted(sql: str) -> list[dict[str, Any]]:
        sent[0] += 1
        return run(sql)

    schemas = [str(s).upper() for s in schemas]
    tables, virtual = columns(counted, schemas)
    keys: dict[str, str] = dict(declared_keys(counted, schemas))
    keys.update({k.upper(): v for k, v in (approved_keys or {}).items()})
    stats: dict[str, dict[str, Any]] = {}
    for table, cols in tables.items():
        say(f"Reading the shape of {table}")
        stats[table] = statistics(counted, table, cols)
        rows = stats[table]["rows"]
        for name, c in stats[table]["columns"].items():
            full = f"{table}.{name}"
            if c["kind"] == "text" and (_num(c["high"]) or 0) > MAX_LENGTH:
                c["prose"] = True                            # measured, not declared: its longest value
                keys.pop(full, None)
                continue
            if full in keys:
                continue
            # every value present and the approximate distinct count within 10% of the rows (the estimate is off by
            # a few percent, by one or two on a small table): a key to confirm with an exact count before it is used
            if rows and c["present"] == rows and c["distinct"] >= 0.9 * rows and rows >= MIN_VALUES:
                keys[full] = "measured"

    roles = {k.upper(): v for k, v in (roles or {}).items()}
    proposed = {(a.upper(), b.upper()) for a, b in proposals or []}

    def fits(full: str, name: str, cand: dict[str, Any], key_full: str, kname: str, key: dict[str, Any]) -> bool:
        if cand["kind"] != key["kind"] or roles.get(full) in ("measure", "flag", "time", "text"):
            return False
        if cand["kind"] == "text":
            return True                                      # lengths differ with spelling and case: the values decide
        lo, hi, klo, khi = _num(cand["low"]), _num(cand["high"]), _num(key["low"]), _num(key["high"])
        if None in (lo, hi, klo, khi):
            return True
        if lo < klo or hi > khi:                             # a pointer's numbers sit inside the key's range
            return False
        if cand["kind"] == "int":
            # a run of numbers 1..N holds every small number: containment alone proves nothing for integers
            span = (hi - lo) / (khi - klo) if khi > klo else 0.0
            backed = (similarity(name, kname) >= MIN_ALIKE or roles.get(full) in ("key", "identifier")
                      or (full, key_full) in proposed)
            return span >= MIN_SPAN and backed
        return True

    pairs = []
    for table, st in stats.items():
        for name, c in st["columns"].items():
            full = f"{table}.{name}"
            if c["distinct"] < MIN_VALUES or c.get("prose"):
                continue
            for key, why in keys.items():
                ktable, _, kname = key.rpartition(".")
                if ktable.split(".")[0] == table.split(".")[0]:
                    continue                                 # the same schema: the schema map's job (schema.py)
                kst = stats.get(ktable, {}).get("columns", {}).get(kname)
                if kst is None or full == key or not fits(full, name, c, key, kname, kst):
                    continue
                pairs.append((similarity(name, kname), full, key, c["kind"]))
    for a, b in sorted(proposed):
        if any(p[1] == a and p[2] == b for p in pairs):
            pairs = [(1.5, *p[1:]) if (p[1], p[2]) == (a, b) else p for p in pairs]
            continue
        ka = stats.get(a.rpartition(".")[0], {}).get("columns", {}).get(a.rpartition(".")[2])
        kb = stats.get(b.rpartition(".")[0], {}).get("columns", {}).get(b.rpartition(".")[2])
        if ka and kb and ka["kind"] == kb["kind"]:
            keys.setdefault(b, "measured")
            pairs.append((1.5, a, b, ka["kind"]))             # an AI proposal: checked first, confirmed like any other
    pairs.sort(key=lambda p: (-p[0], p[1], p[2]))
    checked, not_checked = pairs[:max_checks], max(0, len(pairs) - max_checks)
    samples: dict[str, list[Any]] = {}
    found: list[dict[str, Any]] = []
    partial: list[dict[str, Any]] = []
    for score, col, key, kind_ in checked:
        if col not in samples:
            say(f"Sampling {col}")
            samples[col] = sample(counted, col)
        values = samples[col]
        if len(values) < MIN_VALUES:
            continue
        hits = contained(counted, key, values, kind_)
        share = hits / len(values)
        base = {"from": col, "to": key, "found": hits, "checked": len(values), "share": round(share, 4),
                "names_alike": round(min(score, 1.0), 2), "proposed_by": "ai" if score > 1 else "values",
                "from_live": col.split(".")[0] in virtual, "to_live": key.split(".")[0] in virtual,
                "key_evidence": keys[key]}
        if kind_ == "text" and share >= PARTIAL:
            # text is settled by rows where the key is small enough to list: misspellings are few rows, many values
            say(f"Counting the rows of {col} that match {key}")
            cover = row_coverage(counted, col, key)
            if cover and cover["rows"]:
                if cover["unmatched"] / cover["rows"] <= MAX_ORPHANS:
                    found.append({**base, "confidence": "high", "rows": cover})
                else:
                    partial.append({k: base[k] for k in ("from", "to", "found", "checked", "share")} | {"rows": cover})
            elif share >= MIN_SHARE:
                found.append({**base, "confidence": "high"})
            else:
                partial.append({k: base[k] for k in ("from", "to", "found", "checked", "share")} | {"rows": None})
        elif share >= MIN_SHARE:
            # numbers in a plain sequence match by chance: the data can refute such a link, never confirm it, so it
            # is "low" whoever proposed it, and only a person's confirmation puts it into a model
            found.append({**base, "confidence": "low"})
    # one link per column: the key that holds the most of its values (names break a tie)
    best: dict[str, dict[str, Any]] = {}
    for link in sorted(found, key=lambda l: (-(l["rows"]["matched"] / l["rows"]["rows"] if l.get("rows") else l["share"]),
                                             -l["names_alike"])):
        best.setdefault(link["from"], link)
    links = []
    for link in best.values():
        if link["key_evidence"] == "measured":
            say(f"Confirming {link['to']} is unique")
            if not unique_exactly(counted, link["to"]):
                continue
            link["key_evidence"] = "measured: every value present and different"
        links.append(link)
    links.sort(key=lambda l: (l["from"], l["to"]))
    partial.sort(key=lambda l: -l["share"])
    return {"links": links, "partial": partial, "checked": len(checked), "not_checked": not_checked,
            "keys": {k: v for k, v in keys.items()}, "statements": sent[0], "schemas": schemas,
            "virtual": sorted(virtual)}


def evidence_text(link: dict[str, Any]) -> str:
    """One line a person reads before approving a link."""
    live = " (read live from the source)" if link.get("from_live") or link.get("to_live") else ""
    by = "an AI proposal, checked against the data" if link.get("proposed_by") == "ai" else "found from the values"
    doubt = ("" if link.get("confidence") != "low" else
             " CONFIRM THIS ONE: both columns are plain numbers, and numbers in a sequence match by chance, so the "
             "data cannot prove this link - only that it does not contradict it.")
    if link.get("rows"):
        r = link["rows"]
        odd = f" (not matching: {', '.join(r['unmatched_values'])})" if r["unmatched_values"] else ""
        return (f"{link['from']} -> {link['to']}: {r['matched']:,} of {r['rows']:,} rows of {link['from']} have a value in "
                f"{link['to']}; {r['unmatched']:,} do not{odd}; {link['to']} is a key ({link['key_evidence']}); "
                f"found from the values{live}")
    return doubt.strip() + (" " if doubt else "") + (f"{link['from']} -> {link['to']}: {link['found']} of {link['checked']} sampled values of {link['from']} are in "
            f"{link['to']} ({link['share']:.0%}); {link['to']} is a key ({link['key_evidence']}); {by}{live}")


AI_INSTRUCTIONS = """You link tables of different data sources for a semantic model.
Below are tables with their columns (name and type) and, where approved, what each column means.
Propose pairs where a column of one table refers to the key of a table in ANOTHER schema, even when the names differ
(a customer number in one, a client id in the other). Answer with ONE JSON object and nothing else:
{"links": [{"from": "SCHEMA.TABLE.COLUMN", "to": "SCHEMA.TABLE.COLUMN", "why": "<short reason>"}]}
At most 20 pairs. Every pair will be checked against the data; a wrong one is simply dropped."""


def ai_facts(tables: dict[str, list[dict[str, Any]]], notes: dict[str, str] | None = None) -> dict[str, Any]:
    """What a model is shown: table and column names, types, and approved notes. Never a value."""
    return {t: [{"column": c["name"], "type": c["type"], **({"note": notes[f"{t}.{c['name']}"]}
                                                           if notes and f"{t}.{c['name']}" in notes else {})}
                for c in cols] for t, cols in tables.items()}


def ai_pairs(answer: dict[str, Any], tables: dict[str, list[dict[str, Any]]]) -> list[tuple[str, str]]:
    """The pairs of a model's answer that name real columns of different schemas."""
    real = {f"{t}.{c['name']}".upper() for t, cols in tables.items() for c in cols}
    found = []
    for item in (answer.get("links") or [])[:20] if isinstance(answer, dict) else []:
        if not isinstance(item, dict):
            continue
        a, b = str(item.get("from") or "").upper(), str(item.get("to") or "").upper()
        if a in real and b in real and a.split(".")[0] != b.split(".")[0]:
            found.append((a, b))
    return found
