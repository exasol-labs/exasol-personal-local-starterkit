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

from .card import Screen
from .kitinfo import DATASET_TITLES
from .session import SESSION, quiet

KICKER = "Step 4 of 4 · Share and hand off"


def _bare(col):
    return col.strip('"').split(".")[-1].strip('"') if col else None


def _slug(text: str, limit: int = 60) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    s = s if s and s[0].isalpha() else f"d-{s}"
    return s[:limit].strip("-")


def _dash_url() -> str:
    """dash-server's address from the kit's own `exakit status --json`, remembered for when the status check is slow;
    empty when neither knows it (the card then starts it the kit's way)."""
    from .card import LOG_DIR

    cache = LOG_DIR / "dash_url"
    try:
        from exakit_nb.kit_commands import kit_json

        url = ((kit_json("status") or {}).get("urls") or {}).get("dash-server")
        if url:
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            cache.write_text(url, encoding="utf-8")
            return url.rstrip("/")
    except Exception:
        pass
    try:
        return cache.read_text(encoding="utf-8").strip().rstrip("/")
    except OSError:
        return ""


def _alive(url: str) -> bool:
    import urllib.request

    try:
        with urllib.request.urlopen(url + "/", timeout=3) as r:
            return r.status < 500
    except Exception:
        return False


def _nice_name(ds_id: str) -> str:
    """amazon_sales -> 'Amazon sales'; my_data_customer_churn_prepared -> 'Customer churn'."""
    if ds_id in DATASET_TITLES:
        return DATASET_TITLES[ds_id]
    name = re.sub(r"_prepared$|_joined$", "", ds_id)
    name = re.sub(r"^(my_data|starter_kit)_", "", name)
    words = name.replace("_", " ").strip()
    return words[:1].upper() + words[1:] if words else ds_id


def _dataset():
    import exakit.nb as nb

    with quiet():
        SESSION.workflow_id = nb.continue_workflow("share")
        SESSION.open_latest()
        SESSION.dataset.require_approved("share")
    SESSION.log('workflow_id = nb.continue_workflow("share")', "dataset = nb.dataset(connection, nb.chosen_dataset(None))")
    return SESSION.dataset


def _answers(ds_id: str) -> list[dict]:
    """Questions answered in this workflow (step 3), newest first: their approved SQL can become a dashboard."""
    wf = importlib.import_module("exakit_nb.workflow")
    wid = wf.current_workflow() or wf.last_workflow()
    try:
        events = wf.read_log(wid) if wid else []
    except Exception:
        events = []
    approved = {e.get("sql_digest"): e for e in events if e.get("kind") == "ask.approve" and e.get("dataset") == ds_id}
    seen, asked, out = set(), set(), []
    for e in reversed(events):
        if e.get("kind") == "ask.answer" and e.get("sql_digest") in approved and e["sql_digest"] not in seen:
            seen.add(e["sql_digest"])
            a = approved[e["sql_digest"]]
            if a.get("question") in asked:      # the same question asked again: keep the newest run
                continue
            asked.add(a.get("question"))
            out.append({"value": e["sql_digest"], "label": f"{a.get('question')} · {e.get('row_count', '?')} rows",
                        "question": a.get("question"), "sql": a.get("sql")})
    return out


# =====================================================================================================
class Dashboard(Screen):
    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.error = None
        self.ds, self.groups, self.answers = None, [], []
        self.draft = None
        self.preview_url = None
        self.live_url = None
        self.dash = None
        import exakit.nb as nb

        SESSION.release()   # `exakit status` can stall while this process holds a database connection (kit issue)
        url = _dash_url()
        if _alive(url):
            self.dash = {"state": "running", "url": url}
        else:
            try:
                with quiet():
                    self.dash = nb.addon_ready("dash-server", start=True, show=False)   # starts it the kit's way
                SESSION.log('nb.addon_ready("dash-server")')
            except Exception as exc:
                self.dash = {"state": "not running", "url": url}
                self.flash = {"kind": "warn", "v": f"The dashboard server isn't answering ({str(exc).splitlines()[0][:100]}). "
                                                   "Start it from the Home screen, then run this cell again."}
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

    def _tools(self):
        """The kit's dash-server tool adapter, pointed at the address found when the card opened.
        (nb.dash_tools() looks it up again through `exakit status` with a 15-second limit, which a busy kit can miss.)"""
        from exakit_nb.dash_mcp import DashTools
        import exakit.nb as nb

        url = (self.dash or {}).get("url")
        return DashTools(url) if url else nb.dash_tools()

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
        title = f"{_nice_name(ds.id)} by {group.lower().replace('_', ' ')}"
        return sql, title, "count"

    # -- view ------------------------------------------------------------------------------
    def build(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Make a dashboard",
                "sub": "Pick what to show. You get a preview first; it only goes live after you confirm the figures."}
        if self.error:
            return [head, {"t": "msg", "kind": "error", "v": self.error}]
        ds = self.ds
        blocks = [head, {"t": "summary_row", "v": f"{ds.id} · {ds.fact_table} · column map v{ds.version}",
                         "sub": f"Dashboards: {(self.dash or {}).get('state', 'unknown')} at {(self.dash or {}).get('url', '')}"}]
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
                                               "primary": not self.preview_url, "busy": "Building and checking the preview…"}]}]
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

    # -- actions ---------------------------------------------------------------------------
    def on_preview(self, v: dict) -> None:
        import exakit.nb as nb

        sql, title, measure = self._sql_for(v)
        SESSION.release()   # the preview reads `exakit status`, which waits while a connection is held
        title = str(v.get("title") or "").strip() or title
        name = _slug(f"guided-{title}")
        with quiet():
            nb.continue_workflow("share")
            self.draft = nb.share(self.ds, sql, title, name, measure=measure)
            self.preview_url = self.draft.preview(self._tools())
        self.live_url = None
        SESSION.log(f"draft = nb.share(dataset, '''{sql}''', {title!r}, {name!r}, measure={measure!r})",
                    "preview_path = draft.preview(nb.dash_tools())")
        self.flash = {"kind": "ok", "v": "The preview is built and passed its health check. Open it and check the figures."}

    def on_publish(self, v: dict) -> None:
        if self.draft is None:
            raise ValueError("Make a preview first.")
        if not (v.get("checked") and v.get("ok_to_share")):
            raise ValueError("Tick both boxes before you publish.")
        SESSION.release()
        with quiet():
            self.live_url = self.draft.confirm(self._tools(), figures_checked=True)
        SESSION.log("live_path = draft.confirm(nb.dash_tools(), figures_checked=True)")
        self.flash = {"kind": "ok", "v": "Published. The dashboard is live and passed its health check."}


# =====================================================================================================
class Handoff(Screen):
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
        blocks.append({"t": "next", "v": "Back to Start here", "path": "starter-kit-notebooks/data-scientist/00_quickstart.ipynb"})
        return blocks

    def on_bundle(self, _v: dict) -> None:
        import exakit.nb as nb

        ds = SESSION.dataset or _dataset()
        with quiet():
            nb.continue_workflow("share")
            self.bundle = nb.handoff_bundle(SESSION.connection(), ds)
        SESSION.log("handoff = nb.handoff_bundle(connection, dataset)")
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
    from .card import show

    return show(Dashboard(), Handoff())
