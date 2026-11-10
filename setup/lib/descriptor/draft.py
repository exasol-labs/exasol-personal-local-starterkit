"""Step 3 of the descriptor plan: a profile in, a draft descriptor out, no database (draft(), to_yaml()).

Every column gets a role from roles.classify(); the slots name the columns the notebooks need. The key slot takes
a key column, one with an identifier name first, then the leftmost; with none it stays empty and says "no single
unique column" (composite keys are not hunted). Time takes the time column with the fewest nulls, the leftmost of a
tie: tables put the row's own event date first, and follow-up dates have gaps - a range says nothing about which date
is the event (a follow-up date sent months later spans wider; reviewed 3 Nov against the plan's "widest range"). Text
takes the text column with the longest average length. Target is never drafted: it stays empty until the user sets it, and
training skips with that reason (a guessed target trains on the wrong label and nobody notices).

Two more slots carry what the notebooks group by. Category: a non-sensitive string category with 2 to
CATEGORY_GROUPS values - the grouping to compare - one named as a grouping first (CATEGORY, SEGMENT, ..._TYPE), one
named as an outcome last (STATUS is often the label itself), then the leftmost. Entity: a non-sensitive string column
(a category, or a column no rule fits) shorter than text with more than CATEGORY_GROUPS values but at most one per two
rows - who or where a row comes from - one named so first (CUSTOMER, STORE, CITY), then the most values. Text: one
named as text first, then the longest. Either stays empty, with its reason, when no column fits.

No timestamps, a fixed key order and the columns in table order, so the same profile gives the same bytes.
"""

from __future__ import annotations

import json
from typing import Any

from .roles import TEXT_HINTS, classify, has_name_hint, name_tokens

GROUP_HINTS = frozenset({"category", "type", "segment", "group", "class", "kind", "department", "dept", "tier", "grade",
                         "channel", "method", "mode", "tariff", "brand", "family", "priority", "plan", "line", "division"})
OUTCOME_HINTS = frozenset({"status", "state", "result", "outcome"})
ENTITY_HINTS = frozenset({"customer", "client", "user", "account", "member", "store", "shop", "branch", "site", "city",
                          "state", "region", "country", "location", "merchant", "vendor", "supplier", "device", "clerk",
                          "agent", "team", "product"})
ENTITY_SHARE = 0.5                    # an entity has at most one value per two rows: else it is no grouping


def _hint(name: str, words: frozenset[str]) -> bool:
    return any(token in words for token in name_tokens(name))

FORMAT = 1
SLOTS = ("key", "time", "text", "target", "category", "entity")
CATEGORY_GROUPS = 20
NO_KEY = "no single unique column"
NO_TARGET = "set by the user; never drafted"


def _nulls(entry: dict[str, Any]) -> int:
    return int(entry.get("rows") or 0) - int(entry.get("non_null") or 0)


def _slots(columns: list[dict[str, Any]], roles: dict[str, dict[str, Any]]) -> tuple[dict[str, str | None], dict[str, str]]:
    def having(role: str) -> list[dict[str, Any]]:
        return [c for c in columns if roles[c["column"]]["role"] == role]

    keys = having("key")
    key = (sorted(keys, key=lambda c: not has_name_hint(c["column"]))[0]["column"] if keys else None)
    times = having("time")
    time = min(times, key=_nulls)["column"] if times else None           # min() keeps the leftmost of a tie
    texts = having("text")
    # A column named as text first (P_COMMENT over P_NAME), then the longest.
    text = (max(texts, key=lambda c: (_hint(c["column"], TEXT_HINTS), float(c.get("avg_length") or 0)))["column"]
            if texts else None)
    groups = [c for c in columns if _grouping(c, roles) and roles[c["column"]]["role"] == "category"
              and 2 <= _distinct(c) <= CATEGORY_GROUPS]
    category = min(groups, key=_group_rank)["column"] if groups else None    # min() keeps the leftmost of a tie
    entity = _entity(columns, roles)
    slots = {"key": key, "time": time, "text": text, "target": None, "category": category, "entity": entity}
    why = {"target": NO_TARGET}
    if category is None:
        why["category"] = f"no string category with 2 to {CATEGORY_GROUPS} values"
    if entity is None:
        why["entity"] = f"no short string column with more than {CATEGORY_GROUPS} values"
    if key is None:
        why["key"] = NO_KEY
    if time is None:
        why["time"] = "no time column"
    if text is None:
        why["text"] = "no text column"
    return slots, {slot: why[slot] for slot in SLOTS if slot in why}


def _distinct(column: dict[str, Any]) -> int:
    exact = column.get("exact_distinct")
    return int(exact if exact is not None else column.get("approx_distinct") or 0)


def _grouping(column: dict[str, Any], roles: dict[str, dict[str, Any]]) -> bool:
    """A string column the notebooks may group by: not sensitive, a category or a column no rule fits."""
    found = roles[column["column"]]
    return column.get("kind") == "string" and not found.get("sensitive") and found["role"] in ("category", "other")


def _group_rank(column: dict[str, Any]) -> int:
    """0 for a name that says a grouping (CATEGORY, SEGMENT, ..._TYPE), 2 for one that says an outcome (STATUS: it is
    often the label itself, as Amazon's STATUS gives CANCELLED away), 1 otherwise."""
    tokens = name_tokens(column["column"])
    if any(t in GROUP_HINTS or t.endswith(tuple(GROUP_HINTS)) for t in tokens):
        return 0
    return 2 if any(t in OUTCOME_HINTS or t.endswith(tuple(OUTCOME_HINTS)) for t in tokens) else 1


def _entity(columns: list[dict[str, Any]], roles: dict[str, dict[str, Any]]) -> str | None:
    """A column whose name says who or where (CUSTOMER, STORE, CITY, STATE) first, then the most values; a column
    with a value for nearly every row is no grouping and is left out."""
    from .roles import TEXT_AVG_LENGTH
    fits = [c for c in columns if _grouping(c, roles) and float(c.get("avg_length") or 0) < TEXT_AVG_LENGTH
            and CATEGORY_GROUPS < _distinct(c) <= ENTITY_SHARE * int(c.get("non_null") or 0)]
    return (max(fits, key=lambda c: (_hint(c["column"], ENTITY_HINTS), _distinct(c)))["column"]   # max(): leftmost of a tie
            if fits else None)


def draft(profile: dict[str, Any], dataset: str, version: int = 1) -> dict[str, Any]:
    """The draft descriptor for a profile, as a dict in the order it is written."""
    columns = profile["columns"]
    roles = {c["column"]: classify(c) for c in columns}
    slots, why = _slots(columns, roles)
    source = {k: profile["source"][k] for k in ("kind", "object", "schema_digest", "profiled_rows")}
    if profile["source"].get("prefix"):
        source["profiled"] = profile["source"]["prefix"]
    doc: dict[str, Any] = {"descriptor": FORMAT, "dataset": dataset, "source": source, "version": version,
                           "status": "draft", "grain": f"one row per {slots['key']}" if slots["key"] else ""}
    doc["slots"] = slots
    doc["slot_evidence"] = why
    doc["columns"] = {name: roles[name] for name in (c["column"] for c in columns)}
    return doc


def approved(doc: dict[str, Any], owner: str, approved_at: str, version: int | None = None) -> dict[str, Any]:
    """The same descriptor approved: status approved, owner and approved_at after it, in the order it is written."""
    out: dict[str, Any] = {}
    for key, value in doc.items():
        if key in ("owner", "approved_at"):
            continue
        out[key] = version if key == "version" and version is not None else value
        if key == "status":
            out["status"] = "approved"
            out["owner"], out["approved_at"] = owner, approved_at
    return out


def with_slots(doc: dict[str, Any], **slots: str | None) -> dict[str, Any]:
    """The descriptor with these slots set (a column name) or emptied (None); an empty slot keeps a reason."""
    out = dict(doc)
    out["slots"] = {**doc["slots"], **slots}
    why = {k: v for k, v in (doc.get("slot_evidence") or {}).items() if out["slots"].get(k) is None}
    for name, column in slots.items():
        if column is None and name not in why:
            why[name] = "left empty by the owner"
    out["slot_evidence"] = {k: why[k] for k in SLOTS if k in why}
    return out


def _scalar(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def _flow(entry: dict[str, Any]) -> str:
    return "{" + ", ".join(f"{key}: {_scalar(value)}" for key, value in entry.items()) + "}"


def to_yaml(doc: dict[str, Any]) -> str:
    """The descriptor as YAML: plain keys, every string quoted, a column per line as a flow mapping."""
    lines = []
    for key, value in doc.items():
        if key == "columns":
            lines.append("columns:")
            lines += [f"  {_scalar(name)}: {_flow(entry)}" for name, entry in value.items()]
        elif isinstance(value, dict):
            lines.append(f"{key}:" if value else f"{key}: {{}}")
            lines += [f"  {sub}: {_scalar(item)}" for sub, item in value.items()]
        else:
            lines.append(f"{key}: {_scalar(value)}")
    return "\n".join(lines) + "\n"
