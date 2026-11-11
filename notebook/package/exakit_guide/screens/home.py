"""Home: the kit, read live, and what to do next.

Three questions, answered from the kit's own answers (no list in this file names a kit part):
  1. Is my kit OK?        kit_check, components, addons, ai_clients, persona_plan, model_settings, tracing
  2. What do I do next?   the persona's notebooks (nb.notebooks), marked from the workflow log
  3. Where was I?         the last workflow and the dataset approved last

Every row shows the exact exakit.nb call behind it (Code mode), and its buttons run that call (actions.run).
"""

from __future__ import annotations

import importlib

import json
import re
import threading
from datetime import datetime, timezone
from pathlib import Path

from .. import actions
from ..card import Screen
from ..session import SESSION


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


def _read(action_id: str, **values):
    try:
        return actions.run(action_id, **values)
    except Exception as exc:          # the kit says why; a part it cannot answer is shown as unknown
        return {"_error": str(exc).splitlines()[0] if str(exc) else type(exc).__name__}


def _journey(notebooks: list[dict], events: list[dict]) -> list[dict]:
    """The persona's notebooks in order, each marked done / next / todo from the workflow log's event kinds."""
    wf = importlib.import_module("exakit_nb.workflow")   # the module (exakit_nb.workflow is also a function)

    kinds = [e.get("kind") for e in events]
    sqls = " ".join(str(e.get("sql", "")) for e in events if e.get("kind") == wf.SQL).upper()
    asked_no_answer = wf.ASK_APPROVE in kinds and wf.ASK_ANSWER not in kinds
    done_when = [wf.DESCRIBE_APPROVE in kinds,
                 wf.MLFLOW_RUN in kinds or "VIEW" in sqls or kinds.count(wf.SQL) > 2,
                 wf.ASK_ANSWER in kinds,
                 wf.HANDOFF in kinds or any(e.get("kind") == wf.DASHBOARD_REVISION and e.get("state") == "live" for e in events)]
    out, next_set = [], False
    for i, nb_row in enumerate(notebooks):
        done = done_when[i] if i < len(done_when) else False
        state = "done" if done else ("next" if not next_set else "todo")
        if i == 2 and asked_no_answer:
            state = "attention"
        next_set = next_set or state in ("next", "attention")
        out.append({"n": i + 1, "title": nb_row["title"], "text": nb_row["summary"].split(". ")[0][:140],
                    "path": nb_row["file"], "state": state,
                    "note": "Questions were approved but none returned an answer." if state == "attention" else ""})
    return out


class Home(Screen):
    kind = "home"

    def __init__(self) -> None:
        super().__init__()
        self.data: dict | None = None
        self.loading = True
        self.outputs: dict[str, str] = {}
        self.failed: set[str] = set()      # rows whose last command failed: their kit output opens by itself
        self.confirm: str | None = None
        self.refresh()
        threading.Thread(target=self._load, daemon=True).start()

    # -- the kit, read live ----------------------------------------------------------------
    def _load(self) -> None:
        try:
            self._reload()
        except Exception as exc:
            self.flash = {"kind": "error", "v": f"Could not read the kit's state: {exc}"}
        self.loading = False
        self.refresh()

    def _reload(self) -> None:
        d = {name: _read(action) for name, action in (
            ("kit", "kit.check"), ("components", "kit.components"), ("addons", "kit.addons"),
            ("clients", "kit.ai_clients"), ("plan", "kit.persona_plan"), ("model", "kit.model"),
            ("tracing", "kit.tracing"), ("approved", "kit.approved"), ("workflows", "kit.workflows"),
            ("files", "kit.loaded_files"))}
        # The persona whose notebook this is: its folder (starter-kit-notebooks/<persona>/), else the kit's own.
        persona = Path.cwd().name
        notebooks = _read("kit.notebooks", persona=persona)
        if not notebooks or isinstance(notebooks, dict):
            persona = (d["plan"] or {}).get("persona", "").split(",")[0] if isinstance(d["plan"], dict) else ""
            notebooks = _read("kit.notebooks", persona=persona or None)
        d["notebooks"], d["persona"] = notebooks, persona
        workflows = d["workflows"] if isinstance(d["workflows"], list) else []
        last = max(workflows, key=lambda r: r.get("last") or "") if workflows else None
        events = _read("kit.workflow_log", workflow_id=last["id"]) if last else []
        d["last_workflow"], d["events"] = last, events if isinstance(events, list) else []
        d["working_on"] = SESSION.latest_approved()
        self.data = d

    # -- rows ------------------------------------------------------------------------------
    @staticmethod
    def _act(action_id: str, label: str, **values) -> dict:
        """A button: its label, the exact code it runs (shown in Code mode), and the event that runs it."""
        return {"id": "run:" + json.dumps([action_id, values]), "label": label, "cmd": actions.code(action_id, **values)}

    def _rows(self) -> list[dict]:
        d = self.data or {}
        kit = d.get("kit") if isinstance(d.get("kit"), dict) else {}
        plan = d.get("plan") if isinstance(d.get("plan"), dict) else {}
        addons = {a["id"]: a for a in d.get("addons") or [] if isinstance(a, dict) and a.get("id")}
        rows: list[dict] = []

        running = kit.get("running") or kit.get("status") == "running"
        rows.append({"id": "database", "name": "Database", "dot": "ok" if running else "bad",
                     "text": "Running" if running else "Stopped. Your data is kept.",
                     "cmd": actions.code("kit.check"),
                     "actions": [] if running else [self._act("kit.start", "Start")]})

        loaded = (plan.get("datasets") or {}).get("loaded") or kit.get("datasets_loaded") or []
        files = [f for f in d.get("files") or [] if isinstance(f, dict)]       # your own, from the kit's load record
        pending = (plan.get("datasets") or {}).get("pending") or []
        approved = [a for a in d.get("approved") or [] if isinstance(a, dict)]
        working = next((a for a in approved if a["id"] == d.get("working_on")), None)
        text = (f"Working on {working['table']}" if working else
                f"{len(approved)} column map{'s' if len(approved) != 1 else ''} approved" if approved else
                "Nothing approved yet: step 1 picks and checks your data" if loaded or files else "No data loaded yet")
        shown_files = ", ".join(f"{f['table']} ({f['rows']:,} rows)" if isinstance(f.get("rows"), int) else f["table"]
                                for f in files[:8]) + (f" and {len(files) - 8} more" if len(files) > 8 else "")
        rows.append({"id": "data", "name": "Your data", "dot": "ok" if approved or loaded or files else "warn", "text": text,
                     "sub": (f"Your files: {shown_files}. " if files else "")
                            + (f"Kit datasets: {', '.join(loaded)}." if loaded else "")
                            + (f" Still to load for this persona: {', '.join(pending)}." if pending else ""),
                     "cmd": actions.code("kit.approved"),
                     "actions": [self._act("kit.data_load", f"Load {p}", what=p) for p in pending]
                                + [{**self._act("kit.data_load", "Add data", what="<file, folder or dataset>"),
                                    "form": [{"id": "what", "type": "text", "label": "A file or folder on this computer, or a kit dataset",
                                              "placeholder": "~/Downloads/sales.csv"},
                                             {"id": "schema", "type": "text", "optional": True,
                                              "label": "Into the schema (a file or folder; empty: STARTER_KIT, the kit's default)",
                                              "placeholder": "STARTER_KIT"}], "submit": "Load it"}]})

        clients = [c for c in d.get("clients") or [] if isinstance(c, dict)]
        on = [c["name"] for c in clients if c.get("connected")]
        rows.append({"id": "assistants", "name": "AI assistants", "dot": "ok" if on else "warn",
                     "text": ("Connected: " + ", ".join(on)) if on else "No AI assistant connected yet",
                     "sub": "Available here: " + ", ".join(c["name"] for c in clients if not c.get("connected"))
                            if clients and len(on) < len(clients) else "",
                     "cmd": actions.code("kit.ai_clients"),
                     "actions": [self._act("kit.mcp_doctor", "Check")]})

        # Every add-on the marketplace has (nb.addons(), `exakit marketplace --list`), the persona's first: one not
        # installed is installed from here (nb.addon_ready, as `exakit marketplace <id>` does), one stopped is started.
        persona = (plan.get("addons") or {}).get("installed", []) + (plan.get("addons") or {}).get("pending", [])
        order = [i for i in persona if i in addons] + [i for i in addons if i not in persona]
        for addon_id in order:
            a = addons[addon_id]
            status = str(a.get("status") or "")
            state = (kit.get("services") or {}).get(addon_id)
            installed = bool(a.get("installed"))
            url = (kit.get("urls") or {}).get(addon_id)
            mine = " (for your persona)" if addon_id in persona and not installed else ""
            if installed:
                dot, text = ("ok" if state in (None, "running") else "bad"), ("Running" if state == "running" else
                                                                             "Installed" if state is None else "Stopped")
                buttons = [] if state in (None, "running") else [self._act("kit.addon", "Start", addon=addon_id)]
            elif status == "available":
                dot, text, buttons = "off", "Not installed" + mine, [self._act("kit.addon", "Install", addon=addon_id)]
            elif status == "managed outside the kit":
                dot, text, buttons = "ok", "Yours: installed outside the kit, never changed by it", []
            else:
                dot, text, buttons = "off", (status[:1].upper() + status[1:]) if status else "Not available here", []
            rows.append({"id": f"addon_{addon_id}", "name": a.get("name") or addon_id, "dot": dot, "text": text,
                         "sub": a.get("about") or "", "cmd": actions.code("kit.addon", addon=addon_id),
                         "actions": buttons + ([{"id": f"open_{addon_id}", "label": "Open", "href": url}]
                                               if url and state == "running" else [])})

        model = d.get("model") if isinstance(d.get("model"), dict) else {}
        from exakit_nb.setup_env import EXAMPLE_LANGFUSE, EXAMPLE_MODEL, EXAMPLE_URL

        rows.append({"id": "model", "name": "AI model", "dot": "ok" if model.get("configured") else "off",
                     "text": f"Using {model.get('model_id')}" if model.get("configured") else "Not set up",
                     "sub": "Drafts questions in step 3 and suggests feature ideas in step 2. Everything else works without it.",
                     "cmd": actions.code("kit.model"),
                     "actions": ([self._act("model.forget", "Forget", model=True, langfuse=False)] if model.get("configured") else [])
                                + [{**self._act("model.use", "Change" if model.get("configured") else "Set up",
                                                model_id=model.get("model_id") or EXAMPLE_MODEL,
                                                base_url=model.get("provider_base_url") or EXAMPLE_URL),
                                    "form": [{"id": "model_id", "type": "text", "label": "Model", "value": model.get("model_id") or EXAMPLE_MODEL},
                                             {"id": "base_url", "type": "text", "label": "Provider address",
                                              "value": model.get("provider_base_url") or EXAMPLE_URL},
                                             {"id": "key", "type": "password", "optional": True,
                                              "label": "API key (saved for every notebook, readable only by you, never shown)"}],
                                    "submit": "Use this model"}]})

        tracing = d.get("tracing") is True
        rows.append({"id": "langfuse", "name": "Langfuse tracing", "dot": "ok" if tracing else "off",
                     "text": "On: every AI call is traced" if tracing else "Off",
                     "sub": "The prompt, the answer and the time of every AI call, in your own Langfuse. No rows are sent.",
                     "cmd": actions.code("kit.tracing"),
                     "actions": ([self._act("model.forget", "Forget", model=False, langfuse=True)] if tracing else [])
                                + [{**self._act("model.langfuse", "Change" if tracing else "Set up", langfuse_url=EXAMPLE_LANGFUSE),
                                    "form": [{"id": "langfuse_url", "type": "text", "label": "Langfuse address", "value": EXAMPLE_LANGFUSE},
                                             {"id": "public", "type": "password", "label": "Public key (never shown)"},
                                             {"id": "secret_key", "type": "password", "label": "Secret key (saved for every notebook, readable only by you)"}],
                                    "submit": "Trace to Langfuse"}]})
        return rows

    def _other_rows(self) -> list[dict]:
        """The kit's other services and pending updates: shown folded."""
        d = self.data or {}
        kit = d.get("kit") if isinstance(d.get("kit"), dict) else {}
        plan_addons = {a.get("id") for a in d.get("addons") or [] if isinstance(a, dict)}   # shown above, with their add-on
        rows = []
        for svc, state in (kit.get("services") or {}).items():
            if svc in plan_addons:
                continue
            ok = state == "running"
            rows.append({"id": f"svc_{svc}", "name": svc, "dot": "ok" if ok else "bad",
                         "text": "Running" if ok else str(state).capitalize(),
                         "cmd": actions.code("kit.start_service", service=svc),
                         "actions": [] if ok else [self._act("kit.logs", "See why", service=svc),
                                                   self._act("kit.start_service", "Start", service=svc)]})
        pending = [c for c in d.get("components") or [] if isinstance(c, dict) and c.get("status") == "update_available"]
        if pending:
            rows.append({"id": "updates", "name": "Updates", "dot": "info",
                         "text": f"{len(pending)} update{'s' if len(pending) > 1 else ''} available: "
                                 + ", ".join(c["id"] for c in pending),
                         "sub": next((c["remedy"] for c in pending if c.get("remedy")), ""),
                         "cmd": actions.code("kit.components"),
                         "actions": [{**self._act("kit.update", "Update"),
                                      "confirm": "This updates the kit; a database update restarts it for a minute or two. Continue?"}]})
        return rows

    def _addon_chips(self) -> list[dict]:
        return [{"label": a.get("name") or a.get("id"), "kind": "ok" if a.get("installed") else "muted",
                 "title": a.get("about") or str(a.get("status") or "")}
                for a in (self.data or {}).get("addons") or [] if isinstance(a, dict)]

    # -- view ------------------------------------------------------------------------------
    def build(self) -> list[dict]:
        if self.loading and self.data is None:
            return [{"t": "home_head", "summary": "Checking your kit…", "state": "loading"}, {"t": "skeleton", "rows": 6}]
        rows, other = self._rows(), self._other_rows()
        for r in rows + other:
            if r["id"] in self.outputs:
                r["output"] = self.outputs[r["id"]]
                r["output_open"] = r["id"] in self.failed
            if self.confirm and any(a["id"] == self.confirm for a in r.get("actions", [])):
                r["confirming"] = self.confirm
        attention = [r for r in rows if r["dot"] in ("bad", "warn")]
        rows = attention + [r for r in rows if r not in attention]
        if not attention:
            summary, state = "Everything is ready", "ok"
        elif any(r["id"] == "database" and r["dot"] == "bad" for r in rows):
            summary, state = "The database is stopped", "bad"
        else:
            summary, state = f"Ready to use · {len(attention)} thing{'s' if len(attention) > 1 else ''} to look at", "warn"
        d = self.data or {}
        notebooks = d.get("notebooks") if isinstance(d.get("notebooks"), list) else []
        journey = _journey(notebooks, d.get("events") or [])
        nxt = next((j for j in journey if j["state"] in ("next", "attention")), None)
        last = d.get("last_workflow")
        blocks = [{"t": "home_head", "summary": summary, "state": state}]
        working = d.get("working_on")
        if last or working:
            blocks += [{"t": "section", "v": "Continue where you left off"},
                       {"t": "resume", "text": f"Working on {working}" if working else "Your last session",
                        "sub": " · ".join(x for x in [f"Last session {_ago(last.get('last'))}" if last else "",
                                                       f"Next: {nxt['title']}" if nxt else ""] if x),
                        "path": nxt["path"] if nxt else None,
                        "cmd": actions.code("kit.workflow_log", workflow_id=last["id"]) if last else ""}]
        blocks += [{"t": "section", "v": "Your setup"}, {"t": "setup", "rows": rows},
                   {"t": "details", "title": "The kit's other tools" + (" · updates available" if any(r["id"] == "updates" for r in other) else ""),
                    "blocks": ([{"t": "setup", "rows": other}] if other else [])
                              + [{"t": "chips", "label": "Add-ons", "items": self._addon_chips()}]}]
        if journey:
            blocks += [{"t": "section", "v": "What do you want to do?"}, {"t": "journey", "items": journey}]
        if SESSION.code:
            blocks.append({"t": "code", "code_only": True, "title": "The code behind this card", "v": "\n".join(SESSION.code)})
        blocks.append({"t": "foot", "v": "Every row reads the kit live, and every button runs one exakit.nb call. Switch to Code to see each one."})
        return blocks

    # -- actions ---------------------------------------------------------------------------
    def __getattr__(self, name: str):
        if name.startswith("on_run:"):
            action_id, values = json.loads(name[len("on_run:"):])
            return lambda form: self._run(action_id, values, form)
        raise AttributeError(name)

    def _run(self, action_id: str, values: dict, form: dict) -> None:
        if action_id == "kit.update" and self.confirm is None:
            self.confirm = "run:" + json.dumps([action_id, values])
            return
        self.confirm = None
        values = {**values, **{k: v for k, v in form.items() if k in values and str(v).strip()}}
        if action_id == "kit.data_load" and str(values.get("what") or "").strip():
            # A pasted path as a terminal would read it (~, quotes, file://): the kit command runs with no shell to expand it.
            # A kit dataset's name (amazon_sales) is not a path and is left as typed.
            from exakit_nb import clean_path

            what = str(values["what"]).strip()
            if what[:1] in "~/.'\"" or "/" in what or "\\" in what or what.startswith("file:"):
                values = {**values, "what": clean_path(what)}
        schema = str(form.get("schema") or "").strip().upper()
        if action_id == "kit.data_load" and schema:
            # exakit data-load's own schema setting (EXAKIT_SCHEMA): what the terminal asks, given here.
            if not re.fullmatch(r"[A-Z][A-Z0-9_]{0,127}", schema):
                raise ValueError("A schema name is letters, digits and _, starting with a letter (e.g. MY_DATA).")
            action_id, values = "kit.data_load_into", {**values, "schema": schema}
        empty = [k for k, v in values.items() if str(v).startswith("<") and str(v).endswith(">")]
        if empty:   # a form left blank: its placeholder is not something to run
            raise ValueError("Type a file or folder path, or a kit dataset's name, first."
                             if empty == ["what"] else f"Fill in {', '.join(empty)} first.")
        secret = None
        if action_id == "model.use":
            key = str(form.get("key") or "")
            secret = {"ask": lambda _question, key=key: key}
        elif action_id == "model.langfuse":
            answers = iter((str(form.get("public") or ""), str(form.get("secret_key") or "")))
            if not all(str(form.get(k) or "").strip() for k in ("public", "secret_key")):
                raise ValueError("Enter both Langfuse keys: the public key and the secret key.")
            secret = {"ask": lambda _question, answers=answers: next(answers, "")}
        SESSION.said = ""
        ok = False
        try:
            actions.run(action_id, secret=secret, **values)
            ok = True
        finally:
            # What the kit printed stays under its row, open, whether the command worked or not.
            event = "run:" + json.dumps([action_id, values])
            row = next((r["id"] for r in self._rows() + self._other_rows()
                        if any(a.get("id") == event or a.get("id", "").startswith(f'run:["{action_id}"')
                               for a in r.get("actions", []))), "database")
            if SESSION.said:
                self.outputs[row] = SESSION.said
            (self.failed.discard if ok else self.failed.add)(row)
            if not ok:
                SESSION.said = ""      # shown open under its own row; not a second time under the error
        self._reload()
        self.flash = {"kind": "ok", "v": f"Done: {actions.code(action_id, **values).splitlines()[0]}"}
        if action_id.startswith("kit.data_load"):
            SESSION.changed("data", self)      # the other cards list what is in the database again

    def on_refresh(self, _v: dict) -> None:
        self._reload()
        self.flash = {"kind": "ok", "v": "Up to date."}

    def on_cancel(self, _v: dict) -> None:
        self.confirm = None


def home() -> Home:
    """Show the kit Home screen."""
    return Home()
