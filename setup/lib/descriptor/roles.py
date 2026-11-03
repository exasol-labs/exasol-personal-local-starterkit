"""Step 1 of the descriptor plan: one role per column from its profile, with no database.

Eight roles and no more: key, time, measure, category, flag, text, identifier, other. A ninth needs a review first.
Sensitivity is decided before the role and kept whatever the role is: a string column is sensitive when 90% or more
of its non-null values match the email, phone, IBAN or 5-digit postcode pattern. Then the rules below, first match
wins (classify()):

    all values null                                       -> other
    DATE or TIMESTAMP, or >= 98% match one date pattern   -> time
    string, avg length >= 40, distinct/rows >= 0.5        -> text
    integer or string, no nulls, exact distinct = rows    -> key
    sensitive                                             -> identifier
    BOOLEAN, or exactly 2 distinct non-null values        -> flag      (the exact top values, not the estimate)
    <= 50 distinct, or string with distinct/rows <= 0.02  -> category
    string, distinct/rows >= 0.9                          -> identifier
    DOUBLE, or DECIMAL with scale > 0                     -> measure
    integer                                               -> measure, or identifier by name (id, code, no, nr, key)
    anything else                                         -> other

Confidence is high or low. Low when the deciding number was within 10% of its threshold, or an integer had no name
hint. For a share with a ceiling of 100% (the 98% date match, the 90% sensitive match, the 0.9 and 0.5 distinct
ratios) "within 10%" is 10% of the room between the threshold and the ceiling; for a count or a length it is 10% of
the threshold itself.

A column's profile is the dict profile.py writes per column: column, type, kind, rows, non_null, approx_distinct,
exact_distinct (when measured), avg_length, patterns (match counts) and top (exact [value, count] pairs).
"""

from __future__ import annotations

import re
from typing import Any

ROLES = ("key", "time", "measure", "category", "flag", "text", "identifier", "other")

SENSITIVE_SHARE = 0.90        # of non-null values matching email, phone, IBAN or postcode
DATE_SHARE = 0.98             # of non-null values matching one date pattern
TEXT_AVG_LENGTH = 40          # characters
TEXT_DISTINCT_RATIO = 0.5     # distinct / rows
CATEGORY_DISTINCT = 50        # distinct values
CATEGORY_RATIO = 0.02         # distinct / rows, strings
IDENTIFIER_RATIO = 0.9        # distinct / rows, strings
NEAR = 0.10                   # "within 10% of its threshold": low confidence

SENSITIVE_PATTERNS = ("email", "phone", "iban", "postcode")
DATE_PATTERNS = ("iso", "dotted", "slash")
NAME_HINTS = frozenset({"id", "code", "no", "nr", "key"})

_CAMEL = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+")


def name_tokens(name: str) -> list[str]:
    """The whole words of a column name, split on underscores and camelCase, lower case: CustomerNo -> customer, no."""
    return [token.lower() for part in re.split(r"[_\W]+", name) for token in _CAMEL.findall(part)]


def has_name_hint(name: str) -> bool:
    """True when a whole token of the name says identifier: CUSTOMER_NO yes, PAID_AMOUNT no."""
    return any(token in NAME_HINTS for token in name_tokens(name))


def _near(value: float, threshold: float, ceiling: float | None = None) -> bool:
    room = abs(ceiling - threshold) if ceiling is not None else abs(threshold)
    return abs(value - threshold) <= NEAR * room


def _count(number: int) -> str:
    return f"{number:,}"


def _percent(share: float) -> str:
    text = f"{share * 100:.1f}"
    return (text[:-2] if text.endswith(".0") else text) + "%"


def _distinct(column: dict[str, Any]) -> int:
    exact = column.get("exact_distinct")
    return int(exact if exact is not None else column.get("approx_distinct") or 0)


def _share(column: dict[str, Any], pattern: str) -> float:
    non_null = int(column.get("non_null") or 0)
    return (column.get("patterns") or {}).get(pattern, 0) / non_null if non_null else 0.0


def sensitivity(column: dict[str, Any]) -> tuple[str, float] | None:
    """(pattern, share) when a string column is sensitive, else None."""
    if column.get("kind") != "string" or not column.get("non_null"):
        return None
    pattern, share = max(((p, _share(column, p)) for p in SENSITIVE_PATTERNS), key=lambda item: item[1])
    return (pattern, share) if share >= SENSITIVE_SHARE else None


def _date_pattern(column: dict[str, Any]) -> tuple[str, float, str | None] | None:
    """(pattern, share, slash order) when >= 98% of a string column's values match one date pattern. A slash date
    is DD/MM when some first part is over 12, MM/DD when some second part is; both at once is not one date format."""
    if column.get("kind") != "string" or not column.get("non_null"):
        return None
    pattern, share = max(((p, _share(column, p)) for p in DATE_PATTERNS), key=lambda item: item[1])
    if share < DATE_SHARE:
        return None
    if pattern != "slash":
        return pattern, share, None
    counts = column.get("patterns") or {}
    first, second = counts.get("slash_first_over_12", 0), counts.get("slash_second_over_12", 0)
    if first and second:
        return None
    return pattern, share, "DD/MM" if first else "MM/DD" if second else None


def _range(column: dict[str, Any]) -> str:
    low, high = column.get("min"), column.get("max")
    return f", {str(low)[:10]} to {str(high)[:10]}" if low is not None and high is not None else ""


def _flag_values(column: dict[str, Any]) -> list[tuple[Any, int]] | None:
    """The two values of a two-valued column, from the exact top values covering every non-null row."""
    top = column.get("top")
    if top is None or len(top) != 2:
        return None
    return [(value, int(count)) for value, count in top] if sum(int(count) for _, count in top) == column.get("non_null") else None


def classify(column: dict[str, Any]) -> dict[str, Any]:
    """{role, confidence, evidence, sensitive?} for one column's profile; the rules of the module docstring."""
    kind, rows, non_null = column.get("kind"), int(column.get("rows") or 0), int(column.get("non_null") or 0)
    distinct = _distinct(column)
    ratio = distinct / rows if rows else 0.0
    sensitive = sensitivity(column)

    def result(role: str, low: bool, evidence: str) -> dict[str, Any]:
        found = {"role": role, "confidence": "low" if low else "high", "evidence": evidence}
        if sensitive:
            found["sensitive"] = True
        return found

    if non_null == 0:
        return result("other", False, "every value is null")
    if kind in ("date", "timestamp"):
        return result("time", False, f"{column.get('type', kind.upper())}{_range(column)}")
    dated = _date_pattern(column)
    if dated:
        pattern, share, order = dated
        name = {"iso": "YYYY-MM-DD", "dotted": "DD.MM.YYYY", "slash": order or "DD/MM or MM/DD"}[pattern]
        low = _near(share, DATE_SHARE, 1.0) or (pattern == "slash" and order is None)
        return result("time", low, f"{name} {_percent(share)}{_range(column)}")
    avg = float(column.get("avg_length") or 0)
    if kind == "string" and avg >= TEXT_AVG_LENGTH and ratio >= TEXT_DISTINCT_RATIO:
        low = _near(avg, TEXT_AVG_LENGTH) or _near(ratio, TEXT_DISTINCT_RATIO, 1.0)
        return result("text", low, f"avg {round(avg):,} chars, {_percent(ratio)} distinct")
    exact = column.get("exact_distinct")
    if kind in ("integer", "string") and non_null == rows and exact is not None and int(exact) == rows:
        return result("key", False, f"{_count(rows)} distinct, no nulls")
    if sensitive:
        pattern, share = sensitive
        return result("identifier", _near(share, SENSITIVE_SHARE, 1.0), f"{pattern} {_percent(share)}")
    two = _flag_values(column)
    if kind == "boolean" or two:
        shares = ", ".join(f"{value} {_percent(count / non_null)}" for value, count in sorted(two or [], key=lambda item: -item[1]))
        return result("flag", False, shares or "BOOLEAN")
    if distinct <= CATEGORY_DISTINCT or (kind == "string" and ratio <= CATEGORY_RATIO):
        if distinct <= CATEGORY_DISTINCT:
            return result("category", _near(distinct, CATEGORY_DISTINCT), f"{_count(distinct)} distinct")
        return result("category", _near(ratio, CATEGORY_RATIO, 0.0), f"{_count(distinct)} distinct, {_percent(ratio)} of rows")
    if kind == "string" and ratio >= IDENTIFIER_RATIO:
        return result("identifier", _near(ratio, IDENTIFIER_RATIO, 1.0), f"{_percent(ratio)} distinct")
    if kind in ("double", "decimal"):
        return result("measure", False, f"{column.get('type', kind.upper())}{_range(column)}")
    if kind == "integer":
        if has_name_hint(str(column.get("column", ""))):
            return result("identifier", False, f"integer named as an identifier, {_count(distinct)} distinct")
        return result("measure", True, f"integer, no identifier in its name{_range(column)}")
    return result("other", True, f"{column.get('type', 'unknown type')}, no rule fits")
