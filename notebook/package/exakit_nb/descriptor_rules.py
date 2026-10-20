"""The dataset descriptor's rules, with no IO (a copy of the 0.3.0 kit's exakit/domain/descriptor.py, kept standalone:
the 0.2.0 kit has no Python package of its own): which semantic role each real table and column plays.

A descriptor (``data/datasets/<id>/descriptor.json``, or one beside a user's own file) names the fact table and, for
each role, the one column that plays it: ``entity``, ``category``, ``date``, ``label``, and one or more ``text``
columns. Notebook code builds its SQL from the roles, so the same notebook runs on any dataset whose descriptor
validates. Nothing here guesses: a missing role is named, a column claimed by two roles is refused, a role given two
columns where it takes one is refused, and a role the schema does not know is refused rather than ignored.
"""

from __future__ import annotations

import json
import re
from collections.abc import Collection, Iterator
from dataclasses import dataclass
from typing import Any



class BadInput(ValueError):
    """A descriptor that breaks the rules; the message names what is wrong."""

SCHEMA_VERSION = 1
SINGLE_ROLES = ("entity", "category", "date", "label")   # exactly one column each
MULTI_ROLES = ("text",)                                  # one or more columns
ROLES = SINGLE_ROLES + MULTI_ROLES
KEYS = ("schema_version", "id", "fact_table", "roles")
_IDENT = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")
_ID = re.compile(r"^[a-z0-9]+([-_][a-z0-9]+)*$")        # a dataset id: its folder name (pharma_trials, sample-claims)

Problems = list[str]


@dataclass(frozen=True, slots=True)
class ColumnRef:
    """One real column, upper-cased: ``SCHEMA.TABLE`` and ``COLUMN``."""

    table: str
    column: str

    @property
    def qualified(self) -> str:
        """``SCHEMA.TABLE.COLUMN``."""
        return f"{self.table}.{self.column}"

    @property
    def schema(self) -> str:
        """The schema part of the table."""
        return self.table.split(".", 1)[0]


@dataclass(frozen=True, slots=True)
class Descriptor:
    """A validated descriptor: the fact table and each role's column (``text`` keeps its order)."""

    id: str
    fact_table: str
    roles: dict[str, tuple[ColumnRef, ...]]

    def column(self, role: str) -> ColumnRef:
        """The one column of a single-column role."""
        return self.roles[role][0]

    def references(self) -> Iterator[tuple[str, ColumnRef]]:
        """(role, column) for every column the descriptor names, roles in schema order."""
        for role in ROLES:
            for ref in self.roles.get(role, ()):
                yield role, ref

    def schemas(self) -> list[str]:
        """Every schema the descriptor touches, sorted, each once."""
        return sorted({self.fact_table.split(".", 1)[0]} | {ref.schema for _role, ref in self.references()})


def qualified_table(value: Any) -> str | None:
    """``SCHEMA.TABLE`` upper-cased when ``value`` is two plain SQL names joined by a dot, else None."""
    parts = value.split(".") if isinstance(value, str) else []
    if len(parts) != 2 or not all(_IDENT.match(p) for p in parts):
        return None
    return ".".join(p.upper() for p in parts)


def _ref(value: Any, where: str, problems: Problems) -> ColumnRef | None:
    if not isinstance(value, dict):
        problems.append(f"{where} must be an object with 'table' and 'column'")
        return None
    table = qualified_table(value.get("table"))
    column = value.get("column")
    if table is None:
        problems.append(f"{where}.table must be SCHEMA.TABLE (plain SQL names)")
    if not isinstance(column, str) or not _IDENT.match(column):
        problems.append(f"{where}.column must be one plain SQL column name")
        return None
    unknown = sorted(set(value) - {"table", "column"})
    if unknown:
        problems.append(f"{where} has unknown keys: {', '.join(unknown)}")
    return ColumnRef(table, column.upper()) if table else None


def _single(role: str, value: Any, problems: Problems) -> tuple[ColumnRef, ...]:
    if isinstance(value, list):
        problems.append(f"role '{role}' names {len(value)} columns; it takes exactly one, so it is ambiguous")
        return ()
    ref = _ref(value, f"roles.{role}", problems)
    return (ref,) if ref else ()


def _multi(role: str, value: Any, problems: Problems) -> tuple[ColumnRef, ...]:
    items = value if isinstance(value, list) else [value]
    if not items:
        problems.append(f"role '{role}' names no column; it needs at least one")
    refs = [_ref(item, f"roles.{role}[{n}]", problems) for n, item in enumerate(items)]
    return tuple(r for r in refs if r)


def _roles(doc: dict[str, Any], problems: Problems) -> dict[str, tuple[ColumnRef, ...]]:
    roles = doc.get("roles")
    if not isinstance(roles, dict):
        problems.append("roles must be an object mapping each role to its column")
        return {}
    unknown = sorted(set(roles) - set(ROLES))
    if unknown:
        problems.append(f"unknown roles: {', '.join(unknown)} (the roles are {', '.join(ROLES)})")
    out: dict[str, tuple[ColumnRef, ...]] = {}
    for role in ROLES:
        if role not in roles or roles[role] is None:
            problems.append(f"the '{role}' role is missing")
            continue
        out[role] = (_single if role in SINGLE_ROLES else _multi)(role, roles[role], problems)
    return out


def _duplicates(roles: dict[str, tuple[ColumnRef, ...]]) -> Problems:
    """A column may play one role once; claimed twice, the descriptor is ambiguous and is refused, never resolved."""
    claims: dict[ColumnRef, list[str]] = {}
    for role in ROLES:
        for ref in roles.get(role, ()):
            claims.setdefault(ref, []).append(role)
    return [f"column {ref.qualified} is assigned to more than one role ({', '.join(names)})"
            for ref, names in claims.items() if len(names) > 1]


def validate_descriptor(doc: Any) -> Problems:
    """Every problem of a parsed descriptor, each naming the key or role it is about; an empty list is valid."""
    problems: Problems = []
    if not isinstance(doc, dict):
        return ["the descriptor must be a JSON object"]
    if doc.get("schema_version") != SCHEMA_VERSION:
        return [f"schema_version must be {SCHEMA_VERSION}"]
    if not isinstance(doc.get("id"), str) or not _ID.match(doc["id"]):
        problems.append("id must be the dataset id (lower-case letters and digits, joined by - or _)")
    if qualified_table(doc.get("fact_table")) is None:
        problems.append("fact_table must be SCHEMA.TABLE (plain SQL names)")
    unknown = sorted(set(doc) - set(KEYS))
    if unknown:
        problems.append(f"unknown keys: {', '.join(unknown)}")
    roles = _roles(doc, problems)
    return problems + _duplicates(roles)


def _no_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    seen: dict[str, Any] = {}
    for key, value in pairs:
        if key in seen:
            raise BadInput(f"The descriptor names '{key}' twice in one object; say it once, so nothing is guessed.")
        seen[key] = value
    return seen


def parse_descriptor(text: str, source: str = "the descriptor") -> Descriptor:
    """The descriptor in ``text``, validated; anything else raises BadInput naming every problem found."""
    try:
        doc = json.loads(text, object_pairs_hook=_no_duplicate_keys)
    except ValueError as err:
        raise BadInput(f"{source} is not valid JSON ({err}).") from err
    problems = validate_descriptor(doc)
    if problems:
        raise BadInput(f"{source} is not a valid dataset descriptor: {'; '.join(problems)}.")
    roles = _roles(doc, [])
    return Descriptor(id=doc["id"], fact_table=str(qualified_table(doc["fact_table"])), roles=roles)


def missing_references(descriptor: Descriptor, columns: Collection[str]) -> Problems:
    """What the database lacks, given every ``SCHEMA.TABLE.COLUMN`` it holds (upper-case): a missing table is named
    as a table, a missing column in a table that exists as a column; an empty list means every role resolves."""
    tables = {name.rsplit(".", 1)[0] for name in columns}
    problems: Problems = []
    if descriptor.fact_table not in tables:
        problems.append(f"fact_table {descriptor.fact_table} does not exist")
    for role, ref in descriptor.references():
        if ref.table not in tables:
            problems.append(f"role '{role}' points to table {ref.table}, which does not exist")
        elif ref.qualified not in columns:
            problems.append(f"role '{role}' points to column {ref.qualified}, which does not exist")
    return problems


def data_file_problem(name: str, size: int, formats: Collection[str]) -> str | None:
    """Why a user's data file cannot be described, or None: its type must be one of ``formats`` (by extension, never
    sniffed) and it must hold data."""
    suffix = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    if suffix not in {f.lower() for f in formats}:
        return f"{name} is not a supported data file (the types are: {', '.join(sorted(formats))})"
    if size <= 0:
        return f"{name} is empty"
    return None
