"""Hand off: everything a colleague needs to repeat a piece of work, in one folder (and one zip).

    bundle = nb.handoff_bundle(connection, dataset)       # ~/.exasol-starter-kit/bundles/<workflow id>/ and .zip

The folder holds the approved column map (``descriptor.yaml``), the schema map when there is one
(``schema-map.json``), every query the workflow ran with its digest and row count (``queries.sql``), the workflow log
as it is (``workflow.jsonl``) and a ``README.md`` that says what the data is, which column map version the numbers rest
on, which questions were approved, which dashboards were published and how to repeat it. Nothing in it is a password:
the log is already written without one, and the connection is the kit's.

This is the Data Scientist's hand-off. The ML Engineer's training handoff (one JSON file with the feature view and the
split, ``nb.write_handoff``) is a different thing with its own folder.
"""

from __future__ import annotations

import json
import os
import shutil
from dataclasses import dataclass, field
from html import escape
from pathlib import Path
from typing import Any

from .workflow import (ASK_APPROVE, DASHBOARD_REVISION, DESCRIBE_APPROVE, HANDOFF, SQL, TRACE, current_workflow,
                       home, last_workflow, log_event, log_path, read_log)

FOLDER = "bundles"


@dataclass
class HandoffBundle:
    """Where the bundle is and what is in it."""
    path: Path
    zip_path: Path | None
    workflow_id: str | None
    files: list[str] = field(default_factory=list)
    summary: list[str] = field(default_factory=list)

    def __str__(self) -> str:
        lines = [f"Hand-off bundle: {self.path}" + (f" (and {self.zip_path.name})" if self.zip_path else "")]
        lines += [f"  {name}" for name in self.files]
        lines += self.summary
        return "\n".join(lines)

    __repr__ = __str__

    def _repr_html_(self) -> str:
        items = "".join(f"<li><code>{escape(name)}</code></li>" for name in self.files)
        notes = "".join(f"<li>{escape(line)}</li>" for line in self.summary)
        head = f"<p><b>Hand-off bundle:</b> <code>{escape(str(self.path))}</code>"
        if self.zip_path:
            head += f" and <code>{escape(self.zip_path.name)}</code>"
        return head + "</p><ul>" + items + "</ul>" + (f"<ul>{notes}</ul>" if notes else "")


def _slots(ds: Any) -> dict[str, str | None]:
    return dict(getattr(ds.descriptor, "slots", None) or {})


def _schema_map_file(ds: Any) -> Path | None:
    """The approved schema map of the fact table's schema, when the store has one."""
    table = str(getattr(ds, "fact_table", "") or "")
    schema = table.split(".")[0].strip('"').upper() if "." in table else ""
    if not schema:
        return None
    from .descriptor_store import kit_home, FOLDER as STORE
    found = kit_home() / STORE / schema / "current.json"
    return found if found.is_file() else None


def _queries(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The distinct statements the workflow ran, first occurrence first."""
    seen: set[str] = set()
    found = []
    for event in events:
        if event.get("kind") != SQL or not event.get("sql"):
            continue
        digest = str(event.get("sql_digest") or "")
        if digest in seen:
            continue
        seen.add(digest)
        found.append(event)
    return found


def _readme(ds: Any, workflow_id: str | None, events: list[dict[str, Any]], files: list[str]) -> str:
    slots = _slots(ds)
    queries = _queries(events)
    approvals = [e for e in events if e.get("kind") == DESCRIBE_APPROVE]
    questions = [e for e in events if e.get("kind") == ASK_APPROVE]
    dashboards = [e for e in events if e.get("kind") == DASHBOARD_REVISION]
    traces = [e for e in events if e.get("kind") == TRACE]
    lines = [f"# Hand-off: {ds.id}", "",
             f"Data: `{ds.fact_table}` (dataset `{ds.id}`).",
             f"Column map: v{ds.version}, {ds.status}, by {ds.owner}" + (f", {ds.created}" if getattr(ds, 'created', None) else "") + ".",
             f"Workflow: `{workflow_id}`" if workflow_id else "Workflow: none was active.", "",
             "## What one row is and which columns the work used", "",
             "| Slot | Column |", "|---|---|"]
    lines += [f"| {slot} | `{column}` |" if column else f"| {slot} | - |" for slot, column in slots.items()]
    lines += ["", "## What happened", "",
              f"- {len(queries)} distinct quer{'y' if len(queries) == 1 else 'ies'} ran (`queries.sql`, each with its SHA-256 and row count).",
              f"- {len(approvals)} column-map approval{'s' if len(approvals) != 1 else ''} were logged.",
              f"- {len(questions)} question{'s' if len(questions) != 1 else ''} approved in Ask your data"
              + (": " + "; ".join(f"\"{e.get('question')}\"" for e in questions[:5]) if questions else "") + ".",
              f"- {len(dashboards)} dashboard revision{'s' if len(dashboards) != 1 else ''}"
              + (": " + "; ".join(f"{e.get('app')} r{e.get('revision')} ({e.get('state')})"
                                  + (f" at {e.get('preview_path')}" if e.get("state") == "preview" and e.get("preview_path") else "")
                                  for e in dashboards) if dashboards else "") + ".",
              f"- {len(traces)} model trace{'s' if len(traces) != 1 else ''}"
              + (": " + "; ".join(str(e.get("url") or e.get("name") or "") for e in traces if e.get("url") or e.get("name")) if traces else "") + ".",
              "", "## Files", ""]
    lines += [f"- `{name}`" for name in files]
    lines += ["", "## To repeat it", "",
              "1. On a machine with the starter kit: `exakit data-load " + ds.id + "` (a kit dataset) or load the same table.",
              f"2. In a notebook: `dataset = nb.dataset(connection, \"{ds.id}\")` reads the approved column map; "
              "`exakit describe " + ds.id + " --show` prints it.",
              "3. Run the statements in `queries.sql` in order, or open the Data Scientist notebooks with `DATASET = \"" + ds.id + "\"`.",
              "4. `exakit workflow show " + (workflow_id or "<id>") + "` lists every step with its digest.", ""]
    return "\n".join(lines)


def handoff_bundle(conn, ds: Any, workflow_id: str | None = None, folder: str | os.PathLike | None = None,
                   zip_it: bool = True) -> HandoffBundle:
    """Write the bundle for ``ds`` and the workflow (the active one, else the last one on this machine, else none) into
    ``folder`` (default ``$EXAKIT_HOME/bundles/<workflow id>/``; a bundle for no workflow is named after the dataset)
    and, with ``zip_it``, a zip beside it. The active workflow's log gets a ``handoff`` line with the path."""
    workflow_id = workflow_id or current_workflow() or last_workflow()
    events: list[dict[str, Any]] = []
    if workflow_id and log_path(workflow_id).is_file():
        events = read_log(workflow_id)
    name = workflow_id or f"{ds.id}-v{ds.version}"
    target = Path(folder).expanduser() if folder else home() / FOLDER / name
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(mode=0o700, parents=True)
    files: list[str] = []
    summary: list[str] = []
    descriptor_file = getattr(ds, "descriptor_path", None)
    if descriptor_file and Path(descriptor_file).is_file():
        shutil.copyfile(descriptor_file, target / "descriptor.yaml")
        files.append("descriptor.yaml")
    else:
        summary.append("No column-map file was found for this dataset (a draft that was never approved?): none copied.")
    schema_file = _schema_map_file(ds)
    if schema_file:
        shutil.copyfile(schema_file, target / "schema-map.json")
        files.append("schema-map.json")
    queries = _queries(events)
    if queries:
        text = []
        for i, event in enumerate(queries, 1):
            text.append(f"-- {i}. sha256 {event.get('sql_digest')}; {event.get('rows')} rows; {event.get('ts')}"
                        + (f"; via {event['via']}" if event.get("via") else ""))
            text.append(str(event["sql"]).rstrip().rstrip(";") + ";")
            text.append("")
        (target / "queries.sql").write_text("\n".join(text), encoding="utf-8")
        files.append("queries.sql")
    if workflow_id and log_path(workflow_id).is_file():
        shutil.copyfile(log_path(workflow_id), target / "workflow.jsonl")
        files.append("workflow.jsonl")
    elif workflow_id:
        summary.append(f"The workflow {workflow_id} has no log on this machine: nothing to copy.")
    else:
        summary.append("No workflow was active or remembered: the bundle holds the column map only.")
    (target / "README.md").write_text(_readme(ds, workflow_id, events, ["README.md", *files]), encoding="utf-8")
    files.insert(0, "README.md")
    zip_path = None
    if zip_it:
        zip_path = Path(shutil.make_archive(str(target), "zip", root_dir=target.parent, base_dir=target.name))
    for item in [target, *target.iterdir(), *([zip_path] if zip_path else [])]:
        if os.name != "nt":
            os.chmod(item, 0o700 if item.is_dir() else 0o600)
    log_event(HANDOFF, path=str(target), bundle=True, descriptor_id=ds.id, version=ds.version,
              files=files, zip=str(zip_path) if zip_path else None)
    summary.insert(0, f"{len(queries)} distinct queries, the column map v{ds.version}" + (", the schema map" if schema_file else "")
                   + (", the workflow log" if "workflow.jsonl" in files else "") + ".")
    return HandoffBundle(target, zip_path, workflow_id, files, summary)


__all__ = ["HandoffBundle", "handoff_bundle"]
