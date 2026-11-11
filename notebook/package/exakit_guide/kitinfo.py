"""Read the kit's current state, read-only, from the kit's own answers.

Every fact here comes from `exakit <command> --json`, the kit's manifest or
its workflow log. Nothing is guessed: a part the kit doesn't report is shown
as unknown, not as fine.
"""

from __future__ import annotations

import importlib
import json
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PERSONA = "data-scientist"
NOTEBOOK_DIR = "starter-kit-notebooks/data-scientist"

# The Data Scientist path, as the kit's notebooks lay it out.
JOURNEY = [
    {"n": 1, "title": "Understand your data", "text": "Pick data, check it, approve what each column means.",
     "notebook": "00_quickstart.ipynb"},
    {"n": 2, "title": "Explore and predict", "text": "Clean it, compare groups, see trends, train a first model.",
     "notebook": "01_explore.ipynb"},
    {"n": 3, "title": "Ask in plain words", "text": "Ask a question, check the query, then run it.",
     "notebook": "02_ask_your_data.ipynb"},
    {"n": 4, "title": "Share and hand off", "text": "Publish a dashboard and package the work for others.",
     "notebook": "03_share.ipynb"},
]

DATASET_TITLES = {
    "amazon_sales": "Amazon sales",
    "fraud_transactions": "Fraud transactions",
    "tpch": "TPC-H retail",
    "energy": "Smart-meter energy",
    "weather": "City weather",
}


def _kit_json(*args: str) -> dict:
    from exakit_nb.kit_commands import kit_json

    try:
        return kit_json(*args) or {}
    except Exception as exc:  # the kit says why; keep it
        return {"_error": str(exc)}


def _manifest() -> dict:
    from exakit_nb._kit import _home

    home = _home()
    try:
        return json.loads((Path(home) / "manifest.json").read_text(encoding="utf-8")) if home else {}
    except (OSError, ValueError):
        return {}


def _ago(ts: str | None) -> str:
    if not ts:
        return ""
    try:
        then = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return ts
    mins = int((datetime.now(timezone.utc) - then).total_seconds() // 60)
    if mins < 2:
        return "just now"
    if mins < 60:
        return f"{mins} minutes ago"
    if mins < 60 * 24:
        h = mins // 60
        return f"{h} hour{'s' if h > 1 else ''} ago"
    d = mins // (60 * 24)
    return "yesterday" if d == 1 else f"{d} days ago"


def _workflows() -> dict:
    wf = importlib.import_module("exakit_nb.workflow")
    try:
        rows = wf.list_workflows()
    except Exception:
        rows = []
    if not rows:
        return {"last": None, "events": []}
    last = max(rows, key=lambda r: r.get("last") or "")
    try:
        events = wf.read_log(last["id"])
    except Exception:
        events = []
    return {"last": last, "events": events}


def _journey_state(events: list[dict]) -> list[dict]:
    kinds = [e.get("kind") for e in events]
    sqls = " ".join(str(e.get("sql", "")) for e in events if e.get("kind") == "sql").upper()
    approved = "describe.approve" in kinds
    explored = "mlflow.run" in kinds or "CREATE VIEW" in sqls or "CREATE OR REPLACE VIEW" in sqls
    asked = "ask.answer" in kinds
    asked_no_answer = "ask.approve" in kinds and not asked
    published = any(e.get("kind") == "dashboard.revision" and e.get("state") == "live" for e in events)
    handed = "handoff" in kinds
    done = [approved, explored, asked, published or handed]
    notes = ["", "", "Questions were approved but none returned an answer." if asked_no_answer else "",
             "Dashboard published." if published else ("Hand-off bundle made." if handed else "")]
    out, next_set = [], False
    for step, is_done, note in zip(JOURNEY, done, notes):
        state = "done" if is_done else ("next" if not next_set else "todo")
        if state == "next":
            next_set = True
        if step["n"] == 3 and asked_no_answer:
            state = "attention"
            next_set = True
        out.append({**step, "state": state, "note": note, "path": f"{NOTEBOOK_DIR}/{step['notebook']}"})
    if not next_set and all(done):
        out[0]["state"] = "done"
    return out


def _dataset_of(events: list[dict]) -> str | None:
    for e in reversed(events):
        for key in ("dataset", "descriptor_id"):
            if e.get(key):
                return str(e[key])
    return None


def _last_step(events: list[dict]) -> int | None:
    """Which guided step the last recorded action belongs to (0-based), so Home can reopen it."""
    for e in reversed(events):
        k = str(e.get("kind") or "")
        if k.startswith("describe"):
            return 0
        if k in ("sql", "mlflow.run") or k.startswith("explore"):
            return 1
        if k.startswith("ask"):
            return 2
        if k.startswith(("dashboard", "handoff", "share")):
            return 3
    return None


def _row_counts(fact_tables: dict[str, str]) -> dict[str, int]:
    """Row counts from the database's own statistics (no table scan)."""
    if not fact_tables:
        return {}
    try:
        import exakit.nb as nb

        conn = nb.connect()
        try:
            pairs = [t.split(".", 1) for t in fact_tables.values() if "." in t]
            cond = " OR ".join(f"(TABLE_SCHEMA = '{s}' AND TABLE_NAME = '{n}')" for s, n in pairs)
            rows = conn.execute(f"SELECT TABLE_SCHEMA || '.' || TABLE_NAME, TABLE_ROW_COUNT FROM SYS.EXA_ALL_TABLES WHERE {cond}").fetchall()
        finally:
            conn.close()
        by_table = {r[0]: int(r[1] or 0) for r in rows}
        return {ds: by_table.get(t, 0) for ds, t in fact_tables.items()}
    except Exception:
        return {}


def _fact_tables(ids: list[str]) -> dict[str, str]:
    """Each kit dataset's table, from its descriptor file."""
    out = {}
    for ds_id in ids:
        try:
            from exakit_nb.dataset import _locate
            from exakit_nb.descriptor_rules import read_descriptor

            path, _ = _locate(ds_id)
            out[ds_id] = str(read_descriptor(Path(path)).fact_table)
        except Exception:
            continue
    return out


def _approved() -> list[dict]:
    try:
        from .store import approved

        return approved()
    except Exception:
        return []


def _working_on() -> str | None:
    try:
        from .session import Session

        return Session.latest_approved()
    except Exception:
        return None


def gather() -> dict[str, Any]:
    """Everything the Home screen shows. Each kit command runs in parallel."""
    with ThreadPoolExecutor(max_workers=5) as pool:
        f_status = pool.submit(_kit_json, "status", "--json")
        f_version = pool.submit(_kit_json, "version", "--json")
        f_mcp = pool.submit(_kit_json, "mcp-status", "--json")
        f_market = pool.submit(_kit_json, "marketplace", "--list", "--json")
        f_wf = pool.submit(_workflows)
        status, version, mcp, market, wf = (f.result() for f in (f_status, f_version, f_mcp, f_market, f_wf))
    manifest = _manifest()
    datasets = list(status.get("datasets_loaded") or [])
    facts = _fact_tables(datasets)
    counts = _row_counts(facts)
    try:
        from exakit_nb import model_settings

        from . import aikey

        aikey.load()
        model = model_settings() or {}
    except Exception:
        model = {}
    return {
        "status": status,
        "version": version,
        "mcp": mcp,
        "market": market,
        "manifest": manifest,
        "datasets": [{"id": d, "title": DATASET_TITLES.get(d, d.replace("_", " ").capitalize()),
                      "table": facts.get(d), "rows": counts.get(d)} for d in datasets],
        "model": model,
        "langfuse": _langfuse_state(),
        "approved": _approved(),
        "working_on": _working_on(),
        "workflow": wf["last"],
        "workflow_ago": _ago((wf["last"] or {}).get("last")),
        "workflow_dataset": _dataset_of(wf["events"]),
        "journey": _journey_state(wf["events"]),
        "last_step": _last_step(wf["events"]),
    }


def _langfuse_state() -> dict:
    """Langfuse tracing in this kernel: on only with its address and both keys (the kit's own rule), and where to."""
    import os

    url = os.environ.get("LANGFUSE_BASE_URL") or os.environ.get("LANGFUSE_HOST") or ""
    keys = all(os.environ.get(n) for n in ("LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY"))
    return {"on": bool(url and keys), "url": url, "half": bool(url) and not keys}
