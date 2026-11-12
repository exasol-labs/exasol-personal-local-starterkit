"""Review the profiler's proposed roles in a notebook and approve a versioned descriptor (DS-5, design 2.2).

    review = nb.review_roles(conn, ds)        # profiles the table, prints the evidence, shows the picker
    ds = review.dataset()                     # the approved dataset; waits for the approval

The picker is the descriptor itself: one dropdown per column with the eight roles (key, time, measure, category, flag,
text, identifier, other), set to the role the rules drafted and labelled with the evidence that chose it; then one
dropdown per slot - the columns the notebooks use (key, time, text, target, category, entity) - set to the drafted
column; then an Approve button. Each dropdown is the kit's own (``exakit_nb.picklist.PickList``, the guided cards'
look: the list opens in place and says what each role is for). In JupyterLab the rest is ipywidgets; in Marimo the
review itself is a ``mo.ui.dictionary`` of those dropdowns (through ``mo.ui.anywidget``; ``mo.ui.dropdown`` where it
is missing) with a ``mo.ui.run_button``, so
``ds = review.dataset()`` runs again when the button is clicked and stops cleanly (``mo.stop``) until then; in a plain
Python session ``review.approve({"COLUMN": "role", ...})`` is the same path.

Headless (``EXAKIT_NB_AUTO_APPROVE``, set by ``tools/notebooks.py --run``): ``1`` approves the proposal only when its
roles equal the current approved version's (the kit's store, else the shipped descriptor) - then nothing is written,
no new version, no column comments, so a CI run is idempotent; a proposal that differs stays a draft, the run says
why, and ``dataset()`` hands the draft on so a step that needs an approval (``require_approved``) says what to do.
``force`` approves whatever was proposed: a deliberately scripted approval.

``review_roles(conn, name)`` with a notebook's one assignment (a dataset id, a descriptor file, a data file) opens it as
it is described; a data file with no descriptor beside it is loaded, profiled and reviewed right there, the draft
saved beside it so the assignment reopens it. The active workflow's log gets ``describe.draft`` and
``describe.approve`` lines (X-1).
"""

from __future__ import annotations

import json
import os
import re
from html import escape
from pathlib import Path
from typing import Any

from .dataset import DATA_FILES, Dataset, _locate, checked, dataset, remember_dataset
from .describe import COLUMN_ROLES, SLOTS, Draft, ROLES, describe
from .workflow import DESCRIBE_APPROVE, DESCRIBE_DRAFT, log_event

__all__ = ["ApprovalNeeded", "RoleReview", "review_roles"]

# What each role is for: the second line of each option in the kit's dropdown.
ROLE_HINTS = {
    "key": "Different in every row, like an order number",
    "time": "A date or time: used for trends",
    "measure": "An amount to add up or average",
    "category": "A short list of repeated values: used to compare groups",
    "flag": "Only two values: can be what you predict",
    "text": "Sentences people wrote",
    "identifier": "Names or codes that point at one thing",
    "other": "Left out of everything",
}

AUTO_APPROVE = "EXAKIT_NB_AUTO_APPROVE"
FORCE = "force"
DEFAULT_SCHEMA = "MY_DATA"             # where a data file named by a notebook's assignment loads, as the quickstart's MY_SCHEMA
NONE_LABEL = "—"                  # the slot dropdown's entry for a slot left empty
ROLE_PURPOSES = {
    "key": "unique for every row: it identifies the record",
    "time": "a date or time: it orders events and makes trends",
    "measure": "a number to sum, average or chart",
    "category": "a few repeated values: the groups to compare",
    "flag": "two values (0/1, yes/no): a yes-or-no fact, and a candidate outcome to predict",
    "text": "free text: words to explore, summarise or turn into features",
    "identifier": "names or codes that point at someone or something: not grouped or charted",
    "other": "no rule fits: left out unless you give it a role",
}
SLOT_PURPOSES = {
    "key": "the column that identifies a row",
    "time": "the event date for trends and earlier/later records",
    "text": "the written descriptions to explore",
    "target": "the outcome a model predicts - you choose it, the kit never guesses it",
    "category": "the groups to compare",
    "entity": "who or what a row is about (the organisation, person or item)",
}
LEGACY_SLOT = {"date": "time", "label": "target", "entity": "entity"}   # an earlier picker's names, still accepted


def _rules():
    from . import descriptor_rules
    return descriptor_rules


def _roles_of(descriptor) -> dict[str, Any]:
    """{role: column | [columns]} of a parsed descriptor: the shape Draft.roles has."""
    return {role: ([r.column for r in refs] if role == "text" else refs[0].column) for role, refs in descriptor.roles.items()}


def approved_roles(id: str, file: Path | None = None) -> tuple[dict[str, Any] | None, int | None]:
    """(roles, version) of the current approved descriptor of ``id`` - the one beside a data file, else the kit's
    store, else the one the kit ships - or (None, None) when there is none, or it is a draft."""
    from .own_file import descriptor_beside

    try:
        path = descriptor_beside(file) if file is not None else None
        if path is None:
            path, _ = _locate(id)
        descriptor = _rules().read_descriptor(path)
    except (ValueError, OSError):
        return None, None
    if descriptor.status != "approved":
        return None, None
    return _roles_of(descriptor), descriptor.version


def _differences(proposed: dict[str, Any], approved: dict[str, Any]) -> list[str]:
    """One ``role: approved -> proposed`` per role the two disagree on."""
    def show(value):
        return "-" if value is None else ", ".join(value) if isinstance(value, list) else str(value)
    return [f"{role}: {show(approved.get(role))} -> {show(proposed.get(role))}"
            for role in ROLES if proposed.get(role) != approved.get(role)]


def _percent(rate: Any) -> str:
    try:
        return f"{100 * float(rate):.1f}%"
    except (TypeError, ValueError):
        return "?"


def evidence_summary(entry: dict[str, Any]) -> str:
    """One line a picker shows for a column: type, null share, distinct values or span (what the profiler recorded)."""
    parts = []
    if entry.get("type"):
        parts.append(str(entry["type"]))
    if entry.get("null_rate") is not None:
        parts.append(f"null {_percent(entry['null_rate'])}")
    if entry.get("span_days") is not None:
        parts.append(f"span {entry['span_days']} d")
    elif entry.get("distinct") is not None:
        parts.append(f"{entry['distinct']} distinct")
    if entry.get("avg_len") is not None:
        parts.append(f"avg len {entry['avg_len']}")
    if entry.get("score") is not None:
        parts.append(f"score {entry['score']}")
    if entry.get("role") and entry.get("evidence"):
        parts.append(f"{entry['role']} ({entry.get('confidence', '?')} confidence): {entry['evidence']}")
    return ", ".join(parts)


class ApprovalNeeded(RuntimeError):
    """The roles are not approved yet. A notebook shows the one line, not a traceback; the cells below stop."""

    def _render_traceback_(self) -> list[str]:          # IPython's hook for how an exception is shown
        return [str(self)]


class RoleReview:
    """One proposal. Jupyter shows a dropdown per column and an Approve button; elsewhere approve(choices) is the same
    path. dataset() stops the next cell until approval happened (a headless run hands the draft on, see the module)."""

    def __init__(self, draft: Draft, conn, file: Path | None = None):
        self.draft, self.conn, self.file = draft, conn, file
        self.approved: Dataset | None = None
        self.headless: str | None = None            # what the headless rule decided: "approved", "unchanged", "draft"
        self.settled: Dataset | None = None          # an already-described dataset (opened by name): nothing to profile

    # --- what the picker shows -----------------------------------------------------------------------------------

    def suggestions(self) -> dict[str, str]:
        """{column: drafted role} (one of the eight), in table order."""
        return {column: (self.draft.doc["columns"].get(column) or {}).get("role", "other") for column in self.draft.columns()}

    def low_confidence(self) -> list[str]:
        """The columns drafted at low confidence, in table order: where the draft guessed, so a person looks first."""
        return [c for c in self.suggestions() if (self.draft.doc["columns"].get(c) or {}).get("confidence") == "low"]

    def review_order(self) -> list[str]:
        """The columns as the pickers show them: low confidence first, then the rest, each in table order. Only the
        showing changes - the descriptor keeps the table's order."""
        low = self.low_confidence()
        return low + [c for c in self.suggestions() if c not in low]

    def slot_suggestions(self) -> dict[str, str | None]:
        """{slot: drafted column or None}: the columns the notebooks use."""
        slots = self.draft.slots
        return {slot: slots.get(slot) for slot in SLOTS}

    def _profiled(self) -> dict[str, dict[str, Any]]:
        """The profiler's record per column, when the draft was made in this process."""
        return {c["column"]: c for c in (self.draft.profile or {}).get("columns", [])}

    def labels(self) -> dict[str, tuple[str, str]]:
        """{column: (summary, note)}: the column's type, role and confidence with the evidence that chose the role, and
        its model note when there is one."""
        profiled, out = self._profiled(), {}
        for column in self.suggestions():
            entry = self.draft.doc["columns"].get(column, {})
            kind = str(profiled.get(column, {}).get("type") or "")
            summary = ", ".join(part for part in (kind, f"{entry.get('role', '?')} ({entry.get('confidence', '?')} confidence): "
                                                        f"{entry.get('evidence', '')}" + ("; sensitive" if entry.get("sensitive") else "")) if part)
            out[column] = (summary, entry.get("note", ""))
        return out

    def guide(self) -> str:
        """Explain what is measured and what the user must decide, in every front end."""
        facts = self.draft.evidence.get("table") or {}
        measured, total = facts.get("profiled_rows"), facts.get("rows")
        scope = (f"Measured {measured:,} of {total:,} rows. "
                 if isinstance(measured, int) and isinstance(total, int) else "")
        return (f"Review column suggestions for {self.draft.table}\n"
                "These suggestions come from your table's column names and measured values. " + scope +
                "The rules compare types, missing values, repeated values, dates and text lengths.\n"
                "Every column gets one role:\n" +
                "\n".join(f"  {role}: {purpose}." for role, purpose in ROLE_PURPOSES.items()) +
                "\nThen the slots name the columns the notebooks use:\n" +
                "\n".join(f"  {slot}: {purpose}." for slot, purpose in SLOT_PURPOSES.items()) +
                "\nYou choose the prediction target: the kit never guesses it. Two 0/1 columns can answer "
                "different questions - pick the one that is the outcome you want to predict.\n"
                "A rule's confidence says how close the evidence is to its line; it is not a probability that the "
                "business meaning is correct. The columns drafted at low confidence come first: those are where the "
                "draft guessed, so check them before the rest. Keep useful suggestions, change the others, and leave a "
                "slot empty (—) when no column fits. Approve column map saves this column map for the next notebooks.")

    def explanations(self) -> dict[str, str]:
        """Plain reasons beside the evidence; a low-confidence role says so, and certainty is never implied."""
        slots = {column: slot for slot, column in self.slot_suggestions().items() if column}
        result = {}
        for column, role in self.suggestions().items():
            entry = self.draft.doc["columns"].get(column, {})
            if entry.get("sensitive"):
                result[column] = "Looks like personal data (an e-mail, phone number, IBAN or postcode): it is never charted, grouped or sent to a model."
                continue
            reason = f"{role.capitalize()}: {ROLE_PURPOSES.get(role, '')} ({entry.get('evidence', '')})."
            if column in slots:
                reason += f" The notebooks use it as the {slots[column]}."
            if entry.get("confidence") == "low":
                reason += f" Low confidence: the draft is a guess here ({entry.get('evidence', '')}) - check this one."
            result[column] = reason
        return result

    # --- approving -------------------------------------------------------------------------------------------------

    def approve(self, choices: dict[str, str | None] | None = None, slots: dict[str, str | None] | None = None) -> Dataset:
        """Apply the reviewed roles ({COLUMN: role}, one of the eight; the proposal when None) and slots ({slot:
        COLUMN or None}), then save and comment the approved descriptor. An earlier picker's ``date``, ``label`` and
        ``entity`` are still taken: they put the column in the time, target and entity slot."""
        roles = self.suggestions()
        chosen = self.slot_suggestions()
        unknown = sorted(set(choices or {}) - set(roles))
        if unknown:
            raise ValueError(f"The table has no column: {', '.join(unknown)}")
        for column, role in (choices or {}).items():
            if role in LEGACY_SLOT:
                chosen = {s: (None if c == column else c) for s, c in chosen.items()}
                chosen[LEGACY_SLOT[role]] = column
            elif role is None:
                roles[column] = "other"
            elif role in COLUMN_ROLES:
                roles[column] = role
            else:
                raise ValueError(f"Unknown role: {role} (the roles are {', '.join(COLUMN_ROLES)})")
        for slot, column in (slots or {}).items():
            if slot not in SLOTS:
                raise ValueError(f"Unknown slot: {slot} (the slots are {', '.join(SLOTS)})")
            if column is not None and column not in roles:
                raise ValueError(f"The table has no column: {column}")
            chosen[slot] = column
        taken: dict[str, list[str]] = {}
        for slot, column in chosen.items():
            if column:
                taken.setdefault(column, []).append(slot)
        twice = {column: names for column, names in taken.items() if len(names) > 1}
        if twice:
            column, names = next(iter(twice.items()))
            raise ValueError(f"{column} sits in two slots ({' and '.join(names)}). A column fills one slot: pick one.")
        corrected = self._corrected(roles, chosen)
        self.approved = corrected.approve(conn=self.conn)           # logs the approval to the active workflow
        self._save_beside(corrected)
        return self.approved

    def _corrected(self, roles: dict[str, str], slots: dict[str, str | None]) -> Draft:
        """The draft with the reviewed choices: the roles that changed (marked "set by you"), every slot set to its
        column or emptied with its reason."""
        corrected = self.draft.copy()
        drafted = self.suggestions()
        changed = {column: role for column, role in roles.items() if role != drafted.get(column)}
        if changed:
            corrected.set(**changed)
        reasons = dict(self.draft.doc.get("slot_evidence") or {})
        corrected.slot(**{slot: None for slot in SLOTS})               # empty first, so a column can move between slots
        for slot in SLOTS:
            if slots.get(slot):
                corrected.slot(**{slot: slots[slot]})
            else:
                kept = reasons.get(slot) if self.draft.slots.get(slot) is None else None
                corrected.doc["slot_evidence"][slot] = kept or "left empty during review"
        return corrected

    def _save_beside(self, draft: Draft, only_if_absent: bool = False) -> Path | None:
        """The descriptor beside a data file (``<name>.descriptor.yaml``), so ``DATASET = "<the file>"`` reopens it;
        with ``only_if_absent`` a file that already has one (a draft, or an earlier approval) is left alone."""
        from .own_file import descriptor_beside

        if self.file is None or (only_if_absent and descriptor_beside(self.file) is not None):
            return None
        beside = self.file.parent / f"{self.file.stem}.descriptor.yaml"
        draft.save(beside)
        word = "Approved roles" if draft.doc.get("status") == "approved" else "Proposed roles (a draft)"
        print(f"{word} saved beside {self.file.name}: {beside}")
        return beside

    # --- the headless rule -------------------------------------------------------------------------------------------

    def auto_approve(self, mode: str) -> str:
        """The headless decision for EXAKIT_NB_AUTO_APPROVE=``mode``: ``force`` approves the proposal; ``1`` approves
        only a proposal whose roles equal the current approved version's - then nothing is written (``unchanged``);
        a proposal that differs stays a ``draft`` and the reason is printed."""
        if mode == FORCE:
            print(f"{AUTO_APPROVE}={FORCE}: the headless run approves the proposed roles.")
            self.approve()
            self.headless = "approved"
            return self.headless
        roles, version = approved_roles(self.draft.id, self.file)
        if roles is not None and _differences(self.draft.roles, roles) == []:
            self.approved = dataset(self.conn, self.file if self.file is not None else self.draft.id)
            self.headless = "unchanged"
            print(f"The headless run uses {self.draft.id} v{version}, already approved with these roles: nothing is written.")
            log_event(DESCRIBE_APPROVE, descriptor_id=self.draft.id, table=self.draft.table, version=version,
                      roles=self.draft.roles, unchanged=True)
            return self.headless
        self.headless = "draft"
        why = (f"its roles differ from the approved v{version} ({'; '.join(_differences(self.draft.roles, roles))})"
               if roles is not None else "nothing is approved for it yet")
        print(f"The headless run leaves {self.draft.id} a draft: {why}. The steps below run on the draft; a step that "
              f"needs an approval says so. To approve it on purpose: {AUTO_APPROVE}={FORCE}, or exakit describe "
              f"{self.draft.id} --approve")
        return self.headless

    def _draft_dataset(self) -> Dataset:
        """The proposal as a Dataset with status draft (checked against the database like any descriptor); a data
        file whose draft was saved beside it is opened by that file, as the next notebook opens it."""
        from .own_file import descriptor_beside

        if self.settled is not None:
            return self.settled
        if self.file is not None and descriptor_beside(self.file) is not None:
            return dataset(self.conn, self.file)
        doc = self.draft.to_dict()
        doc.setdefault("status", "draft")
        raw = json.dumps(doc, indent=2, sort_keys=True, default=str).encode("utf-8")
        path = self.file if self.file is not None else Path(f"{self.draft.id}.descriptor.yaml")
        return checked(self.conn, raw, path, remedy="Correct the proposed roles (review.approve({...})).",
                       origin="beside" if self.file is not None else "explicit")

    # --- the handover to the next cell --------------------------------------------------------------------------------

    def _already_approved(self) -> Dataset | None:
        """The approved version the review was opened on, when nobody clicked Approve: nothing is waiting for a person."""
        if self.approved is None and self.draft.status == "approved":
            self.approved = dataset(self.conn, self.file if self.file is not None else self.draft.id)
            print(f"Using the approved roles of {self.approved.id} v{self.approved.version}. To change them, set the "
                  "dropdowns above, click Approve column map and run this cell again.")
        return self.approved

    def dataset(self, draft_ok: bool = False) -> Dataset:
        """The approved dataset: the one approved here, else the approved version the review opened on. Before an
        approval: a headless run (or ``draft_ok``) gets the proposal as a draft Dataset; a person is told to approve
        first, in one line."""
        if self._already_approved() is not None:
            remember_dataset(self.approved)                     # the later notebooks carry on with it
            return self.approved
        if draft_ok or self.headless == "draft":
            return self._draft_dataset()
        raise ApprovalNeeded("Not approved yet: check the dropdowns above, click Approve column map, then run this cell "
                             "again (plain Python: review.approve({...})).")

    # --- the front ends ------------------------------------------------------------------------------------------------

    def show(self):
        """Print the proposal with its evidence, then the picker the front end has (or the headless decision)."""
        print(self.guide())
        self.draft.show()
        mode = os.environ.get(AUTO_APPROVE, "")
        if mode:
            self.auto_approve(mode)
            return self
        widget = self.jupyter_picker()
        if widget is not None:
            from IPython.display import display
            display(widget)
            return self
        print("Review with review.approve({'COLUMN': 'role', ...}, {'slot': 'COLUMN', ...}); the roles are "
              f"{', '.join(COLUMN_ROLES)}, the slots {', '.join(SLOTS)} (None leaves a slot empty).")
        return self

    def jupyter_picker(self):
        """The ipywidgets picker, or None when this is not a Jupyter kernel with ipywidgets."""
        try:
            from IPython import get_ipython
            import ipywidgets as widgets
            shell = get_ipython()
            if shell is None or getattr(shell, "kernel", None) is None:
                raise ImportError("no Jupyter kernel")
        except ImportError:
            return None
        try:            # the kit's own dropdown (the guided cards' look), in place of ipywidgets.Dropdown
            from types import SimpleNamespace

            from .picklist import PickList

            widgets = SimpleNamespace(Dropdown=PickList, HTML=widgets.HTML, VBox=widgets.VBox, Button=widgets.Button,
                                      Output=widgets.Output)
        except ImportError:
            pass
        return self.build_jupyter_picker(widgets)

    def build_jupyter_picker(self, widgets):
        """One dropdown per column with the eight roles (the drafted one set), its reason and evidence under it - the
        columns drafted at low confidence first, under their own heading; then one dropdown per slot with the table's
        columns; then the Approve button. ``widgets`` is ipywidgets (or a stand-in)."""
        labels, explanations, suggested = self.labels(), self.explanations(), self.suggestions()
        low = self.low_confidence()
        pickers, slot_pickers, rows = {}, {}, [widgets.HTML("<b>Column roles</b>")]
        for column in self.review_order():
            role = suggested[column]
            if column == (low or [None])[0]:
                rows.append(widgets.HTML(f"<b>Check these first</b> - {len(low)} drafted at low confidence, where the draft guessed"))
            elif low and column == next(c for c in self.review_order() if c not in low):
                rows.append(widgets.HTML("<b>The rest</b> - drafted at high confidence"))
            summary, runner = labels[column]
            picker = widgets.Dropdown(options=[(r, r, ROLE_HINTS.get(r, "")) for r in COLUMN_ROLES], value=role,
                                      description=column, style={"description_width": "180px"})
            pickers[column] = picker
            note = " &middot; ".join(escape(part) for part in (summary, runner) if part)
            why = escape(explanations[column])
            rows.append(widgets.VBox([picker, widgets.HTML(f"{why}<br><small>Technical evidence: {note}</small>")]))
        rows.append(widgets.HTML("<b>What the notebooks use</b> - one column per slot, or — to leave it empty"))
        columns = list(self.suggestions())
        reasons = self.draft.doc.get("slot_evidence") or {}
        for slot, column in self.slot_suggestions().items():
            picker = widgets.Dropdown(options=[(NONE_LABEL, None), *[(c, c) for c in columns]], value=column,
                                      description=slot, style={"description_width": "180px"})
            slot_pickers[slot] = picker
            hint = SLOT_PURPOSES[slot] + (f" (empty: {reasons[slot]})" if column is None and reasons.get(slot) else "")
            rows.append(widgets.VBox([picker, widgets.HTML(f"<small>{escape(hint)}</small>")]))
        button = widgets.Button(description="Approve column map", button_style="success")
        output = widgets.Output()

        def clicked(_):
            with output:
                output.clear_output()
                try:
                    self.approve({column: picker.value for column, picker in pickers.items()},
                                 {slot: picker.value for slot, picker in slot_pickers.items()})
                    print(f"Approved {self.approved.id} v{self.approved.version}. Run the next cell.")
                except (ValueError, RuntimeError) as err:
                    print(f"Could not approve: {err}")

        button.on_click(clicked)
        return widgets.VBox([*rows, button, output])


def marimo_review(mo, draft: Draft, conn, file: Path | None = None) -> RoleReview:
    """The review as a Marimo element: a ``mo.ui.dictionary`` of one ``mo.ui.dropdown`` per column plus a
    ``mo.ui.run_button``, so the cell ``ds = review.dataset()`` runs again on every change and the approval is computed
    when the button was clicked; until then it stops that cell cleanly. ``mo`` is the marimo module (or a stand-in)."""

    class MarimoRoleReview(RoleReview, mo.ui.dictionary):
        def __init__(self, draft, conn, file):
            RoleReview.__init__(self, draft, conn, file)
            kit_list = _kit_list(mo)
            labels, explanations, suggested = self.labels(), self.explanations(), self.suggestions()
            low = self.low_confidence()
            dropdowns = {}
            for column in self.review_order():                   # low confidence first: a dictionary keeps its order
                role = suggested[column]
                summary, runner = labels[column]
                label = (("**Check first** - drafted at low confidence<br>" if column in low else "") +
                         f"**{escape(column)}**<br>{escape(explanations[column])}" +
                         (f"<br>Technical evidence: {escape(summary)}" if summary else "") +
                         (f"<br>{escape(runner)}" if runner else ""))
                if kit_list:      # the kit's own dropdown: the column, its explanation and evidence under it
                    note = " · ".join(part for part in (explanations[column], summary, runner) if part)
                    dropdowns[column] = mo.ui.anywidget(kit_list(
                        [(r, r, ROLE_HINTS.get(r, "")) for r in COLUMN_ROLES], value=role, note=note,
                        description=("Check first: " if column in low else "") + column))
                else:
                    dropdowns[column] = mo.ui.dropdown(options={r: r for r in COLUMN_ROLES}, value=role, label=label)
            columns = list(self.suggestions())
            if kit_list:
                slot_dropdowns = {slot: mo.ui.anywidget(kit_list([(NONE_LABEL, None), *[(c, c) for c in columns]], value=column,
                                                                 description=slot, note=SLOT_PURPOSES[slot]))
                                  for slot, column in self.slot_suggestions().items()}
            else:
                slot_dropdowns = {slot: mo.ui.dropdown(options={NONE_LABEL: None, **{c: c for c in columns}},
                                                       value=column or NONE_LABEL,
                                                       label=f"**{slot}**: {escape(SLOT_PURPOSES[slot])}")
                                  for slot, column in self.slot_suggestions().items()}
            mo.ui.dictionary.__init__(self, {"roles": mo.ui.dictionary(dropdowns),
                                             "slots": mo.ui.dictionary(slot_dropdowns),
                                             "approve": mo.ui.run_button(label="Approve column map")},
                                      label=f"Roles of {draft.table}" + (f" - the {len(low)} drafted at low "
                                                                          "confidence come first" if low else ""))

        def choices(self) -> dict[str, str | None]:
            values = self.value or {}
            roles = values.get("roles") or {}
            return {column: _picked(roles.get(column)) for column in self.draft.columns()}

        def slot_choices(self) -> dict[str, str | None]:
            values = self.value or {}
            slots = values.get("slots") or {}
            return {slot: _picked(slots.get(slot)) for slot in SLOTS}

        def dataset(self, draft_ok: bool = False) -> Dataset:
            if (self.value or {}).get("approve"):                  # the button was clicked: compute the approval now
                self.approve(self.choices(), self.slot_choices())
            if self._already_approved() is not None:
                remember_dataset(self.approved)
                return self.approved
            if draft_ok or self.headless == "draft":
                return self._draft_dataset()
            mo.stop(True, mo.md("Check the role of each column and the slots above, then click **Approve column map**; the "
                                "cells below run then."))
            raise RuntimeError("Approve the roles first.")          # not reached: mo.stop raises

        def show(self):
            print(self.guide())
            self.draft.show()
            mode = os.environ.get(AUTO_APPROVE, "")
            if mode:
                self.auto_approve(mode)
            else:
                mo.output.append(self)
            return self

    return MarimoRoleReview(draft, conn, file)


def _kit_list(mo):
    """The kit's dropdown widget when this marimo can show an anywidget (mo.ui.anywidget), else None: the plain
    mo.ui.dropdown is used then."""
    if not hasattr(getattr(mo, "ui", None), "anywidget"):
        return None
    try:
        from .picklist import PickList
    except ImportError:
        return None
    return PickList


def _picked(value):
    """A pick as the review reads it: mo.ui.anywidget's value is the widget's state ({"value": ...})."""
    return value.get("value") if isinstance(value, dict) and "value" in value else value


def _marimo():
    """The marimo module when this runs inside a Marimo notebook, else None."""
    try:
        import marimo as mo
    except ImportError:
        return None
    return mo if mo.running_in_notebook() else None


def _default_table(file: Path) -> str:
    """``MY_DATA.<FILE STEM>`` as a plain SQL name: what a data file named by a notebook's assignment loads into."""
    stem = re.sub(r"[^A-Z0-9]+", "_", file.stem.upper()).strip("_") or "DATA"
    return f"{DEFAULT_SCHEMA}.{stem if stem[0].isalpha() else 'T_' + stem}"


def _open(conn, name: str):
    """A notebook's one assignment as what review_roles reviews: a described dataset (settled), or a data file with no
    descriptor beside it, loaded into its default table (a LoadedTable, to be profiled)."""
    from .own_file import descriptor_beside, load_own_file

    from .sources import clean_path

    name = clean_path(name) or name
    given = Path(name)
    if given.is_file() and given.suffix.lower() in DATA_FILES and descriptor_beside(given) is None:
        table = _default_table(given)
        print(f"{given.name} has no descriptor beside it: loading it into {table} and proposing its roles here. "
              "(The quickstart's MY_DATA cell does the same, into the schema MY_SCHEMA names.)")
        return load_own_file(given, table, conn=conn), False
    return dataset(conn, name), True


def review_roles(conn, source: Any) -> RoleReview:
    """Profile the loaded sample, file or connected table, show evidence and role choices, then await approval. Given
    a name (a notebook's one assignment: a dataset id, a descriptor file, a data file with its roles beside it) the
    dataset is opened as it is described and nothing is profiled; a data file with no descriptor beside it is loaded
    and reviewed here."""
    from .own_file import LoadedTable

    settled = False
    if isinstance(source, (str, Path)):
        source, settled = _open(conn, str(source))
    if settled:
        review = RoleReview(Draft({"id": source.id, "fact_table": source.fact_table, "status": source.status,
                                   "version": source.version}), conn)
        review.settled = source
        if source.status == "approved":
            review.approved = source
            print(f"{source.id} v{source.version} is approved: nothing to review.")
        else:
            review.headless = "draft"
            print(f"{source.id} v{source.version} is a draft: the cells run on its proposed roles. To approve them run the "
                  f"quickstart's MY_DATA cell with this file, or: exakit describe {source.id} --approve")
        return review
    proposal = describe(source.fact_table, conn=conn, id=source.id)
    log_event(DESCRIBE_DRAFT, descriptor_id=proposal.id, table=proposal.table, roles=proposal.roles,
              missing=[m.get("role") for m in proposal.missing])
    file = None
    if isinstance(source, LoadedTable) and source.path.is_file():
        file = source.path
    elif isinstance(source, Dataset) and source.descriptor_origin == "beside" and source.path.is_file():
        file = source.path
    mo = _marimo()
    review = marimo_review(mo, proposal, conn, file) if mo is not None else RoleReview(proposal, conn, file)
    review._save_beside(proposal, only_if_absent=True)          # the draft beside a file: the assignment reopens it
    return review.show()
