"""Step 1 of the descriptor plan: one role per column from its profile, with no database.

Eight roles and no more: key, time, measure, category, flag, text, identifier, other. A ninth needs a review first.
Three things are read: the column's type, its numbers (rows, values present, distinct values, length) and the shape of
its values (profile.py counts, per text column, the values that look like a code, a number, three or more words, a
date, an e-mail, ...). Its name is read last and only ever breaks a tie the numbers leave open - QTY with ten values
is a measure, STORE with forty-five is a category - so a column named wrongly still gets the role its values show.

Sensitivity is decided first and kept whatever the role is: a text column is sensitive when 90% or more of its values
are e-mail addresses, phone numbers, IBANs or 5-digit postcodes, or when its name says postcode (ZIP, POSTAL, PLZ) and
90% are shaped like one, or its name says a person's name (FIRST_NAME, SURNAME, CUSTOMER_NAME, DRIVER_NAME), or an address whose
values are long and mostly distinct (STREET_ADDRESS, not ADDR_STATE). Then the
rules below, first match wins (classify()); "distinct share" is distinct values over the values present:

    all values null                                          -> other
    DATE or TIMESTAMP, or >= 98% match one date pattern      -> time
    integer named like a time (TS, EPOCH, ..._AT) holding
      epoch seconds or milliseconds (2001 to 2100)           -> time
    sensitive                                                -> identifier
    one value in every row                                   -> other     (it tells no row apart)
    text: avg length >= 40 and distinct share >= 0.5; or
      >= half the values three words or more, avg >= 15 and
      distinct share >= 0.5; or named like text (COMMENT,
      NOTE, DESCRIPTION, REVIEW, ...) and avg >= 10          -> text
    no nulls, every value distinct, and an integer, or text
      that is code-shaped or named like a key                -> key
    BOOLEAN, or exactly 2 distinct values                    -> flag
    DOUBLE, or DECIMAL with scale > 0                        -> measure
    integer named like an identifier (ID, KEY, NO, ...KEY)   -> identifier
    integer named like an amount (QTY, PRICE, AGE, ..._PCT)  -> measure
    <= 50 distinct, or text with distinct/rows <= 0.02       -> category
    text, >= 98% numbers, named like an amount               -> measure   (a number stored as text)
    text, >= 90% code-shaped (one token holding a digit)     -> identifier
    text, distinct share >= 0.9                              -> identifier
    text, avg length < 40, distinct share <= 0.5             -> category  (short labels: cities, job titles)
    integer                                                  -> measure
    anything else                                            -> other

Confidence is high or low, and "low" is what a reviewer reads first, so it is set wherever the draft is a guess: the
deciding number within 10% of its threshold, a role taken from the name alone, a number with few values and nothing
in its name (a store number or a rating: a category, or a measure?), short labels, a lone integer. For a share with a
ceiling of 100% "within 10%" is 10% of the room between the threshold and the ceiling; for a count or a length it is
10% of the threshold itself.

A column's profile is the dict profile.py writes per column: column, type, kind, rows, non_null, approx_distinct,
exact_distinct (when measured), avg_length, patterns (match counts), min, max and top (exact [value, count] pairs).
"""

from __future__ import annotations

import re
from typing import Any

ROLES = ("key", "time", "measure", "category", "flag", "text", "identifier", "other")

SENSITIVE_SHARE = 0.90        # of non-null values matching email, phone, IBAN or postcode
DATE_SHARE = 0.98             # of non-null values matching one date pattern
TEXT_AVG_LENGTH = 40          # characters
TEXT_DISTINCT_RATIO = 0.5     # distinct / values present
TEXT_WORDS_SHARE = 0.5        # of values with three words or more
TEXT_WORDS_LENGTH = 15        # characters, for text told by its words
TEXT_NAMED_LENGTH = 10        # characters, for text told by its name
CATEGORY_DISTINCT = 50        # distinct values
CATEGORY_RATIO = 0.02         # distinct / rows, strings
IDENTIFIER_RATIO = 0.9        # distinct / values present, strings
CODE_SHARE = 0.90             # of values shaped like a code
NUMBER_SHARE = 0.98           # of values that are numbers, for a number stored as text
LABEL_RATIO = 0.5             # distinct / values present, at most, for short labels
NEAR = 0.10                   # "within 10% of its threshold": low confidence

SENSITIVE_PATTERNS = ("email", "phone", "iban", "postcode")
DATE_PATTERNS = ("iso", "dotted", "slash")
NAME_HINTS = frozenset({"id", "code", "no", "nr", "key"})
KEY_SUFFIXES = ("key",)                       # CUSTKEY, NATIONKEY: names run together
MEASURE_HINTS = frozenset({
    "amount", "amt", "qty", "quantity", "count", "cnt", "total", "sum", "price", "cost", "revenue", "sales", "spend",
    "balance", "value", "age", "years", "months", "weeks", "days", "hours", "minutes", "seconds", "duration", "weight",
    "height", "length", "width", "depth", "size", "distance", "score", "points", "pct", "percent", "percentage",
    "rate", "ratio", "salary", "income", "wage", "fee", "tax", "discount", "margin", "profit", "kwh", "temperature",
    "temp", "humidity", "battery", "volume", "units", "number", "num", "avg", "mean", "min", "max"})
MEASURE_SUFFIXES = ("qty", "amt", "price", "cost", "count", "total", "amount")   # AVAILQTY, SUPPLYCOST, TOTALPRICE
TIME_HINTS = frozenset({"ts", "timestamp", "epoch", "time", "datetime", "at", "unixtime"})
TEXT_HINTS = frozenset({"comment", "comments", "description", "desc", "note", "notes", "remark", "remarks", "review",
                        "feedback", "message", "text", "summary", "body", "reason", "details", "narrative"})
POSTAL_HINTS = frozenset({"zip", "zipcode", "postal", "postcode", "plz"})
PERSON_HINTS = frozenset({"firstname", "lastname", "fullname", "surname", "forename", "givenname", "familyname"})
PERSON_PARTS = frozenset({"first", "last", "full", "given", "family", "middle", "sur"})
PERSON_ROLES = frozenset({"customer", "client", "contact", "employee", "driver", "patient", "user", "owner", "manager",
                          "doctor", "agent", "person", "member", "student", "teacher", "author", "buyer", "seller",
                          "recipient", "sender", "holder", "guest", "passenger", "applicant", "beneficiary"})
ADDRESS_HINTS = frozenset({"address", "street", "addr"})
EPOCH_SECONDS = (978_307_200, 4_102_444_800)              # 2001-01-01 to 2100-01-01
EPOCH_MILLISECONDS = (EPOCH_SECONDS[0] * 1000, EPOCH_SECONDS[1] * 1000)

_CAMEL = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+")


def name_tokens(name: str) -> list[str]:
    """The whole words of a column name, split on underscores and camelCase, lower case: CustomerNo -> customer, no."""
    return [token.lower() for part in re.split(r"[_\W]+", name) for token in _CAMEL.findall(part)]


def has_name_hint(name: str) -> bool:
    """True when a whole token of the name says identifier (CUSTOMER_NO yes, PAID_AMOUNT no), or one ends in KEY as
    run-together names do (O_CUSTKEY)."""
    return any(token in NAME_HINTS or (len(token) > 3 and token.endswith(KEY_SUFFIXES)) for token in name_tokens(name))


def _strong_id_hint(name: str) -> bool:
    """An identifier name that holds with few values too: ID, KEY, NO, NR, ...KEY - not CODE (a code with five values
    is a category: STATUS_CODE)."""
    return any(token in NAME_HINTS - {"code"} or (len(token) > 3 and token.endswith(KEY_SUFFIXES))
               for token in name_tokens(name))


def measure_hint(name: str) -> bool:
    """True when the name says an amount: QTY, UNIT_PRICE, ACCOUNT_AGE, DISCOUNT_PCT, AVAILQTY."""
    return any(token in MEASURE_HINTS or (len(token) > 4 and token.endswith(MEASURE_SUFFIXES))
               for token in name_tokens(name))


def _hint(name: str, words: frozenset[str]) -> bool:
    return any(token in words for token in name_tokens(name))


def _person_name(name: str) -> bool:
    tokens = name_tokens(name)
    joined = "".join(tokens)
    return (any(t in PERSON_HINTS for t in tokens) or joined in PERSON_HINTS
            or ("name" in tokens and any(t in PERSON_PARTS or t in PERSON_ROLES for t in tokens)))


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
    """(what, share) when a string column is sensitive, else None: by its values (e-mail, phone, IBAN, postcode), by a
    postcode name and postcode-shaped values, or by a name that says a person's name, or an address with values long
    (10 characters or more) and mostly distinct - ADDR_STATE is a state."""
    if column.get("kind") != "string" or not column.get("non_null"):
        return None
    pattern, share = max(((p, _share(column, p)) for p in SENSITIVE_PATTERNS), key=lambda item: item[1])
    if share >= SENSITIVE_SHARE:
        return pattern, share
    name = str(column.get("column", ""))
    if _hint(name, POSTAL_HINTS) and _share(column, "postal") >= SENSITIVE_SHARE:
        return "postcode", _share(column, "postal")
    if _person_name(name):
        return "person's name", 1.0
    distinct = _distinct(column)
    if (_hint(name, ADDRESS_HINTS) and float(column.get("avg_length") or 0) >= TEXT_NAMED_LENGTH
            and distinct >= TEXT_DISTINCT_RATIO * column["non_null"]):     # a street address: long and mostly distinct
        return "address", 1.0
    return None


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


def _epoch(column: dict[str, Any]) -> str | None:
    """'seconds' or 'milliseconds' when an integer column named like a time holds Unix times from 2001 to 2100."""
    if column.get("kind") != "integer" or not _hint(str(column.get("column", "")), TIME_HINTS):
        return None
    try:
        low, high = float(column["min"]), float(column["max"])
    except (KeyError, TypeError, ValueError):
        return None
    for unit, (start, end) in (("seconds", EPOCH_SECONDS), ("milliseconds", EPOCH_MILLISECONDS)):
        if start <= low <= high <= end:
            return unit
    return None


def _range(column: dict[str, Any]) -> str:
    low, high = column.get("min"), column.get("max")
    return f", {str(low)[:10]} to {str(high)[:10]}" if low is not None and high is not None else ""


def _flag_values(column: dict[str, Any]) -> list[tuple[Any, int]] | None:
    """The two values of a two-valued column, from the exact top values covering every non-null row."""
    top = column.get("top")
    if top is None or len(top) != 2:
        return None
    return [(value, int(count)) for value, count in top] if sum(int(count) for _, count in top) == column.get("non_null") else None


def _text(column: dict[str, Any], avg: float, present_ratio: float) -> tuple[bool, str] | None:
    """(low, evidence) when a string column is free text, else None."""
    if column.get("kind") != "string" or present_ratio < TEXT_DISTINCT_RATIO:
        return None
    words = _share(column, "words")
    if avg >= TEXT_AVG_LENGTH:
        return (_near(avg, TEXT_AVG_LENGTH) or _near(present_ratio, TEXT_DISTINCT_RATIO, 1.0),
                f"avg {round(avg):,} chars, {_percent(present_ratio)} distinct")
    if words >= TEXT_WORDS_SHARE and avg >= TEXT_WORDS_LENGTH:
        return True, f"{_percent(words)} of values are three words or more, avg {round(avg):,} chars"
    if _hint(str(column.get("column", "")), TEXT_HINTS) and avg >= TEXT_NAMED_LENGTH:
        return True, f"named as text, avg {round(avg):,} chars, {_percent(present_ratio)} distinct"
    return None


def classify(column: dict[str, Any]) -> dict[str, Any]:
    """{role, confidence, evidence, sensitive?} for one column's profile; the rules of the module docstring."""
    kind, rows, non_null = column.get("kind"), int(column.get("rows") or 0), int(column.get("non_null") or 0)
    name = str(column.get("column", ""))
    distinct = _distinct(column)
    ratio = distinct / rows if rows else 0.0
    present_ratio = distinct / non_null if non_null else 0.0
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
        label = {"iso": "YYYY-MM-DD", "dotted": "DD.MM.YYYY", "slash": order or "DD/MM or MM/DD"}[pattern]
        low = _near(share, DATE_SHARE, 1.0) or (pattern == "slash" and order is None)
        return result("time", low, f"{label} {_percent(share)}{_range(column)}")
    epoch = _epoch(column)
    if epoch:
        return result("time", False, f"Unix time in {epoch}, named as a time")
    if sensitive:
        what, share = sensitive
        if what in ("person's name", "address"):
            return result("identifier", True, f"named as a {what}")
        return result("identifier", _near(share, SENSITIVE_SHARE, 1.0), f"{what} {_percent(share)}")
    if distinct == 1:
        return result("other", False, "one value in every row: it tells no row apart" if non_null == rows
                      else f"one value, else empty ({_count(rows - non_null)} of {_count(rows)} rows empty)")
    avg = float(column.get("avg_length") or 0)
    text = _text(column, avg, present_ratio)
    if text:
        return result("text", *text)
    exact = column.get("exact_distinct")
    unique = non_null == rows and exact is not None and int(exact) == rows
    if unique and (kind == "integer" or (kind == "string" and (_share(column, "code") >= CODE_SHARE
                                                                or has_name_hint(name)))):
        return result("key", False, f"{_count(rows)} distinct, no nulls")
    two = _flag_values(column)
    if kind == "boolean" or two:
        shares = ", ".join(f"{value} {_percent(count / non_null)}" for value, count in sorted(two or [], key=lambda item: -item[1]))
        return result("flag", False, shares or "BOOLEAN")
    if kind in ("double", "decimal"):
        return result("measure", False, f"{column.get('type', kind.upper())}{_range(column)}")
    # An identifier name first: ACCOUNT_ID holds "count" but is an id.
    if kind == "integer" and (_strong_id_hint(name) or (has_name_hint(name) and distinct > CATEGORY_DISTINCT)):
        return result("identifier", False, f"integer named as an identifier, {_count(distinct)} distinct")
    if kind == "integer" and measure_hint(name):
        return result("measure", False, f"integer named as an amount, {_count(distinct)} distinct{_range(column)}")
    if distinct <= CATEGORY_DISTINCT:
        # A number with few values and nothing in its name: a store number or a rating - a reviewer decides.
        low = _near(distinct, CATEGORY_DISTINCT) or kind == "integer"
        return result("category", low, f"{_count(distinct)} distinct")
    if kind == "string":
        if _share(column, "number") >= NUMBER_SHARE and measure_hint(name):
            return result("measure", True, f"numbers written as text, named as an amount, {_count(distinct)} distinct")
        code = _share(column, "code")
        if code >= CODE_SHARE:
            return result("identifier", _near(code, CODE_SHARE, 1.0), f"{_percent(code)} code-shaped, {_count(distinct)} distinct")
        if ratio <= CATEGORY_RATIO:
            return result("category", _near(ratio, CATEGORY_RATIO, 0.0), f"{_count(distinct)} distinct, {_percent(ratio)} of rows")
        if present_ratio >= IDENTIFIER_RATIO:
            return result("identifier", _near(present_ratio, IDENTIFIER_RATIO, 1.0), f"{_percent(present_ratio)} distinct")
        if avg < TEXT_AVG_LENGTH and present_ratio <= LABEL_RATIO:
            return result("category", True, f"short labels, {_count(distinct)} distinct, avg {round(avg):,} chars")
    if kind == "integer":
        return result("measure", True, f"integer, nothing in its name{_range(column)}")
    return result("other", True, f"{column.get('type', 'unknown type')}, no rule fits")
