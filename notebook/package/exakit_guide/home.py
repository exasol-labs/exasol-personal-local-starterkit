"""Home: the first screen when the kit's JupyterLab opens.

Three questions, answered from the kit's own records:
  1. Is my kit OK?            (one row per part, each with at most one fix)
  2. What do I do next?       (the Data Scientist path, with done / next)
  3. Where was I?             (the last workflow, one click to continue)

Every button runs the kit's own command (shown in Code mode). Nothing here
changes data; the update button asks first, because the database restarts.
"""

from __future__ import annotations

import re
import threading

from . import kitinfo
from .card import Screen

COMPONENT_NAMES = {
    "personal": "database", "dash-server": "dashboards", "dbt-exasol": "dbt", "json-tables": "JSON Tables",
    "exasol-scheduler": "scheduler", "notebook": "notebooks", "exapump": "exapump", "mcp_server": "AI connection",
    "pyexasol": "Python driver", "exakit": "kit",
}
ADDON_NAMES = {
    "dash-server": "Dashboards", "dbt-exasol": "dbt models", "exasol-scheduler": "Scheduler",
    "json-tables": "JSON Tables", "notebook": "Notebooks", "exasol-vscode": "VS Code", "udf-devkit": "UDF dev kit",
}
CLIENT_NAMES = {
    "claude_code": "Claude Code", "claude_desktop": "Claude Desktop", "codex": "Codex", "cursor": "Cursor",
    "vscode_copilot": "GitHub Copilot", "gemini_cli": "Gemini CLI", "opencode": "OpenCode", "continue": "Continue",
}


ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\[[0-9;]*m")


def _clean(text: str) -> str:
    """Kit output without terminal colour codes."""
    return ANSI.sub("", text or "")


def _last_error(text: str) -> str | None:
    """What went wrong, in plain words: the root cause when we recognise it, else the last error line."""
    m = None
    for line in text.splitlines():
        found = re.search(r"insufficient privileges? for ([^(\"]+)", line, re.I)
        if found:
            m = found
    if m:
        what = re.sub(r"^creating\s+", "to create a ", m.group(1).strip().lower())
        return f"its database login isn't allowed {what}."
    lines = [l.strip() for l in text.splitlines() if re.search(r"error|failed|denied", l, re.I)]
    return lines[-1][:240] if lines else None


def _run_kit(*args: str) -> tuple[bool, str]:
    """Run a kit command the way the kit's notebooks do; return (ok, its output)."""
    from exakit_nb.kit_commands import exakit

    run = exakit(*args, show=False)
    lines = getattr(run, "lines", None)
    text = "\n".join(lines() if callable(lines) else (lines or []))
    return bool(getattr(run, "ok", False)), _clean(text).strip()


class Home(Screen):
    kind = "home"

    def __init__(self) -> None:
        super().__init__()
        self.data: dict | None = None
        self.loading = True
        self.outputs: dict[str, str] = {}  # last command output per row
        self.confirm: str | None = None
        self.refresh()
        threading.Thread(target=self._load, daemon=True).start()

    # -- data ------------------------------------------------------------------------------
    def _load(self) -> None:
        try:
            self.data = kitinfo.gather()
        except Exception as exc:
            self.flash = {"kind": "error", "v": f"Couldn't read the kit's status: {exc}"}
        self.loading = False
        self.refresh()

    def _reload(self) -> None:
        self.data = kitinfo.gather()

    # -- rows ------------------------------------------------------------------------------
    def _rows(self) -> list[dict]:
        d = self.data or {}
        st, ver, man = d.get("status", {}), d.get("version", {}), d.get("manifest", {})
        services, urls = st.get("services") or {}, st.get("urls") or {}
        comps = {c.get("component"): c for c in ver.get("components") or []}
        rows: list[dict] = []

        # Database
        db = comps.get("personal", {})
        running = st.get("running") or st.get("status") == "running"
        rows.append({
            "id": "database", "name": "Database",
            "dot": "ok" if running else "bad",
            "text": f"Running · Exasol Personal {db.get('installed_label') or db.get('installed') or ''}".strip() if running
            else "Stopped. Your data is kept.",
            "cmd": "exakit status",
            "actions": [] if running else [{"id": "db_start", "label": "Start", "cmd": "exakit start"}],
        })

        # Data: what the user approved in step 1 comes first; the kit's samples are a second line
        sets = d.get("datasets") or []
        mine = d.get("approved") or []
        working = next((a for a in mine if a["id"] == d.get("working_on")), None)
        # one name per dataset: a cleaned copy stands in for its raw table; newest first
        base = lambda label: label.replace(" (cleaned)", "")
        taken = {base(working["label"])} if working else set()
        others = []
        for a in mine:
            if a is working or base(a["label"]) in taken:
                continue
            taken.add(base(a["label"]))
            others.append(a["label"])
        more = len(others) - 4
        others = others[:4] + ([f"{more} more"] if more > 0 else [])
        samples = ", ".join(s["title"] for s in sets)
        if working:
            text = f"Working on {working['label']}"
        elif mine:
            text = f"{len(mine)} dataset{'s' if len(mine) != 1 else ''} approved"
        else:
            text = "Nothing approved yet. Step 1 picks and checks your data." if sets else "No data loaded yet"
        sub = []
        if others:
            sub.append(("Also approved: " if working else "") + ", ".join(dict.fromkeys(others)) + ".")
        if samples:
            sub.append(f"Kit samples loaded: {samples}.")
        rows.append({
            "id": "data", "name": "Your data",
            "dot": "ok" if mine or sets else "warn",
            "text": text,
            "sub": " ".join(sub),
            "cmd": "exakit data-load <dataset or file>",
            "actions": [{"id": "data_load", "label": "Add data", "cmd": "exakit data-load <dataset or file>",
                         "form": [{"id": "what", "type": "text", "label": "A file or folder on this computer, or a kit dataset name",
                                   "placeholder": "~/Downloads/sales.csv"}],
                         "submit": "Load it"}],
        })

        # AI assistants (MCP)
        clients = sorted({CLIENT_NAMES.get(a.get("client"), a.get("client")) for a in (d.get("mcp") or {}).get("artifacts") or []
                          if not a.get("removed_at") and a.get("client")})
        mcp_conn = ((man.get("components") or {}).get("mcp_server") or {}).get("connection") or {}
        rows.append({
            "id": "assistants", "name": "AI assistants",
            "dot": "ok" if clients else "warn",
            "text": ("Connected: " + ", ".join(clients)) if clients else "No AI assistant connected yet",
            "sub": f"They read through a read-only login ({mcp_conn.get('user', 'read-only user')}), so they can't change anything." if clients else "",
            "cmd": "exakit mcp-status   ·   exakit mcp-setup",
            "actions": [{"id": "mcp_doctor", "label": "Check", "cmd": "exakit mcp-doctor"}],
        })

        # Answers in notebooks: the kit's Ask runs through the read-only MCP service.
        server = (man.get("components") or {}).get("mcp_server") or {}
        ro = server.get("connection") or {}
        ro_ok = bool(ro.get("validated") and ro.get("user") and ro.get("password_file"))
        if (server.get("backend") != "sidecar" or not server.get("url")) and ro_ok:
            rows.append({
                "id": "ask_path", "name": "Answers in notebooks",
                "dot": "ok",
                "text": f"Questions are answered in step 3, as the read-only login {ro['user']}.",
                "sub": "So an approved question can read your data but never change it.",
                "cmd": "exakit mcp-doctor",
                "actions": [],
            })
        elif server.get("backend") != "sidecar" or not server.get("url"):
            rows.append({
                "id": "ask_path", "name": "Answers in notebooks",
                "dot": "warn",
                "text": "Questions can be drafted and approved, but not answered yet.",
                "sub": "Notebook questions run through a read-only query service that isn't running on this machine.",
                "cmd": "exakit mcp-doctor",
                "actions": [{"id": "mcp_doctor", "label": "Check", "cmd": "exakit mcp-doctor"}],
            })

        # Dashboards
        dash = services.get("dash-server")
        if dash is not None:
            rows.append({
                "id": "dash", "name": "Dashboards",
                "dot": "ok" if dash == "running" else "bad",
                "text": "Running" if dash == "running" else "Stopped",
                "cmd": "exakit start dash-server",
                "actions": ([{"id": "open_dash", "label": "Open", "href": urls.get("dash-server")}] if dash == "running"
                            else [{"id": "dash_start", "label": "Start", "cmd": "exakit start dash-server"}]),
            })
        else:
            rows.append({"id": "dash", "name": "Dashboards", "dot": "off", "text": "Not added",
                         "cmd": "exakit marketplace dash-server",
                         "actions": [{"id": "dash_add", "label": "Add", "cmd": "exakit marketplace dash-server"}]})

        # AI model for notebooks
        model = d.get("model") or {}
        configured = bool(model.get("configured"))
        rows.append({
            "id": "model", "name": "AI model",
            "dot": "ok" if configured else "off",
            "text": (f"Using {model.get('model') or model.get('model_id') or 'your model'}" if configured
                     else "Not set up"),
            "sub": "Used by every guided step: Step 3 drafts questions with it, Step 2 can ask it for feature ideas." if configured
                   else "Only needed to draft questions and read texts with AI. Everything else works without it.",
            "cmd": 'nb.use_model("claude-opus-5-5", "https://api.anthropic.com/v1/")',
            "actions": ([{"id": "model_forget", "label": "Forget", "cmd": "exakit_guide.aikey.forget()"}] if configured else []) + [
                        {"id": "model_setup", "label": "Change" if configured else "Set up", "cmd": "nb.use_model(...)",
                         "form": [
                             {"id": "model", "type": "text", "label": "Model", "value": "claude-opus-5-5"},
                             {"id": "url", "type": "text", "label": "Provider address", "value": "https://api.anthropic.com/v1/"},
                             {"id": "key", "type": "password", "label": "API key (saved for your guided steps, readable only by you, never shown)"},
                         ], "submit": "Use this model"}],
        })

        # Langfuse: a trace of every AI call the notebooks make (the prompt the kit built, the model's answer,
        # the time it took). Never the rows: the kit sends a model none.
        lf = d.get("langfuse") or {}
        rows.append({
            "id": "langfuse", "name": "Langfuse tracing",
            "dot": "ok" if lf.get("on") else ("warn" if lf.get("half") else "off"),
            "text": (f"Tracing to {lf.get('url')}" if lf.get("on")
                     else "Address set, keys missing" if lf.get("half") else "Off"),
            "sub": ("Every AI call in Steps 2 and 3 shows up in Langfuse: the prompt, the answer and how long it took. "
                    "No rows of your data are sent." if lf.get("on")
                    else "Optional: see every AI call the notebooks make, in your own Langfuse."),
            "cmd": 'nb.use_model(langfuse_base_url="https://cloud.langfuse.com")',
            "actions": ([{"id": "langfuse_forget", "label": "Forget", "cmd": "exakit_guide.aikey.forget_langfuse()"}]
                        if lf.get("on") or lf.get("half") else []) + [
                        {"id": "langfuse_setup", "label": "Change" if lf.get("on") else "Set up",
                         "cmd": "nb.use_model(langfuse_base_url=...)",
                         "form": [
                             {"id": "url", "type": "text", "label": "Langfuse address",
                              "value": lf.get("url") or "https://cloud.langfuse.com"},
                             {"id": "public", "type": "password", "label": "Public key (never shown)"},
                             {"id": "secret", "type": "password", "label": "Secret key (saved for your guided steps, readable only by you, never shown)"},
                         ], "submit": "Trace to Langfuse"}],
        })

        return rows

    def _other_rows(self) -> list[dict]:
        """Kit parts the Data Scientist path doesn't use (scheduler, dbt, updates): shown folded, never counted as problems."""
        d = self.data or {}
        st, ver = d.get("status", {}), d.get("version", {})
        services = st.get("services") or {}
        comps = {c.get("component"): c for c in ver.get("components") or []}
        rows: list[dict] = []
        for svc, state in services.items():
            if svc == "dash-server":
                continue
            ok = state == "running"
            gave_up = "gave up" in str(state)
            rows.append({
                "id": f"svc_{svc}", "name": ADDON_NAMES.get(svc, svc),
                "dot": "ok" if ok else "bad",
                "text": "Running" if ok else ("Stopped after failing several times in a row" if gave_up else "Stopped"),
                "cmd": f"exakit logs {svc}   ·   exakit start {svc}",
                "actions": [] if ok else [
                    {"id": f"logs:{svc}", "label": "See why", "cmd": f"exakit logs {svc}"},
                    {"id": f"start:{svc}", "label": "Start", "cmd": f"exakit start {svc}"},
                ],
            })

        # Updates
        pending = [c for c in comps.values() if c.get("status") == "update_available"]
        if pending:
            names = ", ".join(COMPONENT_NAMES.get(c["component"], c["component"]) for c in pending)
            touches_db = any(c["component"] == "personal" for c in pending)
            rows.append({
                "id": "updates", "name": "Updates",
                "dot": "info",
                "text": f"{len(pending)} update{'s' if len(pending) > 1 else ''} available: {names}",
                "sub": "The database restarts for a minute or two during its update." if touches_db else "",
                "cmd": "exakit version   ·   exakit update",
                "actions": [{"id": "update", "label": "Update", "cmd": "exakit update --yes",
                             "confirm": "This updates the kit" + (" and restarts the database for a minute or two" if touches_db else "")
                             + ". Continue?"}],
            })
        return rows

    def _addons(self) -> list[dict]:
        out = []
        for a in (self.data or {}).get("market", {}).get("addons") or []:
            installed = a.get("installed") or a.get("status") == "installed"
            out.append({"label": ADDON_NAMES.get(a.get("id"), a.get("id")),
                        "kind": "ok" if installed else "muted",
                        "title": "Installed" if installed else str(a.get("status") or "")})
        return out

    # -- view ------------------------------------------------------------------------------
    def build(self) -> list[dict]:
        if self.loading and self.data is None:
            return [{"t": "home_head", "summary": "Checking your kit…", "state": "loading"},
                    {"t": "skeleton", "rows": 6}]
        rows = self._rows()
        for r in rows:
            if r["id"] in self.outputs:
                r["output"] = self.outputs[r["id"]]
            if self.confirm and any(a["id"] == self.confirm for a in r.get("actions", [])):
                r["confirming"] = self.confirm
        other = self._other_rows()
        for r in other:
            if r["id"] in self.outputs:
                r["output"] = self.outputs[r["id"]]
            if self.confirm and any(a["id"] == self.confirm for a in r.get("actions", [])):
                r["confirming"] = self.confirm
        attention = [r for r in rows if r["dot"] in ("bad", "warn")]
        other_issues = [r for r in other if r["dot"] in ("bad", "warn")]
        rows = attention + [r for r in rows if r not in attention]   # what needs a look comes first
        if not attention:
            summary, state = "Everything is ready", "ok"
        else:
            summary = f"Ready to use · {len(attention)} thing{'s' if len(attention) > 1 else ''} to look at"
            state = "warn"
            if any(r["id"] == "database" and r["dot"] == "bad" for r in rows):
                summary, state = "The database is stopped", "bad"
        d = self.data or {}
        journey = d.get("journey") or []
        nxt = next((j for j in journey if j["state"] in ("next", "attention")), None)
        wf = d.get("workflow")
        blocks = [{"t": "home_head", "summary": summary, "state": state}]
        # Where was I? first: the data being worked on and one click back into the right step
        working = next((a for a in d.get("approved") or [] if a["id"] == d.get("working_on")), None)
        step = nxt or (journey[d["last_step"]] if d.get("last_step") is not None and d["last_step"] < len(journey) else None)
        if wf or working:
            blocks += [
                {"t": "section", "v": "Continue where you left off"},
                {"t": "resume", "text": f"Working on {working['label']}" if working else "Your last session",
                 "sub": " · ".join(x for x in [f"Last session {d.get('workflow_ago')}" if wf and d.get("workflow_ago") else "",
                                                (f"Next: {nxt['title']}" if nxt else f"Last in: {step['title']}") if step else ""] if x),
                 "path": step["path"] if step else None,
                 "cmd": f"exakit workflow show {wf['id']}" if wf else ""},
            ]
        blocks += [
            {"t": "section", "v": "Your setup"},
            {"t": "setup", "rows": rows},
            {"t": "details", "title": " · ".join(["Other kit tools, not needed for data science"]
                                                 + [f"{r['name']} stopped" for r in other_issues]
                                                 + (["updates available"] if any(r["id"] == "updates" for r in other) else [])),
             "blocks": ([{"t": "setup", "rows": other}] if other else [])
                       + [{"t": "chips", "label": "Add-ons", "items": self._addons()}]},
            {"t": "section", "v": "What do you want to do?"},
            {"t": "journey", "items": journey},
        ]
        blocks.append({"t": "foot", "v": "Every button runs the kit's own command. Switch to Code to see them."})
        return blocks

    # -- actions ---------------------------------------------------------------------------
    def _kit_action(self, row: str, *args: str, ok_text: str) -> None:
        ok, out = _run_kit(*args)
        self.outputs[row] = out or "(no output)"
        self._reload()
        self.flash = {"kind": "ok" if ok else "error",
                      "v": ok_text if ok else f"`exakit {' '.join(args)}` didn't finish. Its output is under the row."}

    def on_refresh(self, _v: dict) -> None:
        self._reload()
        self.flash = {"kind": "ok", "v": "Up to date."}

    def on_db_start(self, _v: dict) -> None:
        self._kit_action("database", "start", ok_text="The database is running.")

    def on_dash_start(self, _v: dict) -> None:
        self._kit_action("dash", "start", "dash-server", ok_text="Dashboards are running.")

    def on_dash_add(self, _v: dict) -> None:
        self._kit_action("dash", "marketplace", "dash-server", ok_text="Dashboards added.")

    def on_mcp_doctor(self, _v: dict) -> None:
        ok, out = _run_kit("mcp-doctor")
        self.outputs["assistants"] = out or "(no output)"
        self.flash = {"kind": "ok" if ok else "warn", "v": "Checked the AI connection. The result is under AI assistants."}

    def on_data_load(self, v: dict) -> None:
        what = str(v.get("what") or "").strip()
        if not what:
            raise ValueError("Enter a file, a folder or a kit dataset name.")
        self._kit_action("data", "data-load", what, ok_text=f"Loaded {what}.")

    def on_model_setup(self, v: dict) -> None:
        from exakit_nb.setup_env import use_model

        model, url, key = (str(v.get(k) or "").strip() for k in ("model", "url", "key"))
        if not model:
            raise ValueError("Enter a model name, for example claude-opus-5-5.")
        use_model(model, url, "", ask=lambda _prompt: key)
        from . import aikey

        aikey.save(model, url, key)   # so Steps 1-4 (each its own kernel) use it too
        self._reload()
        self.flash = {"kind": "ok", "v": f"Using {model} in every guided step. The key is saved in the kit's credentials "
                                         "folder, readable only by you. Forget removes it."}

    def on_langfuse_setup(self, v: dict) -> None:
        from exakit_nb.setup_env import use_model

        url, public, secret = (str(v.get(k) or "").strip() for k in ("url", "public", "secret"))
        if not url:
            raise ValueError("Enter the Langfuse address, for example https://cloud.langfuse.com.")
        if not (public and secret):
            raise ValueError("Enter both Langfuse keys: the public key and the secret key.")
        answers = iter((public, secret))          # use_model asks for the public key, then the secret key
        summary = use_model("", "", url, ask=lambda _prompt: next(answers, ""))
        if summary.get("notes"):
            raise ValueError(" ".join(summary["notes"]))
        from . import aikey

        aikey.save_langfuse(url, public, secret)   # so every guided step (each its own kernel) traces too
        self._reload()
        self.flash = {"kind": "ok", "v": f"Tracing every AI call to {url}. The keys are saved in the kit's credentials "
                                         "folder, readable only by you. Forget removes them."}

    def on_langfuse_forget(self, _v: dict) -> None:
        from . import aikey

        aikey.forget_langfuse()
        self._reload()
        self.flash = {"kind": "ok", "v": "Langfuse tracing is off and its keys are removed."}

    def on_model_forget(self, _v: dict) -> None:
        from . import aikey

        aikey.forget()
        self._reload()
        self.flash = {"kind": "ok", "v": "The AI model and its key are removed. The guided view works without AI."}

    def on_update(self, _v: dict) -> None:
        if self.confirm != "update":
            self.confirm = "update"
            return
        self.confirm = None
        self._kit_action("updates", "update", "--yes", ok_text="The kit is up to date.")

    def on_cancel(self, _v: dict) -> None:
        self.confirm = None

    def __getattr__(self, name: str):
        # Per-service buttons: on_logs:<svc> and on_start:<svc>
        if name.startswith("on_logs:"):
            svc = name.split(":", 1)[1]
            return lambda _v: self._service_logs(svc)
        if name.startswith("on_start:"):
            svc = name.split(":", 1)[1]
            return lambda _v: self._kit_action(f"svc_{svc}", "start", svc, ok_text=f"{ADDON_NAMES.get(svc, svc)} is running.")
        raise AttributeError(name)

    def _service_logs(self, svc: str) -> None:
        ok, out = _run_kit("logs", svc)
        lines = out.splitlines()
        self.outputs[f"svc_{svc}"] = "\n".join(lines[-40:]) or "(no output)"
        why = _last_error(out)
        name = ADDON_NAMES.get(svc, svc)
        self.flash = ({"kind": "warn", "v": f"{name} stopped because {why} The full log is under its row."} if why
                      else {"kind": "info", "v": f"The last lines of the {name} log are under its row."})


def home() -> Home:
    """Show the kit Home screen."""
    return Home()
