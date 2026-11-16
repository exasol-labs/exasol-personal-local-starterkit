"""The rules the kit drafts a column map and finds links with, as values a person can read and change.

    role_rules()                    {"CATEGORY_DISTINCT": 50, "MEASURE_HINTS": [...], ...}: what a draft uses now
    link_rules()                    {"MIN_SHARE": 0.9, "SAMPLE": 500, ...}: what a search for links uses now
    with using({"CATEGORY_DISTINCT": 100}, {"MIN_SHARE": 0.8}):
        ...                         a draft or a search inside runs with those; the defaults come back after

A rule not named keeps its default. A name that is not a rule, or a value of the wrong kind, is refused by name.
Nothing is stored: the notebook's cell holds the rules, and passes them each time.
"""

from __future__ import annotations

import contextlib
import threading
from typing import Any, Iterator

from . import draft, links, profile, roles

ROLE_RULES = ("CATEGORY_DISTINCT", "CATEGORY_RATIO", "IDENTIFIER_RATIO", "LABEL_RATIO", "TEXT_AVG_LENGTH",
              "TEXT_DISTINCT_RATIO", "TEXT_WORDS_SHARE", "TEXT_WORDS_LENGTH", "TEXT_NAMED_LENGTH", "DATE_SHARE",
              "NUMBER_SHARE", "CODE_SHARE", "SENSITIVE_SHARE", "NEAR", "NAME_HINTS", "KEY_SUFFIXES", "MEASURE_HINTS",
              "MEASURE_SUFFIXES", "TIME_HINTS", "TEXT_HINTS", "POSTAL_HINTS", "PERSON_HINTS", "ADDRESS_HINTS")
PROFILE_RULES = ("VIRTUAL_ROWS", "TOP_VALUES", "VALUES_DISTINCT", "EXACT_WITHIN")
LINK_RULES = ("SAMPLE", "MIN_VALUES", "MIN_SHARE", "MAX_CHECKS", "MIN_SPAN", "MIN_ALIKE", "PARTIAL", "MAX_ORPHANS",
              "MAX_LENGTH", "SMALL_KEY")
_LOCK = threading.RLock()


def _shown(value: Any) -> Any:
    return sorted(value) if isinstance(value, frozenset) else list(value) if isinstance(value, tuple) else value


def role_rules() -> dict[str, Any]:
    """The rules a column map is drafted with: thresholds (counts, shares), the name hints (words in a column's name
    that suggest a role), and how a table is read for it (VIRTUAL_ROWS: the rows read of a source read live;
    TOP_VALUES, VALUES_DISTINCT: the values listed per column; EXACT_WITHIN: when a near-unique count is made exact)."""
    return {**{name: _shown(getattr(roles, name)) for name in ROLE_RULES},
            **{name: getattr(profile, name) for name in PROFILE_RULES}}


def link_rules() -> dict[str, Any]:
    """The rules links between tables are found with: how many values are read, and how many must match."""
    return {name: _shown(getattr(links, name)) for name in LINK_RULES}


def _value(name: str, now: Any, given: Any) -> Any:
    if isinstance(now, frozenset):
        if not isinstance(given, (list, tuple, set, frozenset)):
            raise ValueError(f"{name} is a list of words, not {given!r}")
        return frozenset(str(w).lower() for w in given)
    if isinstance(now, tuple):
        if not isinstance(given, (list, tuple)):
            raise ValueError(f"{name} is a list of words, not {given!r}")
        return tuple(str(w).lower() for w in given)
    if isinstance(given, bool) or not isinstance(given, (int, float)):
        raise ValueError(f"{name} is a number, not {given!r}")
    return int(given) if isinstance(now, int) and float(given).is_integer() else float(given)


def _changes(module, allowed: tuple[str, ...], given: dict[str, Any] | None, what: str) -> dict[str, Any]:
    found = {}
    for name, value in (given or {}).items():
        if name not in allowed:
            every = allowed + (PROFILE_RULES if what == "column map" and allowed == ROLE_RULES else ())
            raise ValueError(f"{name} is not a {what} rule: the rules are {', '.join(every)}")
        found[name] = _value(name, getattr(module, name), value)
    return found


@contextlib.contextmanager
def using(for_roles: dict[str, Any] | None = None, for_links: dict[str, Any] | None = None) -> Iterator[None]:
    """Run what is inside with these rules, then put the defaults back (one draft or search at a time)."""
    for_profile = {k: v for k, v in (for_roles or {}).items() if k in PROFILE_RULES}
    for_roles = {k: v for k, v in (for_roles or {}).items() if k not in PROFILE_RULES}
    role_values = _changes(roles, ROLE_RULES, for_roles, "column map")
    profile_values = _changes(profile, PROFILE_RULES, for_profile, "column map")
    link_values = _changes(links, LINK_RULES, for_links, "link")
    targets = [(roles, role_values), (profile, profile_values), (links, link_values)]
    if "TEXT_HINTS" in role_values:
        targets.append((draft, {"TEXT_HINTS": role_values["TEXT_HINTS"]}))
    with _LOCK:
        saved = [(module, {name: getattr(module, name) for name in values}) for module, values in targets]
        try:
            for module, values in targets:
                for name, value in values.items():
                    setattr(module, name, value)
            yield
        finally:
            for module, values in saved:
                for name, value in values.items():
                    setattr(module, name, value)
