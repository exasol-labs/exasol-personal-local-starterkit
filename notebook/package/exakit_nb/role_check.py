"""A second look at a drafted column map by the AI model set up for the kit.

    review = nb.review_roles(connection, chosen_data)
    suggestions = nb.check_roles(review)      # [{"column", "kit_role", "role", "why"}]; nothing is changed
    review.approve({s["column"]: s["role"] for s in suggestions})     # only if you agree

The kit drafts each column's role from measurements (how many distinct values, the type, the share of empty rows).
A model reads names the way a person does: ``ACCT_NO`` is an account number, not an amount, whatever its type. This
asks the model which drafted roles it would change, and why. It is shown the table's name and, for each column, its
name, its type, the drafted role with its confidence, and the kit's measured evidence (counts and shares) with the
column's note. It is never shown a row, and a column the map marks sensitive is left out entirely. An answer is kept
only when it names a real column and one of the eight roles and differs from the draft: the model suggests, the
approval stays yours.
"""

from __future__ import annotations

import json
import re
from typing import Any

from .describe import COLUMN_ROLES

__all__ = ["check_roles"]

MAX_COLUMNS = 200
SYSTEM = "You review a draft data dictionary. Return only one JSON object. No Markdown."
RULES = ("Each column has a drafted role, one of: key (different in every row), time (a date or time), measure (an "
         "amount to add up or average), category (a short list of repeated values to group by), flag (exactly two "
         "values), text (sentences people wrote), identifier (a name or code that points at one thing: not summed, "
         "not grouped), other (left out). Say which drafted roles you would change, judging by the column's name, "
         "type and measured evidence. Change a role only when you are confident; an identifier stored as a number "
         "(an account, a postcode, a phone number) is the usual miss. Answer as JSON: {\"changes\": [{\"column\": "
         "\"NAME\", \"role\": \"one of the eight\", \"why\": \"one short sentence\"}]}. An empty list means the draft "
         "is right.")


def facts(review) -> dict[str, Any]:
    """What the model is shown: the table and, per column, name, type and role with the kit's evidence. No rows; a
    sensitive column is not in it."""
    columns = review.draft.doc.get("columns") or {}
    labels, suggested = review.labels(), review.suggestions()
    listed = []
    for column in list(suggested)[:MAX_COLUMNS]:
        entry = columns.get(column) or {}
        if entry.get("sensitive"):
            continue
        summary, note = labels.get(column, ("", ""))
        listed.append({"column": column, "drafted_role": suggested[column], "confidence": entry.get("confidence") or "",
                       "evidence": summary, **({"note": note} if note else {})})
    return {"table": str(review.draft.table), "columns": listed}


def accept(answer: str, review) -> list[dict[str, str]]:
    """The model's answer as suggestions: only a real, non-sensitive column, one of the eight roles, and a role that
    differs from the draft; each once."""
    found = re.search(r"\{.*\}", answer or "", re.S)
    try:
        changes = json.loads(found.group(0)).get("changes", []) if found else []
    except (ValueError, AttributeError):
        changes = []
    columns = review.draft.doc.get("columns") or {}
    suggested = review.suggestions()
    by_upper = {c.upper(): c for c in suggested}
    out, seen = [], set()
    for item in changes if isinstance(changes, list) else []:
        if not isinstance(item, dict):
            continue
        column = by_upper.get(str(item.get("column") or "").strip().upper())
        role = str(item.get("role") or "").strip().lower()
        if not column or column in seen or role not in COLUMN_ROLES or role == suggested[column]:
            continue
        if (columns.get(column) or {}).get("sensitive"):
            continue
        seen.add(column)
        out.append({"column": column, "kit_role": suggested[column], "role": role,
                    "why": " ".join(str(item.get("why") or "").split())[:240]})
    return out


def check_roles(review, *, show: bool = True) -> list[dict[str, str]]:
    """Ask the AI model set up for the kit (nb.use_model, nb.model_setup) which drafted roles it would change:
    [{"column", "kit_role", "role", "why"}], empty when it agrees. It sees names, types and the kit's measured
    evidence - never a row, never a sensitive column - and nothing is changed: approve what you agree with
    (review.approve({"COLUMN": "role"})). Raises ValueError when no model is set up."""
    from . import model_config
    from .model_config import sampling

    config = model_config.resolve()
    if config is None:
        raise ValueError("No AI model is set up: nb.model_setup() says how (the Home card's AI model row does it).")
    shown = facts(review)
    if not shown["columns"]:
        return []
    from . import tracing

    client = model_config.create_client(config, traced=tracing())
    try:
        answer = client.chat.completions.create(model=config.model_id, messages=[
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": json.dumps({"rules": RULES, **shown})}], **sampling())
    finally:
        try:
            client.close()
        except Exception:                                   # noqa: BLE001 - closing is a courtesy
            pass
    suggestions = accept(answer.choices[0].message.content or "", review)
    if show:
        left_out = len(review.suggestions()) - len(shown["columns"])
        print(f"Asked {config.model_id} about {len(shown['columns'])} columns of {shown['table']} (names, types and the "
              f"kit's evidence; no rows" + (f"; {left_out} sensitive or further columns left out" if left_out else "") + ").")
        if not suggestions:
            print("It agrees with every drafted role.")
        for s in suggestions:
            print(f"  {s['column']}: {s['kit_role']} -> {s['role']}. {s['why']}")
        if suggestions:
            print("Nothing was changed. To use them: review.approve({\"COLUMN\": \"role\", ...}), or the column map card.")
    return suggestions
