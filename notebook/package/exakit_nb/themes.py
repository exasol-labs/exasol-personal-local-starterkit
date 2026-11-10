"""What the texts on each side of the label are about, read by your model and traced to your Langfuse.

    sample = nb.sql(conn, SAMPLE_SQL)                   # LABEL_ and TEXT_: the newest texts on each side of the label
    themes = nb.themes(conn, ds, sample, nb.model_client(), sql=SAMPLE_SQL)

One model call per side (label = 1, label = 0): the model sorts that side's texts into two to four themes
and answers in JSON, so the result is a table - theme, how many texts, their share, an example - with a note in plain
words under it. A theme found on one side only is the clue: what those texts are about that the others are not.

With Langfuse set up (nb.trace), both calls are one trace, ``explore-themes``, each call named after its side, with
what was sent, the answer, tokens, cost and time, and two scores to compare models and runs by: ``valid_json`` (1 when
every answer could be read) and ``texts_placed`` (the share of texts the model gave a theme).
"""

from __future__ import annotations

import json
import re
from typing import Any

from .readout import count_name, name, noun

__all__ = ["themes"]

TRACE_NAME = "explore-themes"
CLIP = 600                      # characters of one text sent: enough for its gist, and the cost stays small
SYSTEM = ("You group short texts into themes. Reply with JSON only, no other words: "
          '{"themes": [{"theme": "<at most five plain words>", "texts": [<the numbers of the texts in this theme>]}]}. '
          "Use two to four themes. Put every text in exactly one theme.")


def _records(sample) -> list[dict[str, Any]]:
    try:
        return list(sample.to_dict(orient="records"))
    except (AttributeError, TypeError):
        texts = list(sample.get("TEXT_", []))
        labels = list(sample.get("LABEL_", [None] * len(texts)))
        return [{"LABEL_": label, "TEXT_": text} for label, text in zip(labels, texts)]


def _sides(sample) -> list[tuple[Any, list[str]]]:
    """[(label value, texts)], the larger value first (1 before 0); one side (None) when there is no label."""
    sides: dict[Any, list[str]] = {}
    for row in _records(sample):
        text = str(row.get("TEXT_") or "").strip()
        if text:
            sides.setdefault(row.get("LABEL_"), []).append(text)
    return sorted(sides.items(), key=lambda item: (item[0] is None, str(item[0])), reverse=True)


def parse(reply: str, count: int) -> tuple[list[tuple[str, list[int]]], bool]:
    """[(theme, [text numbers])] from the model's answer, and whether it could be read: code fences and markdown are
    stripped, numbers outside 1..count or given twice are dropped (the first theme keeps a text)."""
    found = re.search(r"\{.*\}", reply or "", re.S)
    try:
        doc = json.loads(found.group(0)) if found else None
        listed = doc["themes"] if isinstance(doc, dict) else None
    except (ValueError, KeyError, TypeError):
        listed = None
    if not isinstance(listed, list):
        return [], False
    seen: set[int] = set()
    out = []
    for item in listed:
        if not isinstance(item, dict):
            continue
        theme = re.sub(r"[*_`#]+", "", str(item.get("theme") or "")).strip() or "(no name)"
        numbers = []
        for value in item.get("texts") or []:
            try:
                number = int(value)
            except (TypeError, ValueError):
                continue
            if 1 <= number <= count and number not in seen:
                seen.add(number)
                numbers.append(number)
        if numbers:
            out.append((theme, numbers))
    return out, bool(out)


def _ask(client, model: str, texts: list[str], call: str, traced: bool) -> str:
    from .model_config import sampling

    numbered = "\n".join(f"{i}. {' '.join(text.split())[:CLIP]}" for i, text in enumerate(texts, 1))
    extra = {"name": call} if traced else {}            # Langfuse's OpenAI drop-in names the call in the trace
    answer = client.chat.completions.create(model=model, messages=[{"role": "system", "content": SYSTEM},
                                                                   {"role": "user", "content": numbered}],
                                            **sampling(), **extra)
    return answer.choices[0].message.content or ""


def _score(span, name_: str, value: float, comment: str) -> None:
    for method in ("score_trace", "score"):            # Langfuse SDK 5: the span scores its trace
        call = getattr(span, method, None)
        if callable(call):
            try:
                call(name=name_, value=value, comment=comment)
            except Exception:                           # noqa: BLE001 - a score is a bonus; the result stands without it
                pass
            return


def themes(conn, ds, sample, endpoint, *, sql: str | None = None):
    """Sort each side's texts into themes with ``endpoint`` = (client, model) from nb.model_client(); return the table
    (a pandas DataFrame when pandas is there, else a list of rows) and print the note. None without an endpoint."""
    if endpoint is None:
        return None
    from . import trace

    client, model = endpoint
    label = ds.col("label") if ds.has("label") else None
    side_column, count_column, things = name(label) if label else "SAMPLE", count_name(ds), noun(ds)
    rows: list[dict[str, Any]] = []
    sizes, readable, placed = [], 0, 0
    sides = _sides(sample)
    with trace(conn, TRACE_NAME, dataset=ds, sql=sql) as span:
        for value, texts in sides:
            side = f"{label} = {value}" if label else "all"
            reply = _ask(client, model, texts, f"themes where {side}", traced=span is not None)
            found, ok = parse(reply, len(texts))
            sizes.append(f"{len(texts)} with {side}" if label else f"{len(texts)}")
            readable += ok
            placed += sum(len(numbers) for _, numbers in found)
            for theme, numbers in sorted(found, key=lambda item: -len(item[1])):
                rows.append({side_column: value if label else "all", "THEME": theme, count_column: len(numbers),
                             "SHARE_PCT": round(100 * len(numbers) / len(texts), 1),
                             "EXAMPLE": " ".join(texts[numbers[0] - 1].split())[:120]})
            if not ok:
                rows.append({side_column: value if label else "all", "THEME": "(the answer could not be read)",
                             count_column: len(texts), "SHARE_PCT": 100.0, "EXAMPLE": " ".join(reply.split())[:120]})
        total = sum(len(texts) for _, texts in sides)
        if span is not None and sides:
            _score(span, "valid_json", readable / len(sides), "1 when every answer was readable JSON")
            _score(span, "texts_placed", placed / total if total else 0.0, "share of the texts given a theme")
    lines = [f"What this shows: your model read the newest {things} on each side ({', '.join(sizes)}) and sorted each "
             f"side into a few themes. {count_column} = how many of those {things} it put in the theme, SHARE_PCT = "
             "their share of that side, EXAMPLE = the start of one of them."]
    if label and len(sides) > 1:
        lines.append(f"A theme found only where {label} is {sides[0][0]} is the clue to what those {things} are about.")
    lines.append(f"This is a model reading {total} {things}, not all of them: read the examples, then check a theme on "
                 "every row with SQL (for example WHERE text LIKE '%word%') before relying on it.")
    if span is not None:
        lines.append(f'In Langfuse: the trace "{TRACE_NAME}" holds each call - what was sent, the answer, tokens, cost '
                     "and time - and two scores to compare models or runs by: valid_json (1 = every answer could be "
                     "read) and texts_placed (the share of texts given a theme).")
    print("\n".join(lines))
    try:
        import pandas as pd
    except ImportError:
        return rows
    return pd.DataFrame(rows)
