"""The dataset descriptor's rules, with no IO (a copy of the 0.3.0 kit's exakit/domain/descriptor.py, kept standalone:
the 0.2.0 kit has no Python package of its own): which semantic role each real table and column plays.

A descriptor (``data/datasets/<id>/descriptor.yaml``, or one beside a user's own file) names the fact table and, for
each role, the one column that plays it: ``entity``, ``category``, ``date``, ``label``, and one or more ``text``
columns; ``source`` optionally says what the data is (``<dataset id>``, ``file:<path>`` or ``vs:<alias>`` of an
external source's virtual schema). It is YAML (a JSON descriptor still reads), parsed by the standard-library subset
reader below: block and inline mappings and lists, quoted and plain scalars, comments - what any YAML tool writes for
a file this small. Anchors, tags and multi-line strings are refused with the line they are on, never guessed at.
Notebook code builds its SQL from the roles, so the same notebook runs on any dataset whose descriptor validates.
Nothing here guesses: a missing role is named, a column claimed by two roles is refused, a role given two columns
where it takes one is refused, and a role the schema does not know is refused rather than ignored.

Two schema versions read. ``schema_version: 2`` carries the descriptor's record: ``version`` (an integer from 1;
approving writes the next), ``status`` (draft or approved), ``owner``, ``created`` (ISO-8601) and, optionally, the
table ``digest`` (null until computed), ``drafted_by`` (profile, shipped or user), the profiler's ``evidence`` per
role, model-written ``notes`` per column and the roles no column fits, ``missing`` (each with its reason; such a role
may then be absent from ``roles``). A ``schema_version: 1`` file is the 0.2 kit's shape, read as version 1, approved,
owned by the kit, drafted by what shipped it, with no digest and no creation time - nothing it does not say is guessed
beyond that.

A file starting ``descriptor: 1`` is the role-per-column descriptor (setup/lib/descriptor): every column of the source
table has one of eight roles, with its confidence and evidence, and ``slots`` name the columns the notebooks need -
key, time, text, target, and the category and entity they group by. It reads as a Descriptor with schema_version 3:
the time slot is the ``date`` role, the target the ``label``, the text slot the ``text``, category and entity as they
are, and an empty slot is a missing role with the reason ``slot_evidence`` gives. ``columns``, ``slots`` and
``grain`` are kept on the Descriptor for the code that reads the new shape.
"""

from __future__ import annotations

import json
import re
from collections.abc import Collection, Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any



class BadInput(ValueError):
    """A descriptor that breaks the rules; the message names what is wrong."""

SCHEMA_VERSION = 2                                       # what is written today
SCHEMA_VERSIONS = (1, 2)                                 # what is read
SINGLE_ROLES = ("entity", "category", "date", "label")   # exactly one column each
MULTI_ROLES = ("text",)                                  # one or more columns
ROLES = SINGLE_ROLES + MULTI_ROLES
KEYS = ("schema_version", "id", "fact_table", "roles", "source")                      # schema_version 1
RECORD_KEYS = ("version", "status", "owner", "created")                               # schema_version 2, required
OPTIONAL_KEYS = ("digest", "drafted_by", "evidence", "notes", "missing")              # schema_version 2, optional
KEYS_V2 = KEYS + RECORD_KEYS + OPTIONAL_KEYS
STATUSES = ("draft", "approved")
DRAFTERS = ("profile", "shipped", "user")
V1_RECORD = {"version": 1, "status": "approved", "owner": "kit", "created": None, "digest": None, "drafted_by": "shipped"}
DESCRIPTOR_FILES = ("descriptor.yaml", "descriptor.yml", "descriptor.json")   # what a dataset folder may hold, first wins
_IDENT = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")
_ID = re.compile(r"^[a-z0-9]+([-_][a-z0-9]+)*$")        # a dataset id: its folder name (amazon_sales, sample-claims)
_LIVE = "vs:"                                           # a v2 source that is a virtual schema's alias (a live source)

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
    """A validated descriptor: the fact table and each role's column (``text`` keeps its order); ``source`` says what
    the data is as the file wrote it (a dataset id, ``file:<path>``, ``vs:<alias>``; a schema_version 1 file's bare
    alias) or None; and the descriptor's record - ``version``, ``status``, ``owner``, ``created``, the table
    ``digest``, ``drafted_by``, the profiler's ``evidence``, model ``notes`` and the roles ``missing`` with their
    reasons (a schema_version 1 file reads as V1_RECORD, with no evidence, notes or missing roles)."""

    id: str
    fact_table: str
    roles: dict[str, tuple[ColumnRef, ...]]
    source: str | None = None
    schema_version: int = 1
    version: int = 1
    status: str = "approved"
    owner: str = "kit"
    created: str | None = None
    digest: str | None = None
    drafted_by: str = "shipped"
    evidence: dict[str, dict[str, Any]] = field(default_factory=dict)
    notes: dict[str, str] = field(default_factory=dict)
    missing: tuple[dict[str, str], ...] = ()
    columns: dict[str, dict[str, Any]] = field(default_factory=dict)
    slots: dict[str, str | None] = field(default_factory=dict)
    grain: str | None = None

    @property
    def sensitive(self) -> tuple[str, ...]:
        """The columns a role-per-column descriptor marks sensitive: never charted, never sent to a model."""
        return tuple(name for name, entry in self.columns.items() if entry.get("sensitive"))

    @property
    def approved(self) -> bool:
        """Whether the descriptor's status is approved (a draft is what the profiler proposed, not yet confirmed)."""
        return self.status == "approved"

    @property
    def live_source(self) -> str | None:
        """The external source's alias when the fact table is in a virtual schema (a live source): a schema_version 2
        ``vs:<alias>`` source, or a schema_version 1 file's bare ``source``; None for loaded data (a dataset id or a
        file)."""
        if not self.source:
            return None
        if self.schema_version == 1:
            return self.source
        return self.source[len(_LIVE):] if self.source.startswith(_LIVE) else None

    def missing_reason(self, role: str) -> str | None:
        """Why no column plays ``role`` (its line in ``missing``), or None when the role is assigned."""
        return next((str(m["reason"]) for m in self.missing if m.get("role") == role), None)

    def column(self, role: str) -> ColumnRef:
        """The one column of a single-column role; a role listed as missing raises BadInput with its reason."""
        if role not in self.roles:
            reason = self.missing_reason(role)
            raise BadInput(f"The descriptor '{self.id}' has no '{role}' role" + (f": {reason}" if reason else "") + ".")
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
    declared_missing = {m["role"] for m in _missing(doc, [])}
    out: dict[str, tuple[ColumnRef, ...]] = {}
    for role in ROLES:
        if role not in roles or roles[role] is None:
            if role not in declared_missing:                 # a role listed under 'missing' is absent with its reason
                problems.append(f"the '{role}' role is missing")
            continue
        if role in declared_missing:
            problems.append(f"the '{role}' role is both assigned and listed under missing")
        out[role] = (_single if role in SINGLE_ROLES else _multi)(role, roles[role], problems)
    return out


def _missing(doc: dict[str, Any], problems: Problems) -> list[dict[str, str]]:
    """The roles no column fits, each ``{role, reason}``; problems name what is not of that shape."""
    value = doc.get("missing")
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        problems.append("missing must be a list of {role, reason}")
        return []
    out = []
    for n, item in enumerate(value):
        role, reason = item.get("role"), item.get("reason")
        if role not in ROLES or not isinstance(reason, str) or not reason.strip() or set(item) != {"role", "reason"}:
            problems.append(f"missing[{n}] must be {{role: one of {', '.join(ROLES)}, reason: why no column fits}}")
            continue
        out.append({"role": role, "reason": reason})
    return out


def _record_problems(doc: dict[str, Any]) -> Problems:
    """The schema_version 2 record keys, each problem naming its key."""
    problems: Problems = []
    if not isinstance(doc.get("version"), int) or isinstance(doc.get("version"), bool) or doc["version"] < 1:
        problems.append("version must be an integer from 1 (approving writes the next)")
    if doc.get("status") not in STATUSES:
        problems.append(f"status must be {' or '.join(STATUSES)}")
    if not isinstance(doc.get("owner"), str) or not doc["owner"].strip():
        problems.append("owner must be a non-empty string (who approved or drafted the descriptor)")
    if not isinstance(doc.get("created"), str) or _timestamp(doc["created"]) is None:
        problems.append("created must be an ISO-8601 timestamp, e.g. 2026-10-27T10:12:03Z")
    if "digest" in doc and doc["digest"] is not None and (not isinstance(doc["digest"], str) or not doc["digest"].strip()):
        problems.append("digest must be the table's digest string, or null")
    if "drafted_by" in doc and doc["drafted_by"] not in DRAFTERS:
        problems.append(f"drafted_by must be {', '.join(DRAFTERS[:-1])} or {DRAFTERS[-1]}")
    if "evidence" in doc and doc["evidence"] is not None and (not isinstance(doc["evidence"], dict)
                                                           or not all(isinstance(k, str) and isinstance(v, dict)
                                                                      for k, v in doc["evidence"].items())):
        problems.append("evidence must be a mapping of role to a mapping (the numbers that chose its column)")
    if "notes" in doc and doc["notes"] is not None and (not isinstance(doc["notes"], dict)
                                                     or not all(isinstance(k, str) and isinstance(v, str)
                                                                for k, v in doc["notes"].items())):
        problems.append("notes must be a mapping of column to one line of text")
    return problems


def _timestamp(text: str) -> str | None:
    """``text`` when it is an ISO-8601 date or timestamp (a trailing Z read as UTC), else None."""
    from datetime import datetime
    try:
        datetime.fromisoformat(text.strip().replace("Z", "+00:00") if text.strip().endswith("Z") else text.strip())
    except (ValueError, TypeError):
        return None
    return text.strip()


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
    if doc.get("schema_version") not in SCHEMA_VERSIONS or isinstance(doc.get("schema_version"), bool):
        return [f"schema_version must be {' or '.join(str(v) for v in SCHEMA_VERSIONS)}"]
    v2 = doc["schema_version"] == 2
    if not isinstance(doc.get("id"), str) or not _ID.match(doc["id"]):
        problems.append("id must be the dataset id (lower-case letters and digits, joined by - or _)")
    if qualified_table(doc.get("fact_table")) is None:
        problems.append("fact_table must be SCHEMA.TABLE (plain SQL names)")
    unknown = sorted(set(doc) - set(KEYS_V2 if v2 else KEYS))
    if unknown:
        problems.append(f"unknown keys: {', '.join(unknown)}" + ("" if v2 else " (the record keys need schema_version: 2)"))
    source = doc.get("source")
    if v2:
        if source is not None and (not isinstance(source, str) or not source.strip()):
            problems.append("source must be a dataset id, file:<path> or vs:<alias>")
        problems += _record_problems(doc)
        _missing(doc, problems)
    elif source is not None and (not isinstance(source, str) or not _IDENT.match(source)):
        problems.append("source must be one plain name: the external source's alias")
    roles = _roles(doc, problems)
    return problems + _duplicates(roles)


def _record(doc: dict[str, Any]) -> dict[str, Any]:
    """The descriptor's record from a validated document: what a schema_version 2 file says, V1_RECORD for 1."""
    if doc["schema_version"] == 1:
        return dict(V1_RECORD, evidence={}, notes={}, missing=())
    record = {key: doc.get(key, V1_RECORD.get(key)) for key in RECORD_KEYS + ("digest",)}
    record["drafted_by"] = doc.get("drafted_by") or "user"
    record["evidence"] = dict(doc.get("evidence") or {})
    record["notes"] = dict(doc.get("notes") or {})
    record["missing"] = tuple(_missing(doc, []))
    return record


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
    """A plain or quoted scalar: null, true/false, an integer, a decimal number, or a string."""
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
    if re.fullmatch(r"[-+]?[0-9]+\.[0-9]+([eE][-+]?[0-9]+)?", text):
        return float(text)                   # the profiler's evidence: null_rate: 0.02, score: 0.83
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
    if isinstance(doc, dict) and "descriptor" in doc:
        return column_descriptor(doc, source)
    problems = validate_descriptor(doc)
    if problems:
        raise BadInput(f"{source} is not a valid dataset descriptor: {'; '.join(problems)}.")
    roles = _roles(doc, [])
    return Descriptor(id=doc["id"], fact_table=str(qualified_table(doc["fact_table"])), roles=roles,
                      source=doc.get("source"), schema_version=doc["schema_version"], **_record(doc))


# --- the role-per-column descriptor (descriptor: 1) -------------------------------------------------------------

COLUMN_FORMAT = 1
COLUMN_ROLES = ("key", "time", "measure", "category", "flag", "text", "identifier", "other")
SLOT_NAMES = ("key", "time", "text", "target", "category", "entity")
REQUIRED_SLOTS = ("key", "time", "text", "target")
SLOT_ROLES = {"key": ("key",), "time": ("time",), "text": ("text",)}   # the role a slot's column must have
LEGACY_ROLE = {"entity": "entity", "category": "category", "time": "date", "target": "label", "text": "text"}
SOURCE_KINDS = ("local", "file", "virtual")
COLUMN_TOP_KEYS = ("descriptor", "dataset", "source", "version", "status", "owner", "approved_at", "grain", "slots",
                   "slot_evidence", "columns")
SOURCE_KEYS = ("kind", "object", "schema_digest", "profiled_rows", "profiled", "snapshot_of", "snapshot_at")
COLUMN_KEYS = ("role", "confidence", "evidence", "sensitive", "note")


def _column_entry_problems(name: str, entry: Any) -> Problems:
    if not isinstance(entry, dict):
        return [f"columns.{name} must be {{role, confidence, evidence}}"]
    problems = [f"columns.{name}: unknown keys {', '.join(sorted(set(entry) - set(COLUMN_KEYS)))}"] if set(entry) - set(COLUMN_KEYS) else []
    if entry.get("role") not in COLUMN_ROLES:
        problems.append(f"columns.{name}.role must be one of {', '.join(COLUMN_ROLES)}")
    if entry.get("confidence") not in ("high", "low"):
        problems.append(f"columns.{name}.confidence must be high or low")
    if not isinstance(entry.get("evidence"), str):
        problems.append(f"columns.{name}.evidence must be the numbers that chose the role, as text")
    if "sensitive" in entry and not isinstance(entry["sensitive"], bool):
        problems.append(f"columns.{name}.sensitive must be true or false")
    if "note" in entry and not isinstance(entry["note"], str):
        problems.append(f"columns.{name}.note must be one line of text")
    return problems


def _slot_problems(slots: Any, columns: dict[str, Any]) -> Problems:
    if not isinstance(slots, dict):
        return ["slots must map key, time, text and target to a column or null"]
    problems = [f"slots: unknown slots {', '.join(sorted(set(slots) - set(SLOT_NAMES)))}"] if set(slots) - set(SLOT_NAMES) else []
    problems += [f"slots.{name} is missing (null leaves it empty on purpose)" for name in REQUIRED_SLOTS if name not in slots]
    taken: dict[str, str] = {}
    for name, column in slots.items():
        if column is None:
            continue
        if not isinstance(column, str) or column not in columns:
            problems.append(f"slots.{name} names {column!r}, which is not one of the columns")
            continue
        if column in taken:
            problems.append(f"column {column} sits in two slots ({taken[column]}, {name})")
        taken[column] = name
        entry = columns[column] if isinstance(columns[column], dict) else {}
        if name in SLOT_ROLES and entry.get("role") not in SLOT_ROLES[name]:
            problems.append(f"slots.{name} needs a column with role {SLOT_ROLES[name][0]}; {column} is {entry.get('role')}")
        if entry.get("sensitive") and name in ("target", "category", "entity", "text"):
            problems.append(f"slots.{name}: {column} is sensitive, so it is never grouped, charted or sent to a model")
        if name in LEGACY_ROLE and not _IDENT.match(column):
            problems.append(f"slots.{name}: {column} is not a plain SQL name; give it one through a view")
    return problems


def validate_column_descriptor(doc: Any) -> Problems:
    """Every problem of a role-per-column descriptor (descriptor: 1), each naming its key; empty when valid."""
    if not isinstance(doc, dict) or doc.get("descriptor") != COLUMN_FORMAT or isinstance(doc.get("descriptor"), bool):
        return [f"descriptor must be {COLUMN_FORMAT}"]
    problems = [f"unknown keys: {', '.join(sorted(set(doc) - set(COLUMN_TOP_KEYS)))}"] if set(doc) - set(COLUMN_TOP_KEYS) else []
    if not isinstance(doc.get("dataset"), str) or not _ID.match(doc["dataset"]):
        problems.append("dataset must be the dataset id (lower-case letters and digits, joined by - or _)")
    source = doc.get("source")
    if not isinstance(source, dict):
        problems.append("source must be {kind, object, schema_digest, profiled_rows}")
        source = {}
    problems += [f"source: unknown keys {', '.join(sorted(set(source) - set(SOURCE_KEYS)))}"] if set(source) - set(SOURCE_KEYS) else []
    if source.get("kind") not in SOURCE_KINDS:
        problems.append(f"source.kind must be {', '.join(SOURCE_KINDS)}")
    if qualified_table(source.get("object")) is None:
        problems.append("source.object must be SCHEMA.TABLE (plain SQL names)")
    if source.get("schema_digest") is not None and not str(source["schema_digest"]).startswith("sha256:"):
        problems.append("source.schema_digest must be sha256:<hex>, or null")
    if not isinstance(doc.get("version"), int) or isinstance(doc.get("version"), bool) or doc["version"] < 1:
        problems.append("version must be an integer from 1 (approving writes the next)")
    if doc.get("status") not in STATUSES:
        problems.append(f"status must be {' or '.join(STATUSES)}")
    if doc.get("status") == "approved":
        if not isinstance(doc.get("owner"), str) or not doc["owner"].strip():
            problems.append("owner must name who approved it")
        if not isinstance(doc.get("approved_at"), str) or _timestamp(doc["approved_at"]) is None:
            problems.append("approved_at must be an ISO-8601 timestamp")
    if "grain" in doc and doc["grain"] is not None and not isinstance(doc["grain"], str):
        problems.append("grain must be one line, e.g. one row per order line")
    columns = doc.get("columns")
    if not isinstance(columns, dict) or not columns:
        return problems + ["columns must give every column of the table its role"]
    for name, entry in columns.items():
        problems += _column_entry_problems(str(name), entry)
    evidence = doc.get("slot_evidence")
    if evidence is not None and (not isinstance(evidence, dict) or not all(isinstance(v, str) for v in evidence.values())):
        problems.append("slot_evidence must map a slot to why it is empty")
    return problems + _slot_problems(doc.get("slots"), columns)


def column_descriptor(doc: dict[str, Any], source: str = "the descriptor") -> Descriptor:
    """A role-per-column descriptor as the Descriptor every consumer reads (schema_version 3); BadInput names every
    problem of an invalid one."""
    problems = validate_column_descriptor(doc)
    if problems:
        raise BadInput(f"{source} is not a valid dataset descriptor: {'; '.join(problems)}.")
    table = str(qualified_table(doc["source"]["object"]))
    slots = {name: doc["slots"].get(name) for name in SLOT_NAMES}
    why = dict(doc.get("slot_evidence") or {})
    roles: dict[str, tuple[ColumnRef, ...]] = {}
    missing = []
    for slot, role in LEGACY_ROLE.items():
        if slots.get(slot):
            roles[role] = (ColumnRef(table, slots[slot].upper()),)
        else:
            missing.append({"role": role, "reason": why.get(slot) or f"no {slot} column is set"})
    kind = doc["source"]["kind"]
    status = doc["status"]
    owner = str(doc.get("owner") or "kit")
    return Descriptor(
        id=doc["dataset"], fact_table=table, roles=roles,
        source=f"vs:{table.split('.', 1)[0]}" if kind == "virtual" else (f"file:{table}" if kind == "file" else doc["dataset"]),
        schema_version=3, version=doc["version"], status=status, owner=owner, created=doc.get("approved_at"),
        digest=doc["source"].get("schema_digest"),
        drafted_by="profile" if status == "draft" else ("shipped" if owner == "kit" else "user"),
        evidence={role: {"column": slots[slot], **{k: v for k, v in doc["columns"][slots[slot]].items() if k != "role"}}
                  for slot, role in LEGACY_ROLE.items() if slots.get(slot)},
        notes={name: entry["note"] for name, entry in doc["columns"].items() if entry.get("note")},
        missing=tuple(missing), columns={str(k): dict(v) for k, v in doc["columns"].items()}, slots=slots,
        grain=doc.get("grain"))


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
