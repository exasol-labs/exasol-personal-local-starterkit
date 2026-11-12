"""Step 4 · Share and hand off, in the guided view.

Cards on the kit's own share engine (03_share.ipynb):
  Make a dashboard -> nb.continue_workflow, nb.addon_ready("dash-server"), nb.share(...),
                      ShareDraft.preview(nb.dash_tools()), then ShareDraft.confirm(..., figures_checked=True)
  Hand it off      -> nb.handoff_bundle(connection, dataset)
The kit's rules stay in force: the dashboard reads through the read-only
profile, the preview must be healthy, and nothing goes live until a person
says the figures were checked.
"""

from __future__ import annotations

import importlib

import re
import subprocess
import sys
from pathlib import Path

from .. import actions
from ..card import Screen
from ..session import SESSION

KICKER = "Step 4 of 4 · Share and hand off"


def _bare(col):
    return col.strip('"').split(".")[-1].strip('"') if col else None


def _slug(text: str, limit: int = 60) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    s = s if s and s[0].isalpha() else f"d-{s}"
    return s[:limit].strip("-")


def _title(ds) -> str:
    """The dataset's name as the kit gives it (a sample's label in dataset.conf), else its id in words."""
    label = next((d["label"] for d in actions.run("kit.datasets") if d["id"] == ds.id), None)
    if label:
        return label.split(" (")[0]
    words = ds.id.replace("_", " ").strip()
    return words[:1].upper() + words[1:]


def _dataset():
    SESSION.open_latest("share.open")
    SESSION.dataset.require_approved("share")
    return SESSION.dataset


def _answers(ds_id: str) -> list[dict]:
    """Questions answered in the last workflow (step 3), newest first, from its log (nb.workflow_log): their approved
    SQL can become a dashboard."""
    wf = importlib.import_module("exakit_nb.workflow")   # the module (exakit_nb.workflow is also a function)

    workflows = actions.run("kit.workflows") or []       # nb.list_workflows(): the last one written to
    last = max(workflows, key=lambda r: r.get("last") or "")["id"] if workflows else None
    events = actions.run("kit.workflow_log", workflow_id=last) if last else []
    approved = {e.get("sql_digest"): e for e in events if e.get("kind") == wf.ASK_APPROVE and e.get("dataset") == ds_id}
    seen, asked, out = set(), set(), []
    for e in reversed(events):
        if e.get("kind") == wf.ASK_ANSWER and e.get("sql_digest") in approved and e["sql_digest"] not in seen:
            seen.add(e["sql_digest"])
            a = approved[e["sql_digest"]]
            if a.get("question") in asked:      # the same question asked again: keep the newest run
                continue
            asked.add(a.get("question"))
            out.append({"value": e["sql_digest"], "label": f"{a.get('question')} · {e.get('row_count', '?')} rows",
                        "question": a.get("question"), "sql": a.get("sql")})
    return out


def _first_notebook() -> dict | None:
    rows = actions.run("kit.notebooks", persona=Path.cwd().name) or []
    return rows[0] if rows else None


# =====================================================================================================
class Dashboard(Screen):
    help = (('Preview, check, publish', 'communicate/preview-check-publish#preview-check-publish'),
            ('What a reader sees', 'communicate/what-a-reader-sees#what-a-reader-sees'),)
    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.error = None
        self.ds, self.groups, self.answers = None, [], []
        self.draft = None
        self.preview_url = None
        self.live_url = None
        self.dash = None
        SESSION.release()   # `exakit status` can stall while this process holds a database connection (kit issue)
        try:
            self.dash = actions.run("share.server")     # installs and starts it the kit's way when needed
        except Exception as exc:
            # Nothing for the user to do: making a preview installs and starts it (see _server_ready).
            self.dash = {"state": "not running", "url": "", "why": str(exc).splitlines()[0][:160]}
        try:
            self.ds = _dataset()
            cols = dict(getattr(self.ds.descriptor, "columns", {}) or {})
            label = _bare(self.ds.col("label")) if self.ds.has("label") else None
            first = _bare(self.ds.group_by()[1])
            groups = [c for c, e in cols.items() if e.get("role") in ("category", "flag") and c != label and not e.get("sensitive")]
            self.groups = ([first] if first in groups else []) + [g for g in groups if g != first]
            self.answers = _answers(self.ds.id)
        except Exception as exc:
            self.error = str(exc).splitlines()[0]
        self.refresh()
        SESSION.release()

    # -- what goes on the dashboard ------------------------------------------------------------
    def _sql_for(self, v: dict) -> tuple[str, str, str]:
        import exakit.nb as nb

        ds = self.ds
        if v.get("what") == "answer":
            pick = next((a for a in self.answers if a["value"] == v.get("answer")), None)
            if pick is None:
                raise ValueError("Pick an answer from step 3.")
            return pick["sql"], str(pick["question"]).rstrip("?"), "value"
        group = str(v.get("group") or (self.groups[0] if self.groups else ""))
        if not group:
            raise ValueError("No column was marked Group to compare in step 1.")
        g, count_h = f'"{group}"', nb.count_name(ds)
        rate = ""
        if ds.has("label"):
            rate = f", ROUND(100 * AVG({ds.col('label')}), 1) AS {nb.name(ds.col('label'), 'PCT')}"
        sql = f"SELECT {g} AS {nb.name(group)}, COUNT(*) AS {count_h}{rate} FROM {ds.fact_table} GROUP BY 1 ORDER BY {count_h} DESC"
        title = f"{_title(ds)} by {group.lower().replace('_', ' ')}"
        return sql, title, "count"

    # -- view ------------------------------------------------------------------------------
    def build(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Make a dashboard",
                "sub": "Pick what to show. You get a preview first; it only goes live after you confirm the figures."}
        if self.error:
            return [head, {"t": "msg", "kind": "error", "v": self.error}]
        ds = self.ds
        blocks = [head, {"t": "summary_row", "v": f"{ds.id} · {ds.fact_table} · column map v{ds.version}",
                         "sub": (f"Dashboards: running at {self.dash['url']}" if self._server_up()
                                 else "Dashboards: the dashboard server is set up for you when you make the preview")}]
        group_opts = [{"value": g, "label": g} for g in self.groups]
        options = [{"value": "compare", "title": "A comparison", "text": "Counts per group, with the outcome's rate when there is one.",
                    "disabled": not self.groups, "disabled_reason": "No column was marked Group to compare in step 1.",
                    "fields": [{"id": "group", "type": "select", "label": "Compare by", "value": self.groups[0] if self.groups else "", "options": group_opts}]},
                   {"value": "answer", "title": "An answer from step 3", "text": f"{len(self.answers)} answered question{'s' if len(self.answers) != 1 else ''} to pick from.",
                    "disabled": not self.answers, "disabled_reason": "Ask and run a question in step 3 first.",
                    "fields": [{"id": "answer", "type": "select", "label": "Answer", "value": self.answers[0]["value"] if self.answers else "",
                                "options": [{"value": a["value"], "label": a["label"]} for a in self.answers]}]}]
        blocks += [{"t": "choice", "id": "what", "value": "compare" if self.groups else "answer", "options": options},
                   {"t": "fields", "items": [{"id": "title", "type": "text", "label": "Title (optional)", "placeholder": "Named after the data if empty"}]},
                   {"t": "actions", "items": [{"id": "preview", "label": "Make a preview" if not self.preview_url else "Make a new preview",
                                               "primary": not self.preview_url,
                                               "busy": "Building and checking the preview…" if self._server_up()
                                                       else "Setting up the dashboard server, then building the preview…"}]}]
        if self.draft is not None and self.preview_url:
            blocks += [{"t": "linkcard", "title": "Preview ready and healthy", "text": f"“{self.draft.title}” · not visible to anyone else yet.",
                        "href": self.dash["url"] + self.preview_url, "label": "Open the preview"},
                       {"t": "code", "code_only": True, "title": "The dashboard's query", "v": self.draft.sql},
                       {"t": "checks", "items": [{"id": "checked", "label": "I opened the preview and the figures look right."},
                                                 {"id": "ok_to_share", "label": "This data is OK to share with the people who will see it."}]},
                       {"t": "actions", "items": [{"id": "publish", "label": "Publish", "primary": True, "busy": "Publishing…"}]}]
        if self.live_url:
            blocks.append({"t": "linkcard", "title": "Live", "text": "Anyone who can reach this dashboard server can open it.",
                           "href": self.dash["url"] + self.live_url, "label": "Open the dashboard", "kind": "ok"})
        return blocks

    # -- the dashboard server -----------------------------------------------------------------
    def _server_up(self) -> bool:
        return bool(self.dash and self.dash.get("state") == "running" and self.dash.get("url"))

    def _server_ready(self, again: bool = False) -> None:
        """The dashboard server, installed and running: made so here when it is not, with the kit's own
        nb.addon_ready("dash-server") (`exakit marketplace dash-server`, `exakit start dash-server`). Nothing is
        asked: sharing needs it, and it is the kit's own add-on. ``again`` checks it even when it was up before."""
        if self._server_up() and not again:
            return
        SESSION.release()   # `exakit status` can stall while this process holds a database connection (kit issue)
        self.dash = actions.run("share.server")
        if not self._server_up():
            raise RuntimeError("The dashboard server was installed but is not running "
                               f"(state: {(self.dash or {}).get('state') or 'unknown'}). On Home: Start, next to Dash Server.")

    # -- actions ---------------------------------------------------------------------------
    def on_preview(self, v: dict) -> None:
        sql, title, measure = self._sql_for(v)
        self._server_ready()
        SESSION.release()   # the preview reads `exakit status`, which waits while a connection is held
        title = str(v.get("title") or "").strip() or title
        self.draft = actions.run("share.draft", sql=sql, title=title, name=_slug(f"{self.ds.id}-{title}"), measure=measure)
        try:
            self.preview_url = actions.run("share.preview")
        except Exception:
            if self._gone():
                # It was removed or stopped since this card opened: set it up again and build the preview once more.
                self._server_ready(again=True)
                self.preview_url = actions.run("share.preview")
            else:
                raise
        self.live_url = None
        self.flash = {"kind": "ok", "v": "The preview is built and passed its health check. Open it and check the figures."}

    def _gone(self) -> bool:
        """True when the dashboard server is not there any more (not installed, or stopped): the kit's own state."""
        SESSION.release()
        try:
            state = actions.run("kit.check")
        except Exception:
            return True
        return (state.get("services") or {}).get("dash-server") != "running"

    def on_publish(self, v: dict) -> None:
        if self.draft is None:
            raise ValueError("Make a preview first.")
        if not (v.get("checked") and v.get("ok_to_share")):
            raise ValueError("Tick both boxes before you publish.")
        self._server_ready()
        SESSION.release()
        self.live_url = actions.run("share.publish")
        self.flash = {"kind": "ok", "v": "Published. The dashboard is live and passed its health check."}


# =====================================================================================================
class Handoff(Screen):
    help = (('What the hand-off holds', 'communicate/hand-off-bundle#the-hand-off-bundle'),
            ('When a hand-off goes stale', 'monitor/stale-hand-off#a-training-hand-off-that-went-stale'),)
    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.bundle = None
        self.refresh()

    def build(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Hand it off",
                "sub": "One folder (and a zip) with everything someone needs to repeat or build on this work. No passwords inside."}
        blocks = [head, {"t": "p", "muted": True, "v": "The kit packs:"}, {"t": "list", "items": [
            "README: what was done and how to repeat it",
            "The approved column map (descriptor)",
            "Every query that ran, in order",
            "The workflow log: each step, approval and answer, with times"]},
            {"t": "actions", "items": [{"id": "bundle", "label": "Create the hand-off bundle" if not self.bundle else "Create it again",
                                        "primary": not self.bundle, "busy": "Packing…"}]}]
        b = self.bundle
        if b is not None:
            blocks.append({"t": "linkcard", "title": "Bundle ready", "text": str(b.zip_path or b.path), "kind": "ok",
                           "button": {"id": "reveal", "label": "Show in Finder" if sys.platform == "darwin" else "Show the folder"}})
            blocks.append({"t": "details", "title": f"What's inside ({len(b.files)} files)", "blocks": [
                {"t": "list", "items": list(b.files)}] + ([{"t": "p", "muted": True, "v": " ".join(b.summary)}] if b.summary else [])})
        first = _first_notebook()
        if first:
            blocks.append({"t": "next", "v": f"Back to {first['title'].split(':')[0]}", "path": first["file"]})
        return blocks

    def on_bundle(self, _v: dict) -> None:
        if SESSION.dataset is None:
            _dataset()
        self.bundle = actions.run("share.handoff")
        self.flash = {"kind": "ok", "v": f"Packed {len(self.bundle.files)} files."}

    def on_reveal(self, _v: dict) -> None:
        target = str(self.bundle.zip_path or self.bundle.path)
        if sys.platform == "darwin":
            subprocess.run(["open", "-R", target], check=False)
        elif sys.platform.startswith("win"):
            subprocess.run(["explorer", "/select,", target], check=False)
        else:
            subprocess.run(["xdg-open", str(self.bundle.path)], check=False)


def share():
    """Step 4 in the guided view: preview and publish a dashboard, then create the hand-off bundle."""
    from ..card import show

    return show(Dashboard(), Handoff(), docs="communicate")
