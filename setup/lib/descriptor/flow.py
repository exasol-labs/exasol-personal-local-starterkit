"""Step 4 of the descriptor plan: describe a table and approve its descriptor, versioned in the kit's store.

describe() on a table with an approved descriptor re-checks the schema digest. It matches: the approved version is
returned (force=True profiles again). It does not: a new draft is made, the roles of the columns whose name and type
are unchanged are carried over, the rest are flagged, and the old version stays approved for the old digest. With
nothing approved, the table is profiled and drafted. The draft is kept as draft.yaml (with its profile) until it is
approved; it is never a version.

approve() runs these in order and stops at the first failure:
    1. every column has a role and no column sits in two slots (the descriptor rules);
    2. the live schema digest still matches the draft's - the table may have been reloaded since describe();
    3. the data against the slots (review.py): the key unique and never empty now, the target two-valued - else
       refused; a column that gives the target away, and the low-confidence roles nobody changed - warned, in the
       result's "warnings" and the log (a live source is not queried: every count would be a round trip to it);
    4. v(n+1).yaml with status approved, the owner (the OS user unless given) and approved_at; v(n) is untouched;
    5. current.yaml replaced through a temp file and os.replace;
    6. published (publish.py) and read back;
    7. one line for the workflow log: table, version, what was published, the warnings.
A publish that fails leaves the approval standing: the result says "approved, not published" and why. Approving
what the current version already says writes nothing.
"""

from __future__ import annotations

import datetime as dt
import getpass
import os
import re
from typing import Any, Callable

from . import draft as drafting
from . import profile as profiling
from . import publish as publishing
from . import review as reviewing
from . import store

OWNER_VARIABLE = "EXAKIT_DESCRIPTOR_OWNER"
CHANGED = "changed since v{version}: "


def _rules():
    try:
        import descriptor_rules                                  # tools/ on the path (the kit copy, the tests)
    except ImportError:
        from exakit_nb import descriptor_rules                   # type: ignore[no-redef]
    return descriptor_rules


def table_name(table: str) -> str:
    """SCHEMA.TABLE as the database spells it: a plain part upper-cased, a quoted part kept."""
    match = re.match(r'^\s*("(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*("(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)\s*$', table or "")
    if not match:
        raise ValueError(f"Name the table as SCHEMA.TABLE, not '{table}'.")
    parts = [p[1:-1].replace('""', '"') if p.startswith('"') else p.upper() for p in match.groups()]
    return ".".join(parts)


def dataset_id(table: str) -> str:
    """A dataset id from a table name: AMAZON.ORDER_LINES -> amazon_order_lines."""
    return re.sub(r"_+", "_", re.sub(r"[^a-z0-9]+", "_", table.lower())).strip("_") or "dataset"


def owner_name(owner: str | None = None) -> str:
    return owner or os.environ.get(OWNER_VARIABLE) or getpass.getuser()


def load(text: str) -> dict[str, Any]:
    return _rules().load_yaml(text)


def live_digest(run: Callable[[str], list[dict[str, Any]]], table: str) -> str:
    schema, name = table.split(".", 1)
    columns, _virtual = profiling._shape(run, schema, name)
    return profiling.schema_digest(columns)


def _carry_over(doc: dict[str, Any], old: dict[str, Any], old_profile: dict[str, Any] | None,
                new_profile: dict[str, Any]) -> list[str]:
    """Roles of the columns whose name and type did not change come from the approved version; the rest are flagged
    (low confidence, the evidence saying so). The changed or new column names."""
    new_types = {c["column"]: c["type"] for c in new_profile["columns"]}
    if old_profile is None and old.get("source", {}).get("schema_digest") == new_profile["source"]["schema_digest"]:
        # No profile kept with the approval (a shipped descriptor the store adopted), but the same names and types in
        # the same order: nothing changed.
        old_types = dict(new_types)
    else:
        old_types = {c["column"]: c["type"] for c in (old_profile or {}).get("columns", [])}
    changed = []
    for name, entry in doc["columns"].items():
        if name in old["columns"] and old_types.get(name) == new_types.get(name) and name in old_types:
            doc["columns"][name] = dict(old["columns"][name])
        else:
            changed.append(name)
            doc["columns"][name] = dict(entry, confidence="low", evidence=CHANGED.format(version=old["version"]) + entry["evidence"])
    for slot, column in (old.get("slots") or {}).items():
        if column and column in doc["columns"] and column not in changed:
            doc["slots"][slot] = column
            doc.get("slot_evidence", {}).pop(slot, None)
    if old.get("grain"):
        doc["grain"] = old["grain"]
    return changed


def describe(run: Callable[[str], list[dict[str, Any]]], table: str, *, dataset: str | None = None, force: bool = False,
             home=None) -> dict[str, Any]:
    """{status: approved|draft, doc, profile, changed, previous}: the approved descriptor when the table still
    matches it, else a fresh draft (carried over from the approved one where the columns did not change)."""
    table = table_name(table)
    approved_text = store.current(table, home)
    approved = load(approved_text) if approved_text else None
    if approved and not force and live_digest(run, table) == approved["source"]["schema_digest"]:
        return {"status": "approved", "doc": approved, "profile": None, "changed": [], "previous": approved["version"]}
    found = profiling.profile(None, table, run=run)
    version = max(store.versions(table, home) or [0]) + 1
    doc = drafting.draft(found, dataset or (approved or {}).get("dataset") or dataset_id(table), version)
    changed = []
    if approved:
        old_profile = store.read_profile(table, approved["version"], home)
        changed = _carry_over(doc, approved, old_profile, found)
    store.write_profile(table, found, home, version=version)
    store.write_draft(table, drafting.to_yaml(doc), home)
    return {"status": "draft", "doc": doc, "profile": found, "changed": changed,
            "previous": approved["version"] if approved else None}


def problems(doc: dict[str, Any], live_columns: list[str] | None = None) -> list[str]:
    """Step 1: the descriptor rules, and every live column given a role."""
    found = _rules().validate_column_descriptor(doc)
    if live_columns is not None and list(doc.get("columns") or {}) != live_columns:
        found.append("the descriptor must give every column of the table its role, in table order")
    return found


def _same(a: dict[str, Any], b: dict[str, Any]) -> bool:
    keep = ("dataset", "source", "grain", "slots", "columns")
    return all(a.get(k) == b.get(k) for k in keep)


def _published_view(run: Callable[[str], list[dict[str, Any]]], table: str) -> str | None:
    """EXAKIT_SEMANTIC.<view> when an earlier approval published it and it is still there; None otherwise."""
    name = publishing.view_name(table)
    try:
        rows = run(f"SELECT VIEW_NAME FROM EXA_ALL_VIEWS WHERE VIEW_SCHEMA = {publishing.literal(publishing.SCHEMA)} "
                   f"AND VIEW_NAME = {publishing.literal(name)}")
    except Exception:                                   # the answer is a courtesy; the approval stands without it
        return None
    return f"{publishing.SCHEMA}.{name}" if rows else None


def approve(run: Callable[[str], list[dict[str, Any]]], execute: Callable[[str], Any], doc: dict[str, Any], *,
            owner: str | None = None, home=None, reader: str | None = None, publish: bool = True,
            log: Callable[..., None] | None = None, now: Callable[[], dt.datetime] | None = None) -> dict[str, Any]:
    """Approve a draft: the six steps of the module docstring. {status, version, path, published|reason, ...}."""
    table = table_name(doc["source"]["object"])
    schema, name = table.split(".", 1)
    columns, _virtual = profiling._shape(run, schema, name)
    wrong = problems(doc, [c["column"] for c in columns])
    if wrong:
        raise ValueError("The descriptor cannot be approved: " + "; ".join(wrong))
    if profiling.schema_digest(columns) != doc["source"]["schema_digest"]:
        raise ValueError(f"{table} changed since it was described (its columns or types differ): describe it again")
    approved_text = store.current(table, home)
    if approved_text and _same(load(approved_text), doc):
        current = load(approved_text)
        # Where the approval this run is using lives: nothing new was written, so the reader would otherwise have
        # no path to open, nor the view an agent reads the roles from.
        path = store.folder(table, home) / f"v{current['version']}.yaml"
        view = _published_view(run, table)
        unchanged: dict[str, Any] = {"status": "unchanged", "version": current["version"], "table": table,
                                     "path": str(path)}
        if view is None and publish:
            # Approved but never published: a shipped dataset's descriptor the store adopted, or an approval whose
            # publish failed. Publish it now, so an agent finds its roles in EXAKIT_SEMANTIC.
            try:
                view = publishing.publish(execute, run, current, reader)["view"]
            except Exception as err:                   # the approval stands; say why it is not published
                unchanged["reason"] = f"{type(err).__name__}: {err}"
        unchanged["published"] = view
        unchanged["message"] = (f"{table} v{current['version']} already says this; nothing was written. It is stored "
                                f"at {path}" + (f"; published as {view}" if view else ""))
        return unchanged
    if doc["source"].get("kind") == "virtual":
        checked = {"refused": [], "leaks": [], "unreviewed": reviewing.unreviewed(doc)}
    else:
        checked = reviewing.review(run, doc)
    if checked["refused"]:
        raise ValueError("The descriptor cannot be approved: " + "; ".join(checked["refused"]))
    warnings = list(checked["leaks"])
    if checked["unreviewed"]:
        warnings.append(f"{len(checked['unreviewed'])} role(s) drafted at low confidence were approved as drafted: "
                        + "; ".join(checked["unreviewed"]))
    stamp = (now() if now else dt.datetime.now(dt.timezone.utc)).replace(microsecond=0)
    version = max(store.versions(table, home) or [0]) + 1
    final = drafting.approved(doc, owner_name(owner), stamp.isoformat().replace("+00:00", "Z"), version=version)
    text = drafting.to_yaml(final)
    path = store.write_version(table, version, text, home)
    store.replace_current(table, text, home)
    store.promote_profile(table, version, home)
    result: dict[str, Any] = {"status": "approved", "table": table, "version": version, "owner": final["owner"],
                              "path": str(path), "warnings": warnings}
    if publish:
        try:
            result["published"] = publishing.publish(execute, run, final, reader)["view"]
        except Exception as err:                       # the approval stands; say why it is not published
            result["status"], result["reason"] = "approved, not published", f"{type(err).__name__}: {err}"
    if log:
        log("describe.approve", table=table, version=version, published=result.get("published") or result.get("reason"),
            warnings=warnings)
    return result
