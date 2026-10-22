"""The dataset descriptor's rules, with no IO (a copy of the 0.3.0 kit's exakit/domain/descriptor.py, kept standalone:
the 0.2.0 kit has no Python package of its own): which semantic role each real table and column plays.

A descriptor (``data/datasets/<id>/descriptor.yaml``, or one beside a user's own file) names the fact table and, for
each role, the one column that plays it: ``entity``, ``category``, ``date``, ``label``, and one or more ``text``
columns; ``source`` optionally names where the table lives (a virtual schema's alias for an external source). It is
YAML (a JSON descriptor still reads), parsed by the standard-library subset reader below: block and inline mappings
and lists, quoted and plain scalars, comments - what any YAML tool writes for a file this small. Anchors, tags and
multi-line strings are refused with the line they are on, never guessed at. Notebook code builds its SQL from the roles, so the same notebook runs on any dataset whose descriptor
validates. Nothing here guesses: a missing role is named, a column claimed by two roles is refused, a role given two
columns where it takes one is refused, and a role the schema does not know is refused rather than ignored.
"""

from __future__ import annotations

import json
import re
from collections.abc import Collection, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any



class BadInput(ValueError):
    """A descriptor that breaks the rules; the message names what is wrong."""

SCHEMA_VERSION = 1
SINGLE_ROLES = ("entity", "category", "date", "label")   # exactly one column each
MULTI_ROLES = ("text",)                                  # one or more columns
ROLES = SINGLE_ROLES + MULTI_ROLES
KEYS = ("schema_version", "id", "fact_table", "roles", "source")
DESCRIPTOR_FILES = ("descriptor.yaml", "descriptor.yml", "descriptor.json")   # what a dataset folder may hold, first wins
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
    """A validated descriptor: the fact table and each role's column (``text`` keeps its order); ``source`` names an
    external source's alias when the table is in a virtual schema, else None."""

    id: str
    fact_table: str
    roles: dict[str, tuple[ColumnRef, ...]]
    source: str | None = None

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
        return ["the descriptor must be a mapping of keys to values"]
    if doc.get("schema_version") != SCHEMA_VERSION:
        return [f"schema_version must be {SCHEMA_VERSION}"]
    if not isinstance(doc.get("id"), str) or not _ID.match(doc["id"]):
        problems.append("id must be the dataset id (lower-case letters and digits, joined by - or _)")
    if qualified_table(doc.get("fact_table")) is None:
        problems.append("fact_table must be SCHEMA.TABLE (plain SQL names)")
    unknown = sorted(set(doc) - set(KEYS))
    if unknown:
        problems.append(f"unknown keys: {', '.join(unknown)}")
    if doc.get("source") is not None and (not isinstance(doc["source"], str) or not _IDENT.match(doc["source"])):
        problems.append("source must be one plain name: the external source's alias")
    roles = _roles(doc, problems)
    return problems + _duplicates(roles)


def _no_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    seen: dict[str, Any] = {}
    for key, value in pairs:
        if key in seen:
            raise BadInput(f"The descriptor names '{key}' twice in one object; say it once, so nothing is guessed.")
        seen[key] = value
    return seen


# --- the YAML subset ---------------------------------------------------------------------------------------------

_REFUSED = ("&", "*", "!", "|", ">", "%", "@", "`")


class _YamlError(ValueError):
    """A line the subset reader does not accept; the message names it."""


def _strip_comment(line: str) -> str:
    """The line without a # comment (a # inside quotes, or not after a space, is text)."""
    quote = ""
    for n, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = ""
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and (n == 0 or line[n - 1] in " \t"):
            return line[:n].rstrip()
    return line.rstrip()


def _scalar(text: str, where: str) -> Any:
    """A plain or quoted scalar: null, true/false, an integer, or a string."""
    text = text.strip()
    if not text:
        return None
    if text[0] in "'\"":
        if len(text) < 2 or text[-1] != text[0]:
            raise _YamlError(f"{where}: an unclosed quote")
        body = text[1:-1]
        return body.replace("''", "'") if text[0] == "'" else json.loads(f'"{body}"')
    if text[0] in _REFUSED:
        raise _YamlError(f"{where}: '{text[0]}' (anchors, aliases, tags, multi-line text) is not read here; "
                         "write the value out in plain or quoted form")
    if text in ("null", "~", "Null", "NULL"):
        return None
    if text in ("true", "True", "TRUE"):
        return True
    if text in ("false", "False", "FALSE"):
        return False
    if re.fullmatch(r"[-+]?[0-9]+", text):
        return int(text)
    return text


def _flow(text: str, where: str) -> Any:
    """An inline value: {a: b, ...}, [a, b, ...] or a scalar."""
    value, rest = _flow_value(text.strip(), where)
    if rest.strip():
        raise _YamlError(f"{where}: unexpected text after the value: {rest.strip()!r}")
    return value


def _flow_value(text: str, where: str) -> tuple[Any, str]:
    if text.startswith("{"):
        out: dict[str, Any] = {}
        rest = text[1:].lstrip()
        while not rest.startswith("}"):
            if not rest:
                raise _YamlError(f"{where}: an unclosed {{")
            key, rest = _flow_token(rest, where, ":")
            if not rest.startswith(":"):
                raise _YamlError(f"{where}: a key in {{...}} needs ': value'")
            value, rest = _flow_value(rest[1:].lstrip(), where)
            if key in out:
                raise BadInput(f"The descriptor names '{key}' twice in one object; say it once, so nothing is guessed.")
            out[str(key)] = value
            rest = rest.lstrip()
            if rest.startswith(","):
                rest = rest[1:].lstrip()
        return out, rest[1:]
    if text.startswith("["):
        items: list[Any] = []
        rest = text[1:].lstrip()
        while not rest.startswith("]"):
            if not rest:
                raise _YamlError(f"{where}: an unclosed [")
            value, rest = _flow_value(rest, where)
            items.append(value)
            rest = rest.lstrip()
            if rest.startswith(","):
                rest = rest[1:].lstrip()
        return items, rest[1:]
    return _flow_token(text, where, ",}]")


def _flow_token(text: str, where: str, stops: str) -> tuple[Any, str]:
    """One scalar inside a flow collection, up to the first unquoted stop character."""
    text = text.lstrip()
    quote = text[:1]
    if quote in ("'", '"'):
        end = 1
        while end < len(text):
            if text[end] == quote:
                if quote == "'" and text[end + 1:end + 2] == "'":
                    end += 2
                    continue
                break
            end += 2 if quote == '"' and text[end] == "\\" else 1
        if end >= len(text):
            raise _YamlError(f"{where}: an unclosed quote")
        return _scalar(text[:end + 1], where), text[end + 1:]
    end = 0
    while end < len(text) and text[end] not in stops:
        end += 1
    return _scalar(text[:end], where), text[end:]


def _lines(text: str) -> list[tuple[int, int, str]]:
    """(line number, indent, content) of every line that holds something."""
    out = []
    for number, raw in enumerate(text.splitlines(), 1):
        if "\t" in raw[:len(raw) - len(raw.lstrip())]:
            raise _YamlError(f"line {number}: indent with spaces, not tabs")
        line = _strip_comment(raw)
        if not line.strip() or line.strip() in ("---", "..."):
            continue
        out.append((number, len(line) - len(line.lstrip()), line.strip()))
    return out


def _block(lines: list[tuple[int, int, str]], at: int, indent: int) -> tuple[Any, int]:
    """The block that starts at lines[at], all of whose lines are indented exactly ``indent``."""
    number, _, content = lines[at]
    if content == "-" or content.startswith("- "):
        items: list[Any] = []
        while at < len(lines) and lines[at][1] == indent and (lines[at][2] == "-" or lines[at][2].startswith("- ")):
            number, _, content = lines[at]
            rest = content[1:].strip()
            if not rest:
                if at + 1 < len(lines) and lines[at + 1][1] > indent:
                    value, at = _block(lines, at + 1, lines[at + 1][1])
                else:
                    value, at = None, at + 1
            elif rest[0] not in "{['\"" and re.match(r"[^:]+:( |$)", rest):
                lines[at] = (number, indent + 2, rest)       # "- key: value" starts a mapping one level in
                value, at = _block(lines, at, indent + 2)
            else:
                value, at = _flow(rest, f"line {number}"), at + 1
            items.append(value)
        return items, at
    mapping: dict[str, Any] = {}
    while at < len(lines) and lines[at][1] == indent:
        number, _, content = lines[at]
        match = re.match(r"^(\"[^\"]*\"|'[^']*'|[^:\s][^:]*?)\s*:(\s+(.*))?$", content)
        if not match or content.startswith("- "):
            raise _YamlError(f"line {number}: expected 'key: value'")
        key = str(_scalar(match.group(1), f"line {number}"))
        if key in mapping:
            raise BadInput(f"The descriptor names '{key}' twice in one object; say it once, so nothing is guessed.")
        rest = (match.group(3) or "").strip()
        if rest:
            mapping[key], at = _flow(rest, f"line {number}"), at + 1
        elif at + 1 < len(lines) and lines[at + 1][1] > indent:
            mapping[key], at = _block(lines, at + 1, lines[at + 1][1])
        elif at + 1 < len(lines) and lines[at + 1][1] == indent and lines[at + 1][2].startswith("- "):
            mapping[key], at = _block(lines, at + 1, indent)  # a list may sit at its key's own indent
        else:
            mapping[key], at = None, at + 1
    if at < len(lines) and lines[at][1] > indent:
        raise _YamlError(f"line {lines[at][0]}: indented further than the lines before it")
    return mapping, at


def load_yaml(text: str) -> Any:
    """The document in ``text`` (the YAML subset above); _YamlError names the first line it cannot read."""
    lines = _lines(text)
    if not lines:
        return None
    value, at = _block(lines, 0, lines[0][1])
    if at < len(lines):
        raise _YamlError(f"line {lines[at][0]}: less indented than the document's first line")
    return value


def parse_descriptor(text: str, source: str = "the descriptor") -> Descriptor:
    """The descriptor in ``text`` (YAML, or JSON when it starts with {), validated; anything else raises BadInput
    naming every problem found."""
    try:
        if text.lstrip().startswith("{"):
            doc = json.loads(text, object_pairs_hook=_no_duplicate_keys)
        else:
            doc = load_yaml(text)
    except ValueError as err:
        if isinstance(err, BadInput):
            raise
        raise BadInput(f"{source} cannot be read ({err}).") from err
    problems = validate_descriptor(doc)
    if problems:
        raise BadInput(f"{source} is not a valid dataset descriptor: {'; '.join(problems)}.")
    roles = _roles(doc, [])
    return Descriptor(id=doc["id"], fact_table=str(qualified_table(doc["fact_table"])), roles=roles,
                      source=doc.get("source"))


def descriptor_file(folder: Path) -> Path | None:
    """The descriptor a dataset folder holds (descriptor.yaml first), or None."""
    return next((folder / name for name in DESCRIPTOR_FILES if (folder / name).is_file()), None)


def read_descriptor(path: Path) -> Descriptor:
    """The validated descriptor in a file - or in a dataset folder's descriptor file."""
    path = Path(path).expanduser()
    if path.is_dir():
        found = descriptor_file(path)
        if found is None:
            raise BadInput(f"{path} holds no {DESCRIPTOR_FILES[0]}.")
        path = found
    return parse_descriptor(path.read_text(encoding="utf-8-sig"), str(path))


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
