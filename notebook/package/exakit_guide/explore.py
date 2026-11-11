"""Step 2 · Explore and predict, in the guided view.

Cards on the kit's own explore engine (01_explore.ipynb), plus a model
comparison and tested feature ideas:
  Working on        -> nb.continue_workflow, nb.chosen_dataset, nb.dataset
  Is it clean?      -> nb.data_checks, nb.describe_schema / joined_view, nb.typed_view (created on approval)
  Compare and trend -> the kit's group and over-time SQL, nb.note_groups, nb.note_trend
  Predict           -> nb.leakage_check, then modeling.compare (4 models, same split), nb.note_model
  Feature ideas     -> modeling.ideas, each tried on held-out rows before it's kept
"""

from __future__ import annotations

import json
import re
import threading

from . import modeling as M
from . import store
from .card import Screen
from .kitinfo import DATASET_TITLES
from .session import SESSION, quiet

KICKER = "Step 2 of 4 · Explore and predict"
CHECK_TITLES = {
    "repeated key": "Repeated IDs", "repeated id": "Repeated IDs", "exact copies": "Repeated rows",
    "empty cells": "Empty cells", "placeholder": "Placeholder values", "rare label": "Rare outcome",
}


def _bare(col):
    return M._bare(col)


def _ds_label(ds) -> str:
    title = DATASET_TITLES.get(ds.id, ds.id)
    return f"{title} · {ds.fact_table} · column map v{ds.version}"


def _approved_choices() -> list[dict]:
    out = []
    folders = store._store_folders()
    names = {f.name.upper() for f, _ in folders}
    for _folder, doc in folders:
        ds_id = str(doc.get("dataset") or "")
        obj = (doc.get("source") or {}).get("object") or ""
        if f"EXAKIT_PREPARED.{obj.replace('.', '__')}__PLAIN".upper() in names:
            continue    # the kit can't read this raw table's map back; its plain-name version is listed instead
        if ds_id and doc.get("status") == "approved":
            out.append({"value": ds_id, "label": f"{DATASET_TITLES.get(ds_id, ds_id)} · {obj}"})
    return out


def _state():
    """Step 2's shared state lives on the session."""
    if not hasattr(SESSION, "x"):
        SESSION.x = {}
    return SESSION.x


# =====================================================================================================
class WorkingOn(Screen):
    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.loading = True
        self.choices: list[dict] = []
        self.kit_said = ""
        SESSION.listen(self)
        self.refresh()
        threading.Thread(target=self._load, daemon=True).start()

    def _load(self) -> None:
        import exakit.nb as nb

        try:
            with quiet() as out:
                SESSION.workflow_id = nb.continue_workflow("explore")
                conn = SESSION.connection()
                SESSION.open_latest()
            self.kit_said = out.text
            SESSION.log("import exakit.nb as nb", "connection = nb.connect()", 'workflow_id = nb.continue_workflow("explore")',
                        "dataset = nb.dataset(connection, nb.chosen_dataset(None))")
            self.choices = _approved_choices()
        except Exception as exc:
            self.flash = {"kind": "error", "v": f"Couldn't open the data you approved last: {str(exc).splitlines()[0]} "
                                                "Pick another below, or approve one in step 1."}
            self.choices = _approved_choices()
        self.loading = False
        self.refresh()
        SESSION.changed("dataset", self)
        SESSION.release()

    def build(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Working on",
                "sub": "The data you approved in step 1. Everything below uses it."}
        if self.loading:
            return [head, {"t": "empty", "v": "Opening the data you approved last…"}]
        ds = SESSION.dataset
        blocks = [head]
        if ds is not None:
            rows = ""
            try:
                n = SESSION.connection().execute(f"SELECT COUNT(*) FROM {ds.fact_table}").fetchone()[0]
                rows = f" · {int(n):,} rows"
            except Exception:
                pass
            blocks.append({"t": "summary_row", "v": _ds_label(ds) + rows,
                           "sub": "Predicting " + (_bare(ds.col("label")) if ds.has("label") else "nothing (explore only)")})
        if self.choices:
            current = ds.id if ds is not None else ""
            blocks.append({"t": "inline_form", "fields": [{"id": "pick", "type": "select", "label": "Switch to",
                           "value": current, "options": self.choices}], "action": {"id": "switch", "label": "Use this"}})
        if SESSION.code:
            blocks.append({"t": "code", "code_only": True, "title": "The kit calls behind this step", "v": "\n".join(SESSION.code)})
        return blocks

    def on_switch(self, v: dict) -> None:
        import exakit.nb as nb

        ds_id = str(v.get("pick") or "")
        with quiet():
            SESSION.dataset = nb.dataset(SESSION.connection(), ds_id)
        SESSION.log(f'dataset = nb.dataset(connection, "{ds_id}")')
        _state().clear()
        self.flash = {"kind": "ok", "v": f"Now working on {ds_id}."}
        SESSION.changed("dataset", self)

    def on_session(self, what: str) -> None:
        self.refresh()


# =====================================================================================================
class Prepare(Screen):
    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.findings = None
        self.typed = None
        self.joined = None
        self.kit_said = ""
        SESSION.listen(self)
        self.refresh()

    def on_session(self, what: str) -> None:
        if what == "dataset" and SESSION.dataset is not None:
            self._check()
        self.refresh()

    def _check(self) -> None:
        import exakit.nb as nb

        ds, conn = SESSION.dataset, SESSION.connection()
        with quiet() as out:
            self.findings = nb.data_checks(conn, ds, show=False)
            try:
                self.joined = nb.describe_schema(conn, ds).joined_view(ds)
            except Exception:
                self.joined = None
            self.typed = nb.typed_view(conn, ds)
        self.kit_said = out.text
        SESSION.log("findings = nb.data_checks(connection, dataset)", "typed = nb.typed_view(connection, dataset)")

    def build(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Is the data clean?",
                "sub": "The kit checked every row. It can make a cleaned copy (a view); your table stays as it is."}
        if SESSION.dataset is None or self.findings is None:
            return [head, {"t": "empty", "v": "Waiting for the data…"}]
        items = []
        for _, r in self.findings.iterrows():
            items.append({"title": CHECK_TITLES.get(r["CHECK"], r["CHECK"].capitalize()) + (f" in {r['COLUMN_NAME']}" if r["COLUMN_NAME"] else ""),
                          "count": int(r["ROWS_AFFECTED"]), "pct": float(r["PCT"]), "text": str(r["MEANS"]),
                          "kind": "warn" if r["CHECK"] in ("placeholder", "exact copies", "repeated key", "repeated id") else "info"})
        blocks = [head]
        if not items:
            blocks.append({"t": "msg", "kind": "ok", "v": "No problems found: no repeats, copies, empty cells or placeholders."})
        else:
            blocks.append({"t": "findings", "items": items})
        if self.joined is not None and getattr(self.joined, "needed", False):
            joins = [f"{j.get('source', '')} → {j.get('target', '')}" for j in (self.joined.joins or [])]
            blocks += [{"t": "subhead", "v": "Linked tables"},
                       {"t": "p", "v": "This table links to others. A joined view brings their columns in.", "muted": True},
                       {"t": "list", "items": joins},
                       {"t": "code", "code_only": True, "title": "The view the kit would create", "v": self.joined.sql},
                       {"t": "actions", "items": [{"id": "join", "label": "Create the joined view", "busy": "Creating…"}]}]
        t = self.typed
        if t is not None and t.needed and t.created is None:
            fix = [f"{c.column}: {c.before} → {c.after} ({c.why})" for c in t.changes] + list(t.cleaning)
            blocks += [{"t": "subhead", "v": "A cleaned copy"},
                       {"t": "p", "v": "The kit proposes a cleaned view that fixes this:", "muted": True},
                       {"t": "list", "items": fix},
                       {"t": "code", "code_only": True, "title": "The view the kit would create", "v": t.sql},
                       {"t": "actions", "items": [{"id": "clean", "label": "Create the cleaned copy", "primary": True, "busy": "Creating…"}]},
                       {"t": "p", "v": "Nothing is created until you click. The steps below then use the cleaned copy.", "muted": True}]
        elif t is not None and t.created is not None:
            blocks.append({"t": "msg", "kind": "ok", "v": f"Using the cleaned copy {t.view}. The steps below read it."})
        elif t is not None:
            blocks.append({"t": "p", "muted": True, "v": "No cleaned copy needed: every column already has the right type and nothing needs fixing."})
        if self.kit_said:
            blocks.append({"t": "details", "title": "What the kit said", "blocks": [{"t": "pre", "v": self.kit_said}]})
        return blocks

    def on_clean(self, _v: dict) -> None:
        with quiet() as out:
            SESSION.dataset = self.typed.create(SESSION.connection())
        self.kit_said = out.text
        SESSION.log("dataset = typed.create(connection)")
        _state().clear()
        self.flash = {"kind": "ok", "v": "Created the cleaned copy. Everything below now uses it."}
        created = self.typed
        self._check()
        self.typed = created if self.typed is None or not self.typed.needed else self.typed
        SESSION.changed("dataset", self)

    def on_join(self, _v: dict) -> None:
        with quiet() as out:
            SESSION.dataset = self.joined.create(SESSION.connection())
        self.kit_said = out.text
        SESSION.log("dataset = joined.create(connection)")
        _state().clear()
        self.flash = {"kind": "ok", "v": "Created the joined view. Everything below now uses it."}
        self._check()
        SESSION.changed("dataset", self)


# =====================================================================================================
class Compare(Screen):
    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.groups: list[str] = []
        self.group = None
        self.result = None
        self.trend = None
        SESSION.listen(self)
        self.refresh()

    def on_session(self, what: str) -> None:
        if what == "dataset" and SESSION.dataset is not None:
            self._options()
            self._groups()
            self._trend()
        self.refresh()

    def _options(self) -> None:
        ds = SESSION.dataset
        cols = dict(getattr(ds.descriptor, "columns", {}) or {})
        label = _bare(ds.col("label")) if ds.has("label") else None
        cands = [c for c, e in cols.items() if e.get("role") in ("category", "flag") and c != label and not e.get("sensitive")]
        first = _bare(ds.group_by()[1])
        self.groups = ([first] if first in cands else []) + [c for c in cands if c != first]
        if self.group not in self.groups:
            self.group = self.groups[0] if self.groups else None

    def _groups(self) -> None:
        import exakit.nb as nb

        self.result = None
        if not self.group:
            return
        ds, conn = SESSION.dataset, SESSION.connection()
        g = f'"{self.group}"'
        group_h, count_h = nb.name(self.group), nb.count_name(ds)
        has_label = ds.has("label")
        pct_h = nb.name(ds.col("label"), "PCT") if has_label else None
        rate = f",\n       ROUND(100 * AVG({ds.col('label')}), 1) AS {pct_h}" if pct_h else ""
        sql = f"SELECT {g} AS {group_h},\n       COUNT(*) AS {count_h}{rate}\nFROM {ds.fact_table}\nGROUP BY {g}\nORDER BY {count_h} DESC\nLIMIT 15"
        with quiet():
            frame = nb.sql(conn, sql)
            overall = nb.sql(conn, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({ds.col('label')}), 1) AS PCT FROM {ds.fact_table}") if pct_h else None
            note = nb.note_groups(frame, ds, group_h, count_h, pct_h, overall=(overall["N"][0], overall["PCT"][0]) if pct_h else None)
        SESSION.log(f"groups = nb.sql(connection, '''{sql}''')")
        if pct_h:
            items = [{"label": "(no value)" if r[group_h] is None else str(r[group_h]), "value": float(r[pct_h] or 0) / 100, "rows": int(r[count_h])}
                     for _, r in frame.iterrows() if int(r[count_h]) >= 30]
            items.sort(key=lambda i: -i["value"])
            title = f"{_bare(ds.col('label'))} rate by {self.group}"
        else:
            items = [{"label": "(no value)" if r[group_h] is None else str(r[group_h]), "value": int(r[count_h]), "rows": int(r[count_h])} for _, r in frame.iterrows()]
            title = f"{count_h.replace('_', ' ').capitalize()} by {self.group}"
        self.result = {"title": title, "items": items, "pct": bool(pct_h),
                       "overall": float(overall["PCT"][0]) / 100 if pct_h else None, "note": note, "sql": sql}

    def _trend(self) -> None:
        import exakit.nb as nb

        self.trend = None
        ds, conn = SESSION.dataset, SESSION.connection()
        if not ds.has("date"):
            self.trend = {"skip": "No date was chosen in step 1, so there is no trend to show."}
            return
        d = ds.col("date")
        count_h = nb.count_name(ds)
        pct_h = nb.name(ds.col("label"), "PCT") if ds.has("label") else None
        with quiet():
            span = nb.sql(conn, f"SELECT DAYS_BETWEEN(MAX({d}), MIN({d})) AS DAYS FROM {ds.fact_table}")
            days = int(span["DAYS"][0] or 0)
            period = "DAY" if days <= 62 else "MONTH" if days <= 3 * 366 else "YEAR"
            rate = f",\n       ROUND(100 * AVG({ds.col('label')}), 1) AS {pct_h}" if pct_h else ""
            sql = (f"SELECT CAST(DATE_TRUNC('{period}', {d}) AS DATE) AS {period}_START,\n       COUNT(*) AS {count_h}{rate}\n"
                   f"FROM {ds.fact_table}\nWHERE {d} IS NOT NULL\nGROUP BY 1\nORDER BY 1")
            frame = nb.sql(conn, sql)
            note = nb.note_trend(frame, ds, f"{period}_START", count_h, pct_h)
        SESSION.log(f"over_time = nb.sql(connection, '''{sql}''')")
        fmt = {"DAY": "%d %b", "MONTH": "%b %Y", "YEAR": "%Y"}[period]
        col = pct_h or count_h
        import pandas as pd

        when = pd.to_datetime(frame[f"{period}_START"], errors="coerce")
        pts = [{"period": when.iloc[i].strftime(fmt) if pd.notna(when.iloc[i]) else str(r[f"{period}_START"]),
                "value": (float(r[col] or 0) / 100) if pct_h else int(r[col]), "rows": int(r[count_h])}
               for i, (_, r) in enumerate(frame.iterrows())
               if not pct_h or int(r[count_h]) >= 30]   # the kit's rule: a % from under 30 rows isn't trustworthy
        title = (f"{_bare(ds.col('label'))} rate by {period.lower()}" if pct_h else f"{count_h.replace('_', ' ').capitalize()} by {period.lower()}")
        self.trend = {"title": title, "points": pts, "pct": bool(pct_h), "note": note, "sql": sql}

    def build(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Compare groups and see trends",
                "sub": "Where the outcome is higher or lower, and how it changes over time."}
        if SESSION.dataset is None:
            return [head, {"t": "empty", "v": "Waiting for the data…"}]
        blocks = [head]
        if self.groups:
            blocks.append({"t": "inline_form", "fields": [{"id": "group", "type": "select", "label": "Compare by", "value": self.group,
                                                           "options": [{"value": g, "label": g} for g in self.groups]}],
                           "action": {"id": "regroup", "label": "Show"}, "live": True})
        r = self.result
        if r:
            blocks += [{"t": "bars", "title": r["title"], "items": r["items"], "pct": r["pct"], "overall": r["overall"],
                        "note": "Dashed line: overall rate. Highlighted bars are above it. Groups under 30 rows are left out." if r["pct"] else ""},
                       {"t": "note", "v": r["note"]}, {"t": "code", "code_only": True, "title": "The query", "v": r["sql"]}]
        elif not self.groups:
            blocks.append({"t": "p", "muted": True, "v": "No column was marked Group to compare in step 1."})
        t = self.trend
        if t and t.get("skip"):
            blocks.append({"t": "p", "muted": True, "v": t["skip"]})
        elif t:
            blocks += [{"t": "line", "title": t["title"], "points": t["points"], "pct": t["pct"],
                        "note": "Periods with fewer than 30 rows are left out." if t["pct"] else ""},
                       {"t": "note", "v": t["note"]}, {"t": "code", "code_only": True, "title": "The query", "v": t["sql"]}]
        return blocks

    def on_regroup(self, v: dict) -> None:
        self.group = str(v.get("group") or self.group)
        self._groups()


# =====================================================================================================
class Predict(Screen):
    """The model lab: the Data Scientist picks the task, the model and the split; the results follow."""

    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.data = None
        self.leaks: list[str] = []
        self.result = None
        self.result_task = None
        SESSION.listen(self)
        self.refresh()

    def on_session(self, what: str) -> None:
        if what == "dataset" and SESSION.dataset is not None:
            self._load()
        self.refresh()

    def _load(self) -> None:
        import exakit.nb as nb

        ds, conn = SESSION.dataset, SESSION.connection()
        self.result, self.result_task = None, None
        _state().pop("result", None)
        with quiet():
            self.leaks = nb.leakage_check(conn, ds, show=False)
            self.data = M.load(conn, ds, self.leaks)
        _state()["data"] = self.data
        SESSION.log("leaking = nb.leakage_check(connection, dataset)", f"rows = nb.sql(connection, '''{self.data.sql}''')")

    # -- view --------------------------------------------------------------------------------
    def _model_options(self, task: str) -> list[dict]:
        opts = [{"value": "all", "label": "Compare all", "group": ""}] if task in ("predict_yes_no", "predict_number") else []
        for key, (family, label, _s, _f) in M.catalog(task).items():
            if key == "baseline":
                continue
            opts.append({"value": key, "label": label, "group": family})
        return opts

    def build(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Build a model",
                "sub": "Choose what to do, which model and how to split the data. Or keep the recommendations."}
        if SESSION.dataset is None or self.data is None:
            return [head, {"t": "empty", "v": "Waiting for the data…"}]
        d = self.data
        measures = d.numeric
        has_target = bool(d.target_flag)
        options = [
            {"value": "predict_yes_no", "title": "Predict yes or no", "text": f"Predicts whether {d.target_flag} is 1 or 0 for a row (classification). Learns from past rows where the answer is known." if has_target
             else "Predicts yes or no for each row (classification).", "disabled": not has_target,
             "disabled_reason": "Needs a yes-or-no column. Pick one in step 1 (What do you want to predict?).",
             "fields": [{"id": "model_predict_yes_no", "type": "select", "label": "Model (Compare all is recommended)", "value": "all", "options": self._model_options("predict_yes_no")}]},
            {"value": "predict_number", "title": "Predict a number", "text": "Estimates an amount, like a deal size (regression). Learns from past rows where the amount is known.",
             "disabled": not measures, "disabled_reason": "Needs a column marked Number to add up.",
             "fields": [{"id": "target_number", "type": "select", "label": "Number to predict", "value": measures[0] if measures else "",
                         "options": [{"value": m, "label": m} for m in measures]},
                        {"id": "model_predict_number", "type": "select", "label": "Model (Compare all is recommended)", "value": "all", "options": self._model_options("predict_number")}]},
            {"value": "find_groups", "title": "Find natural groups", "text": "Sorts the rows into groups of similar rows (clustering). Nothing to predict: the groups come from the data itself.",
             "fields": [{"id": "model_find_groups", "type": "select", "label": "Model", "value": "kmeans", "options": self._model_options("find_groups")},
                        {"id": "clusters", "type": "select", "label": "How many groups", "value": "0",
                         "options": [{"value": "0", "label": "Let the data decide (2-6)"}] + [{"value": str(k), "label": str(k)} for k in range(2, 9)]}]},
            {"value": "find_unusual", "title": "Find unusual rows", "text": "Finds the rows that look least like the rest (anomaly detection). Nothing to predict.",
             "fields": [{"id": "model_find_unusual", "type": "select", "label": "Model", "value": "isolation_forest", "options": self._model_options("find_unusual")},
                        {"id": "contamination", "type": "range", "label": "Share of rows to flag", "value": 2, "min": 1, "max": 10, "step": 1, "unit": "%"}]},
        ]
        n = len(d.frame)
        pos = int(d.frame[d.target_flag].sum()) if has_target else None
        blocks = [head,
                  {"t": "choice", "id": "task", "value": "predict_yes_no" if has_target else "predict_number" if measures else "find_groups", "options": options, "cols": 4},
                  {"t": "split", "rows": n, "pos": pos, "has_date": bool(d.date), "date": d.date,
                   "groups": [g for g in d.groups if g != d.target_flag], "supervised": ["predict_yes_no", "predict_number"]},
                  {"t": "details", "title": "Advanced settings", "blocks": [
                      {"t": "fields", "items": [
                          {"id": "effort", "type": "select", "label": "Effort (trees and boosting rounds)", "value": "balanced",
                           "options": [{"value": "fast", "label": "Fast"}, {"value": "balanced", "label": "Balanced"}, {"value": "thorough", "label": "Thorough"}]},
                          {"id": "max_depth", "type": "number", "label": "Max tree depth (empty = no limit) · trees, boosting", "value": ""},
                          {"id": "C", "type": "number", "label": "Regularisation C (lower = simpler) · linear, SVM", "value": "1.0"},
                          {"id": "neighbours", "type": "number", "label": "Neighbours · k-nearest, outlier factor", "value": "15"},
                          {"id": "learning_rate", "type": "number", "label": "Learning rate · boosting", "value": "0.1"}]}]},
                  {"t": "plan", "v": "Leaves out the columns below; the rest go into the model.", "inputs": [],
                   "left_out": [{"column": c, "why": w} for c, w in d.left_out]},
                  {"t": "actions", "items": [{"id": "run", "label": "Run", "primary": True, "busy": "Training…"}]}]
        if self.result is not None:
            blocks += self._result_blocks()
        return blocks

    def _result_blocks(self) -> list[dict]:
        task, res = self.result_task, self.result
        out = [{"t": "divider"}, {"t": "subhead", "v": M.TASKS[task][0]}]
        run = res.get("_run")
        for note in (run.notes if run else []):
            out.append({"t": "p", "muted": True, "v": note})
        for c, why in (run.dropped if run else []):
            out.append({"t": "msg", "kind": "warn", "v": f"Left out {c}: it {why}."})
        if task in ("predict_yes_no", "predict_number"):
            sp = res["split"]
            line = sp["text"] + (f" Learn from {sp['train']:,} rows, test on {sp['test']:,}" +
                                 (f" ({sp['train_pos']:,} and {sp['test_pos']:,} with a 1)." if "test_pos" in sp else "."))
            out.append({"t": "p", "v": line})
            if sp.get("warn"):
                out.append({"t": "msg", "kind": "warn", "v": sp["warn"]})
            rows = []
            for r in res["board"]:
                if "error" in r:
                    rows.append({"model": f"{r['model']} (couldn't train: {r['error']})", "cells": ["", "", "", "", ""], "picked": False})
                    continue
                if task == "predict_yes_no":
                    cells = [f"{r['cv']:.3f} ± {r['cv_sd']:.3f}", f"{r['roc_auc']:.3f}", f"{r['pr_auc']:.3f}", f"{r['f1']:.2f}", f"{r['seconds']:.1f}s"]
                else:
                    cells = [f"{r['cv']:.3f} ± {r['cv_sd']:.3f}", f"{r['r2']:.3f}", f"{r['mae']:,.0f}", f"{r['rmse']:,.0f}", f"{r['seconds']:.1f}s"]
                rows.append({"model": r["model"], "family": r["family"], "cells": cells, "picked": r is res["pick"]})
            metric = run.metric_label
            headers = ([f"Cross-validated {metric}", "Held-out ROC AUC", "Held-out PR AUC", "F1", "Time"] if task == "predict_yes_no"
                       else ["Cross-validated R²", "Held-out R²", "Mean error (MAE)", "RMSE", "Time"])
            pick, best = res["pick"], res["best"]
            if res["chosen_by"] == "you":
                base = next((r for r in res["board"] if r.get("key") == "baseline" and "cv" in r), None)
                why = f"You picked {pick['model']}." + (f" The baseline (no learning) scores {base['cv']:.3f}, for comparison." if base else "")
            elif best is pick:
                why = f"{pick['model']} has the best cross-validated {metric}."
            else:
                why = f"{best['model']} scored {best['cv'] - pick['cv']:.3f} higher, within the noise, so the simpler {pick['model']} is picked."
            out += [{"t": "board", "headers": headers, "rows": rows, "why": why},
                    {"t": "metrics", "items": [
                        {"label": f"Held-out {metric}", "value": f"{pick['held']:.2f}",
                         "sub": ("0.5 is guessing, 1.0 is perfect" if metric == "ROC AUC" else
                                 f"guessing scores {run.rate:.2f}" if metric == "PR AUC" else "0 is guessing the average, 1 is perfect")},
                        {"label": "Learned from", "value": f"{res['train_rows']:,}", "sub": "rows"},
                        {"label": "Tested on", "value": f"{res['test_rows']:,}", "sub": "rows it never saw"}]}]
            if res.get("note"):
                out.append({"t": "note", "v": res["note"]})
            if res.get("importance"):
                out.append({"t": "bars", "title": "What the model leans on", "items": res["importance"], "pct": False, "overall": None,
                            "note": "How much the held-out score drops when that input is scrambled. Leads to look into, not causes."})
            if res.get("ideas_used"):
                out.append({"t": "p", "muted": True, "v": "Includes your kept ideas: " + ", ".join(res["ideas_used"]) + "."})
            out.append({"t": "details", "title": "How this was calculated", "blocks": [{"t": "list", "items": [
                f"Rows: up to {M.ROW_LIMIT:,}, newest first, read once from the approved data.",
                f"Split: {sp['text']} {res['folds']}-fold cross-validation on the learning side.",
                "Compare all: every model of this task on the same rows; the best cross-validated score wins, a simpler model within 0.01 wins a tie." if res["chosen_by"] != "you"
                else "Your model, trained on the same rows as the baseline it is shown against.",
                "Inputs: blanks in numbers filled with the middle value; groups become yes/no indicators, values seen under 10 times pooled.",
                "Rare outcomes get extra weight (balanced class weights). Fixed random seed 0: the same result every run."]}]})
        elif task == "find_groups":
            g = res
            quality = "clearly separate" if g["score"] >= 0.5 else "fairly distinct" if g["score"] >= 0.25 else "overlapping: real but soft differences"
            out.append({"t": "p", "v": f"{g['model']} found {g['k']} groups in {g['rows']:,} rows. "
                                       f"Separation score {g['score']:.2f} (0 = overlapping, 1 = clearly separate): {quality}."
                                       + (" Hierarchical clustering ran on a 5,000-row sample." if g["sampled"] else "")})
            if g["tried"]:
                out.append({"t": "p", "muted": True, "v": "Tried " + ", ".join(f"{k} groups ({s:.2f})" for k, s in g["tried"]) + "; picked the best separated."})
            out.append({"t": "clusters", "groups": g["groups"], "overall": g.get("overall_rate"),
                        "outcome": SESSION.dataset and (_bare(SESSION.dataset.col("label")) if SESSION.dataset.has("label") else None)})
        else:
            u = res
            line = f"{u['model']} flagged {u['flagged']:,} of {u['rows']:,} rows ({u['flagged'] / max(u['rows'], 1):.1%}) as unusual."
            if u.get("rate_unusual") is not None:
                out_name = _bare(SESSION.dataset.col("label")) if SESSION.dataset.has("label") else "the outcome"
                line += f" {out_name} is 1 for {u['rate_unusual']:.0%} of them, against {u['rate_rest']:.0%} of the rest."
            out.append({"t": "p", "v": line})
            if u["traits"]:
                out.append({"t": "list", "items": ["What the flagged rows have in common: " + t for t in u["traits"]]})
            out.append({"t": "table", "columns": u["columns"][-1:] + u["columns"][:-1], "rows": [r[-1:] + r[:-1] for r in u["top"]],
                        "wrap_first": True})
            out.append({"t": "p", "muted": True, "v": "The 10 most unusual rows. Unusual is not wrong: check them before acting."})
        return out

    # -- run ---------------------------------------------------------------------------------
    def on_run(self, v: dict) -> None:
        import exakit.nb as nb

        task = v.get("task") or "predict_yes_no"
        d = self.data
        kept = _state().get("kept", {}) if task in ("predict_yes_no", "predict_number") else {}
        target_number = v.get("target_number") if task == "predict_number" else None
        settings = {k: v.get(k) for k in ("train_pct", "split_method", "split_group", "folds", "effort", "max_depth", "C",
                                          "neighbours", "learning_rate", "clusters", "contamination")}
        run = M.prepare(d, task, target_number, {k: x["series"] for k, x in kept.items()})
        model = v.get(f"model_{task}") or "all"
        if task in ("predict_yes_no", "predict_number"):
            res = M.supervised(d, run, settings, model)
            res["importance"] = M.importance(res, run.metric)
            res["ideas_used"] = [x["title"] for x in kept.values()]
            if task == "predict_yes_no" and run.metric == "roc_auc":
                with quiet():
                    note = nb.note_model(res["pick"]["held"], SESSION.dataset, len(run.X), run.rate)
                    # the kit's sentence assumes its fixed 75/25 split; say what this run actually did
                    res["note"] = note.replace("It was checked on a quarter of them it had not seen.",
                                               f"It was checked on {res['test_rows']:,} of them it had not seen.")
        elif task == "find_groups":
            res = M.find_groups(d, run, settings, model)
        else:
            res = M.find_unusual(d, run, settings, model)
        res["_run"] = run
        self.result, self.result_task = res, task
        _state().update({"result": res if task in ("predict_yes_no", "predict_number") else None, "task": task,
                         "target_number": target_number, "settings": settings, "run": run})
        SESSION.log(f"# model lab: task={task}, model={model}, settings={settings}  (exakit_guide.modeling)")
        if task in ("predict_yes_no", "predict_number"):
            self.flash = {"kind": "ok", "v": f"Done. {res['pick']['model']} is " + ("your pick." if model != "all" else "the pick.")
                                             + " The feature ideas below are tested against it."}
        else:
            self.flash = {"kind": "ok", "v": "Done."}
        SESSION.changed("model", self)


# =====================================================================================================
class Ideas(Screen):
    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.items: list = []
        self.tried: dict[str, dict] = {}
        self.for_task = None
        SESSION.listen(self)
        self.refresh()

    def on_session(self, what: str) -> None:
        if what == "dataset":
            self.items, self.tried, self.for_task = [], {}, None
            _state().pop("kept", None)
        if what == "model":
            st = _state()
            if st.get("result") is not None and st.get("task") != self.for_task:
                self.items, self.tried, self.for_task = M.ideas(st["data"], st["run"]), {}, st.get("task")
                st.pop("kept", None)
        self.refresh()

    def _ai_ready(self) -> bool:
        try:
            from exakit_nb import model_settings

            return bool((model_settings() or {}).get("configured"))
        except Exception:
            return False

    def build(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Feature ideas",
                "sub": "New inputs the model could use. Each is tried on rows the model never saw, and only kept if it helps."}
        nxt = {"t": "next", "v": "Next: ask in plain words", "path": "starter-kit-notebooks/data-scientist/02_ask_your_data.ipynb"}
        st = _state()
        if st.get("task") in ("find_groups", "find_unusual"):
            return [head, {"t": "empty", "v": "Feature ideas are tested against a prediction score, so they apply to Predict yes or no "
                                              "and Predict a number. Groups and unusual rows have no score to improve."}, nxt]
        res = st.get("result")
        if res is None:
            return [head, {"t": "empty", "v": "Run a prediction above first. The ideas are tested against the picked model."}, nxt]
        kept = st.get("kept", {})
        items = []
        for idea in self.items:
            t = self.tried.get(idea.id)
            items.append({"id": idea.id, "title": idea.title, "why": idea.why, "sql": idea.sql, "source": idea.source,
                          "verdict": t["verdict"] if t else None, "text": t["text"] if t else None, "kept": idea.id in kept})
        blocks = [head, {"t": "p", "muted": True, "v": f"Tested with {res['pick']['model']} on the split you chose."},
                  {"t": "ideas", "items": items}]
        if not items:
            blocks.append({"t": "p", "muted": True, "v": "No ideas fit this data's columns."})
        if kept:
            blocks.append({"t": "actions", "items": [{"id": "rerun", "label": f"Run again with {len(kept)} kept idea{'s' if len(kept) > 1 else ''}",
                                                      "primary": True, "busy": "Training…"}]})
        if self._ai_ready():
            blocks += [{"t": "actions", "items": [{"id": "ai", "label": "Ask AI for more ideas", "busy": "Asking…"}]},
                       {"t": "p", "muted": True, "v": "Sends column names, their roles, the kit's evidence and the scores. Never rows."}]
        else:
            blocks.append({"t": "p", "muted": True, "v": "These ideas come from rules. Set up an AI model on the Home screen to also get ideas from AI (it sees column names and scores, never rows)."})
        return blocks + [nxt]

    def __getattr__(self, name: str):
        if name.startswith("on_try:"):
            return lambda _v, i=name.split(":", 1)[1]: self._try(i)
        if name.startswith("on_keep:"):
            return lambda _v, i=name.split(":", 1)[1]: self._keep(i)
        raise AttributeError(name)

    def _try(self, idea_id: str) -> None:
        st = _state()
        idea = next(i for i in self.items if i.id == idea_id)
        self.tried[idea_id] = M.try_idea(st["data"], st["task"], st.get("target_number"), st["settings"], st["result"]["pick"]["key"],
                                         st["result"], idea, {k: v["series"] for k, v in st.get("kept", {}).items()})

    def _keep(self, idea_id: str) -> None:
        kept = _state().setdefault("kept", {})
        if idea_id in kept:
            kept.pop(idea_id)
            return
        idea = next(i for i in self.items if i.id == idea_id)
        t = self.tried.get(idea_id)
        if t and t["verdict"] == "suspicious":
            raise ValueError("This idea makes the score almost perfect, which usually means it gives the answer away. It can't be kept.")
        kept[idea_id] = {"title": idea.title, "series": t["series"] if t else idea.build(_state()["data"].frame), "sql": idea.sql}

    def on_rerun(self, _v: dict) -> None:
        raise ValueError("Click Run in the Build a model card above: it uses your kept ideas.")

    def on_ai(self, _v: dict) -> None:
        """Ask the user's model for ideas, limited to kinds the rules can build and test."""
        from exakit_nb import model_client

        st = _state()
        d, ds, run = st["data"], SESSION.dataset, st["run"]
        endpoint = model_client()
        if endpoint is None:
            raise ValueError("No AI model is set up. Use Set up on the Home screen.")
        client, model = endpoint
        cols = {c: {"role": e.get("role"), "evidence": e.get("evidence")} for c, e in (ds.descriptor.columns or {}).items()
                if not e.get("sensitive")}
        prompt = {"target": run.target, "columns": cols, "scores": [{r["model"]: round(r["cv"], 3)} for r in st["result"]["board"]],
                  "allowed_kinds": {"ratio_to_group": ["measure", "group column"], "combine": ["group column", "group column"],
                                    "days_since": ["date column"], "as_number": ["column"], "is_missing": ["column"]},
                  "rules": "Suggest up to 4 new model inputs as JSON: {\"ideas\": [{\"kind\", \"columns\", \"title\", \"why\"}]}. "
                           "Use only the allowed kinds and existing column names. Never use the target or a column filled in after the outcome."}
        try:
            answer = client.chat.completions.create(model=model, messages=[
                {"role": "system", "content": "Return only one JSON object. No Markdown."},
                {"role": "user", "content": json.dumps(prompt)}])
        finally:
            try:
                client.close()
            except Exception:
                pass
        raw = answer.choices[0].message.content or ""
        m = re.search(r"\{.*\}", raw, re.S)
        found = json.loads(m.group(0)).get("ideas", []) if m else []
        f, added = d.frame, 0
        for x in found[:4]:
            kind, c = x.get("kind"), [str(v) for v in x.get("columns", [])]
            if any(col not in f.columns for col in c) or run.target in c:
                continue
            build, sql = None, ""
            if kind == "ratio_to_group" and len(c) == 2:
                build, sql = (lambda fr, a=c[0], b=c[1]: fr[a] / fr.groupby(b)[a].transform("mean")), f'"{c[0]}" / AVG("{c[0]}") OVER (PARTITION BY "{c[1]}")'
            elif kind == "combine" and len(c) == 2:
                build, sql = (lambda fr, a=c[0], b=c[1]: fr[a].astype(str) + " · " + fr[b].astype(str)), f'"{c[0]}" || \' · \' || "{c[1]}"'
            elif kind == "days_since" and len(c) == 1:
                build, sql = (lambda fr, a=c[0]: (fr[a].max() - fr[a]).dt.days.astype(float)), f'DAYS_BETWEEN(CURRENT_DATE, "{c[0]}")'
            elif kind == "as_number" and len(c) == 1:
                build, sql = (lambda fr, a=c[0]: __import__("pandas").to_numeric(fr[a], errors="coerce").astype(float)), f'CAST("{c[0]}" AS DOUBLE)'
            elif kind == "is_missing" and len(c) == 1:
                build, sql = (lambda fr, a=c[0]: fr[a].isna().astype(float)), f'CASE WHEN "{c[0]}" IS NULL THEN 1 ELSE 0 END'
            if build is None:
                continue
            self.items.append(M.Idea(f"ai{len(self.items)}", str(x.get("title") or kind)[:80], str(x.get("why") or "")[:240], sql, build, "ai"))
            added += 1
        self.flash = {"kind": "ok" if added else "warn",
                      "v": f"{added} idea{'s' if added != 1 else ''} from AI added below. Try each one before keeping it." if added
                      else "The AI didn't suggest anything usable for this data."}


def explore():
    """Step 2 in the guided view: check and clean, compare, then predict and test feature ideas."""
    from .card import show

    return show(WorkingOn(), Prepare(), Compare(), Predict(), Ideas())
