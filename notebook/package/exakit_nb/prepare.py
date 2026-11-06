"""Prepare, the part that changes something: a typed, cleaned view of a table, proposed from the data and created only
when the user says so.

A file loaded as text (every column VARCHAR, as CSVs often are), blank cells, placeholder values and rows copied twice
all make a result quietly wrong. typed_view() reads the table - not just its names - and proposes one view over it:

    - a text column whose every value parses as a number becomes DECIMAL (DOUBLE with an exponent), as a date (in one
      of the formats below) DATE, as a timestamp TIMESTAMP, as true/false BOOLEAN; an identifier, and a number written
      with a leading zero, and a column named like a code (postal code, phone, SKU, ..._ID), stay text;
    - text is trimmed and a blank cell becomes NULL;
    - the placeholders the data checks find ("Unknown Device", "N/A", ...) become NULL;
    - rows that are exact copies of another in every column but the key are dropped (the first, by the key, is kept).

Nothing is written until ``create()``: the proposal shows each change with the evidence for it and the exact SQL. Then
the view goes into the EXAKIT_PREPARED schema, and it gets its own approved descriptor - the same roles as the table it
came from, a column that became a date filling an empty time slot - so every later step reads the prepared data.

    prepared = nb.typed_view(conn, ds)     # the proposal: what changes, why, and the CREATE VIEW
    ds = prepared.create(conn)             # the view, described and approved; the dataset from here on
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from html import escape
from typing import Any

SCHEMA = "EXAKIT_PREPARED"
DATE_FORMATS = ("YYYY-MM-DD", "DD-MM-YYYY", "DD.MM.YYYY", "MM/DD/YYYY", "DD/MM/YYYY")
TIMESTAMP_FORMATS = ("YYYY-MM-DD HH24:MI:SS", "YYYY-MM-DD HH24:MI")
MAX_PRECISION = 36
# A column named like a code stays text even when its values are digits: a postal code, a phone number, an SKU is a
# name, not a quantity (and arithmetic on it is a mistake waiting to happen).
CODE_NAME = re.compile(r"(^|_)(ID|IDS|CODE|CODES|ZIP|POSTAL|POSTCODE|PIN|PHONE|MOBILE|SKU|ASIN|EAN|UPC|ISBN|IBAN)(_|$)|"
                       r"(ZIP|POSTCODE|PHONE)", re.IGNORECASE)


def _q(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _literal(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def _split(table: str) -> tuple[str, str]:
    schema, name = table.split(".", 1)
    return schema.strip('"'), name.strip('"')


@dataclass
class Change:
    column: str
    before: str
    after: str
    why: str


@dataclass
class TypedView:
    """The proposal. ``changes`` and ``cleaning`` say what the view does differently from the table, ``sql`` is the
    CREATE VIEW that ``create()`` runs - nothing has run before that."""
    dataset: Any
    view: str
    sql: str
    changes: list[Change] = field(default_factory=list)
    cleaning: list[str] = field(default_factory=list)
    created: Any = None

    @property
    def needed(self) -> bool:
        """Whether the view would differ from the table at all."""
        return bool(self.changes or self.cleaning)

    def _state(self) -> str:
        if self.created is not None:
            return f"Created {self.view} and approved its column map: the steps below read it."
        if not self.needed:
            return f"{self.dataset.fact_table} needs no typed view: every column already has its type, and nothing to clean."
        return "Not created yet: nothing has run. To use it, set USE_PREPARED = True in the first cell (or call create)."

    def __str__(self) -> str:
        lines = [f"Typed view of {self.dataset.fact_table} -> {self.view}"]
        if self.changes:
            lines.append("Types:")
            lines += [f"  - {c.column}: {c.before} -> {c.after} ({c.why})" for c in self.changes]
        if self.cleaning:
            lines.append("Cleaning:")
            lines += [f"  - {line}" for line in self.cleaning]
        lines.append(self._state())
        if self.needed:
            lines += ["", self.sql]
        return "\n".join(lines)

    def _repr_html_(self) -> str:
        html = [f"<p><b>Typed view of</b> <code>{escape(self.dataset.fact_table)}</code> &rarr; <code>{escape(self.view)}</code></p>"]
        if self.changes:
            rows = "".join(f"<tr><td><code>{escape(c.column)}</code></td><td>{escape(c.before)}</td><td>{escape(c.after)}</td>"
                           f"<td>{escape(c.why)}</td></tr>" for c in self.changes)
            html.append("<table><tr><th>Column</th><th>Now</th><th>In the view</th><th>Why</th></tr>" + rows + "</table>")
        if self.cleaning:
            html.append("<ul>" + "".join(f"<li>{escape(line)}</li>" for line in self.cleaning) + "</ul>")
        html.append(f"<p>{escape(self._state())}</p>")
        if self.needed:
            html.append(f"<pre style=\"white-space: pre-wrap\">{escape(self.sql)}</pre>")
        return "\n".join(html)

    def create(self, conn) -> Any:
        """Create the view (after the user has read it), describe it, carry the table's roles over and approve them;
        returns the view's dataset, which the later steps then use. With nothing to change, the dataset as it was."""
        if not self.needed:
            print(self._state())
            return self.dataset
        from . import describe as describe_table
        from .dataset import remember_dataset
        from .workflow import log_sql

        for statement in (f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}", self.sql):
            conn.execute(statement)
            log_sql(conn, statement, None)
        schema, name = _split(self.view)
        source = self.dataset
        draft = describe_table(f"{schema}.{name}", conn=conn, id=_prepared_id(source.id), force=True)
        columns = dict(getattr(source.descriptor, "columns", {}) or {})
        changed = {c.column: c.after for c in self.changes}
        roles = {}
        for column, entry in columns.items():
            role = entry.get("role")
            if changed.get(column, "").startswith(("DATE", "TIMESTAMP")):
                role = "time"                                     # a date found inside a text column
            if role:
                roles[column] = role
        if roles:
            draft.set(**roles)
        slots = dict(getattr(source.descriptor, "slots", {}) or {})
        if not slots.get("time"):
            found = next((c.column for c in self.changes if c.after.startswith(("DATE", "TIMESTAMP"))), None)
            if found:
                slots["time"] = found
        draft.slot(**{slot: None for slot in slots})               # empty first, so a column can move between slots
        draft.slot(**{slot: (column[0] if isinstance(column, list) else column)
                      for slot, column in slots.items() if column})
        self.created = draft.approve(conn=conn)
        remember_dataset(self.created)
        print(self._state())
        return self.created


def _prepared_id(dataset_id: str) -> str:
    return dataset_id if dataset_id.endswith("_prepared") else f"{dataset_id}_prepared"


def _detect(conn, table: str, text_columns: list[str]):
    """One query: for every text column, how many values are not blank and how many parse as each type."""
    from . import sql

    parts = []
    for i, column in enumerate(text_columns):
        value = f"NULLIF(TRIM({_q(column)}), '')"
        parts += [f"COUNT({value}) AS N{i}",
                  f"COUNT(CASE WHEN IS_NUMBER({value}) THEN 1 END) AS NUM{i}",
                  f"COUNT(CASE WHEN {value} REGEXP_LIKE '.*[eE].*' THEN 1 END) AS EXP{i}",
                  f"COUNT(CASE WHEN {value} REGEXP_LIKE '[+-]?0[0-9]+([.].*)?' THEN 1 END) AS LZ{i}",
                  f"MAX(LENGTH(REGEXP_REPLACE(REGEXP_REPLACE({value}, '[.].*$', ''), '[^0-9]', ''))) AS INT{i}",
                  f"MAX(CASE WHEN INSTR({value}, '.') > 0 THEN LENGTH({value}) - INSTR({value}, '.') ELSE 0 END) AS SC{i}",
                  f"COUNT(CASE WHEN IS_BOOLEAN({value}) THEN 1 END) AS B{i}"]
        parts += [f"COUNT(CASE WHEN IS_DATE({value}, {_literal(f)}) THEN 1 END) AS D{i}_{k}" for k, f in enumerate(DATE_FORMATS)]
        parts += [f"COUNT(CASE WHEN IS_TIMESTAMP({value}, {_literal(f)}) THEN 1 END) AS T{i}_{k}"
                  for k, f in enumerate(TIMESTAMP_FORMATS)]
    return sql(conn, f"SELECT {', '.join(parts)} FROM {table}")


def typed_view(conn, ds) -> TypedView:
    """The proposal for ``ds``'s table: its types, its cleaning and the CREATE VIEW, built from the data and the
    descriptor. Only SELECTs run; nothing is created until ``create()``."""
    from . import sql
    from .data_checks import placeholders

    schema, name = _split(ds.fact_table)
    types = sql(conn, f"SELECT COLUMN_NAME AS NAME_, COLUMN_TYPE AS TYPE_ FROM SYS.EXA_ALL_COLUMNS "
                      f"WHERE COLUMN_SCHEMA = {_literal(schema)} AND COLUMN_TABLE = {_literal(name)} "
                      f"ORDER BY COLUMN_ORDINAL_POSITION")
    columns = list(zip(types["NAME_"], types["TYPE_"]))
    entries = dict(getattr(ds.descriptor, "columns", {}) or {})
    text = [c for c, t in columns if str(t).upper().startswith(("VARCHAR", "CHAR"))]
    found = _detect(conn, ds.fact_table, text).iloc[0] if text else {}
    unknown = placeholders(conn, ds)

    changes: list[Change] = []
    select: list[str] = []
    for column, kind in columns:
        quoted = _q(column)
        if column not in text:
            select.append(quoted)
            continue
        i = text.index(column)
        n = int(found[f"N{i}"] or 0)
        value = f"NULLIF(TRIM({quoted}), '')"
        if column in unknown:
            listed = ", ".join(_literal(v) for v, _ in unknown[column])
            value = f"CASE WHEN TRIM({quoted}) IN ({listed}) THEN NULL ELSE {value} END"
        target = None
        role = (entries.get(column) or {}).get("role")
        if (n and int(found[f"NUM{i}"]) == n and role not in ("identifier", "key") and not int(found[f"LZ{i}"])
                and not CODE_NAME.search(column)):
            if int(found[f"EXP{i}"]):
                target, why, expression = "DOUBLE", f"all {n:,} values are numbers, some with an exponent", f"CAST({value} AS DOUBLE)"
            else:
                scale = int(found[f"SC{i}"] or 0)
                precision = max(1, int(found[f"INT{i}"] or 0)) + scale
                if precision > MAX_PRECISION:
                    target, expression = "DOUBLE", f"CAST({value} AS DOUBLE)"
                else:
                    target, expression = f"DECIMAL({precision},{scale})", f"CAST({value} AS DECIMAL({precision},{scale}))"
                why = f"all {n:,} values are numbers"
        if target is None and n:
            fmt = next((f for k, f in enumerate(DATE_FORMATS) if int(found[f"D{i}_{k}"]) == n), None)
            if fmt:
                target, why, expression = "DATE", f"all {n:,} values are dates written {fmt}", f"TO_DATE({value}, {_literal(fmt)})"
        if target is None and n:
            fmt = next((f for k, f in enumerate(TIMESTAMP_FORMATS) if int(found[f"T{i}_{k}"]) == n), None)
            if fmt:
                target, why, expression = ("TIMESTAMP", f"all {n:,} values are timestamps written {fmt}",
                                           f"TO_TIMESTAMP({value}, {_literal(fmt)})")
        if target is None and n and int(found[f"B{i}"]) == n:
            target, why, expression = "BOOLEAN", f"all {n:,} values are true/false", f"CAST({value} AS BOOLEAN)"
        if target is None:
            expression = value
        else:
            changes.append(Change(column, str(kind), target, why))
        select.append(f"{expression} AS {quoted}")

    cleaning: list[str] = []
    for column, hits in unknown.items():
        cleaning.append(f"{column}: " + ", ".join(f"'{v}' ({n:,} rows)" for v, n in hits) + " becomes NULL")
    if text:
        cleaning.append(f"text in {len(text)} column(s) is trimmed, and a blank cell becomes NULL")
    key = (getattr(ds.descriptor, "slots", {}) or {}).get("key")
    others = [c for c, _ in columns if c != key]
    # Copies are judged on the CLEANED values: two rows that differ only by a placeholder and a blank are one row
    # once both are NULL, so the counting and the dropping both run over the view's own expressions.
    cleaned = f"(SELECT {', '.join(select)}\n      FROM {ds.fact_table})"
    body = f"SELECT {', '.join(select)}\nFROM {ds.fact_table}"
    copies = 0
    worth_distinct = False
    same = others if key else [c for c, _ in columns]
    if same:
        total = sql(conn, f"SELECT COUNT(*) AS N FROM {ds.fact_table}")
        distinct = sql(conn, f"SELECT COUNT(*) AS N FROM (SELECT DISTINCT {', '.join(_q(c) for c in same)} FROM {cleaned})")
        copies = int(total["N"][0]) - int(distinct["N"][0])
    if copies and not key:
        # No key: a row equal to another in every column is a plain copy.
        cleaning.append(f"{copies:,} rows that copy another row in every column are dropped (one of each is kept)")
        body = f"SELECT DISTINCT *\nFROM {cleaned}"
        copies, worth_distinct = 0, True
    if copies:
        cleaning.append(f"{copies:,} rows that copy another row in every column but {key} are dropped (the first by {key} is kept)")
        partition = ", ".join(_q(c) for c in others)
        body = (f"SELECT {', '.join(_q(c) for c, _ in columns)}\nFROM (\n    SELECT C_.*,\n"
                f"           ROW_NUMBER() OVER (PARTITION BY {partition} ORDER BY {_q(key)}) AS COPY_\n"
                f"    FROM {cleaned} C_)\nWHERE COPY_ = 1")
    view = f"{SCHEMA}.{_q(f'{schema}__{name}')}"
    # Only the type changes and the real cleaning make a view worth having; trimming alone does not.
    worth = bool(changes or unknown or copies or worth_distinct)
    if not worth:
        cleaning = []
    statement = (f"CREATE OR REPLACE VIEW {view} AS\n{body}\n"
                 f"COMMENT IS {_literal(f'The typed, cleaned view of {ds.fact_table} the starter kit proposed and the user created')}")
    return TypedView(ds, view, statement, changes, cleaning)
