"""Numbers as a reader expects them: money in the data's own currency, counts with thousands separators, shares as
percentages, IDs and years left as they are.

    currency = nb.currency_of(connection, dataset)     # "INR" when the table's CURRENCY column holds one code
    nb.formatted(answer, dataset, currency)            # the answer with every number written out (for reading)
    nb.format_value(1234567.5, nb.column_format("TOTAL_AMOUNT", [1234567.5], dataset, "INR"))   # "₹12,34,567.50"

How a result column is read, from its name and its values (and the column map: a measure whose name says money):
- money: AMOUNT, PRICE, REVENUE, SALES, COST, FEE, SPEND, INCOME, PAYMENT, BALANCE, PROFIT, SALARY, CHARGE ... and a
  TOTAL_/AVG_/SUM_ of one; two decimals, the currency's symbol when the data names one (INR in Indian grouping:
  12,34,567.50), else no symbol;
- percent: a name ending in PCT, PERCENT or SHARE; one decimal and %;
- an ID, a code, a key or a year: written as it is, no separators;
- a whole number (a count): thousands separators;
- any other number: thousands separators, at most two decimals, no trailing zeros.
Nothing changes the numbers themselves: the table's values are what the database returned.
"""

from __future__ import annotations

import math
import re
from typing import Any

__all__ = ["column_format", "currency_of", "format_value", "formatted"]

MONEY = ("AMOUNT", "PRICE", "REVENUE", "SALES", "SALE", "COST", "COSTS", "FEE", "FEES", "SPEND", "SPENT", "INCOME",
         "PAYMENT", "PAID", "BALANCE", "PROFIT", "SALARY", "CHARGE", "CHARGES", "TURNOVER", "GMV", "BUDGET", "TARGET_AMOUNT",
         "DISCOUNT", "TAX", "PREMIUM", "WAGE", "WAGES", "EARNINGS", "LOSS", "DEPOSIT", "WITHDRAWAL", "ACCTBAL", "EXTENDEDPRICE",
         "TOTALPRICE", "SUPPLYCOST", "RETAILPRICE")
PREFIXES = ("TOTAL_", "AVG_", "AVERAGE_", "SUM_", "MIN_", "MAX_", "MEDIAN_", "MEAN_")
AS_IS = re.compile(r"(^|_)(ID|IDS|KEY|CODE|NO|NUMBER|NR|YEAR|YR|ZIP|PIN|PINCODE|POSTCODE|POSTAL_CODE|PHONE)$|^(YEAR|ID)$")
PERCENT = re.compile(r"(PCT|PERCENT|PERCENTAGE|SHARE)$")
SYMBOL = {"INR": "₹", "USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥", "CNY": "¥", "AUD": "A$", "CAD": "C$", "CHF": "CHF ",
          "SGD": "S$", "AED": "AED ", "BRL": "R$", "KRW": "₩", "MXN": "MX$", "ZAR": "R ", "SEK": "SEK ", "NOK": "NOK ",
          "DKK": "DKK ", "PLN": "zł ", "HKD": "HK$", "NZD": "NZ$"}
NO_DECIMALS = ("JPY", "KRW")


def _words(column: str) -> list[str]:
    return [w for w in re.split(r"[^A-Z0-9]+", str(column).upper()) if w]


def _is_money(column: str, dataset: Any = None) -> bool:
    name = str(column).upper()
    for pre in PREFIXES:
        if name.startswith(pre):
            name = name[len(pre):]
            break
    if name.endswith(("_PCT", "_PERCENT", "_SHARE", "_RATE", "_COUNT")):
        return False
    words = _words(name)
    if any(w in MONEY for w in words) or name in MONEY:
        return True
    # the column map: a measure of that name whose note says money
    columns = dict(getattr(getattr(dataset, "descriptor", None), "columns", {}) or {})
    entry = columns.get(name) or {}
    note = str(entry.get("note") or "").lower()
    return entry.get("role") == "measure" and any(w in note for w in ("currency", "rupee", "dollar", "euro", "price", "amount", "paid", "revenue"))


def _numbers(values) -> list[float]:
    out = []
    for v in values:
        if isinstance(v, bool) or v is None:
            continue
        try:
            f = float(v)
        except (TypeError, ValueError):
            return []                          # text in the column: not a number column
        if not math.isnan(f):
            out.append(f)
    return out


def column_format(column: str, values, dataset: Any = None, currency: str | None = None) -> dict[str, Any]:
    """How to write a result column: {"kind": "money"|"percent"|"as_is"|"count"|"number"|"text", "currency", "decimals"}."""
    nums = _numbers(list(values))
    if not nums:
        return {"kind": "text"}
    name = str(column).upper()
    if PERCENT.search(name):
        return {"kind": "percent", "decimals": 1}
    if AS_IS.search(name):
        return {"kind": "as_is"}
    if _is_money(name, dataset):
        code = (currency or "").upper() or None
        return {"kind": "money", "currency": code, "decimals": 0 if code in NO_DECIMALS else 2}
    if all(float(x).is_integer() for x in nums):
        return {"kind": "count", "decimals": 0}
    return {"kind": "number", "decimals": 2}


def _grouped(number: float, decimals: int, indian: bool = False) -> str:
    text = f"{abs(number):,.{decimals}f}"
    if indian:                                 # 12,34,567.50: the last three digits, then pairs
        whole, _, frac = f"{abs(number):.{decimals}f}".partition(".")
        head, tail = whole[:-3], whole[-3:]
        pairs = []
        while len(head) > 2:
            pairs.insert(0, head[-2:])
            head = head[:-2]
        text = ",".join(([head] if head else []) + pairs + [tail]) + (f".{frac}" if decimals else "")
    return ("-" if number < 0 else "") + text


def format_value(value: Any, fmt: dict[str, Any]) -> str:
    """One value written out as ``fmt`` (column_format) says; text, an empty value or a non-number as it is."""
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return ""
    kind = fmt.get("kind")
    if kind in (None, "text") or isinstance(value, bool):
        return str(value)
    try:
        number = float(value)
    except (TypeError, ValueError):
        return str(value)
    if kind == "as_is":
        return str(int(number)) if number.is_integer() else str(value)
    if kind == "percent":
        return f"{number:,.{fmt.get('decimals', 1)}f}%"
    if kind == "money":
        code = fmt.get("currency")
        text = _grouped(number, int(fmt.get("decimals", 2)), indian=code == "INR")
        if not code:
            return text
        sign, digits = ("-", text[1:]) if text.startswith("-") else ("", text)
        return f"{sign}{SYMBOL.get(code, code + ' ')}{digits}"
    if kind == "count":
        return _grouped(number, 0)
    text = _grouped(number, int(fmt.get("decimals", 2)))
    return text.rstrip("0").rstrip(".") if "." in text else text


CURRENCY_COLUMNS = re.compile(r"^(CURRENCY|CURRENCY_CODE|CCY|CUR|ISO_CURRENCY|CURRENCY_ISO)$|_CURRENCY(_CODE)?$")


def currency_of(conn, dataset) -> str | None:
    """The currency the dataset's money is in: the one ISO code (USD, INR, EUR ...) its currency column holds, read
    with one bounded, read-only statement; None when it has no such column, or more than one code in it."""
    columns = list(dict(getattr(getattr(dataset, "descriptor", None), "columns", {}) or {}))
    column = next((c for c in columns if CURRENCY_COLUMNS.search(str(c).upper())), None)
    if column is None or conn is None:
        return None
    quoted = '"' + str(column).replace('"', '""') + '"'
    table = ".".join('"' + p.replace('"', '""') + '"' for p in str(dataset.fact_table).split(".", 1))
    try:
        rows = conn.execute(f"SELECT DISTINCT {quoted} FROM {table} WHERE {quoted} IS NOT NULL LIMIT 2").fetchall()
    except Exception:
        return None
    codes = {str(r[0]).strip().upper() for r in rows if r and r[0] is not None}
    return codes.pop() if len(codes) == 1 and re.fullmatch(r"[A-Z]{3}", next(iter(codes))) else None


def formatted(frame, dataset: Any = None, currency: str | None = None):
    """A copy of a result with every number written out for reading (money in its currency, counts with separators,
    shares as %); the result itself is unchanged."""
    out = frame.copy()
    for column in out.columns:
        fmt = column_format(str(column), out[column].tolist(), dataset, currency)
        if fmt["kind"] != "text":
            out[column] = [format_value(v, fmt) for v in out[column].tolist()]
    return out
