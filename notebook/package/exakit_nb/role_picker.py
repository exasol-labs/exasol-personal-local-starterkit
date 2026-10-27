"""Review the profiler's proposed roles in a notebook and approve a versioned descriptor (DS-5, design 2.2).

    review = nb.review_roles(conn, ds)        # profiles the table, prints the evidence, shows the picker
    ds = review.dataset()                     # the approved dataset; waits for the approval

The picker is one dropdown per column, each labelled with the column's evidence (type, null share, distinct values or
span) and, under it, the runner-up for the role it was proposed for, plus an Approve button. In JupyterLab it is
ipywidgets; in Marimo the review itself is a ``mo.ui.dictionary`` of ``mo.ui.dropdown`` with a ``mo.ui.run_button``, so
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
from pathlib import Path
from typing import Any

from .dataset import DATA_FILES, Dataset, _locate, checked, dataset
from .describe import Draft, ROLES, describe
from .workflow import DESCRIBE_APPROVE, DESCRIBE_DRAFT, log_event

__all__ = ["RoleReview", "review_roles"]

AUTO_APPROVE = "EXAKIT_NB_AUTO_APPROVE"
FORCE = "force"
DEFAULT_SCHEMA = "MY_DATA"             # where a data file named by a notebook's assignment loads, as the quickstart's OWN_TABLE
NONE_LABEL = "—"                  # the dropdown entry for a column that plays no role


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
    return ", ".join(parts)


class RoleReview:
    """One proposal. Jupyter shows a dropdown per column and an Approve button; elsewhere approve(choices) is the same
    path. dataset() stops the next cell until approval happened (a headless run hands the draft on, see the module)."""

    def __init__(self, draft: Draft, conn, file: Path | None = None):
        self.draft, self.conn, self.file = draft, conn, file
        self.approved: Dataset | None = None
        self.headless: str | None = None            # what the headless rule decided: "approved", "unchanged", "draft"
        self.settled: Dataset | None = None          # an already-described dataset (opened by name): nothing to profile

    # --- what the picker shows -----------------------------------------------------------------------------------

    def suggestions(self) -> dict[str, str | None]:
        """{column: proposed role or None}, in table order."""
        assigned: dict[str, str | None] = {column: None for column in self.draft.columns()}
        for role, value in self.draft.roles.items():
            for column in value if isinstance(value, list) else [value]:
                assigned[column] = role
        return assigned

    def _profiled(self) -> dict[str, dict[str, Any]]:
        """The profiler's record per column, when the draft was made in this process."""
        return {c["column"]: c for c in (self.draft.profile or {}).get("columns", [])}

    def labels(self) -> dict[str, tuple[str, str]]:
        """{column: (evidence summary, runner-up line)} from the draft's evidence: the chosen column's numbers for a
        role it plays (the profile's for the others), the role's runner-up under the column it was proposed for."""
        evidence, profiled = self.draft.evidence, self._profiled()
        by_column: dict[str, dict[str, Any]] = {}
        for role, entry in evidence.items():
            if role == "text" and isinstance(entry, dict):
                for item in entry.get("columns") or []:
                    if isinstance(item, dict) and item.get("column"):
                        by_column.setdefault(str(item["column"]), {}).update(item)
            elif isinstance(entry, dict) and entry.get("column"):
                by_column.setdefault(str(entry["column"]), {}).update(entry)
        excluded = evidence.get("excluded") if isinstance(evidence.get("excluded"), dict) else {}
        out = {}
        for column, role in self.suggestions().items():
            summary = evidence_summary(by_column.get(column) or profiled.get(column) or {})
            if column in excluded:
                summary = f"{summary}; excluded: {excluded[column]}" if summary else f"excluded: {excluded[column]}"
            runner = ""
            entry = evidence.get(role) if role else None
            candidate = entry.get("runner_up") if isinstance(entry, dict) else None
            if isinstance(candidate, dict) and candidate.get("column"):
                score = f" ({candidate['score']})" if candidate.get("score") is not None else ""
                runner = f"runner-up for {role}: {candidate['column']}{score}"
            out[column] = (summary, runner)
        return out

    # --- approving -------------------------------------------------------------------------------------------------

    def approve(self, choices: dict[str, str | None] | None = None) -> Dataset:
        """Apply column -> role choices (the proposal when None), then save and comment the approved descriptor."""
        selected = self.suggestions() if choices is None else choices
        unknown = sorted(set(selected) - set(self.draft.columns()))
        if unknown:
            raise ValueError(f"The table has no column: {', '.join(unknown)}")
        invalid = sorted({role for role in selected.values() if role is not None and role not in ROLES})
        if invalid:
            raise ValueError(f"Unknown role: {', '.join(invalid)}")
        groups: dict[str, list[str]] = {role: [] for role in ROLES}
        for column, role in selected.items():
            if role:
                groups[role].append(column)
        for role in ROLES:
            if role != "text" and len(groups[role]) > 1:
                raise ValueError(f"The {role} role has two columns: {', '.join(groups[role])}. Pick one.")
        corrected = self._corrected(groups)
        self.approved = corrected.approve(conn=self.conn)
        log_event(DESCRIBE_APPROVE, descriptor_id=corrected.id, table=corrected.table,
                  version=getattr(self.approved, "version", corrected.doc.get("version")),
                  digest=corrected.doc.get("digest"), roles=corrected.roles, unchanged=False)
        self._save_beside(corrected)
        return self.approved

    def _corrected(self, groups: dict[str, list[str]]) -> Draft:
        doc = self.draft.to_dict()
        doc["roles"] = {}
        doc["missing"] = []
        corrected = Draft(doc, self.draft.profile)
        original = self.draft.roles
        for role in ROLES:
            columns = groups[role]
            if columns:
                chosen = columns if role == "text" else columns[0]
                corrected.set(role, chosen)
                if chosen == original.get(role):
                    evidence = self.draft.evidence.get(role)
                    if evidence is not None:
                        corrected.doc.setdefault("evidence", {})[role] = evidence
            else:
                old = next((m.get("reason") for m in self.draft.missing if m.get("role") == role), None)
                corrected.doc["missing"].append({"role": role, "reason": old or "left unassigned during review"})
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

    def dataset(self, draft_ok: bool = False) -> Dataset:
        """The approved dataset. Before approval: a headless run (or ``draft_ok``) gets the proposal as a draft
        Dataset; a person is told to approve first."""
        if self.approved is not None:
            return self.approved
        if draft_ok or self.headless == "draft":
            return self._draft_dataset()
        raise RuntimeError("Review the proposed roles and click Approve descriptor, or call review.approve({...}) first.")

    # --- the front ends ------------------------------------------------------------------------------------------------

    def show(self):
        """Print the proposal with its evidence, then the picker the front end has (or the headless decision)."""
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
        print("Review with review.approve({'COLUMN': 'role', ...}); use None to leave a column unassigned.")
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
        return self.build_jupyter_picker(widgets)

    def build_jupyter_picker(self, widgets):
        """One dropdown per column, labelled with the column, its evidence and the runner-up under it, then the
        Approve button. ``widgets`` is the ipywidgets module (or a stand-in)."""
        labels = self.labels()
        pickers, rows = {}, []
        for column, role in self.suggestions().items():
            summary, runner = labels[column]
            picker = widgets.Dropdown(options=[(NONE_LABEL, None), *[(r, r) for r in ROLES]], value=role,
                                      description=column, style={"description_width": "180px"})
            pickers[column] = picker
            note = " &middot; ".join(part for part in (summary, runner) if part)
            rows.append(widgets.VBox([picker, widgets.HTML(f"<small>{note}</small>")]) if note else picker)
        button = widgets.Button(description="Approve descriptor", button_style="success")
        output = widgets.Output()

        def clicked(_):
            with output:
                output.clear_output()
                try:
                    self.approve({column: picker.value for column, picker in pickers.items()})
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
            labels = self.labels()
            dropdowns = {}
            for column, role in self.suggestions().items():
                summary, runner = labels[column]
                label = f"**{column}**" + (f" &middot; {summary}" if summary else "") + (f"<br>{runner}" if runner else "")
                dropdowns[column] = mo.ui.dropdown(options={NONE_LABEL: None, **{r: r for r in ROLES}},
                                                   value=role or NONE_LABEL, label=label)
            mo.ui.dictionary.__init__(self, {"roles": mo.ui.dictionary(dropdowns),
                                             "approve": mo.ui.run_button(label="Approve descriptor")},
                                      label=f"Roles of {draft.table}")

        def choices(self) -> dict[str, str | None]:
            values = self.value or {}
            roles = values.get("roles") or {}
            return {column: roles.get(column) for column in self.draft.columns()}

        def dataset(self, draft_ok: bool = False) -> Dataset:
            if (self.value or {}).get("approve"):                  # the button was clicked: compute the approval now
                self.approve(self.choices())
            if self.approved is not None:
                return self.approved
            if draft_ok or self.headless == "draft":
                return self._draft_dataset()
            mo.stop(True, mo.md("Pick a role per column above and click **Approve descriptor**; the cells below run then."))
            raise RuntimeError("Approve the roles first.")          # not reached: mo.stop raises

        def show(self):
            self.draft.show()
            mode = os.environ.get(AUTO_APPROVE, "")
            if mode:
                self.auto_approve(mode)
            else:
                mo.output.append(self)
            return self

    return MarimoRoleReview(draft, conn, file)


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

    given = Path(name).expanduser()
    if given.is_file() and given.suffix.lower() in DATA_FILES and descriptor_beside(given) is None:
        table = _default_table(given)
        print(f"{given.name} has no descriptor beside it: loading it into {table} and proposing its roles here. "
              "(The quickstart's OWN_FILE cell does the same with a table name of your choice.)")
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
                  f"quickstart's OWN_FILE cell with this file, or: exakit describe {source.id} --approve")
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
