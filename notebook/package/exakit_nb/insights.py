"""What an answer says, in sentences: worked out from the result itself by fixed rules, with no model and no new query.

    nb.insights(answer)          # ["12 rows.", "Electronics is the largest: 3,920,412 (41% of the total).", ...]

The rules look at the first text or date column (what the rows are about) and the numeric columns (what is
measured): the largest and the smallest, the top one's share of the total when every value is positive, the change
from the first to the last period of a time series, and values far from the rest (outside 1.5 times the
interquartile range). A result with no number has only its row count. Nothing leaves this computer.
"""

from __future__ import annotations

from typing import Any

__all__ = ["insight_rules", "insights"]

INSIGHT_RULES = {"SENTENCES": 6, "TOP": 3, "OUTLIER_IQR": 1.5, "OUTLIER_MIN_ROWS": 8}


def insight_rules() -> dict:
    """The rules the insights are worked out with, to copy, change and pass (nb.insights(answer, rules={...})):

    SENTENCES          at most this many sentences
    TOP                "the top N hold x% of the total"
    OUTLIER_IQR        a value further than this many interquartile ranges from the middle half is far from the rest
    OUTLIER_MIN_ROWS   values are compared this way only with at least this many rows"""
    return dict(INSIGHT_RULES)


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if number == number and abs(number) != float("inf") else None


def _shown(value: float) -> str:
    return f"{value:,.0f}" if abs(value) >= 100 or float(value).is_integer() else f"{value:,.2f}"


def _is_time(values: list[Any]) -> bool:
    import datetime as dt

    return bool(values) and all(isinstance(v, (dt.date, dt.datetime)) or
                                (isinstance(v, str) and len(v) >= 7 and v[:4].isdigit() and v[4] in "-/") for v in values)


def insights(frame, *, limit: int | None = None, rules: dict | None = None) -> list[str]:
    """Up to SENTENCES sentences about a result (a pandas DataFrame, or rows as a list of dicts); ``rules`` changes
    the rules (nb.insight_rules() lists them)."""
    rules = {**INSIGHT_RULES, **{k: v for k, v in (rules or {}).items()}}
    wrong = [k for k in rules if k not in INSIGHT_RULES]
    if wrong:
        raise ValueError(f"{wrong[0]} is not an insight rule: the rules are {', '.join(INSIGHT_RULES)}")
    limit = int(limit if limit is not None else rules["SENTENCES"])
    try:
        columns = [str(c) for c in frame.columns]
        rows = frame.astype(object).values.tolist()
    except AttributeError:
        rows_in = list(frame or [])
        columns = list(rows_in[0].keys()) if rows_in else []
        rows = [[r.get(c) for c in columns] for r in rows_in]
    said = [f"{len(rows):,} row{'s' if len(rows) != 1 else ''}."]
    if not rows:
        return said
    numeric = [i for i, _ in enumerate(columns) if all(_number(r[i]) is not None for r in rows if r[i] is not None)
               and any(_number(r[i]) is not None for r in rows)]
    labels = [i for i in range(len(columns)) if i not in numeric]
    if not numeric:
        return said
    label = labels[0] if labels else None
    measure = numeric[0]
    name = columns[measure].replace("_", " ").lower()
    pairs = [(r[label] if label is not None else f"row {n + 1}", _number(r[measure])) for n, r in enumerate(rows)
             if _number(r[measure]) is not None]
    if len(pairs) == 1:
        return said + [f"{name}: {_shown(pairs[0][1])}."]
    if label is not None and _is_time([p[0] for p in pairs]):
        ordered = sorted(pairs, key=lambda p: str(p[0]))
        first, last = ordered[0], ordered[-1]
        if first[1]:
            change = (last[1] - first[1]) / abs(first[1])
            said.append(f"{name} went from {_shown(first[1])} ({first[0]}) to {_shown(last[1])} ({last[0]}): "
                        f"{'up' if change >= 0 else 'down'} {abs(change):.0%}.")
        peak = max(ordered, key=lambda p: p[1])
        said.append(f"The highest {name} was {_shown(peak[1])} in {peak[0]}.")
    else:
        top = max(pairs, key=lambda p: p[1])
        low = min(pairs, key=lambda p: p[1])
        total = sum(p[1] for p in pairs)
        share = f" ({top[1] / total:.0%} of the total)" if total > 0 and all(p[1] >= 0 for p in pairs) else ""
        said.append(f"{top[0]} has the largest {name}: {_shown(top[1])}{share}.")
        said.append(f"{low[0]} has the smallest: {_shown(low[1])}.")
        top_n = int(rules["TOP"])
        if total > 0 and all(p[1] >= 0 for p in pairs) and len(pairs) > top_n > 0:
            ranked = sorted((p[1] for p in pairs), reverse=True)
            share_top = sum(ranked[:top_n]) / total
            said.append(f"The top {top_n} hold {share_top:.0%} of the total {name}.")
    values = sorted(p[1] for p in pairs)
    if len(values) >= int(rules["OUTLIER_MIN_ROWS"]):
        q1, q3 = values[len(values) // 4], values[(3 * len(values)) // 4]
        span = q3 - q1
        k = float(rules["OUTLIER_IQR"])
        far = [p for p in pairs if span and (p[1] > q3 + k * span or p[1] < q1 - k * span)]
        if far:
            said.append("Far from the rest: " + ", ".join(f"{p[0]} ({_shown(p[1])})" for p in far[:3])
                        + (f" and {len(far) - 3} more" if len(far) > 3 else "") + ".")
    return said[:limit]
