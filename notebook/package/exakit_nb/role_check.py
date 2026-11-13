"""A second look at a drafted column map by the AI model set up for the kit.

    review = nb.review_roles(connection, chosen_data)
    filled = nb.fill_column_map(review)       # {"roles": [...], "slots": {...}, "notes": {...}}; nothing is changed
    review.approve({r["column"]: r["role"] for r in filled["roles"]}, filled["slots"], notes=filled["notes"])   # if you agree
    suggestions = nb.check_roles(review)      # only the roles it would change: [{"column", "kit_role", "role", "why"}]

The kit drafts each column's role from measurements (how many distinct values, the type, the share of empty rows).
A model reads names the way a person does: ``ACCT_NO`` is an account number, not an amount, whatever its type. This
asks the model three things in one call: which drafted roles it would change and why, which column fits each slot
the notebooks use (the group to compare, who a row is about, the date, the text), and one sentence saying what each
column holds. It is shown the table's name and, for each column, its
name, its type, the drafted role with its confidence, and the kit's measured evidence (counts and shares) with the
column's note. It is never shown a row, and a column the map marks sensitive is left out entirely. An answer is kept
only when it names a real column and one of the eight roles and differs from the draft; a slot only when its column
has the role the kit requires there; a role is never changed to key and the key slot never moved to another column,
because "different in every row" is measured, not read from a name; and what to predict is never picked for you. The
model suggests, the approval stays yours.
"""

from __future__ import annotations

import json
import re
from typing import Any

from .describe import COLUMN_ROLES

__all__ = ["check_roles", "fill_column_map"]

MAX_COLUMNS = 200
NOTE_LIMIT = 300
AI_SLOTS = ("category", "entity", "time", "text")      # key is measured; target is the person's question
SYSTEM = "You complete a draft data dictionary. Return only one JSON object. No Markdown."
RULES = ("Each column has a drafted role, one of: key (different in every row), time (a date or time), measure (an "
         "amount to add up or average), category (a short list of repeated values to group by), flag (exactly two "
         "values), text (sentences people wrote), identifier (a name or code that points at one thing: not summed, "
         "not grouped), other (left out). Do three things, judging by each column's name, type and measured evidence. "
         "1. roles: say which drafted roles you would change. Change one only when you are confident; an identifier "
         "stored as a number (an account, a postcode, a phone number) is the usual miss. Never change a role to key. "
         "2. slots: name the one column that best fits each of: category (the main group a person would compare), "
         "entity (who or what a row is about: a customer, a product, a place), time (the date for trends; its role "
         "must be time), text (comments to read; its role must be text). Use null where no column fits. A column "
         "fills one slot. 3. notes: for every column, one plain sentence of at most 20 words saying what it holds, "
         "for a reader who does not know the table. Do not guess numbers or values you were not shown. Answer as "
         "JSON: {\"roles\": [{\"column\": \"NAME\", \"role\": \"one of the eight\", \"why\": \"one short sentence\"}], "
         "\"slots\": {\"category\": \"NAME or null\", \"entity\": ..., \"time\": ..., \"text\": ...}, "
         "\"notes\": {\"NAME\": \"sentence\"}}.")


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


def _parsed(answer: str) -> dict[str, Any]:
    found = re.search(r"\{.*\}", answer or "", re.S)
    try:
        value = json.loads(found.group(0)) if found else {}
    except (ValueError, AttributeError):
        value = {}
    return value if isinstance(value, dict) else {}


def _open_columns(review) -> dict[str, str]:
    """{UPPER NAME: column} of the columns a model may speak about: the table's, without the sensitive ones."""
    columns = review.draft.doc.get("columns") or {}
    return {c.upper(): c for c in review.suggestions() if not (columns.get(c) or {}).get("sensitive")}


def accept(answer: str, review) -> list[dict[str, str]]:
    """The model's role changes as suggestions: only a real, non-sensitive column, one of the eight roles, a role
    that differs from the draft and is not key; each column once. (An answer may hold them under "roles" or, as an
    earlier prompt asked, "changes".)"""
    parsed = _parsed(answer)
    changes = parsed.get("roles", parsed.get("changes", []))
    suggested, known = review.suggestions(), _open_columns(review)
    out, seen = [], set()
    for item in changes if isinstance(changes, list) else []:
        if not isinstance(item, dict):
            continue
        column = known.get(str(item.get("column") or "").strip().upper())
        role = str(item.get("role") or "").strip().lower()
        if not column or column in seen or role not in COLUMN_ROLES or role == suggested[column] or role == "key":
            continue
        seen.add(column)
        out.append({"column": column, "kit_role": suggested[column], "role": role,
                    "why": " ".join(str(item.get("why") or "").split())[:240]})
    return out


def accept_slots(answer: str, review, roles: list[dict[str, str]]) -> dict[str, str]:
    """The model's slots that the kit would accept: a real, non-sensitive column whose role (after the model's own
    role changes) is the one the kit requires for that slot, a column in one slot only, and never the key or the
    target. Only a slot that would differ from the draft is returned."""
    from .descriptor_rules import SLOT_ROLES

    asked = _parsed(answer).get("slots")
    known = _open_columns(review)
    final = {**review.suggestions(), **{r["column"]: r["role"] for r in roles}}
    drafted = review.slot_suggestions()
    taken = {c for slot, c in drafted.items() if c and slot not in AI_SLOTS}        # the key and the target keep theirs
    out: dict[str, str] = {}
    for slot in AI_SLOTS:
        column = known.get(str((asked or {}).get(slot) or "").strip().upper()) if isinstance(asked, dict) else None
        if not column or column in taken:
            continue
        required = SLOT_ROLES.get(slot)
        if required and final[column] not in required:
            continue
        if final[column] in ("other", "measure") and not required:
            continue                                   # nothing to group by or to be about
        taken.add(column)
        if drafted.get(slot) != column:
            out[slot] = column
    return out


def accept_notes(answer: str, review) -> dict[str, str]:
    """The model's descriptions: a real, non-sensitive column, one line, cut at NOTE_LIMIT; a column that already has
    a note keeps it (the model fills what is empty)."""
    asked = _parsed(answer).get("notes")
    known = _open_columns(review)
    columns = review.draft.doc.get("columns") or {}
    out: dict[str, str] = {}
    for name, text in (asked.items() if isinstance(asked, dict) else []):
        column = known.get(str(name).strip().upper())
        text = " ".join(str(text or "").split())[:NOTE_LIMIT]
        if column and text and not str((columns.get(column) or {}).get("note") or "").strip():
            out[column] = text
    return out


def fill_column_map(review, *, show: bool = True) -> dict[str, Any]:
    """Ask the AI model set up for the kit (nb.use_model, nb.model_setup) to complete the drafted column map, in one
    call: {"roles": [{"column", "kit_role", "role", "why"}] (the drafted roles it would change), "slots": {slot:
    COLUMN} (the group to compare, who a row is about, the date, the text - where it would differ from the draft and
    the kit's rules allow it), "notes": {COLUMN: one sentence} (for a column with no description yet)}. It sees names,
    types and the kit's measured evidence - never a row, never a sensitive column. It never picks what to predict or
    what makes a row unique. Nothing is changed: review.approve(roles, slots, notes=notes) with what you agree with.
    Raises ValueError when no model is set up."""
    from . import model_config
    from .model_config import sampling

    config = model_config.resolve()
    if config is None:
        raise ValueError("No AI model is set up: nb.model_setup() says how (the Home card's AI model row does it).")
    shown = facts(review)
    if not shown["columns"]:
        return {"roles": [], "slots": {}, "notes": {}}
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
    text = answer.choices[0].message.content or ""
    roles = accept(text, review)
    filled = {"roles": roles, "slots": accept_slots(text, review, roles), "notes": accept_notes(text, review)}
    if show:
        left_out = len(review.suggestions()) - len(shown["columns"])
        print(f"Asked {config.model_id} about {len(shown['columns'])} columns of {shown['table']} (names, types and the "
              f"kit's evidence; no rows" + (f"; {left_out} sensitive or further columns left out" if left_out else "") + ").")
        if not roles:
            print("It agrees with every drafted role.")
        for r in roles:
            print(f"  {r['column']}: {r['kit_role']} -> {r['role']}. {r['why']}")
        for slot, column in filled["slots"].items():
            print(f"  slot {slot}: {column}")
        if filled["notes"]:
            print(f"  {len(filled['notes'])} column descriptions written.")
        if roles or filled["slots"] or filled["notes"]:
            print("Nothing was changed. To use them: review.approve({COLUMN: role}, {slot: COLUMN}, notes={COLUMN: text}), "
                  "or the column map card.")
    return filled


def check_roles(review, *, show: bool = True) -> list[dict[str, str]]:
    """Only the roles the AI model would change: [{"column", "kit_role", "role", "why"}], empty when it agrees
    (nb.fill_column_map's "roles"; the same call, the same rules). Nothing is changed."""
    return fill_column_map(review, show=show)["roles"]
