"""Step 3 · Ask in plain words, in the guided view.

Two ways in, one engine (the kit's 02_ask_your_data.ipynb):
  guide.ask()            an Ask card: type a question, check the plan, approve, see the answer
  %%ask <question>       any notebook cell can be just a sentence

Drafting: the user's AI model when one is set up (nb.ask; it sees the approved column map, never rows), otherwise
the kit's rules (nb.draft_question, no model). Either way it is the kit's Proposal: nothing runs before approve(),
and run() goes through the read-only MCP service only. Every step is one cell of the notebook (actions: ask.*).
"""

from __future__ import annotations

import re
from pathlib import Path

from .. import actions
from ..card import Screen
from ..session import SESSION


def _dataset():
    if SESSION.dataset is None or SESSION.latest_approved() != SESSION.followed:
        SESSION.open_latest("ask.open")
    else:
        SESSION.dataset.require_approved("ask")
    return SESSION.dataset


def _model_ready() -> bool:
    model = actions.run("kit.model") or {}
    return bool(model.get("configured"))


def _next_notebook() -> dict | None:
    rows = actions.run("kit.notebooks", persona=Path.cwd().name) or []
    files = [r["file"].rsplit("/", 1)[-1] for r in rows]
    here = next((i for i, f in enumerate(files) if f.startswith("02_")), 2)
    return rows[here + 1] if here + 1 < len(rows) else None


def _formats(frame, dataset=None, currency: str | None = None) -> dict:
    """How each result column is written (exakit_nb.number_format): money in the data's currency, counts, shares."""
    from exakit_nb.number_format import column_format

    return {str(c): column_format(str(c), frame[c].tolist(), dataset, currency) for c in frame.columns}


def _explain(frame, formats: dict | None = None) -> tuple[str, dict | None]:
    """One line on what the answer shows, and a chart when the shape fits. ``formats`` (from _formats) writes every
    number the way a reader expects: money in its currency, counts with separators, shares as %."""
    import pandas as pd

    from exakit_nb.number_format import format_value

    formats = formats or {}

    n = len(frame)
    if n == 0:
        return "No rows match this question.", None
    import warnings

    warnings.filterwarnings("ignore", message="Could not infer format")
    cols = list(frame.columns)
    nums = [c for c in cols if pd.api.types.is_numeric_dtype(pd.to_numeric(frame[c], errors="coerce")) and frame[c].notna().all()
            and not isinstance(frame[c].iloc[0], str)]
    if n == 1 and len(cols) == 1:
        return f"The answer is {format_value(frame.iloc[0, 0], formats.get(str(cols[0]), {}))}.", None
    first = cols[0]
    if "RANK" in cols and len(cols) >= 3:
        # "top Y in each X": name the winner in each group
        second = cols[1]
        tops = frame[frame["RANK"] == 1]
        pairs = [f"{r[first]} → {r[second]}" for _, r in tops.head(8).iterrows()]
        more = f" (and {len(tops) - 8} more)" if len(tops) > 8 else ""
        return f"Top {_readable(second)} in each {_readable(first)}: " + ", ".join(pairs) + more + ".", None
    cols_wo_rank = [c for c in cols if c != "RANK"]
    value = next((c for c in reversed(cols_wo_rank) if c in nums and c != first), None)
    if value is None:
        return f"{n} row{'s' if n != 1 else ''}.", None
    v = pd.to_numeric(frame[value], errors="coerce")
    is_pct = value.upper().endswith("PCT")
    label = _readable(value)
    fmt = formats.get(str(value)) or ({"kind": "percent", "decimals": 1} if is_pct else {"kind": "number", "decimals": 2})
    show = lambda x: format_value(x, fmt)
    dates = pd.to_datetime(frame[first], errors="coerce")
    if dates.notna().all() and n >= 2:
        order = dates.argsort()
        a, b = order.iloc[0], order.iloc[-1]
        line = (f"From {dates.iloc[a]:%b %Y} to {dates.iloc[b]:%b %Y}, {label} went from {show(v.iloc[a])} to {show(v.iloc[b])}. "
                f"Highest: {dates.iloc[v.idxmax()]:%b %Y} ({show(v.max())}).")
        pts = [{"period": f"{dates.iloc[i]:%b %Y}", "value": float(v.iloc[i]) / (100 if is_pct else 1), "rows": None,
                "display": show(v.iloc[i])} for i in order]
        return line, {"t": "line", "title": f"{label} over time", "points": pts, "pct": is_pct}
    hi, lo = v.idxmax(), v.idxmin()
    textcols = [c for c in cols_wo_rank if c not in nums]
    who = (lambda i: " · ".join(str(frame[c].iloc[i]) for c in textcols[:2])) if len(textcols) >= 2 else (lambda i: str(frame[first].iloc[i]))
    line = f"{n} row{'s' if n != 1 else ''}. Highest {label}: {who(hi)} ({show(v.iloc[hi])})."
    if n > 1:
        line += f" Lowest: {who(lo)} ({show(v.iloc[lo])})."
    if len(textcols) >= 2:
        return line, None     # combinations read better as a table than as bars
    items = [{"label": str(frame[first].iloc[i]), "value": float(v.iloc[i]) / (100 if is_pct else 1), "rows": None,
              "display": show(v.iloc[i])} for i in range(min(n, 15))]
    return line, {"t": "bars", "title": f"{label} by {_readable(first)}", "items": items, "pct": is_pct, "overall": None}


def _readable(col: str) -> str:
    """CHURNED_RATE_PCT -> 'CHURNED rate (%)', TOTAL_MONTHLY_FEE -> 'Total MONTHLY_FEE'."""
    c = str(col)
    m = re.match(r"^(.*)_RATE_PCT$", c)
    if m:
        return f"{m.group(1)} rate (%)"
    for pre, word in (("TOTAL_", "Total"), ("AVG_", "Average")):
        if c.startswith(pre):
            return f"{word} {c[len(pre):]}"
    return c.replace("_START", " start").replace("_PCT", " (%)")


# =====================================================================================================
class Ask(Screen):
    """One question: draft -> plan -> approve -> answer. With no question given, shows a question box."""
    help = (('Ask questions in plain language', 'explore/questions'),)

    kind = "card"

    def __init__(self, question: str | None = None, box: bool = True) -> None:
        self.kind = "card" if box else "ask"     # %%ask cells keep their sentence visible in the guided view
        super().__init__()
        self.box = box
        self.question = (question or "").strip()
        self.proposal = None
        self.drafted_by = ""
        self.my_notes: list[str] = []
        self.answer = None
        self.ran_as = ""
        self.history: list[dict] = []
        self.view = "table"                  # the answer as: table, chart, insights or json
        self.board, self.page = "my-dashboard", "Overview"
        self.tile_title: str | None = None       # the pinned tile's title; None: the question asked
        self.error = None
        try:
            self.ds = _dataset()
            self.examples = list(actions.run("ask.examples") or [])
        except Exception as exc:
            self.ds, self.examples = None, []
            self.error = str(exc).splitlines()[0]
        if self.question and self.ds is not None:
            try:
                self._draft(self.question)
            except Exception as exc:
                self.flash = {"kind": "error", "v": str(exc).splitlines()[0]}
        self.refresh()
        SESSION.release()

    # -- drafting --------------------------------------------------------------------------
    def _draft(self, question: str, use_model: bool | None = None) -> None:
        self.question, self.answer, self.my_notes = question.strip(), None, []
        self.tile_title = None                     # a new question: its own title
        if not self.question:
            raise ValueError("Type a question first.")
        use_model = _model_ready() if use_model is None else use_model
        if use_model:
            try:
                self.proposal = actions.run("ask.model", question=self.question)
                self.drafted_by = "your AI model (it saw the column map, never rows)"
                return
            except Exception as exc:
                self.flash = {"kind": "warn", "v": f"Your AI model couldn't draft this ({str(exc).splitlines()[0][:120]}). "
                                                   "The kit's rules tried instead."}
        self.proposal = actions.run("ask.rules", question=self.question)
        self.my_notes = list(self.proposal.doubts[-1:])
        self.drafted_by = "the kit's rules (no AI model, nothing leaves this computer)"

    # -- view ------------------------------------------------------------------------------
    def build(self) -> list[dict]:
        blocks: list[dict] = []
        if self.box:
            blocks.append({"t": "head", "kicker": "Step 3 of 4 · Ask in plain words", "title": "Ask your data",
                           "sub": "Ask in your own words. You see the plan first. Nothing runs until you approve it."})
        if self.error:
            return blocks + [{"t": "msg", "kind": "error", "v": self.error + " Approve a column map in step 1 first."}]
        if self.box:
            ds = self.ds
            blocks.append({"t": "summary_row", "v": f"{ds.id} · {ds.fact_table} · column map v{ds.version}",
                           "sub": "Drafts with your AI model." if _model_ready() else
                                  "Drafts with the kit's rules. Set up an AI model on the Home screen for harder questions."})
            mine = SESSION.your_rules("ASK_RULES", "DRAFT_RULES", "INSIGHT_RULES")
            if mine:
                blocks.append(mine)
            blocks.append({"t": "askbox", "value": self.question, "examples": self.examples,
                           "placeholder": f"For example: {self.examples[0]}" if self.examples else "Ask a question about this data"})
        else:
            blocks.append({"t": "question", "v": self.question})
        p = self.proposal
        if p is not None:
            approved = bool(getattr(p, "_approved_digest", None))
            blocks.append({"t": "proposal", "summary": (self.my_notes[0] if self.my_notes and self.my_notes[0] else "The plan for this question."),
                           "by": self.drafted_by, "assumptions": list(p.assumptions or []), "doubts": list(p.doubts or []),
                           "plan": list(getattr(p, "plan", None) or []), "checked": getattr(p, "checked", None),
                           "checked_line": getattr(p, "checked_line", ""),
                           "sql": p.sql, "approved": approved, "ran": self.answer is not None})
        if self.answer is not None:
            frame, line, chart = self.answer
            blocks.append({"t": "answer", "v": line, "rows": len(frame), "ran_as": self.ran_as})
            blocks += self._outputs(frame, chart)
        if self.box and self.history:
            blocks.append({"t": "details", "title": f"Asked so far ({len(self.history)})", "blocks": [
                {"t": "list", "items": [f"{h['question']} · {h['rows']} rows" for h in self.history]}]})
        after = _next_notebook() if (self.box or self.answer is not None) else None
        if after:   # %%ask cards: the way forward appears once there's an answer
            blocks.append({"t": "next", "v": f"Next: {after['title']}", "path": after["file"]})
        return blocks

    def _outputs(self, frame, chart: dict | None) -> list[dict]:
        """The answer four ways - a table, a chart, insights (sentences from fixed rules: nb.insights) and JSON - with
        downloads made in the browser, then the two ways to keep it: on a dashboard page (nb.pin), and as a verified
        question of the semantic model (proposal.verify) when it was answered from the model."""
        import json

        from exakit_nb.number_format import format_value

        formats = getattr(self, "formats", None) or _formats(frame)
        plain = [[(None if v is None else (float(v) if hasattr(v, "as_integer_ratio") and not isinstance(v, (bool, int)) else v))
                  for v in row] for row in frame.astype(object).values.tolist()]
        columns = [str(c) for c in frame.columns]
        records = [dict(zip(columns, row)) for row in plain]
        views = [{"id": "table", "label": "Table"}] + ([{"id": "chart", "label": "Chart"}] if chart else []) \
            + [{"id": "insights", "label": "Insights"}, {"id": "json", "label": "JSON"}]
        view = self.view if any(v["id"] == self.view for v in views) else "table"
        blocks: list[dict] = [{"t": "tabs", "value": view, "items": views}]
        if view == "chart" and chart:
            blocks.append(chart)
        elif view == "insights":
            said = actions.run("ask.insights") or []
            blocks.append({"t": "list", "items": said})
            blocks.append({"t": "p", "muted": True, "v": "Worked out from the answer by fixed rules: no model, no new query."})
        elif view == "json":
            blocks.append({"t": "pre", "v": json.dumps(records[:50], indent=2, default=str)
                           + ("\n…" if len(records) > 50 else "")})
        else:
            blocks.append({"t": "table", "columns": columns, "rows": plain,
                           "display": [[format_value(v, formats.get(str(c), {})) for c, v in zip(frame.columns, row)]
                                       for row in frame.astype(object).values.tolist()[:200]]})
        import csv
        import io

        out = io.StringIO()
        writer = csv.writer(out)
        writer.writerow(columns)
        writer.writerows(plain)
        items = [{"label": "CSV", "filename": "answer.csv", "mime": "text/csv", "text": out.getvalue()},
                 {"label": "JSON", "filename": "answer.json", "mime": "application/json",
                  "text": json.dumps(records, indent=2, default=str)}]
        if chart and view == "chart":
            items.append({"label": "PNG", "filename": "answer.png", "png": True})
        blocks.append({"t": "downloads", "label": "Download", "items": items})
        # keep it: on a dashboard page, and in the model as a verified question
        p = self.proposal
        blocks += [{"t": "subhead", "v": "Keep this answer",
                    "tip": "Pin it to a page of a dashboard: the next notebook (03_share) publishes the pages as one "
                           "dashboard on Dash Server, with tabs and filters. You can also save a question as a trusted "
                           "question: anyone who asks it again, here or in an AI tool, gets this checked answer "
                           "instead of a new guess."},
                   {"t": "fields", "items": [{"id": "ask_keep", "type": "group", "fields": [
                       {"id": "tile_title", "type": "text", "label": "Title on the dashboard",
                        "value": self.tile_title or (p.question if p is not None else ""), "placeholder": "Revenue by region"},
                       {"id": "board", "type": "text", "label": "Dashboard", "value": self.board, "placeholder": "sales-overview"},
                       {"id": "page", "type": "text", "label": "Page", "value": self.page, "placeholder": "Overview"}]}]},
                   {"t": "actions", "items": [{"id": "pin", "label": "Pin to dashboard", "busy": "Pinning…"}]
                    + ([{"id": "verify", "label": "Save as a trusted question", "busy": "Saving…"}]
                       if p is not None and getattr(p, "request", None) else [])}]
        return blocks

    # -- actions ---------------------------------------------------------------------------
    def on_tab_table(self, _v: dict) -> None:
        self.view = "table"

    def on_tab_chart(self, _v: dict) -> None:
        self.view = "chart"

    def on_tab_insights(self, _v: dict) -> None:
        self.view = "insights"

    def on_tab_json(self, _v: dict) -> None:
        self.view = "json"

    def on_pin(self, v: dict) -> None:
        """Pin the approved answer to a page of a dashboard (nb.pin): its SQL exactly as approved."""
        self.board = str(v.get("board") or self.board).strip().lower() or "my-dashboard"
        self.page = " ".join(str(v.get("page") or self.page).split()) or "Overview"
        title = " ".join(str(v.get("tile_title") or "").split()) or None
        self.tile_title = title
        tile = actions.run("ask.pin", board=self.board, page=self.page, title=title)
        try:
            building = actions.run("ask.prepare_preview", board=self.board) == "building"
        except Exception:                       # noqa: BLE001 - 03_share builds the preview when asked
            building = False
        self.flash = {"kind": "ok", "v": f"Pinned to {self.board} / {self.page} as a {tile['kind']}. "
                      + ("Its preview is being built now, so 03_share shows it at once." if building else "03_share publishes it.")}

    def on_verify(self, _v: dict) -> None:
        """Keep the question in the semantic model as a verified question (proposal.verify)."""
        found = actions.run("ask.verify")
        self.flash = {"kind": "ok", "v": f"Saved as a trusted question: {found['verified']['name']}. Asked again, it gets this answer."}

    def on_draft(self, v: dict) -> None:
        self._draft(str(v.get("question") or ""))

    def on_edit(self, v: dict) -> None:
        """Your own SQL in place of the drafted one; ``title`` (when given) is what it now answers, shown on the tile."""
        if self.proposal is None:
            raise ValueError("Draft a question first: your own SQL then replaces the drafted one.")
        actions.run("ask.edit", sql=str(v.get("sql") or ""))     # the kit checks it is one read-only statement
        self.answer, self.my_notes = None, ["Your own SQL. Check it, then approve."]
        self.drafted_by = "you"
        self.tile_title = " ".join(str(v.get("title") or "").split()) or self.tile_title

    def on_run(self, _v: dict) -> None:
        if self.proposal is None:
            raise ValueError("Draft a question first.")
        # approve() then run(), through the kit's read-only service only (the MCP server's read-only user); when it
        # is not running the kit says so, with its fix (exakit mcp-doctor).
        frame = actions.run("ask.run")
        self.ran_as = "through the kit's read-only service"
        try:
            currency = actions.run("ask.currency")       # the data's own currency, when its table names one
        except Exception:
            currency = None
        self.formats = _formats(frame, self.ds, currency)
        line, chart = _explain(frame, self.formats)
        self.answer, self.view = (frame, line, chart), "table"
        self.history.append({"question": self.proposal.question, "rows": len(frame)})
        self.flash = {"kind": "ok", "v": "Ran after your approval. Logged in the kit's workflow, so the hand-off bundle includes it."}


def ask(question: str | None = None) -> Ask:
    """Step 3 in the guided view: an Ask card. With a question, drafts it right away."""
    from ..card import mark

    return mark(Ask(question, box=True), docs="explore")     # the page's first card: the kit's mark and Docs
