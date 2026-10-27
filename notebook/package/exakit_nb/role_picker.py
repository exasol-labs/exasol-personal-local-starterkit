"""Review the profiler's proposed roles in a notebook and approve a versioned descriptor."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .describe import Draft, ROLES, describe

__all__ = ["RoleReview", "review_roles"]


class RoleReview:
    """One proposal. Jupyter shows a dropdown per column and an Approve button; elsewhere approve(choices)
    is the same path. dataset() stops the next cell until approval happened."""

    def __init__(self, draft: Draft, conn, file: Path | None = None):
        self.draft, self.conn, self.file = draft, conn, file
        self.approved = None

    def suggestions(self) -> dict[str, str | None]:
        assigned: dict[str, str | None] = {column: None for column in self.draft.columns()}
        for role, value in self.draft.roles.items():
            for column in value if isinstance(value, list) else [value]:
                assigned[column] = role
        return assigned

    def approve(self, choices: dict[str, str | None] | None = None):
        """Apply column -> role choices, then save and comment the approved descriptor."""
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
        self.approved = corrected.approve(conn=self.conn)
        if self.file is not None:
            beside = self.file.parent / f"{self.file.stem}.descriptor.yaml"
            corrected.save(beside)
            print(f"Approved roles saved beside {self.file.name}: {beside}")
        return self.approved

    def dataset(self):
        if self.approved is None:
            raise RuntimeError("Review the proposed roles and click Approve descriptor, or call review.approve({...}) first.")
        return self.approved

    def show(self):
        self.draft.show()
        if os.environ.get("EXAKIT_NB_AUTO_APPROVE") == "1":
            print("The headless notebook run approves the proposed roles.")
            self.approve()
            return self
        try:
            from IPython import get_ipython
            from IPython.display import display
            import ipywidgets as widgets
            shell = get_ipython()
            if shell is None or getattr(shell, "kernel", None) is None:
                raise ImportError("no Jupyter kernel")
        except ImportError:
            print("Review with review.approve({'COLUMN': 'role', ...}); use None to leave a column unassigned.")
            return self
        pickers = {column: widgets.Dropdown(options=[("—", None), *[(r, r) for r in ROLES]],
                                             value=role, description=column, style={"description_width": "180px"})
                   for column, role in self.suggestions().items()}
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
        display(widgets.VBox([*pickers.values(), button, output]))
        return self


def review_roles(conn, source: Any) -> RoleReview:
    """Profile the loaded sample, file or connected table, show evidence and role choices, then await approval."""
    proposal = describe(source.fact_table, conn=conn, id=source.id)
    from .own_file import LoadedTable
    return RoleReview(proposal, conn, source.path if isinstance(source, LoadedTable) and source.path.is_file() else None).show()
