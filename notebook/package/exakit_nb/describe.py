"""Describe a table from a notebook (DS-2, DS-5): the role-per-column descriptor of setup/lib/descriptor.

    d = exakit_nb.describe("AMAZON.ORDER_LINES")    # profile, draft v(n+1), show the table
    d.set(PRODUCT="category", ZIP_CODE="identifier")  # corrections, chainable
    d.slot(target="TIMELY_RESPONSE")                  # target=None leaves it empty on purpose
    ds = d.approve()                                  # check, write, publish; the Dataset read back

describe() on a table whose approved descriptor still matches it returns that one (force=True profiles again);
otherwise the table is profiled once, in SQL, and every column gets one of eight roles with the evidence that chose
it; the slots name the columns the notebooks use. show() lists column, type, role, confidence, evidence and note,
low confidence first, the slots above. approve() checks every column has a role and none sits in two slots, checks
the table has not changed since it was profiled, writes the next version into the kit's store and publishes the
roles as column comments on a view in EXAKIT_SEMANTIC (a publish that fails leaves the approval standing, and says
why). The active workflow's log gets one line.

The work is the kit's own service, setup/lib/describe_service.py in the kit copy (the one `exakit describe` runs),
loaded from its file and run in this process over the kit's connection; without the kit copy, `exakit describe
--json` runs as a child process instead.

The role review (role_picker) speaks the five roles of earlier descriptors - entity, category, date, label, text - so
``roles``, ``evidence``, ``missing`` and ``set(role, column)`` read and write the matching slots: date is the time
slot and label the target.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
from pathlib import Path
from typing import Any

from ._kit import exakit_command, setting

SAMPLE = 10000                          # accepted for the earlier signature; a virtual table is read as its first 10,000 rows
ROLES = ("entity", "category", "date", "label", "text")
SINGLE_ROLES = ("entity", "category", "date", "label")
SLOT_OF = {"entity": "entity", "category": "category", "date": "time", "label": "target", "text": "text"}
COLUMN_ROLES = ("key", "time", "measure", "category", "flag", "text", "identifier", "other")
SLOTS = ("key", "time", "text", "target", "category", "entity")

__all__ = ["Draft", "describe", "describe_service"]


def describe_service():
    """The kit's describe service (setup/lib/describe_service.py), loaded from the kit copy's file - or from the
    checkout this package sits in; None when neither is there."""
    candidates = []
    kit = setting("EXAKIT_NB_KIT")
    if kit:
        candidates.append(Path(kit) / "setup" / "lib" / "describe_service.py")
    candidates.append(Path(__file__).resolve().parents[3] / "setup" / "lib" / "describe_service.py")
    for path in candidates:
        if path.is_file():
            spec = importlib.util.spec_from_file_location("exakit_describe_service", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)          # type: ignore[union-attr]
            return module
    return None


def _resolve(name: str) -> tuple[str, str | None]:
    """(table, dataset id or None) for ``SCHEMA.TABLE`` or a shipped dataset id (its descriptor's table)."""
    if "." in name:
        return name, None
    from . import descriptor_rules
    datasets = setting("EXAKIT_NB_DATASETS")
    folder = Path(datasets) / name if datasets else None
    if folder is not None and folder.is_dir():
        path = descriptor_rules.descriptor_file(folder)
        if path is not None:
            return descriptor_rules.read_descriptor(path).fact_table, name
    from .descriptor_store import current_descriptor
    stored = current_descriptor(name)
    if stored is not None:
        return descriptor_rules.read_descriptor(stored).fact_table, name
    raise ValueError(f"'{name}' is neither SCHEMA.TABLE nor a dataset id the kit knows.")


def describe(table_or_dataset: str, sample: int = SAMPLE, *, conn=None, id: str | None = None, force: bool = False) -> "Draft":
    """Describe ``SCHEMA.TABLE`` (or a dataset id's table): the approved descriptor when the table still matches it,
    else a fresh draft. Uses the connection given, else opens the kit's. Only SELECTs run."""
    table, slug = _resolve(str(table_or_dataset))
    service = describe_service()
    if service is not None:
        own = conn is None
        if own:
            from . import connect
            conn = connect()
        try:
            found = service.describe(conn, table, dataset=id or slug, force=force)
        finally:
            if own:
                conn.close()
        if found["status"] == "draft":                       # step 7: a model's one line per column, when one is set up
            service.with_notes(found["doc"], service.model_notes(found["doc"], found["profile"]))
        return Draft(found["doc"], found.get("profile"), changed=found.get("changed") or [])
    command = exakit_command()
    if command is None:
        raise RuntimeError("The kit's describe service was not found (no kit copy beside this Python and exakit's launcher is "
                           "not on PATH); install the notebook add-on: exakit marketplace notebook")
    args = [*command, "describe", table, "--json"] + (["--id", id or slug] if id or slug else [])
    run = subprocess.run(args, capture_output=True, text=True)
    if run.returncode != 0:
        raise RuntimeError(f"exakit describe failed (exit {run.returncode}): {(run.stderr or run.stdout).strip()}")
    found = json.loads(run.stdout)
    return Draft(found["doc"], None, changed=found.get("changed") or [])


class Draft:
    """A descriptor proposed for a table (status draft), or the approved one describe() returned."""

    def __init__(self, doc: dict[str, Any], profile: dict[str, Any] | None = None, *, changed: list[str] | None = None):
        self.doc = doc
        self.profile = profile
        self.changed = list(changed or [])

    # --- what it says ------------------------------------------------------------------------------------------------

    @property
    def id(self) -> str:
        return str(self.doc["dataset"])

    @property
    def table(self) -> str:
        return str(self.doc["source"]["object"])

    @property
    def version(self) -> int:
        return int(self.doc.get("version") or 1)

    @property
    def status(self) -> str:
        return str(self.doc.get("status"))

    @property
    def slots(self) -> dict[str, str | None]:
        return dict(self.doc.get("slots") or {})

    @property
    def column_roles(self) -> dict[str, str]:
        return {name: entry["role"] for name, entry in self.doc["columns"].items()}

    @property
    def roles(self) -> dict[str, Any]:
        """The five roles of earlier descriptors, read from the slots: {role: column}, {text: [column]}."""
        out: dict[str, Any] = {}
        for role, slot in SLOT_OF.items():
            column = self.slots.get(slot)
            if column:
                out[role] = [column] if role == "text" else column
        return out

    @property
    def evidence(self) -> dict[str, Any]:
        """Per role, the column with its role, confidence and the evidence that chose it, plus the profile's numbers."""
        numbers = {c["column"]: c for c in (self.profile or {}).get("columns", [])}
        out: dict[str, Any] = {}
        for role, value in self.roles.items():
            for column in value if isinstance(value, list) else [value]:
                entry = {"column": column, **self.doc["columns"].get(column, {})}
                facts = numbers.get(column) or {}
                entry.update({k: v for k, v in (("type", facts.get("type")), ("distinct", facts.get("approx_distinct")),
                                                 ("avg_len", facts.get("avg_length"))) if v is not None})
                if role == "text":
                    out.setdefault("text", {"columns": []})["columns"].append(entry)
                else:
                    out[role] = entry
        if self.profile:
            out["table"] = {"rows": self.profile["source"]["profiled_rows"], "profiled_rows": self.profile["source"]["profiled_rows"],
                            "statements": len(self.profile.get("statements") or [])}
        return out

    @property
    def missing(self) -> list[dict[str, str]]:
        """The roles no column plays, each with the reason the empty slot gives."""
        why = self.doc.get("slot_evidence") or {}
        return [{"role": role, "reason": why.get(slot) or f"no {slot} column is set"}
                for role, slot in SLOT_OF.items() if not self.slots.get(slot)]

    @property
    def notes(self) -> dict[str, str]:
        return {name: entry["note"] for name, entry in self.doc["columns"].items() if entry.get("note")}

    def columns(self) -> list[str]:
        """The table's columns, in table order."""
        return list(self.doc["columns"])

    # --- corrections -------------------------------------------------------------------------------------------------

    def _column(self, name: str) -> str:
        if name in self.doc["columns"]:
            return name
        if name.upper() in self.doc["columns"]:
            return name.upper()
        raise ValueError(f"{self.table} has no column '{name}' (it has: {', '.join(self.doc['columns'])}).")

    def set(self, role: str | None = None, column: str | list[str] | None = None, **columns: str) -> "Draft":
        """``set(COLUMN="role", ...)`` gives columns a role (one of the eight); ``set("label", "COLUMN")``, the form of
        earlier descriptors, puts a column in that role's slot. Chainable."""
        if role is not None:
            if role not in ROLES:
                raise ValueError(f"'{role}' is not a role (the roles are {', '.join(ROLES)}; or set(COLUMN=role) with one "
                                 f"of {', '.join(COLUMN_ROLES)}).")
            chosen = column[0] if isinstance(column, (list, tuple)) and column else column
            return self.slot(**{SLOT_OF[role]: chosen})
        for name, value in columns.items():
            if value not in COLUMN_ROLES:
                raise ValueError(f"'{value}' is not a role; the roles are {', '.join(COLUMN_ROLES)}.")
            name = self._column(name)
            self.doc["columns"][name] = dict(self.doc["columns"][name], role=value, confidence="high", evidence="set by you")
        return self

    def slot(self, **slots: str | None) -> "Draft":
        """Put a column in a slot (key, time, text, target, category, entity), or None to leave it empty on purpose."""
        for name, column in slots.items():
            if name not in SLOTS:
                raise ValueError(f"'{name}' is not a slot; the slots are {', '.join(SLOTS)}.")
            chosen = None if column is None else self._column(str(column))
            taken = next((s for s, c in self.slots.items() if c == chosen and s != name and chosen), None)
            if taken:
                raise ValueError(f"{chosen} already sits in the {taken} slot; empty that one first.")
            self.doc["slots"][name] = chosen
            why = self.doc.setdefault("slot_evidence", {})
            if chosen is None:
                why[name] = "left empty by you"
            else:
                why.pop(name, None)
        return self

    def assign(self, role: str, column: str | list[str] | None, reason: str | None = None) -> "Draft":
        """The role review's correction: ``role`` (one of the five) to ``column``, or empty with ``reason``."""
        slot = SLOT_OF[role]
        chosen = column[0] if isinstance(column, (list, tuple)) and column else column
        self.slot(**{slot: chosen or None})
        if not chosen and reason:
            self.doc["slot_evidence"][slot] = reason
        return self

    def copy(self) -> "Draft":
        return Draft(copy.deepcopy(self.doc), self.profile, changed=self.changed)

    # --- keeping and approving ---------------------------------------------------------------------------------------

    def to_dict(self) -> dict[str, Any]:
        """The descriptor document (a copy)."""
        return copy.deepcopy(self.doc)

    def to_yaml(self) -> str:
        service = describe_service()
        if service is None:
            raise RuntimeError("The kit's describe service was not found; install the notebook add-on: exakit marketplace notebook")
        return service.drafting.to_yaml(self.doc)

    def save(self, path: str | Path) -> Path:
        """Write the descriptor as YAML; exakit_nb.dataset(conn, path) reads it back."""
        target = Path(path).expanduser()
        target.write_text(self.to_yaml(), encoding="utf-8")
        return target

    def approve(self, owner: str | None = None, comments: bool = True, *, conn=None, sample: int | None = None):
        """Approve: every column has a role and none sits in two slots, the table has not changed since it was
        profiled, the next version is written into the kit's store with current.yaml, and the roles are published on
        a view in EXAKIT_SEMANTIC (``comments=False`` skips it). ``owner`` defaults to EXAKIT_DESCRIPTOR_OWNER or the
        OS user. Returns the Dataset read back from the store."""
        from .dataset import dataset
        from .workflow import log_event

        service = describe_service()
        if service is None:
            raise RuntimeError("The kit's describe service was not found (no kit copy beside this Python); approve on the "
                               f"command line: exakit describe {self.id} --approve")
        own = conn is None
        if own:
            from . import connect
            conn = connect()
        try:
            result = service.approve_document(conn, self.to_dict(), owner=owner, publish=comments, log=log_event)
            if result["status"] == "unchanged":
                # Nothing new, but this run uses that approval: say where it is, as an approval does.
                print(f"{result['table']} v{result['version']} already says this; nothing was written.")
                print(f"Stored at: {result['path']}")
                if result.get("published"):
                    print(f"Published as {result['published']}: agents read the roles from its column comments.")
            else:
                print(f"Approved {result['table']} v{result['version']} (owner {result['owner']}): {result['path']}")
                if result.get("published"):
                    print(f"Published as {result['published']}: agents read the roles from its column comments.")
                elif result.get("reason"):
                    print(f"Approved, not published: {result['reason']}. Retry with: exakit describe {self.id} --comments")
                for warning in result.get("warnings") or []:
                    print(f"Warning: {warning}")
            current = service.store.folder(result["table"]) / service.store.CURRENT
            self.doc = service.flow.load(current.read_text(encoding="utf-8"))
            return dataset(conn, str(current))
        finally:
            if own:
                conn.close()

    # --- showing -----------------------------------------------------------------------------------------------------

    def _lines(self) -> list[str]:
        numbers = {c["column"]: c for c in (self.profile or {}).get("columns", [])}
        out = [f"{self.table} - {self.status} descriptor '{self.id}' v{self.version}"
               + (f" (grain: {self.doc['grain']})" if self.doc.get("grain") else "")]
        why = self.doc.get("slot_evidence") or {}
        out.append("slots: " + "; ".join(f"{s}={self.slots.get(s) or '-'}" + (f" ({why[s]})" if s in why else "") for s in SLOTS))
        rows = []
        for name, entry in sorted(self.doc["columns"].items(), key=lambda item: item[1].get("confidence") != "low"):
            role = entry["role"] + (" (sensitive)" if entry.get("sensitive") else "")
            changed = " [changed]" if name in self.changed else ""
            rows.append((name + changed, str(numbers.get(name, {}).get("type", "")), role, entry.get("confidence", ""),
                         entry.get("evidence", ""), entry.get("note", "")))
        head = ("column", "type", "role", "confidence", "evidence", "note")
        widths = [max(len(r[i]) for r in rows + [head]) for i in range(len(head))]
        out.append("  ".join(h.ljust(w) for h, w in zip(head, widths)).rstrip())
        out.append("  ".join("-" * w for w in widths))
        out += ["  ".join(v.ljust(w) for v, w in zip(r, widths)).rstrip() for r in rows]
        return out

    def show(self) -> None:
        """Print column, type, role, confidence, evidence and note, low confidence first, the slots above."""
        print("\n".join(self._lines()))

    def __repr__(self) -> str:
        return f"Draft({self.id!r}, {self.table}, slots={self.slots!r})"
