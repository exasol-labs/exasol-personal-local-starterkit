"""Describe a table from a notebook (DS-5, design 2.2): ``describe(table_or_dataset, sample=10000)`` profiles the
table and returns a ``Draft`` - the descriptor the kit proposes, a role per column with the evidence that chose it
and the roles no column fits - for the user to look at (``show()``), correct (``set(role, column)``), keep
(``save(path)``, ``to_dict()``) and approve (``approve(owner=None, comments=True) -> Dataset``: the next version in
the kit's store with the table digest, the roles written into the column comments, and the dataset read back from
the store, so ``ds.status == "approved"`` and the steps that need an approved descriptor go on).

The profiling, the scoring and the approving are the kit's own service, setup/lib/describe_service.py in the kit
copy (the same code `exakit describe` runs), loaded from its file and run in this process over the kit's connection;
when the kit copy is not found, `exakit describe --json` runs as a child process instead. The draft is
deterministic: the same table gives the same roles, offline, with or without a model (a model only adds ``notes``,
one line per column).
"""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
from pathlib import Path
from typing import Any

from ._kit import exakit_command, setting

SAMPLE = 10000
ROLES = ("entity", "category", "date", "label", "text")
SINGLE_ROLES = ("entity", "category", "date", "label")

__all__ = ["Draft", "describe", "describe_service"]


def _rules():
    from . import descriptor_rules
    return descriptor_rules


def describe_service():
    """The kit's profiler module (setup/lib/describe_service.py), loaded from the kit copy's file - or from the
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
    """(fact table, dataset id or None) for ``SCHEMA.TABLE`` or a shipped dataset id (its descriptor's fact table)."""
    if "." in name:
        return name, None
    datasets = setting("EXAKIT_NB_DATASETS")
    folder = Path(datasets) / name if datasets else None
    if folder is not None and folder.is_dir():
        path = _rules().descriptor_file(folder)
        if path is not None:
            descriptor = _rules().read_descriptor(path)
            return descriptor.fact_table, descriptor.id
    raise ValueError(f"'{name}' is neither SCHEMA.TABLE nor a shipped dataset id (the kit's data/datasets).")


def describe(table_or_dataset: str, sample: int = SAMPLE, *, conn=None, id: str | None = None) -> "Draft":
    """Profile ``SCHEMA.TABLE`` (or a shipped dataset's fact table) and return the kit's draft descriptor. Uses the
    connection given, else opens the kit's; a virtual table or one past 5 million rows is profiled on ``sample``
    rows. Only SELECTs run."""
    table, slug = _resolve(str(table_or_dataset))
    service = describe_service()
    if service is not None:
        own = conn is None
        if own:
            from . import connect
            conn = connect()
        try:
            prof = service.profile(conn, table, sample)
        finally:
            if own:
                conn.close()
        kit = setting("EXAKIT_NB_KIT")
        doc = service.draft(prof, prof["table"], id or slug, root=Path(kit) if kit else None)
        notes = service.model_notes(doc, prof)
        if notes:
            doc["notes"] = notes
        return Draft(doc, prof)
    command = exakit_command()
    if command is None:
        raise RuntimeError("The kit's profiler was not found (no kit copy beside this Python and exakit's launcher is not on PATH); "
                           "install the notebook add-on: exakit marketplace notebook")
    args = [*command, "describe", table, "--sample", str(sample), "--json"] + (["--id", id or slug] if id or slug else [])
    run = subprocess.run(args, capture_output=True, text=True)
    if run.returncode != 0:
        raise RuntimeError(f"exakit describe failed (exit {run.returncode}): {(run.stderr or run.stdout).strip()}")
    return Draft(json.loads(run.stdout), None)


class Draft:
    """A drafted descriptor (schema_version 2, status draft): ``roles`` is what the kit proposes, ``evidence`` the
    numbers behind each role (with its runner-up), ``missing`` the roles no column fits. ``show()`` prints it,
    ``set(role, column)`` corrects a role, ``save(path)`` writes the YAML the notebooks read, ``to_dict()`` is the
    document, ``approve()`` writes the next approved version into the kit's store and returns the Dataset."""

    def __init__(self, doc: dict[str, Any], profile: dict[str, Any] | None = None):
        self.doc = doc
        self.profile = profile

    @property
    def id(self) -> str:
        return str(self.doc["id"])

    @property
    def table(self) -> str:
        return str(self.doc["fact_table"])

    @property
    def roles(self) -> dict[str, Any]:
        """{role: column} for the single roles, {text: [columns]} for text."""
        return {role: ([r["column"] for r in ref] if isinstance(ref, list) else ref["column"])
                for role, ref in self.doc.get("roles", {}).items()}

    @property
    def evidence(self) -> dict[str, Any]:
        return dict(self.doc.get("evidence") or {})

    @property
    def missing(self) -> list[dict[str, str]]:
        return list(self.doc.get("missing") or [])

    @property
    def notes(self) -> dict[str, str]:
        return dict(self.doc.get("notes") or {})

    def columns(self) -> list[str]:
        """The table's columns, when the profile is here (an in-process draft); else the ones the draft names."""
        if self.profile:
            return [c["column"] for c in self.profile["columns"]]
        named = [v if isinstance(v, str) else v for v in self.roles.values()]
        return sorted({c for v in named for c in (v if isinstance(v, list) else [v])})

    def _claimed_by(self, column: str, except_role: str) -> str | None:
        for role, value in self.roles.items():
            if role != except_role and (column == value or (isinstance(value, list) and column in value)):
                return role
        return None

    def set(self, role: str, column: str | list[str]) -> "Draft":
        """Give ``role`` to ``column`` (text takes one column or a list); the role leaves ``missing``. A column
        another role already has is refused, naming it - set that role first."""
        if role not in ROLES:
            raise ValueError(f"'{role}' is not a role (the roles are {', '.join(ROLES)}).")
        columns = list(column) if isinstance(column, (list, tuple)) else [column]
        if role in SINGLE_ROLES and len(columns) != 1:
            raise ValueError(f"The '{role}' role takes exactly one column.")
        known = self.columns()
        for name in columns:
            if not isinstance(name, str) or not name.strip():
                raise ValueError("Name the column as a string.")
            if self.profile and name not in known:
                raise ValueError(f"{self.table} has no column '{name}' (it has: {', '.join(known)}).")
            other = self._claimed_by(name, role)
            if other:
                raise ValueError(f"{name} already plays the '{other}' role; set that role to another column first.")
        ref = [{"table": self.table, "column": c} for c in columns]
        self.doc.setdefault("roles", {})[role] = ref if role == "text" else ref[0]
        self.doc["missing"] = [m for m in self.missing if m.get("role") != role]
        evidence = self.doc.setdefault("evidence", {})
        chosen = evidence.get(role) if isinstance(evidence.get(role), dict) else {}
        evidence[role] = dict(chosen, set_by="user", column=columns[0] if role != "text" else chosen.get("column"))
        if role == "text":
            evidence[role]["columns"] = [{"column": c} for c in columns]
        return self

    def to_dict(self) -> dict[str, Any]:
        """The draft document (a copy)."""
        return copy.deepcopy(self.doc)

    def save(self, path: str | Path) -> Path:
        """Write the draft as YAML in the kit's descriptor layout; exakit.nb.dataset(conn, path) reads it back. The
        service's writer is used when the kit copy is there (it keeps a number-like value such as "0" a string);
        else the package's own save_descriptor."""
        about = f"Which column of {self.table} plays which role; drafted by exakit.nb.describe."
        service = describe_service()
        target = Path(path).expanduser()
        if service is not None:
            target.write_text(service.to_yaml(self.to_dict(), about), encoding="utf-8")
            return target
        from .own_file import save_descriptor
        return save_descriptor(self.to_dict(), target, about)

    def approve(self, owner: str | None = None, comments: bool = True, *, conn=None, sample: int = SAMPLE):
        """Approve this draft (design 2.2): the roles validated by the descriptor rules, the table digest computed,
        version n+1 written into the kit's store (``~/.exasol-starter-kit/descriptors/<id>/``) with ``current``,
        then the roles written into the table's column comments (a view in STARTER_KIT for a virtual table; a
        comment that cannot be written is a printed warning, the descriptor approved all the same; ``comments=False``
        skips them). ``owner`` defaults to EXAKIT_DESCRIPTOR_OWNER or the OS user. Approving the roles the current
        approved version already has writes nothing and says so. Returns the Dataset read back from the store, so
        ``ds.status == "approved"``. Uses the connection given, else opens the kit's."""
        from .dataset import dataset

        service = describe_service()
        if service is None:
            raise RuntimeError("The kit's describe service was not found (no kit copy beside this Python); approve on the command line: "
                               f"exakit describe {self.id} --approve")
        own = conn is None
        if own:
            from . import connect
            conn = connect()
        try:
            kit = setting("EXAKIT_NB_KIT")
            result = service.approve(conn, self.to_dict(), owner=owner, comments=comments, sample=sample,
                                     root=Path(kit) if kit else None)
            if result.get("unchanged"):
                print(result["message"])
            else:
                print(f"Approved {result['id']} v{result['version']} (owner {result['owner']}, digest {result['digest'][:19]}...): {result['path']}")
                for warning in result["comments"].get("warnings", []):
                    print(f"Warning: {warning}")
            self.doc.update(status="approved", version=result["version"], owner=result.get("owner", self.doc.get("owner")),
                            digest=result.get("digest"))
            return dataset(conn, self.id)
        finally:
            if own:
                conn.close()

    def _lines(self) -> list[str]:
        evidence = self.evidence
        rows: list[tuple[str, str, str, str]] = []
        for role in ROLES:
            if role == "text" and "text" in self.roles:
                for entry in (evidence.get("text") or {}).get("columns") or [{"column": c} for c in self.roles["text"]]:
                    rows.append(("text", str(entry.get("column")), _summary(entry), ""))
                rows[-1] = rows[-1][:3] + (_runner(evidence.get("text")),)
            elif role in self.roles:
                rows.append((role, str(self.roles[role]), _summary(evidence.get(role) or {}), _runner(evidence.get(role))))
            else:
                reason = next((m["reason"] for m in self.missing if m.get("role") == role), "no column fits")
                rows.append((role, "-", f"missing: {reason}", ""))
        widths = [max(len(r[i]) for r in rows + [("role", "column", "evidence", "runner-up")]) for i in range(4)]
        head = ("role", "column", "evidence", "runner-up")
        out = [f"{self.table} - draft descriptor '{self.id}' (version {self.doc.get('version')}, {self.doc.get('status')}, owner {self.doc.get('owner')})",
               "  ".join(h.ljust(w) for h, w in zip(head, widths)).rstrip(),
               "  ".join("-" * w for w in widths)]
        out += ["  ".join(v.ljust(w) for v, w in zip(r, widths)).rstrip() for r in rows]
        excluded = evidence.get("excluded") or {}
        if excluded:
            out.append("excluded: " + "; ".join(f"{c} ({why})" for c, why in excluded.items()))
        facts = evidence.get("table") or {}
        if facts:
            out.append(f"profiled {facts.get('profiled_rows')} of {facts.get('rows')} rows"
                       + (" (a sample)" if facts.get("sampled") else "") + f" in {facts.get('statements')} statements")
        for column, note in self.notes.items():
            out.append(f"note {column}: {note}")
        return out

    def show(self) -> None:
        """Print the draft as a table: role, column, the evidence behind it and the runner-up."""
        print("\n".join(self._lines()))

    def __repr__(self) -> str:
        return f"Draft({self.id!r}, roles={self.roles!r}, missing={[m['role'] for m in self.missing]!r})"


def _summary(entry: dict[str, Any]) -> str:
    parts = []
    for key, label in (("type", ""), ("null_rate", "null"), ("distinct", "distinct"), ("distinct_ratio", "ratio"),
                       ("span_days", "span d"), ("date_parse_rate", "parse"), ("avg_len", "avg len"), ("max_len", "max len"),
                       ("min_share", "min share"), ("score", "score")):
        if entry.get(key) is not None:
            parts.append(f"{label} {entry[key]}".strip())
    if entry.get("set_by") == "user":
        parts.append("set by you")
    return ", ".join(parts)


def _runner(entry: Any) -> str:
    runner = entry.get("runner_up") if isinstance(entry, dict) else None
    return f"{runner['column']} ({runner.get('score')})" if isinstance(runner, dict) and runner.get("column") else ""
