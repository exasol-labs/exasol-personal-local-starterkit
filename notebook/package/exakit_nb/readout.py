"""Plain-language notes under a notebook's results, for a reader who is not a data scientist.

    by = nb.name(CATEGORY)                              # CATEGORY: result columns are named after the data
    pct = nb.name(LABEL, "PCT")                         # CANCELLED_PCT: the % of rows where CANCELLED is 1
    count = nb.count_name(ds)                           # ORDER_LINES: the count column, named after what a row is
    nb.note_groups(first_rows, ds, by, count, pct, overall=(128975, 14.2))
    nb.note_trend(over_time, ds, "PERIOD", count, pct)
    nb.note_model(auc, ds, rows=20000)

Each note says what one row of the result is, what each number means in the data's own words (``ds.grain``: "one
row per order line" makes them order lines), the overall figure, the highest and lowest groups, which groups are too small to
trust, and that a difference between groups is not a cause. Nothing is computed that the result does not hold.
"""

from __future__ import annotations

import re
from typing import Any

__all__ = ["count_name", "name", "noun", "note_groups", "note_model", "note_trend"]

SMALL = 30                     # fewer rows than this: the group's % moves a lot with one row, so it is not compared
_STOP = ("in", "of", "for", "with", "by", "from", "at", "on", "per", "where", "when", "that", "which")   # a grain's noun ends


def name(column: str | None, suffix: str = "") -> str:
    """A result column named after a data column: ``CANCELLED`` + ``PCT`` -> ``CANCELLED_PCT``; quotes, dots and
    spaces become underscores, so the name works unquoted in SQL."""
    base = re.sub(r"[^A-Z0-9]+", "_", str(column or "").split(".")[-1].upper()).strip("_") or "VALUE"
    if base[0].isdigit():
        base = "C_" + base
    return f"{base}_{suffix}" if suffix else base


def noun(ds, one: bool = False) -> str:
    """What a row is, from the descriptor's grain: "one row per order line" -> "order lines" (``one=True``: "order
    line"), "one row per store and week" -> "store weeks"; at most three words, up to a comma or a word such as "in" or
    "per"; "rows" when the descriptor does not say."""
    grain = str(getattr(getattr(ds, "descriptor", None), "grain", None) or "")
    found = re.search(r"\bper\s+([a-z][a-z -]*)", grain.lower())
    words: list[str] = []
    for part in (found.group(1).split() if found else []):
        if part in _STOP:
            break
        if part in ("a", "an", "the"):
            if words:          # "client the campaign phoned": an article after the noun starts a clause
                break
            continue
        if part != "and":      # "store and week": joined, not a word of its own
            words.append(part)
    words = words[:3] or ["row"]
    if one:
        return " ".join(words)
    word = words[-1]
    plural = word if word.endswith("s") else word[:-1] + "ies" if word.endswith("y") and word[-2:-1] not in "aeiou" else word + "s"
    return " ".join(words[:-1] + [plural])


def count_name(ds) -> str:
    """The count column, named after what is counted: ORDER_LINES, STORE_WEEKS; ROW_COUNT when the descriptor does
    not say (ROWS is an SQL word)."""
    found = name(noun(ds))
    return "ROW_COUNT" if found == "ROWS" else found


def _label(ds) -> str | None:
    return ds.col("label") if ds is not None and ds.has("label") else None


def _rows(frame) -> list[dict[str, Any]]:
    """The result's rows as dicts (a pandas DataFrame, or anything with to_dict(orient="records"))."""
    try:
        return list(frame.to_dict(orient="records"))
    except (AttributeError, TypeError):
        return []


def _num(value) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return None if number != number else number      # NaN


def note_groups(frame, ds, by: str | tuple[str, ...], rows: str = "ROW_COUNT", pct: str | None = None, *,
                overall: tuple[Any, Any] | None = None) -> str:
    """Print (and return) the note under a per-group result: one line per fact, in the data's own words."""
    things, label = noun(ds), _label(ds)
    keys = [by] if isinstance(by, str) else list(by)
    by = " and ".join(keys)
    lines = [f"What this shows: one line per {by}. {rows} = how many {things}."]
    if pct and label:
        lines[0] += f" {pct} = the % of those {things} where {label} is 1."
    records = [dict(r, _group=" / ".join(str(r.get(k)) for k in keys)) for r in _rows(frame)
               if _num(r.get(rows)) is not None]
    if overall and pct and label and _num(overall[0]) is not None and _num(overall[1]) is not None:
        lines.append(f"Overall: {_num(overall[1]):.1f}% of {int(_num(overall[0])):,} {things} have {label} = 1.")
    if pct and label:
        solid = [r for r in records if _num(r.get(rows)) >= SMALL and _num(r.get(pct)) is not None]
        small = [r for r in records if _num(r.get(rows)) < SMALL]
        if len(solid) >= 2:
            high = max(solid, key=lambda r: _num(r[pct]))
            low = min(solid, key=lambda r: _num(r[pct]))
            lines.append(f"Highest: {high['_group']}, {_num(high[pct]):.1f}% of {int(_num(high[rows])):,} {things}. "
                         f"Lowest: {low['_group']}, {_num(low[pct]):.1f}% of {int(_num(low[rows])):,} {things}.")
        if small:
            shown = ", ".join(f"{r['_group']} ({int(_num(r[rows]))})" for r in small[:5])
            lines.append(f"Too few {things} to trust their %: {shown}. Below {SMALL}, one {noun(ds, one=True)} "
                         "more or less changes the % a lot.")
        lines.append(f"Counts, not causes: a higher % in one {by} does not mean the {by} makes {label} = 1; "
                     f"those {things} may simply be about different things.")
        lines.append(f"{label} is the outcome chosen in the column map. Check how it was produced (a person, a rule or "
                     "a model) before acting on it.")
    elif records:
        biggest = max(records, key=lambda r: _num(r[rows]))
        lines.append(f"Largest: {biggest['_group']} with {int(_num(biggest[rows])):,} {things}. Size only: this says nothing "
                     "about why a group is bigger.")
    text = "\n".join(lines)
    print(text)
    return text


def note_trend(frame, ds, period: str = "PERIOD", rows: str = "ROW_COUNT", pct: str | None = None) -> str:
    """Print (and return) the note under a per-period result: the busiest period and the highest and lowest %."""
    things, label = noun(ds), _label(ds)
    records = [r for r in _rows(frame) if _num(r.get(rows)) is not None]
    unit = period.split("_")[0].lower()                 # MONTH_START -> month
    first_day = f" ({period} is its first day)" if unit in ("month", "year") else ""
    lines = [f"What this shows: one line per {unit}{first_day}. {rows} = how many {things} in it."
             + (f" {pct} = the % of them where {label} is 1." if pct and label else "")]
    if records:
        busiest = max(records, key=lambda r: _num(r[rows]))
        lines.append(f"Busiest: {busiest[period]} with {int(_num(busiest[rows])):,} {things}.")
    if pct and label:
        solid = [r for r in records if _num(r.get(rows)) >= SMALL and _num(r.get(pct)) is not None]
        if len(solid) >= 2:
            high = max(solid, key=lambda r: _num(r[pct]))
            low = min(solid, key=lambda r: _num(r[pct]))
            lines.append(f"Highest %: {high[period]} ({_num(high[pct]):.1f}%). Lowest %: {low[period]} ({_num(low[pct]):.1f}%). "
                         f"Periods with fewer than {SMALL} {things} are left out of this comparison.")
        lines.append("A change over time shows when something moved, not why: check what else changed then "
                     "(new sources, a new way of labelling, news).")
    text = "\n".join(lines)
    print(text)
    return text


def _model_event(ds, rows: int, score: float) -> None:
    """One line in the active workflow's log: a model was trained and scored on this dataset."""
    try:
        import importlib

        wf = importlib.import_module("exakit_nb.workflow")       # the module: exakit_nb.workflow is a function too
        wf.log_event(wf.MODEL, dataset=getattr(ds, "id", None), rows=int(rows), score=round(float(score), 4))
    except Exception:
        pass                                                      # a note never fails over its log line


def note_model(auc: float, ds, rows: int, share: float | None = None) -> str:
    """Print (and return) the note under the small model's score, in words."""
    things, label = noun(ds), _label(ds) or "the outcome"
    chance = round(100 * float(auc))
    _model_event(ds, rows, auc)
    verdict = ("about as good as guessing" if auc < 0.6 else "a weak signal" if auc < 0.7
               else "a useful signal" if auc < 0.85 else "a strong signal - check it is not too good to be true")
    lines = [f"What this means: shown one {noun(ds, one=True)} where {label} is 1 and one where it is 0, the model gives "
             f"the first one the higher score {chance}% of the time (50% is guessing): {verdict}.",
             f"It learned from {rows:,} {things}" + (f", {share:.1%} of them with {label} = 1." if share is not None else ".")
             + " It was checked on a quarter of them it had not seen."]
    if share is not None:
        common = max(float(share), 1 - float(share))
        lines.append(f"The baseline to beat: always answering {label} = {1 if share >= 0.5 else 0} is right "
                     f"{common:.0%} of the time, which is why accuracy is not the score here.")
    text = "\n".join(lines)
    print(text)
    return text
