"""Step 1 · Understand your data, in the guided view.

Two cards on the kit's own quickstart engine (00_quickstart.ipynb):
  Choose your data   -> nb.workflow, nb.connect, nb.load_sample / nb.dataset / load_own_file / load_source
  Column map         -> nb.review_roles, RoleReview.approve, then the quickstart's first result
Nothing is simulated: approving writes the same versioned column map the kit's
notebook writes, and the next steps read it.
"""

from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path

from .. import actions
from ..card import Screen
from ..session import SESSION

KICKER = "Step 1 of 4 · Understand your data"

ROLE_LABELS = {
    "key": "Unique ID",
    "time": "Date or time",
    "measure": "Number to add up",
    "category": "Group to compare",
    "flag": "Yes or no",
    "text": "Free text",
    "identifier": "Name or code",
    "other": "Leave out",
}
ROLE_MEANING = {
    "key": "Different in every row, like an order number. Used to spot repeated rows.",
    "time": "A date or time. Used for trends.",
    "measure": "An amount you can add up or average, like price or quantity.",
    "category": "A short list of repeated values, like a product type or a region. Used to compare groups.",
    "flag": "Only two values, like 0/1 or yes/no. Can be the thing you predict.",
    "text": "Sentences people wrote, like comments or descriptions. Not short labels.",
    "identifier": "Names or codes that point at one thing, like a product code or a postcode. Not grouped or charted.",
    "other": "Left out of everything.",
}
SLOT_LABELS = {
    "category": ("Main group to compare", "Charts and counts are split by this."),
    "entity": ("Who or what a row is about", "A customer, place or product."),
    "time": ("Date for trends", "Puts rows in order over time."),
    "key": ("What makes a row unique", "Used to spot repeated rows."),
    "text": ("Text to read", "Comments or descriptions, if there are any."),
}
# The kit's own rule: the slots that need exactly one role (descriptor_rules.SLOT_ROLES).
from exakit_nb.descriptor_rules import SLOT_ROLES as _KIT_SLOT_ROLES

SLOT_REQUIRED = {slot: roles[0] for slot, roles in _KIT_SLOT_ROLES.items()}
# category and entity accept any role in the kit; these are the roles that make sense there (a warning, not a block).
SLOT_SENSIBLE = {"category": ["category", "identifier", "flag"], "entity": ["category", "identifier", "flag", "key"]}
SLOT_ROLES = {**{k: [v] for k, v in SLOT_REQUIRED.items()}, **SLOT_SENSIBLE}
PLAIN_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")


def _split(evidence: str) -> list[tuple[str, float]]:
    """'0 85.8%, 1 14.2%' -> [('0', 85.8), ('1', 14.2)]"""
    return [(v.strip(), float(p)) for v, p in re.findall(r"([^,]+?)\s+([\d.]+)%", evidence or "")]


def target_verdict(evidence: str) -> dict:
    """Is this yes/no column something the kit can predict, in plain words?"""
    parts = _split(evidence)
    if len(parts) < 2:
        return {"verdict": "unknown", "text": "Two values."}
    values = {v.lower() for v, _ in parts}
    minority = min(p for _, p in parts)
    if not values <= {"0", "1", "true", "false"}:
        names = " and ".join(f"“{v}”" for v, _ in parts)
        return {"verdict": "no", "text": f"Holds {names}, not 0 and 1, so the kit can't count or predict it."}
    yes = next((p for v, p in parts if v in ("1", "true")), minority)
    if minority < 1:
        return {"verdict": "rare", "text": f"{yes:.1f}% are 1. Too rare to learn from reliably."}
    if minority < 5:
        return {"verdict": "ok", "text": f"{yes:.1f}% are 1. Rare, but workable (like fraud)."}
    return {"verdict": "good", "text": f"{yes:.1f}% are 1. A good balance to learn from."}


def _avoid(evidence: str) -> dict:
    """Roles that don't fit what the kit measured, with why."""
    out = {}
    m = re.search(r"avg (\d+) chars", evidence or "")
    if (m and int(m.group(1)) < 30) or re.search(r"^\d+ distinct$|short labels|code-shaped", evidence or ""):
        out["text"] = "These are short labels, not sentences. Group to compare or Name or code fits better."
    if not re.search(r"\b(DATE|TIMESTAMP)\b|to \d{4}-\d{2}", evidence or ""):
        out["time"] = "The kit found no dates in this column."
    if len(_split(evidence)) != 2:
        out["flag"] = "This column doesn't have exactly two values."
    return out


_SLOT_WORDS = {"key": "What makes a row unique", "time": "Date for trends", "text": "Text to read",
               "target": "What to predict", "category": "Main group to compare", "entity": "Who or what a row is about"}






def _plain_kit_error(text: str) -> str:
    """The kit's descriptor problems ("slots.key needs a column with role key; X is identifier") in plain words."""
    out = []
    for m in re.finditer(r"slots\.(\w+) needs a column with role (\w+); (\S+) is (\w+)", text):
        slot, need, col, has = m.groups()
        out.append(f"“{_SLOT_WORDS.get(slot, slot)}” must be a column marked {ROLE_LABELS.get(need, need)}, "
                   f"and {col} is marked {ROLE_LABELS.get(has, has)}.")
    for m in re.finditer(r"slots\.key: (.+?) repeats \(([\d,]+) values in ([\d,]+) rows\)", text):
        col, vals, rows = m.groups()
        repeats = int(rows.replace(",", "")) - int(vals.replace(",", ""))
        out.append(f"“What makes a row unique” must be different in every row, and {col} repeats in {repeats:,} rows "
                   f"(often repeated copies of the same row). Leave it empty for now; the cleaned copy in step 2 removes repeats.")
    for m in re.finditer(r"column (\S+) sits in two slots \((\w+), (\w+)\)", text):
        col, a, b = m.groups()
        out.append(f"{col} is used for both “{_SLOT_WORDS.get(a, a)}” and “{_SLOT_WORDS.get(b, b)}”.")
    m = re.search(r"object (\S+) not found", text)
    if m and not out:
        out.append(f"The kit looked for a column called {m.group(1)} and couldn't find it. That happens when column names "
                   "have spaces or small letters. Pick the data again: the guided view now gives such tables plain names.")
    if out:
        text_out = " ".join(out)
        return text_out if text_out.endswith("repeats.") else text_out + " Pick another column, or leave it empty."
    return text.replace("The descriptor cannot be approved: ", "The column map can't be saved yet: ")


def _diff(a: dict, b: dict) -> list[str]:
    out = []
    if (a["slots"].get("target") or None) != (b["slots"].get("target") or None):
        out.append(f"predict {b['slots'].get('target') or 'nothing'}")
    for c, r in b["roles"].items():
        if a["roles"].get(c) and a["roles"][c] != r:
            out.append(f"{c} → {ROLE_LABELS.get(r, r)}")
    for k in ("category", "entity", "time", "key", "text"):
        if (a["slots"].get(k) or None) != (b["slots"].get(k) or None):
            out.append(f"{SLOT_LABELS[k][0].lower()} → {b['slots'].get(k) or 'none'}")
    return out


def _plain_reason(reason: str) -> str:
    m = re.search(r"The label (\S+) must be 0 or 1; \S+ also holds (.+?)\. Describe", reason)
    if m:
        return f"what to predict is {m.group(1)}, which holds {m.group(2)} instead of 0 and 1."
    return reason


def _ago(ts) -> str:
    try:
        t = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except ValueError:
        return ""
    local = t.astimezone()
    day = "today" if local.date() == datetime.now().date() else local.strftime("%d %b")
    return f"{day} at {local.strftime('%H:%M')}"


def _listed(value) -> list[str]:
    """A card value that may be one text or a list of ticks, as a list of the non-empty ones."""
    values = value if isinstance(value, (list, tuple)) else [value]
    return [str(x).strip() for x in values if x is not None and str(x).strip()]


def use_chosen(entry: dict) -> None:
    """Make one of the chosen tables the one the cards work on (`chosen_data` already holds it)."""
    SESSION.source_label = entry["label"]
    SESSION.source_rows = entry.get("rows")
    SESSION.broken = entry.get("broken")
    SESSION.review, SESSION.dataset = None, None


# =====================================================================================================
class ChooseData(Screen):
    """Choose the data: kit datasets, your own (tables already in the database, or a new file or folder) and
    external sources (connected ones, or a new connection) - any number of them, from any mix of the three. Each
    ticked table is loaded with its own cell; the first is the one the column map opens on, and the column map card
    moves between them. Semantic views starts with their schemas ticked. Every option and every step is one cell of
    the quickstart's code section (actions: data.*)."""
    help = (('Load your data', 'get-the-data'),
            ('Connect an external source', 'get-the-data/external-sources#step-by-step-a-new-external-source'),)

    kind = "card"
    # True when the card adds to the tables already chosen (the sources part of 01_explore's Understand card): a pick
    # joins them instead of replacing them, and the quickstart's way on is not shown.
    ADDING = False
    connector, src_name, conn_n, tip = None, "", 0, ""
    failed: list[str] = []          # what was ticked and could not be loaded, with the kit's reason
    preset, typed_storage = None, ""     # the settings chosen for a source that has some (the kit says which)
    # The password typed for the connection being set up, held here until it connects: the card's own box is emptied
    # the moment it is sent, and it sits on an earlier step, so a connect tried again (the source refused, a name did
    # not resolve) would go out with no password. Never shown, logged or saved; forgotten on success or a new source.
    _kept_secret = ""

    def __init__(self) -> None:
        super().__init__()
        self.samples: list[dict] = []
        self.own: list[dict] = []
        self.sources: list[str] = []
        self.connectors: list[dict] = []
        self.forms: dict[str, dict] = {}       # each connector's inputs, as `exakit connect` asks them (nb.connector_inputs)
        self.parsed: dict[str, dict] = {}      # a connection string read per connector (nb.read_connection_string)
        self.tip = ""                          # the engine's tip about this computer's public IP
        self.source_tables: dict[str, list[dict]] = {}   # each connected source's tables
        self.connector: str | None = None      # the data source chosen for a new connection
        self.src_name = ""
        self.conn_n = 0
        self.rows: dict[str, str] = {}
        self.kit_said = ""
        self.done = False
        self.loading = True
        SESSION.listen(self)
        self.refresh()
        import threading

        threading.Thread(target=self._load_options, daemon=True).start()

    def _load_options(self) -> None:
        """What can be picked, live: the kit's samples, your tables and approved maps, connected sources, connectors."""
        try:
            self.samples = [s for s in actions.run("kit.datasets") if s.get("described")]
            self.connectors = actions.run("data.connectors")
            self.forms = actions.run("data.connector_forms")
            try:        # the connect menu's first line: this computer's public IP, to allow at a cloud source
                self.tip = next((e.split(" ", 1)[1] for e in actions.run("data.source_tips") if "Tip:" in e), "")
            except Exception:
                self.tip = ""
            approved = {a["table"].upper(): a for a in actions.run("kit.approved")}
            found = actions.run("data.map")
            self.rows = {r["table"].upper(): r["rows_shown"] for r in found.table_rows}
            self.own = []
            for r in found.table_rows:
                if r["origin"] != "local":
                    continue
                a = approved.pop(r["table"].upper(), None)
                self.own.append({"value": f"ds:{a['id']}" if a else f"tbl:{r['table']}",
                                 "label": f"{r['table']} · {r['rows_shown']} rows · " + (f"column map v{a['version']}" if a else r["map"])})
            sample_schemas = {s["schema"].upper() for s in actions.run("kit.datasets")}
            for table, a in approved.items():     # approved maps over views (a cleaned or plain-name copy)
                if table.split(".")[0] not in sample_schemas:
                    self.own.append({"value": f"ds:{a['id']}", "label": f"{a['table']} · column map v{a['version']}"})
            self.sources = sorted({r["table"].split(".")[0] for r in found.table_rows if r["origin"] == "source"})
            self.source_tables = {x: [{"value": r["table"].split(".", 1)[1], "label": r["table"].split(".", 1)[1],
                                       "hint": f"{r['rows_shown']} rows" if r.get("rows_shown") else ""}
                                      for r in found.table_rows if r["origin"] == "source" and r["table"].split(".")[0] == x]
                                  for x in self.sources}
        except Exception as exc:
            self.flash = {"kind": "warn", "v": f"Part of what is available could not be read: {str(exc).splitlines()[0]}"}
        self.loading = False
        self.refresh()
        SESSION.release()

    def build(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Choose your data",
                "sub": "Tick everything you want to work on: kit datasets, your own tables and external sources, "
                       "together. You can change it at any time."}
        if self.loading:
            return [head, {"t": "empty", "v": "Looking at what's available…"}]
        samples = [{"value": s["id"], "label": s["label"], "hint": "Loaded" if s["loaded"] else "Downloads the first time"}
                   for s in self.samples]
        own_options = [{"value": o["value"], "label": o["label"]} for o in self.own] + [{"value": "__new__", "label": "Load a new file…"}]
        new_only = {"field": "own", "equals": "__new__"}
        conn = self._cf()
        connect_only = {"field": conn, "equals": "__connect__"}
        options = [
            {"value": "sample", "title": "Kit datasets", "text": "Ready-made data that comes with the kit.",
             "disabled": not samples, "disabled_reason": "The kit lists no dataset with a column map.",
             "fields": [{"id": "sample", "type": "picks", "label": "Datasets",
                         "value": [samples[0]["value"]] if samples else [], "options": samples}]},
            {"value": "file", "title": "Your own data", "text": "Tables in the database, or a new file or folder.",
             "fields": [{"id": "own", "type": "picks", "label": "Tables", "value": [own_options[0]["value"]], "options": own_options},
                        {"id": "path", "type": "text", "label": "File or folder (CSV, Excel, Parquet, JSON)", "placeholder": "~/Downloads/sales.xlsx", "show_if": new_only},
                        {"id": "schema", "type": "text", "label": "Save it under (optional)", "placeholder": "MY_DATA", "show_if": new_only}]},
            {"value": "source", "title": "External sources", "text": "Live data in other systems, read where it is.",
             "fields": self._source_fields(connect_only)},
        ]
        # A new connection is one form; once its data source (and the source's own settings) are chosen, the form's
        # two buttons show: test it, or connect it and use everything ticked.
        connecting = [{"field": "kind", "equals": "source"}, connect_only]
        # "Use this data" loads everything ticked; it shows whenever no new connection is being entered.
        plain = {"any": [{"field": "kind", "not": "source"}, {"field": conn, "not": "__connect__"}]}
        use = {"id": "use", "label": "Use this data", "primary": True, "busy": "Loading…"}
        items = []
        if self._ready():
            # One button does everything ticked: it connects the new source, and loads the datasets, tables and
            # file ticked beside it.
            items += [{"id": "test_source", "label": "Test connection", "busy": "Testing…", "show_if": connecting, "no_secret": True},
                      {**use, "label": "Connect and use this data", "busy": "Connecting…", "show_if": connecting},
                      {**use, "show_if": plain}]
        else:
            items.append(use)      # no data source chosen for a new connection yet: the rest ticked is still usable
        blocks = [head, {"t": "choice", "id": "kind", "multi": True, "value": ["sample"] if samples else ["file"],
                         "options": options, "below": True,
                         "actions": items}]     # the buttons sit inside the panel under the ticked options
        if self.done and SESSION.source is not None and not self.ADDING:
            rows = f" · {SESSION.source_rows} rows" if SESSION.source_rows else ""
            what = (f"{len(SESSION.chosen)} tables: {', '.join(e['table'] for e in SESSION.chosen)}"
                    if len(SESSION.chosen) > 1 else f"{SESSION.source_label}{rows}")
            blocks.append({"t": "msg", "kind": "ok", "keep": True,
                           "v": f"Using {what}. Next, 01_explore opens it: what each column means and how your "
                                "tables connect, then the checks, the groups and a first prediction."})
            nxt = _next_notebook()            # the bottom of the quickstart: the way on, once the data is chosen
            if nxt:
                blocks.append({"t": "next", "v": f"Next: {nxt['title']}", "path": nxt["file"]})
        if self.failed:
            blocks.append({"t": "msg", "kind": "warn", "v": "; ".join(self.failed)})
        if self.kit_said:
            blocks.append({"t": "details", "title": "What the kit said", "blocks": [{"t": "pre", "v": self.kit_said}]})
        if SESSION.code:
            blocks.append({"t": "code", "code_only": True, "title": "The code behind this step", "v": "\n".join(SESSION.code)})
        return blocks

    def _wanted(self, v: dict) -> tuple[list[tuple[str, str, dict, str]], bool]:
        """Everything ticked, as the loading cells to run: (action, variable, its values, label). A new connection
        is connected here first (on its last step); the second value says whether one was."""
        kinds = _listed(v.get("kind")) or ["sample"]
        wanted: list[tuple[str, str, dict, str]] = []
        connected = False
        if "sample" in kinds:
            for dataset_id in _listed(v.get("sample")):
                label = next((s["label"] for s in self.samples if s["id"] == dataset_id), dataset_id)
                wanted.append(("data.sample", "sample_data", {"dataset_id": dataset_id}, label))
        if "file" in kinds:
            for own in _listed(v.get("own")) or ["__new__"]:
                if own.startswith("ds:"):
                    wanted.append(("data.approved", "own_data", {"dataset_id": own[3:]}, own[3:]))
                elif own.startswith("tbl:"):
                    wanted.append(("data.table", "own_data", {"table": own[4:]}, own[4:]))
                else:
                    path = str(v.get("path") or "").strip()
                    if not path:
                        raise ValueError("Enter the path to a file or folder.")
                    schema = str(v.get("schema") or "").strip() or None
                    wanted.append(("data.own_file", "own_data", {"path": path, "schema": schema}, Path(path).expanduser().name))
        if "source" in kinds:
            for schema in _listed(v.get(self._cf())):
                if schema == "__connect__":
                    if not self._ready() and (len(kinds) > 1 or len(_listed(v.get(self._cf()))) > 1):
                        continue              # a new connection with no data source chosen: the rest is loaded without it
                    try:
                        schema = self._connect(v)
                    except Exception as exc:
                        if len(kinds) == 1 and len(_listed(v.get(self._cf()))) == 1:
                            raise                 # the connection is all that was asked for: its reason is the answer
                        # other things are ticked too: they are loaded, and the connection's reason is said with them
                        self.failed.append(f"the new connection ({str(exc).splitlines()[0] if str(exc) else type(exc).__name__})")
                        continue
                    # the next new connection starts from an empty form, and the list of connections from its top
                    self.conn_n, self.connector, self.preset, self.src_name = self.conn_n + 1, None, None, ""
                    connected = True
                    tables = _listed(v.get("table")) or self._new_source_tables(schema)
                    if not tables:
                        continue
                else:
                    tables = _listed(v.get(self._tid(schema))) or _listed(v.get("table")) or [""]
                for table in tables:
                    source = f"{schema}.{table}" if table and "." not in table else (table or schema)
                    wanted.append(("data.source", "source_data", {"source": source}, source))
        return wanted, connected

    MANY_TABLES = 10

    def _new_source_tables(self, schema: str) -> list[str]:
        """The tables to open of a source that was just connected: all of them when it has a few (it was connected
        to be used), its one table, or none when it has many - then it is connected and listed, and its tables are
        ticked under Connections. [""] leaves the choice to nb.load_source (a source whose tables could not be listed)."""
        try:
            self._load_options()                       # reads the database again: the new source and its tables
        except Exception:
            return [""]
        names = [t["value"] for t in (self.source_tables or {}).get(schema, [])]
        if len(names) > self.MANY_TABLES:
            self.failed.append(f"{schema} is connected and has {len(names)} tables: tick the ones to use under Connections, "
                               "then press Use this data")
            return []
        return names or [""]

    def on_use(self, v: dict) -> None:
        from ..actions import Var

        SESSION.broken = None
        self.failed = []
        if not SESSION.get("workflow_id"):      # guide.start() began one; a screen shown on its own begins it here
            actions.run("data.workflow")
        wanted, connected = self._wanted(v)
        if not wanted:
            if connected and self.failed:              # connected, with many tables: nothing to open yet, and said so
                self.done = False
                return
            raise ValueError("Tick at least one dataset, table or source.")
        several = len(wanted) > 1 or self.ADDING     # adding: every table is kept by name beside the ones there
        if several and not self.ADDING:
            actions.run("data.several")
        chosen: list[dict] = list(SESSION.chosen) if self.ADDING else []
        before = len(chosen)
        for action_id, variable, values, label in wanted:
            SESSION.broken = None
            try:
                variable = self._open(action_id, variable, **values)
                data = SESSION.get(variable)
                if data is None:
                    raise ValueError("nothing was loaded")
            except Exception as exc:
                if not several:
                    raise
                self.failed.append(f"{label} ({str(exc).splitlines()[0] if str(exc) else type(exc).__name__})")
                continue
            table = str(data.fact_table)
            if any(e["table"] == table for e in chosen):
                continue                              # two ticks that open the same table
            if several:
                actions.run("data.keep", table=table, data=Var(variable))
            chosen.append({"label": f"{label} ({table})", "table": table, "variable": variable,
                           "rows": self.rows.get(table.upper()), "broken": SESSION.broken})
        if len(chosen) == before:
            SESSION.broken = None
            raise ValueError("Nothing new was loaded. The kit's note is under 'What the kit said'." if self.ADDING else
                             "Nothing was loaded. The kit's note is under 'What the kit said'.")
        if self.ADDING:                     # the first table added is the one worked on next
            chosen = chosen[before:] + chosen[:before]
        if several:
            actions.run("data.switch", table=chosen[0]["table"])
        else:
            actions.run("data.choose", data=Var(chosen[0]["variable"]))
        if SESSION.source is None:
            raise ValueError("Nothing was loaded. The kit's note is under 'What the kit said'.")
        SESSION.chosen, SESSION.chosen_n = chosen, SESSION.chosen_n + 1
        use_chosen(chosen[0])
        actions.run("data.remember", tables=[e["table"] for e in chosen])    # what 01_explore opens
        self.done = True
        if connected or any(action_id == "data.own_file" for action_id, *_rest in wanted):
            self._load_options()                      # what was just loaded or connected can be picked
        SESSION.changed("source", self)

    def _open(self, action_id: str, variable: str, **values) -> str:
        """Run one loading cell; a saved column map the kit refuses (what to predict is not 0/1, say) opens the table
        itself with nb.use_table, so the map can be fixed below. Returns the variable that holds the data."""
        try:
            actions.run(action_id, **values)
        except ValueError as exc:
            dataset_id = values.get("dataset_id")
            table = next((a["table"] for a in actions.run("kit.approved") if a["id"] == dataset_id), None)
            if not table:
                raise
            actions.run("data.table", table=table)
            SESSION.broken = {"id": dataset_id, "reason": str(exc).splitlines()[0]}
            variable = "own_data"
        finally:
            self.kit_said = SESSION.said or self.kit_said
        return variable

    @staticmethod
    def _fid(connector: str, name: str) -> str:
        return f"cx_{connector.replace('-', '_')}__{name}"

    def _sid(self, cid: str) -> str:
        """The field names of a connector's inputs after its string was read (one set per reading, so a string read
        again fills them anew)."""
        return f"{cid}_r{self.parsed.get(cid, {}).get('n', 0)}"

    def _input_field(self, cid: str, spec: dict, only: list) -> dict:
        label = spec["label"].split(" - ")[0] + (" *" if spec["required"] else "")
        field = {"id": self._fid(cid, spec["name"]), "label": label, "value": spec["default"], "show_if": only,
                 "placeholder": spec["default"] or ("path to the file" if spec["file"] else "")}
        if spec["kind"] == "secret":
            field.update(type="password", value="", label=label + " (goes to the kit only, never shown, saved or logged here)")
        elif spec["choices"]:
            field.update(type="select", options=[{"value": c, "label": c} for c in spec["choices"]])
        else:
            field.update(type="text")
        if spec.get("hint"):
            field["label"] += " - " + " ".join(spec["hint"])       # what the connect form says above this question
        return field

    def _name_label(self) -> str:
        """The connect form's own first question (the engine's source-name input)."""
        for form in self.forms.values():
            if form.get("name_input"):
                return form["name_input"]["label"]
        return "Name for this connection"

    @staticmethod
    def _tid(schema: str) -> str:
        return "src_tbl__" + re.sub(r"\W", "_", schema)

    def _cf(self) -> str:
        """The Connection box's field name: a new one after each connect, so the box opens on the list again."""
        return f"src_schema_{self.conn_n}" if self.conn_n else "src_schema"

    def _groups(self, cid: str) -> tuple[list[dict], list[dict]]:
        """A connector's inputs as fields, in `exakit connect`'s order: what is still needed (required, or missing
        from the connection string that was read; the password with them), then the optional rest (a CA file, a
        port ...), filled in from the string or the kit's default."""
        form, read = self.forms.get(cid) or {}, self.parsed.get(cid)
        # One set of fields per reading (a string read again fills them anew); before a reading, the plain set.
        sid = self._sid(cid) if read else cid
        first = set(read["missing"]) if read else {i["name"] for i in form.get("inputs", []) if i["required"]}
        needed, rest = [], []
        for spec in form.get("inputs", []):
            if read and spec["kind"] == "secret" and read["credential_in_string"] and not spec.get("storage"):
                continue                                   # the string holds it
            if spec["name"] in first or (spec["kind"] == "secret" and spec["required"]):
                needed.append(self._input_field(sid, {**spec, "required": True}, None))
                continue
            field = self._input_field(sid, {**spec, "required": False}, None)
            if read and spec["kind"] != "secret":
                field["value"] = read["values"].get(spec["name"], spec["default"])
            field["label"] += " (optional)"
            rest.append(field)
        return needed, rest

    def _ready(self) -> bool:
        """A data source is chosen and every setting the kit asks for it is settled: its details can be filled in."""
        form = self.forms.get(self.connector or "")
        return bool(form) and not form.get("gate") and not self._pending(form)

    def _source_fields(self, connect_only: dict) -> list[dict]:
        """External sources: the connections there are, with the tables to read from each, and - under "New
        connection" - one form for a new one: the data source, the source's own settings where it has some (each a
        list; the ones after it follow the choice), how to fill it in, then the name and every detail in one place,
        the required ones first. Nothing here names a source: the list, each setting, each question, label, default
        and choice is what the kit's `exakit connect` asks (nb.connectors, nb.connector_inputs,
        nb.read_connection_string), so a source added or changed in the kit shows here as it is."""
        tables = self.source_tables or {}
        fields: list[dict] = [{"id": self._cf(), "type": "picks", "label": "Connections",
                               "value": [self.sources[0] if self.sources else "__connect__"],
                               "options": [{"value": x, "label": x, "hint": f"{len(tables.get(x, []))} tables" if tables.get(x) else ""}
                                           for x in self.sources] + [{"value": "__connect__", "label": "New connection…"}]}]
        for schema in self.sources:
            found, only = tables.get(schema, []), {"field": self._cf(), "equals": schema}
            fields.append({"id": self._tid(schema), "type": "picks", "label": f"Tables of {schema}",
                           "value": [found[0]["value"]], "options": found, "show_if": only} if found else
                          {"id": self._tid(schema), "type": "text", "label": "Table (empty: its one table, or the list of them)",
                           "placeholder": "ORDERS", "show_if": only})
        for field in self._new_connection():
            field["show_if"] = [connect_only, field.pop("by")] if "by" in field else connect_only
            fields.append(field)
        return fields

    def _new_connection(self) -> list[dict]:
        cid = self.connector or ""
        form, read = self.forms.get(cid) or {}, self.parsed.get(cid)
        out: list[dict] = [{"id": "src_h_new", "type": "heading", "v": "New connection"}]
        top: list[dict] = []                    # the data source and how to fill it in, side by side
        out.append({"id": "src_top", "type": "group", "fields": top})
        top.append({"id": "connector", "type": "select", "label": "Data source *", "value": cid, "sync": True,
                    "placeholder": "Choose a data source…", "send_on_change": "src_pick",
                    "options": [{"value": c["id"], "label": c["name"], "disabled": bool(c.get("gate")),
                                 "hint": (f"not available yet: {c['gate']}" if c.get("gate") else c.get("summary") or "")}
                                for c in self.connectors]})
        if not form:
            return out
        # The source's own settings, as the kit asks them: one list each. A choice decides what the next ones offer.
        chosen = self.preset or {}
        settings = []
        for spec in form.get("setting_inputs", []):
            labels = spec.get("choice_labels") or spec["choices"]
            settings.append({"id": self._fid(cid, "set_" + spec["name"]), "type": "select", "sync": True,
                             "label": spec["label"].split(" - ")[0] + " *", "value": chosen.get(spec["name"], ""),
                             "placeholder": "Choose…", "send_on_change": "src_set",
                             "options": [{"value": value, "label": label} for value, label in zip(spec["choices"], labels)]
                                        + [{"value": f"__off__{n}", "label": said, "disabled": True}
                                           for n, said in enumerate(spec.get("disabled") or [])]})
        if settings:
            out.append({"id": self._fid(cid, "settings"), "type": "group", "fields": settings})
        if self._pending(form):
            return out + [{"id": self._fid(cid, "pending"), "type": "note", "v": "Choose these and the details to fill in show here."}]
        how = self._fid(cid, "how")
        if form.get("forms"):
            top.append({"id": how, "type": "select", "label": "How to fill it in", "value": "manual",
                        "options": [{"value": "manual", "label": "Fill in the details", "hint": "the name, the host, the account and the rest, below"},
                                    {"value": "string", "label": "Paste a connection string", "hint": "the kit reads it and fills in the details"}]})
            out.append({"id": self._fid(cid, "url"), "type": "text", "wide": True, "by": {"field": how, "equals": "string"},
                        "send_on_change": "src_read", "placeholder": form["forms"][0],
                        "label": f"Connection string ({' or '.join(form['forms'][:2])})"})
            out.append({"id": self._fid(cid, "hint"), "type": "note", "by": {"field": how, "equals": "string"},
                        "v": (f"Read: {read['masked']}. What it did not hold is marked * below." if read else
                              "Paste it: the kit reads it, fills in the details below and leaves only what it does not hold.")})
        needed, rest = self._groups(cid)
        name = {"id": "src_name", "type": "text", "value": self.src_name,
                "label": self._name_label() + " *", "placeholder": "sales (lower case; tables appear as VS_SALES)"}
        for field in needed + rest:
            if field.get("type") == "password" or len(field["label"]) > 70:
                field["wide"] = True
        out += [{"id": self._fid(cid, "h_needed"), "type": "heading", "v": "Details"},
                {"id": self._fid(cid, "needed"), "type": "group", "fields": [name] + needed}]
        if rest:
            out += [{"id": self._fid(cid, "h_rest"), "type": "heading", "v": "Optional settings",
                     "sub": ("filled in from the string or the kit's default" if read else "the kit's defaults")
                            + "; change one only to use another value"},
                    {"id": self._fid(cid, "rest"), "type": "group", "fields": rest}]
        said = ([f"Access the reader needs: {form['access']}."] if form.get("access") else []) + form.get("tips", [])[:1]
        if said:
            out.append({"id": self._fid(cid, "note"), "type": "note", "v": " ".join(said)})
        if self.tip:
            out.append({"id": "src_tip", "type": "note", "v": self.tip})
        return out

    def on_src_pick(self, v: dict) -> None:
        """A data source was picked: its form, as the kit gives it."""
        connector = str(v.get("connector") or "").strip()
        form = self.forms.get(connector)
        if not form:
            raise ValueError("Choose the data source first.")
        if form.get("gate"):
            raise ValueError(f"{form['name']} is not available yet: {form['gate']}")
        if connector != self.connector:
            self._kept_secret, self.typed_storage, self.preset = "", "", {}     # another source: its own secrets
            self.src_name = str(v.get("src_name") or "").strip().lower()
        self.connector = connector
        self._settle_all()

    def on_src_set(self, v: dict) -> None:
        """One of the source's settings was picked: the settings before it stay, the ones after it are asked of the
        kit again (what they offer follows this choice), and the details shown are that combination's."""
        cid = self.connector or ""
        before = self.preset or {}
        chosen: dict = {}
        for spec in (self.forms.get(cid) or {}).get("setting_inputs", []):
            value = str(v.get(self._fid(cid, "set_" + spec["name"])) or "").strip()
            if value not in spec["choices"]:
                break
            chosen[spec["name"]] = value
            if value != before.get(spec["name"]):
                break                                  # this is the one that changed: what follows it starts again
        if chosen != before:
            self._kept_secret, self.typed_storage = "", ""
        self.preset = chosen
        self.src_name = str(v.get("src_name") or self.src_name or "").strip().lower()
        self._settle_all()

    def on_src_read(self, v: dict) -> None:
        """A connection string was pasted: read it the way `exakit connect --url` reads it, so the details fill in
        and only what it does not hold is left to type."""
        cid = self.connector or ""
        text = str(v.get(self._fid(cid, "url")) or "").strip()
        if not text or not self.forms.get(cid):
            return
        read = self.parsed.get(cid)
        if not read or read.get("text") != text:
            self._read_string(cid, text)
            self.kit_said = SESSION.said or self.kit_said

    def _settle_all(self) -> None:
        """Ask the kit for the form of the settings chosen so far, taking its own default for each setting it asks
        next, until none is left to ask or the next one has no default (that one is the user's to pick)."""
        form = self.forms.get(self.connector or "") or {}
        if not form.get("setting_inputs"):
            return
        for _ in range(12):
            form = self._settle(self.connector, self.preset or {})
            pending = self._pending(form)
            if not pending or not pending[0]["default"]:
                return
            self.preset = {**(self.preset or {}), pending[0]["name"]: pending[0]["default"]}

    def _pending(self, form: dict) -> list[dict]:
        """The connector's setting questions the tree pick did not answer (a Lakehouse's catalog login)."""
        return [spec for spec in form.get("setting_inputs", []) if spec["name"] not in (self.preset or {})]

    def _settle(self, connector: str, settings: dict) -> dict:
        """The connector's form for these settings, asked of the kit (nb.connector_inputs(connector, **settings))."""
        self.forms = actions.run("data.connector_form", connector=connector, settings=settings)
        self.kit_said = SESSION.said or self.kit_said
        return self.forms.get(connector) or {}

    def _read_string(self, connector: str, text: str) -> dict:
        """Read a connection string with the kit's own engine (nb.read_connection_string, `exakit connect --url`'s
        reader). The string stays in the notebook's SOURCE_URL variable, as the code section holds it: the code shown
        and the workflow log name the variable, never the string - it may hold a password."""
        from ..actions import Var

        SESSION.set("SOURCE_URL", text)
        read = dict(actions.run("data.read_string", connector=connector, text=Var("SOURCE_URL"), settings=self.preset or {}))
        # A setting the string itself shows (a folder path: no catalog) is chosen with it: the steps after ask that
        # combination's details. A setting is never a detail to type again.
        names = {spec["name"] for spec in (self.forms.get(connector) or {}).get("setting_inputs", [])}
        shown = {key: value for key, value in read["values"].items() if key in names and key not in (self.preset or {})}
        if shown:
            self.preset = {**(self.preset or {}), **shown}
            self._settle(connector, self.preset)
        read["values"] = {key: value for key, value in read["values"].items() if key not in names}
        read["text"] = text
        read["n"] = self.parsed.get(connector, {}).get("n", 0) + 1
        self.parsed[connector] = read
        return read

    def _source_inputs(self, v: dict, needed_only: bool = False) -> tuple[str, str, dict, str]:
        """The chosen connector, the source's name, its settings for nb.connect_source / nb.test_source (url=,
        password_file=, and each input by name) and the password, from the card's fields: with a connection string,
        the string (without its password) and only the inputs it did not give; else every input."""
        connector = str(self.connector or v.get("connector") or "").strip()
        form = self.forms.get(connector)
        if not form:
            raise ValueError("Choose the kind of source first.")
        if form.get("gate"):
            raise ValueError(f"{form['name']} is not available yet: {form['gate']}")
        name = str(v.get("src_name") or self.src_name or "").strip().lower()
        if not name and not needed_only:
            raise ValueError("Give the source a name (lower case, e.g. sales): its tables appear as VS_<NAME>.")
        specs = form["inputs"]
        settings: dict = {}
        password = ""
        prefix = self._sid(connector) if connector in self.parsed else connector     # the fields on screen when pressed
        text = str(v.get(self._fid(connector, "url")) or "").strip() if form.get("forms") else ""
        if v.get(self._fid(connector, "how")) == "manual":
            text = ""
        if text:
            read = self.parsed.get(connector)
            if not read or read.get("text") != text:
                read = self._read_string(connector, text)       # not read yet, or changed since: read it now
            from ..actions import Var

            settings["url"] = Var("SOURCE_URL")      # nb.connect_source uses a password in it, and never shows it
            required, given = set(read["missing"]), dict(read["values"])
        else:
            required, given = {i["name"] for i in specs if i["required"]}, {}
        if prefix == connector:      # fields drawn before any reading hold the kit's defaults, not the string's values
            given = {}
        missing = []
        for spec in specs:
            raw = v.get(self._fid(prefix, spec["name"]))
            value = str(raw or "").strip()
            if spec["kind"] == "secret" and spec.get("storage"):
                self.typed_storage = str(raw or "") or self.typed_storage   # the second secret: its own file, never the password's way
                if spec["name"] in required and not self.typed_storage and not needed_only:
                    missing.append(spec["label"].split(" - ")[0])
            elif spec["kind"] == "secret":
                # as pasted, without the blank a copy picked up around it (never part of a password a person means)
                password = str(raw or "").strip() or password
            elif spec["kind"] == "secret-file":
                if value:
                    settings["password_file"] = value
            # Only what differs from what the string gave or the kit's default goes on: the string says the rest.
            elif value and value != given.get(spec["name"], spec["default"]):
                settings[spec["name"]] = value
            if spec["name"] in required and not value and spec["kind"] != "secret":   # the kit asks a password itself
                missing.append(spec["label"].split(" - ")[0])
        if missing:
            raise ValueError("Fill in: " + ", ".join(missing))
        self._kept_secret = password = password or self._kept_secret        # as typed this time, else as typed before
        return connector, name, {**(self.preset or {}), **settings}, password

    def on_test_source(self, v: dict) -> None:
        """Test connection: the kit's own check of the inputs, then whether this computer reaches the source
        (nb.test_source). Nothing is connected or changed, and no password is needed."""
        connector, name, settings, _ = self._source_inputs(v)
        result = actions.run("data.test_source", connector=connector, name=name, settings=settings)
        self.kit_said = SESSION.said or self.kit_said
        self.flash = {"kind": "ok" if result.ok else "error", "keep": True,
                      "v": (f"Connection test for {name}: ready. Use this data connects it." if result.ok
                            else f"Connection test for {name}: not ready yet. Fix the line marked below, then test again."),
                      "lines": [("ok" if ok else "error", f"{what}: {said}") for what, ok, said in result.checks]}

    def _connect(self, v: dict) -> str:
        """Connect an external source with the kit's own `exakit connect` (nb.connect_source), from the connector's
        own inputs: the password goes to it on standard input, never into a cell, a log or this card. Returns the new
        schema (VS_<NAME>)."""
        connector, name, settings, typed = self._source_inputs(v)
        # The card's box answers the kit's own password question (a source without one: Enter, empty).
        schema = actions.run("data.connect_source", connector=connector, name=name, settings=settings,
                             secret={"secret": lambda _question: typed,
                                     **({"storage_secret": lambda _question: self.typed_storage} if self.typed_storage else {})})
        self.kit_said = SESSION.said or self.kit_said
        self._kept_secret, self.typed_storage = "", ""         # connected: nothing is held any longer
        if schema and schema not in self.sources:
            self.sources.append(schema)
        return schema

    def on_session(self, what: str) -> None:
        if what == "data":     # a load (Home's Add data): read again what is in the database, so it can be picked
            import threading

            self.loading = True
            self.refresh()
            threading.Thread(target=self._load_options, daemon=True).start()
            return
        self.refresh()


# =====================================================================================================
class ColumnMap(Screen):
    help = (('Approve the column map', 'explore/approve-the-column-map'),)
    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.kit_said = ""
        self.first: dict | None = None
        self.leaks: list[str] = []
        self.ai: dict | None = None        # the AI's second look at this table's draft: {"items": [...]} or {"error"}
        SESSION.listen(self)
        self.refresh()

    ai: dict | None = None

    # -- loading the proposal ---------------------------------------------------------
    def on_session(self, what: str) -> None:
        if what == "source":
            self._review()
        elif what == "ai" and SESSION.source is not None:      # the one AI button filled this table's answer in
            self.ai = SESSION.ai_maps.get(str(SESSION.source.fact_table))
        self.refresh()

    def _review(self, reuse: bool = False) -> None:
        """Draw up this table's column map (nb.review_roles) and keep it by table name, so going back to a table
        reads nothing again (reuse=True: role_review = role_reviews[table])."""
        from ..actions import Var

        self.first, self.leaks = None, []
        table = str(SESSION.source.fact_table) if SESSION.source is not None else ""
        self.ai = SESSION.ai_maps.get(table) if table else None
        kept = SESSION.get("role_reviews")
        seen = self.__dict__.setdefault("seen", {})       # {table: (leaks, first look)}: what was read with the review
        if reuse and isinstance(kept, dict) and table in kept:
            actions.run("map.reuse", table=table)
            if table in seen:                             # nothing changed since: the same answers, no query
                self.leaks, self.first = seen[table]
                self.kit_said = SESSION.said
                if SESSION.review.draft.status == "approved":
                    actions.run("map.keep")
                return
        else:
            actions.run("map.review")
            if table:
                if not isinstance(kept, dict):
                    actions.run("map.reviews")
                actions.run("map.remember", table=table)
        self.kit_said = SESSION.said
        try:
            actions.run("map.draft")
            self.leaks = list(actions.run("map.leakage", data=Var("draft_dataset")) or [])
        except Exception:
            self.leaks = []
        if SESSION.review.draft.status == "approved":
            try:
                actions.run("map.keep")
            except ValueError as exc:   # the saved map is approved but the kit refuses to read it back
                SESSION.dataset = None
                SESSION.broken = {"id": SESSION.review.draft.id, "reason": str(exc).splitlines()[0]}
                return
            self._first_result_safe()
        if table:
            seen[table] = (self.leaks, self.first)

    # -- view ---------------------------------------------------------------------------
    def build(self) -> list[dict]:
        """The card, top to bottom: the tables chosen (when there are several: one tab each, saying which are
        approved; this card works on the one picked), the AI's second look at the kit's guesses, then the three
        questions and Approve - and, once this table is approved, the way on to the next one."""
        blocks = self._blocks()
        rv = SESSION.review
        if rv is None or SESSION.source is None:
            return blocks
        top: list[dict] = []
        now = str(SESSION.source.fact_table)
        several = len(SESSION.chosen) > 1
        approved = self._approved_tables() if several else set()
        if several:
            left = [e["table"] for e in SESSION.chosen if e["table"].upper() not in approved]
            top.append({"t": "tablepick", "field": "map_table_pick", "action": "map_switch", "value": now,
                        "label": f"{len(SESSION.chosen)} tables · {len(SESSION.chosen) - len(left)} approved",
                        "items": [{"value": e["table"], "label": e["table"],
                                   "state": "approved" if e["table"].upper() in approved else "todo"}
                                  for e in SESSION.chosen]})
        if several:
            top += self._all_blocks(len(left))
        mine = SESSION.your_rules("ROLE_RULES", "LINK_RULES")
        if mine:
            top.append(mine)
        top.append(self._ai_block(rv))
        blocks[1:1] = top
        if several and now.upper() in approved:
            # This table is done: the way on, right under Approve.
            left = [e["table"] for e in SESSION.chosen if e["table"].upper() not in approved]
            at = next((i for i, b in enumerate(blocks) if b.get("t") == "actions"
                       and any(a.get("id") == "approve" for a in b.get("items", []))), len(blocks) - 1)
            done = len(SESSION.chosen) - len(left)
            blocks.insert(at + 1, {"t": "linkcard", "kind": "ok", "title": f"{now} is approved",
                                   "text": f"{done} of {len(SESSION.chosen)} tables approved. Next: {left[0]}.",
                                   "button": {"label": f"Review {left[0]}", "id": "map_next"}} if left else
                          {"t": "linkcard", "kind": "ok", "title": f"All {len(SESSION.chosen)} tables are approved",
                           "text": "They are saved in your data map. Check how they connect, below."})
        return blocks

    # -- every chosen table at once ---------------------------------------------------------------------------------
    all_review: dict | None = None      # nb.schema_review(role_reviews): what to look at across the tables

    def _all_blocks(self, left: int) -> list[dict]:
        """Approve the chosen tables together: the kit drafts each, and one screen shows only what needs a person -
        the columns it guessed at, across every table, and the columns it marked personal data. What it is sure of
        is counted, not listed. One button approves them all; the semantic model is updated once per source."""
        if left < 2:                       # one table left: its own tab approves it
            return []
        found = self.all_review
        if found is None:
            return [{"t": "actions", "items": [{"id": "map_all", "label": f"Review all {len(SESSION.chosen)} tables together",
                                                "busy": "Reading each table…"}]}]
        todo = [t for t in found["tables"] if t not in found["approved"]]
        blocks: list[dict] = [{"t": "subhead", "v": f"All {len(found['tables'])} tables at once",
                               "tip": "Only what needs you is shown: the columns the kit was not sure about, in every table. "
                                      "Change one if it is wrong. What to predict is not set here: pick it in a table's own "
                                      "tab when you want a model."}]
        if found["check"]:
            options = [{"value": k, "label": v} for k, v in ROLE_LABELS.items()]
            blocks.append({"t": "fields", "items": [{"id": "map_all_check", "type": "group", "fields": [
                {"id": f"all:{c['table']}:{c['column']}", "type": "select", "value": c["role"], "options": options,
                 "label": f"{c['table'].split('.', 1)[1]}.{c['column']}" + (f" ({c['evidence']})" if c["evidence"] else "")}
                for c in found["check"]]}]})
        else:
            blocks.append({"t": "p", "muted": True, "v": "The kit is confident about every column of these tables."})
        if found["sensitive"]:
            blocks.append({"t": "p", "v": "Personal data, never charted, grouped or sent to a model: "
                           + ", ".join(f"{c['table'].split('.', 1)[1]}.{c['column']}" for c in found["sensitive"]) + "."})
        blocks += [{"t": "p", "muted": True, "v": f"{found['fine']} other columns look fine. Each table's tab shows them all."},
                   {"t": "actions", "items": [{"id": "map_all_approve", "label": f"Approve all {len(todo)} tables", "primary": True,
                                               "busy": "Approving, then saving your data map once…"}]}]
        return blocks

    def on_map_all(self, _v: dict) -> None:
        """Draw up every chosen table's column map (the ones not read yet: nb.review_roles each), then say what to
        look at across them (nb.schema_review)."""
        current = str(SESSION.source.fact_table)
        kept = SESSION.get("role_reviews")
        if not isinstance(kept, dict):
            actions.run("map.reviews")
            actions.run("map.remember", table=current)
            kept = SESSION.get("role_reviews")
        failed = []
        with SESSION.showing_queries():
            for entry in SESSION.chosen:
                table = entry["table"]
                if table in kept:
                    continue
                print(f"Reading {table}: each column's type, how many values and how they spread")
                try:
                    actions.run("understand.switch", table=table)
                    actions.run("map.review_keep", table=table)
                except Exception as exc:
                    failed.append(f"{table} ({str(exc).splitlines()[0][:160] if str(exc) else type(exc).__name__})")
            actions.run("understand.switch", table=current)
        self.all_review = dict(actions.run("map.schema_review"))
        if failed:
            self.flash = {"kind": "warn", "v": "Not read, so not in this approval: " + "; ".join(failed)}

    def on_map_all_approve(self, v: dict) -> None:
        """Approve every table as drafted, with the columns changed here (nb.approve_all): one approval, and the
        semantic model updated once per source."""
        found = self.all_review or {}
        choices: dict[str, dict[str, str]] = {}
        for c in found.get("check") or []:
            picked = str(v.get(f"all:{c['table']}:{c['column']}") or "")
            if picked and picked != c["role"]:
                choices.setdefault(c["table"], {})[c["column"]] = picked
        current = str(SESSION.source.fact_table)
        try:
            actions.run("map.approve_all", choices=choices or None, table=current)
        except ValueError as exc:
            raise ValueError(_plain_kit_error(str(exc))) from exc
        self.kit_said = SESSION.said
        self.all_review = None
        self.__dict__.setdefault("seen", {}).clear()          # each table's first look is of its approved map now
        actions.run("map.reviews")                            # the drafts are approved maps now: read again when opened
        count = len(found.get("tables") or [])
        self._reload_saved()
        self.flash = {"kind": "ok", "v": f"Approved {count} tables. " + _publish_note(self.kit_said)}
        SESSION.changed_later("dataset", self)

    @staticmethod
    def _approved_tables() -> set[str]:
        try:
            return {a["table"].upper() for a in actions.run("kit.approved")}
        except Exception:
            return set()

    def _ai_block(self, rv) -> dict:
        """The AI, at the top of the card: one button has the model set up for the kit complete the draft - the
        meanings it would change (each with why), the other choices (the group to compare, who a row is about, the
        date, the text) and a description for every column. Its answer is filled into the card at once, where every
        field can still be changed and one Undo puts the kit's own draft back; nothing is saved until Approve. It
        never picks what to predict or what makes a row unique. Without a model: where to set one up."""
        try:
            model = actions.run("kit.model") or {}
        except Exception:
            model = {}
        labels = dict(ROLE_LABELS)
        items = fill = None
        if self.ai and "items" in self.ai:
            items = [{"column": i["column"], "to": i["role"], "from_label": labels.get(i["kit_role"], i["kit_role"]),
                      "to_label": labels.get(i["role"], i["role"]), "why": i["why"]} for i in self.ai["items"]]
            fill = {"id": self.ai["id"], "roles": {i["column"]: i["role"] for i in self.ai["items"]},
                    "slots": dict(self.ai.get("slots") or {}), "notes": dict(self.ai.get("notes") or {}),
                    "slot_labels": {slot: SLOT_LABELS[slot][0] for slot in (self.ai.get("slots") or {}) if slot in SLOT_LABELS}}
        sensitive = sum(1 for e in (rv.draft.doc.get("columns") or {}).values() if e.get("sensitive"))
        return {"t": "aicheck", "configured": bool(model.get("configured")), "model": model.get("model_id") or "",
                "items": items, "fill": fill, "error": (self.ai or {}).get("error") or "",
                "sees": "It is shown column names, types and what the kit measured. Never a row"
                        + (f", and not the {sensitive} personal-data column{'s' if sensitive != 1 else ''}." if sensitive else ".")}

    def on_ai_check(self, _v: dict) -> None:
        """Fill in with AI: nb.fill_column_map on this table's draft. The card fills its answer in; nothing is saved."""
        if SESSION.review is None:
            raise ValueError("Choose your data above first.")
        try:
            found = dict(actions.run("map.ai_check") or {})
            SESSION.ai_runs += 1
            self.ai = {"id": SESSION.ai_runs, "items": list(found.get("roles") or []), "slots": dict(found.get("slots") or {}),
                       "notes": dict(found.get("notes") or {})}
            SESSION.ai_maps[str(SESSION.source.fact_table)] = self.ai
        except ValueError:
            raise
        except Exception as exc:        # the provider refused, the network, an answer that is not JSON
            self.ai = {"error": (str(exc).splitlines() or [type(exc).__name__])[0][:300]}
        self.kit_said = SESSION.said or self.kit_said

    def _switch_to(self, table: str) -> None:
        entry = next((e for e in SESSION.chosen if e["table"] == table), None)
        if entry is None or (SESSION.source is not None and str(SESSION.source.fact_table) == table):
            return
        print(f"Opening {table}")
        actions.run("understand.switch", table=table)
        use_chosen(entry)
        kept = SESSION.get("role_reviews")
        if not (isinstance(kept, dict) and table in kept):
            print(f"Reading {table}: each column's type, how many values and how they spread")
        with SESSION.showing_queries():
            self._review(reuse=True)
        SESSION.changed("source", self)
        if SESSION.dataset is not None:        # an approved table: the steps under this card follow it
            SESSION.changed("dataset", self)

    def on_map_switch(self, v: dict) -> None:
        """Another of the chosen tables: its column map opens here (the cell: chosen_data = chosen_tables[...])."""
        self._switch_to(next((str(value) for key, value in v.items() if str(key).startswith("map_table_")), ""))

    def on_map_next(self, _v: dict) -> None:
        """On to the next chosen table that has no approved column map yet."""
        approved = self._approved_tables()
        left = [e["table"] for e in SESSION.chosen if e["table"].upper() not in approved]
        if left:
            self._switch_to(left[0])

    def _blocks(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Column roles",
                "sub": "The role of every column of each table you chose, as the kit read it from the data. Confirm the "
                       "prediction target, the columns it was unsure of and the column settings, then approve: every later "
                       "step works from the approved roles. You can change them later; each approval is a new version."}
        rv = SESSION.review
        if rv is None:
            return [head, {"t": "empty", "v": "Choose your data above first."}]
        draft = rv.draft
        cols = draft.doc.get("columns") or {}
        sugg, slots = self._baseline()
        rows = []
        measured = {}
        for h in _versions(draft.id)[0]:   # what the kit measured before someone overrode it ("set by you")
            for c, ev in h["evidence"].items():
                if ev and ev != "set by you" and c not in measured:
                    measured[c] = ev
        for c in rv.review_order():
            ev = str((cols.get(c) or {}).get("evidence") or "")
            raw = ev
            if ev == "set by you" and measured.get(c):
                raw = measured[c]
                ev = f"set by you · the kit measured: {raw}"
            e = cols.get(c) or {}
            rows.append({"column": c, "role": sugg.get(c, "other"), "evidence": ev,
                         "low": e.get("confidence") == "low", "sensitive": bool(e.get("sensitive")),
                         "leak": c in self.leaks, "avoid": _avoid(raw), "plain": bool(PLAIN_NAME.match(c)), "raw": raw,
                         "note": str(e.get("note") or "")})
        targets = []
        for c in sugg:
            if sugg[c] == "flag" or c == slots.get("target"):
                ev = str((cols.get(c) or {}).get("evidence") or "")
                targets.append({"value": c, "label": c, **target_verdict(ev), "leak": c in self.leaks})
        # A column different in (almost) every row is the natural unique ID, even when the kit called it a code.
        # The kit accepts a unique ID only when it is different in EVERY row. Suggest one only then;
        # a column that is unique except for repeated rows gets a note instead (the cleaned copy fixes that).
        key_suggest, key_near = None, None
        total = SESSION.source_rows or 0
        if not slots.get("key") and total:
            for r in rows:
                m = re.search(r"([\d,]+) distinct", r["raw"])
                if not m or r["role"] not in ("identifier", "key") or "postcode" in r["raw"]:
                    continue
                distinct = int(m.group(1).replace(",", ""))
                if distinct == total:
                    key_suggest = r["column"]
                    break
                if distinct >= 0.99 * total and key_near is None:
                    key_near = (r["column"], total - distinct)
        no_target_reason = None
        if not targets:
            no_target_reason = ("This data has no yes-or-no column, so there's nothing to predict yet. "
                                "That's fine: you can still explore it. If one column has exactly two values, "
                                "mark it as Yes or no under All columns and it appears here.")
        order = {"good": 0, "ok": 1, "rare": 2, "unknown": 3, "no": 4}
        targets.sort(key=lambda t: (order.get(t["verdict"], 5), t["value"]))
        other_slots = []
        for slot in ("category", "entity", "time", "key", "text"):
            label, hint = SLOT_LABELS[slot]
            reason = (draft.doc.get("slot_evidence") or {}).get(slot)
            other_slots.append({"id": slot, "label": label,
                                "hint": hint if slots.get(slot) or not reason else f"{hint} None found: {reason}.",
                                "value": slots.get(slot) or "", "roles": SLOT_ROLES[slot],
                                "required": SLOT_REQUIRED.get(slot), "required_label": ROLE_LABELS.get(SLOT_REQUIRED.get(slot, ""), ""),
                                "plain_names": slot != "key", "no_sensitive": slot in ("category", "entity", "text")})
        for x in other_slots:
            if x["id"] == "key" and key_suggest:
                x["suggest"] = key_suggest
            elif x["id"] == "key" and key_near:
                x["hint"] = (f"Used to spot repeated rows. {key_near[0]} would be unique, but {key_near[1]:,} rows repeat it. "
                             "Leave this empty for now: the cleaned copy in step 2 removes the repeats.")
        broken_now = bool(getattr(SESSION, "broken", None))
        approved = draft.status == "approved" and not broken_now
        blocks = [head]
        broken = getattr(SESSION, "broken", None)
        if broken and broken.get("id") == draft.id:
            blocks.append({"t": "msg", "kind": "error",
                           "v": f"The saved column map can't be used: {_plain_reason(broken['reason'])} "
                                "Fix it below, or go back to the earlier version."})
        blocks += self._version_blocks(approved or bool(broken))
        if self.leaks:
            blocks.append({"t": "msg", "kind": "warn",
                           "v": f"{', '.join(self.leaks)} gives the answer away: it's filled in after the outcome. "
                                "The prediction step leaves it out automatically."})
        blocks += [
            {"t": "rolemap", "roles": [{"value": k, "label": v, "meaning": ROLE_MEANING[k]} for k, v in ROLE_LABELS.items()],
             "rows": rows, "targets": targets, "target": slots.get("target") or "", "slots": other_slots,
             "no_target_reason": no_target_reason,
             "approved": approved},
            {"t": "actions", "items": [{"id": "approve", "label": "Approve column map", "primary": True, "busy": "Saving…",
                                        "changed_label": "Approve changes",
                                        "unchanged_label": "Keep these choices" if approved else "Approve column map"}]},
        ]
        if self.first:
            blocks += self._first_blocks()
        if self.kit_said:
            blocks.append({"t": "details", "title": "What the kit said", "blocks": [{"t": "pre", "v": self.kit_said}]})
        if SESSION.code:
            blocks.append({"t": "code", "code_only": True, "title": "The kit calls behind this step", "v": "\n".join(SESSION.code)})
        return blocks

    def _baseline(self) -> tuple[dict, dict]:
        """What the screen starts from: the latest approved version's choices when there is one
        (so the screen always shows what was saved), else the kit's proposal."""
        rv = SESSION.review
        sugg, slots = dict(rv.suggestions()), dict(rv.slot_suggestions())
        if SESSION.broken:
            return sugg, slots
        ds = SESSION.dataset
        if ds is not None and getattr(ds, "status", "") == "approved":
            # What the kit will really use: the descriptor it opened (beside the file wins over the store).
            for c, e in (getattr(ds.descriptor, "columns", {}) or {}).items():
                if c in sugg and e.get("role"):
                    sugg[c] = e["role"]
            for k in ("key", "time", "text", "target", "category", "entity"):
                v = (getattr(ds.descriptor, "slots", {}) or {}).get(k)
                slots[k] = (v[0] if isinstance(v, list) else v) or None
            return sugg, slots
        hist, number = _versions(rv.draft.id)
        cur = next((h for h in hist if h["version"] == number), None)
        if cur:
            for c, r in cur["roles"].items():
                if c in sugg and r:
                    sugg[c] = r
            for k in ("key", "time", "text", "target", "category", "entity"):
                slots[k] = cur["slots"].get(k) or None
        return sugg, slots

    def _version_blocks(self, show: bool) -> list[dict]:
        if not show or SESSION.review is None:
            return []
        ds_id = SESSION.dataset.id if SESSION.dataset is not None else SESSION.review.draft.id
        hist, number = _versions(ds_id)
        if SESSION.dataset is not None:
            number = SESSION.dataset.version
        cur = next((h for h in hist if h["version"] == number), None)
        if cur is None:
            return []
        when = f" (saved {_ago(cur['approved_at'])})" if cur.get("approved_at") else ""
        block = {"t": "version", "v": f"You're on version {number}{when}.",
                 "about": "Each time you approve a change, the kit saves a new version. The next steps always use the newest one. "
                          "Nothing is ever deleted: restoring an older version saves its choices as a new version.",
                 "changes": [], "history": []}
        prev = None
        for h in hist:
            lines = _diff(prev, h) if prev else ["First approval."]
            block["history"].append({"version": h["version"], "when": _ago(h.get("approved_at")), "text": "; ".join(lines) or "No change."})
            prev = h
        block["history"].reverse()
        older = [h["version"] for h in hist if h["version"] != number]
        if older:
            block["restore"] = {"id": "restore", "options": [{"value": str(v), "label": f"Version {v}"} for v in reversed(older)],
                                "value": str(older[-1])}
        return [block]

    def _first_blocks(self) -> list[dict]:
        f = self.first
        out = [{"t": "divider"}, {"t": "subhead", "v": "A first look"}]
        if f.get("error"):
            return out + [{"t": "msg", "kind": "warn", "v": f["error"]}]
        if f.get("missing"):
            out.append({"t": "p", "muted": True, "v": " ".join(f["missing"])})
        out.append({"t": "bars", "title": f["title"], "items": f["items"], "pct": f["pct"], "overall": f.get("overall"),
                    "note": "Dashed line: overall rate. Highlighted bars are above it." if f["pct"] else ""})
        if f.get("note"):
            out.append({"t": "note", "v": f["note"]})
        return out              # the way on to the next notebook is at the bottom of the notebook (Semantic views)

    # -- approving ------------------------------------------------------------------------
    def _check(self, roles: dict, slots: dict) -> None:
        """Stop choices the kit can't work with, in plain words, before anything is saved."""
        cols = SESSION.review.draft.doc.get("columns") or {}
        target = slots.get("target")
        if target:
            if roles.get(target) != "flag":
                raise ValueError(f"{target} is what you want to predict, so it must be a Yes or no column.")
            verdict = target_verdict(str((cols.get(target) or {}).get("evidence") or ""))
            if verdict["verdict"] == "no":
                raise ValueError(f"{target} can't be predicted: it {verdict['text'][0].lower()}{verdict['text'][1:]} "
                                 "Pick a column with 0 and 1, or Nothing, just explore.")
        seen: dict[str, str] = {}
        for slot, col in slots.items():
            if not col:
                continue
            label = "What to predict" if slot == "target" else SLOT_LABELS[slot][0]
            if col in seen:
                raise ValueError(f"{col} is used for both “{seen[col]}” and “{label}”. A column can fill only one of these.")
            seen[col] = label
            need = SLOT_REQUIRED.get(slot)
            if need and roles.get(col) != need:
                raise ValueError(f"“{label}” must be a column marked {ROLE_LABELS[need]}, and {col} is marked "
                                 f"{ROLE_LABELS.get(roles.get(col), roles.get(col))}. Pick another column, or leave it empty.")
            if (cols.get(col) or {}).get("sensitive") and slot in ("target", "category", "entity", "text"):
                raise ValueError(f"{col} holds personal data, so it can't be used as “{label}”.")
            if slot != "key" and not PLAIN_NAME.match(col):
                raise ValueError(f"{col} has spaces or symbols in its name, so it can't be used as “{label}” yet.")

    def on_approve(self, v: dict) -> None:
        rv = SESSION.review
        if rv is None:
            raise ValueError("Choose your data above first.")
        rv.conn = SESSION.connection()   # the review keeps a connection; give it a live one
        roles = dict(v.get("roles") or {})
        slots = {k: (val or None) for k, val in (v.get("slots") or {}).items()}
        base_roles, base_slots = self._baseline()
        sugg, drafted = base_roles, base_slots
        role_changes = {c: r for c, r in roles.items() if r != base_roles.get(c)}
        slot_changes = {s: c for s, c in slots.items() if c != base_slots.get(s)}
        # A column's description, as typed or as the AI wrote it: only the ones that differ from what is saved.
        saved = rv.draft.doc.get("columns") or {}
        note_changes = {c: " ".join(str(t or "").split()) for c, t in (v.get("notes") or {}).items()
                        if c in saved and " ".join(str(t or "").split()) != str((saved.get(c) or {}).get("note") or "").strip()}
        if rv.draft.status == "approved" and not role_changes and not slot_changes and not note_changes and not SESSION.broken:
            actions.run("map.keep")
            self.flash = {"kind": "ok", "v": f"Kept the approved choices (version {SESSION.dataset.version})."}
        else:
            self._check({**sugg, **roles}, {**drafted, **slots})
            kit_sugg = rv.suggestions()
            self._save({c: r for c, r in {**sugg, **roles}.items() if r != kit_sugg.get(c)} or None, {**drafted, **slots},
                       note_changes or None)
            self.flash = {"kind": "ok", "v": f"Approved. Saved as version {SESSION.dataset.version}; the next steps use it. "
                                             + _publish_note(self.kit_said)}
            t = slots.get("target")
            if t:
                verdict = target_verdict(str(((rv.draft.doc.get("columns") or {}).get(t) or {}).get("evidence") or ""))
                if verdict["verdict"] == "rare":
                    self.flash = {"kind": "warn", "v": f"Approved as version {SESSION.dataset.version}. Note: {t}: {verdict['text']}"}
        flash = self.flash
        self._reload_saved()
        self.flash = flash
        # the cards below (checks, groups, the model) follow in the background: saving is done when it is saved
        SESSION.changed_later("dataset", self)

    def _save(self, choices: dict | None, slots: dict, notes: dict | None = None) -> None:
        try:
            actions.run("map.approve", choices=choices, slots=slots, notes=notes)
        except ValueError as exc:
            raise ValueError(_plain_kit_error(str(exc))) from exc
        self.kit_said = SESSION.said      # this approval's own lines: _publish_note reads them

    def on_restore(self, v: dict) -> None:
        ds_id = SESSION.dataset.id if SESSION.dataset is not None else SESSION.review.draft.id
        want = int(v.get("restore_to") or 0)
        target = next((h for h in _versions(ds_id)[0] if h["version"] == want), None)
        if target is None:
            raise ValueError("Pick a version to restore.")
        self._restore(target)

    def _restore(self, old: dict) -> None:
        SESSION.review.conn = SESSION.connection()
        kit_sugg = SESSION.review.suggestions()
        choices = {c: r for c, r in old["roles"].items() if c in kit_sugg and r and r != kit_sugg[c]}
        slots = {k: (old["slots"].get(k) or None) for k in ("key", "time", "text", "target", "category", "entity")}
        self._save(choices or None, slots)
        new_version = SESSION.dataset.version
        SESSION.broken = None
        self._reload_saved()
        self.flash = {"kind": "ok", "v": f"Restored version {old['version']}'s choices. Saved as version {new_version}."}
        SESSION.changed("dataset", self)

    def _reload_saved(self) -> None:
        """Show exactly what was saved: re-read the kit's proposal for the new version, then the first look."""
        self._review()
        if SESSION.dataset is not None and not self.first:
            self._first_result_safe()
            if SESSION.source is not None:
                self.__dict__.setdefault("seen", {})[str(SESSION.source.fact_table)] = (self.leaks, self.first)

    def _first_result_safe(self) -> None:
        try:
            self._first_result()
        except Exception as exc:
            import traceback

            from ..card import _logger

            _logger().error("first look failed: %r\n%s", exc, traceback.format_exc())
            lines = [l for l in str(exc).splitlines() if l.strip()]
            why = lines[0][:200] if lines else exc.__class__.__name__
            self.first = {"error": f"The first look couldn't be drawn with these choices ({why}). The details are in the guided-view log."}

    def _first_result(self) -> None:
        """The quickstart's first result: rows per group, with the outcome's rate when there is one."""
        import exakit.nb as nb
        from exakit_nb.readout import SMALL

        from ..actions import Var

        ds = SESSION.dataset
        missing = {m["role"]: m["reason"] for m in ds.missing}
        group_role, group_col = ds.group_by()
        has_label = ds.has("label") and group_role != "label"
        group_h, count_h = nb.name(group_col), nb.count_name(ds)
        pct_h = nb.name(ds.col("label"), "PCT") if has_label else None
        rate_sql = f",\n       ROUND(100 * AVG({ds.col('label')}), 1) AS {pct_h}" if pct_h else ""
        sql = (f"SELECT {group_col} AS {group_h},\n       COUNT(*) AS {count_h}{rate_sql}\n"
               f"FROM {ds.fact_table}\nGROUP BY {group_col}\nORDER BY {count_h} DESC\nLIMIT 10")
        frame = actions.run("map.first_result", sql=sql)
        overall = (actions.run("map.first_overall", sql=f"SELECT COUNT(*) AS N, ROUND(100 * AVG({ds.col('label')}), 1) AS PCT FROM {ds.fact_table}")
                   if pct_h else None)
        note = actions.run("map.first_note", group=group_h, count=count_h, pct=pct_h,
                           overall=Var('(first_overall["N"][0], first_overall["PCT"][0])') if pct_h else None)
        label_name = (ds.col("label") or "").strip('"').split(".")[-1] if has_label else ""
        if pct_h:
            items = [{"label": "(no value)" if r[group_h] is None else str(r[group_h]), "value": float(r[pct_h] or 0) / 100, "rows": int(r[count_h])}
                     for _, r in frame.iterrows() if int(r[count_h]) >= SMALL]   # the kit's rule: below SMALL rows a % isn't trustworthy
            items.sort(key=lambda i: -i["value"])
            title = f"{label_name} rate by {group_h}"
        else:
            items = [{"label": "(no value)" if r[group_h] is None else str(r[group_h]), "value": int(r[count_h]), "rows": int(r[count_h])} for _, r in frame.iterrows()]
            title = f"{count_h.replace('_', ' ').capitalize()} by {group_h}"
        notes = []
        if group_role != "category":
            notes.append(f"No group column was chosen ({missing.get('category', 'none approved')}), so rows are counted per {group_role}.")
        if "label" in missing:
            notes.append(f"Nothing to predict was chosen ({missing['label']}), so rates are left out.")
        self.first = {"title": title, "items": items, "pct": bool(pct_h),
                      "overall": float(overall["PCT"][0]) / 100 if pct_h else None, "note": note, "missing": notes}


class DataMap(Screen):
    """Every table in the database by origin - external source, your data, sample data - with its column map's state
    and the roles in it (nb.data_map, metadata only). Redrawn when data is chosen or a column map approved, so an
    approval shows up here as "approved vN, in semantic model ..."."""
    help = (('Read the data map', 'get-the-data/the-data-map'),)

    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.rows: list[list] = []
        self.links: list[list] = []
        self.loading, self.error = True, None
        SESSION.listen(self)
        self.refresh()
        import threading

        threading.Thread(target=self._load, daemon=True).start()

    def _load(self) -> None:
        try:
            found = actions.run("data.map")
            self.rows = [[r["origin_label"], r["table"], r["rows_shown"], r["columns"], r["map"], r["summary"]]
                         for r in found.table_rows]
            self.links = [[f"{k['from_table']}.{k['from_column']}", f"{k['to_table']}.{k['to_column']}", k["kind"],
                           k["origins"]] for k in found.link_rows]
            self.error = None
        except Exception as exc:
            self.error = str(exc).splitlines()[0] if str(exc) else type(exc).__name__
        self.loading = False
        self.refresh()
        SESSION.release()

    def build(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Your data map",
                "sub": "Every table, by where it comes from, with its column map and the roles in it."}
        if self.loading:
            return [head, {"t": "empty", "v": "Reading the database's tables…"}]
        if self.error:
            return [head, {"t": "msg", "kind": "warn", "v": f"The map could not be read: {self.error}"},
                    {"t": "actions", "items": [{"id": "reload", "label": "Read it again"}]}]
        blocks = [head, {"t": "table", "wrap_first": True,
                         "columns": ["Origin", "Table", "Rows", "Columns", "Column map", "Roles"], "rows": self.rows}]
        if self.links:
            blocks += [{"t": "subhead", "v": "Columns that link tables"},
                       {"t": "p", "muted": True, "v": "A possible link only shares a column name: check it before joining the tables."},
                       {"t": "table", "columns": ["From", "To", "Kind", "Origins"], "rows": self.links}]
        blocks.append({"t": "actions", "items": [{"id": "reload", "label": "Read it again"}]})
        blocks.append({"t": "code", "code_only": True, "title": "The code behind this card", "v": actions.code("data.map")})
        return blocks

    def on_reload(self, _v: dict) -> None:
        self.loading = True
        self._load()

    def on_session(self, what: str) -> None:
        if what in ("source", "dataset", "data"):
            import threading

            self.loading = True
            self.refresh()
            threading.Thread(target=self._load, daemon=True).start()


def json_key(found: dict | None) -> tuple | None:
    """A dict as something the picks can be compared by (the check and the apply must be of the same document)."""
    return tuple(sorted(found.items())) if found else None


class SemanticViews(Screen):
    """Your data map, filled in by you: exactly what Exasol Semantic Views needs, nothing worked out behind your back.

    1. The tables: what one row of each is (its grain) and what it is, from its approved column map; you change them.
    2. How they connect: this column points at that table's key, many-to-one or one-to-one. You add each link; the
       one AI button above suggests them from names, never from rows. Check with data runs one bounded count per
       link, only when you press it.
    3. Where questions start: the tables questions begin from (each becomes a semantic view).
    4. Metrics: the plain totals come from the column maps; your own add a condition ("only completed orders").
    5. Rules for AI tools, in your words ("revenue excludes tax").
    Save hands all of it to Semantic Views, which checks it and says what is wrong, word for word. The card opens
    from this computer only (the approved column maps and what you saved before): no query while it loads. Every
    button is a cell of the quickstart (actions: semantic.*)."""
    help = (('Your data map', 'explore/semantic-views#one-model-across-sources'),
            ('Links and their type', 'explore/semantic-views#links-across-sources'),)

    kind = "card"
    HOW = (("sum", "Sum of a column"), ("count", "Number of rows"), ("average", "Average of a column"))

    def __init__(self) -> None:
        super().__init__()
        self.n = 0                                  # a new form: the fields start from what the card holds now
        self.facts: dict = {"tables": {}, "missing": []}
        self.dm: dict = self._empty()
        self.checked: dict[str, str] = {}           # "FROM=TO" -> what Check with data found
        self.result_text, self.warnings, self.preview_text = "", [], ""
        self.saved, self.loading, self.error = False, True, None
        SESSION.listen(self)
        self._load()

    n, saved, loading, error, result_text, preview_text = 0, False, True, None, "", ""
    facts: dict = {"tables": {}, "missing": []}
    dm: dict = {}
    checked: dict = {}
    warnings: list = []
    fusion_doc = fusion_said = None
    fusion_for: tuple = ()
    report: dict | None = None           # what Semantic Views found wrong (nb.validate_data_map), after a save or a check
    versions: list | None = None         # the saved versions, from the model (nb.data_map_versions), when asked for
    more: dict = {}                      # what the More from Semantic Views buttons read: suggestions, totals, frozen views, log

    @staticmethod
    def _empty() -> dict:
        return {"grains": {}, "table_notes": {}, "links": [], "starts": [], "metrics": [], "instructions": [], "description": "",
                "hidden": {}, "synonyms": {}}

    @staticmethod
    def _chosen_tables() -> list[str]:
        return [e["table"].upper() for e in SESSION.chosen]

    # -- what the card holds ----------------------------------------------------------------------------------------
    def _load(self) -> None:
        """The approved column maps of the chosen tables and what was saved before: files on this computer."""
        try:
            found = actions.run("semantic.inputs", tables=self._chosen_tables())
            self.facts = {"tables": dict(found.get("tables") or {}), "missing": list(found.get("missing") or [])}
            self.dm = {k: found.get(k) if found.get(k) is not None else v for k, v in self._empty().items()}
            self.dm["links"] = [dict(l) for l in self.dm["links"]]
            self.saved, self.error = bool(found.get("saved")), None
        except Exception as exc:
            self.error = str(exc).splitlines()[0] if str(exc) else type(exc).__name__
        self.loading, self.n = False, self.n + 1
        self.refresh()

    @property
    def tables(self) -> list[dict]:
        """The chosen tables as the fusion section lists them: {table, approved}."""
        return [{"table": t, "approved": t in self.facts["tables"]} for t in self._chosen_tables()]

    @property
    def columns(self) -> dict[str, list[str]]:
        return {t: [c["name"] for c in f["columns"]] for t, f in self.facts["tables"].items()}

    @property
    def models(self) -> list[dict]:
        return [{"model": "all_data", "refreshable": True, "kit": True}] if self.saved else []

    @property
    def links(self) -> list[dict]:
        return self.dm.get("links") or []

    def _id(self, kind: str, key: str = "") -> str:
        return f"dm{kind}{self.n}:{key}"

    def _of_role(self, table: str, roles: tuple) -> list[dict]:
        return [c for c in (self.facts["tables"].get(table) or {}).get("columns") or [] if c["role"] in roles]

    def _collected(self, v: dict) -> dict:
        """The data map as the form says it now: what is ticked, typed and picked. A field the form did not send is
        as the card holds it."""
        tables = list(self.facts["tables"])
        has = lambda kind, key="": self._id(kind, key) in v
        text = lambda kind, key="": " ".join(str(v.get(self._id(kind, key)) or "").split())
        dm: dict = {"tables": tables}
        dm["description"] = (text("about") if has("about") else self.dm.get("description") or "") or None
        for kind, name in (("grain", "grains"), ("note", "table_notes")):
            dm[name] = {t: (text(kind, t) if has(kind, t) else (self.dm.get(name) or {}).get(t, "")) for t in tables}
            dm[name] = {t: x for t, x in dm[name].items() if x}
        kept = {str(x) for x in v.get(self._id("links")) or []} if has("links") else {str(i) for i in range(len(self.links))}
        dm["links"] = [{"from": l["from"], "to": l["to"],
                        "type": str(v.get(self._id("ltype", str(i))) or l.get("type") or "MANY_TO_ONE"),
                        "join": str(v.get(self._id("ljoin", str(i))) or l.get("join") or "LEFT"),
                        "fanout": (str(v.get(self._id("lfan", str(i)))) if has("lfan", str(i)) else l.get("fanout")) or None,
                        "note": text("lnote", str(i)) if has("lnote", str(i)) else l.get("note") or "", "by": l.get("by") or "you"}
                       for i, l in enumerate(self.links) if str(i) in kept]
        starts = [str(t) for t in v.get(self._id("starts")) or []] if has("starts") else list(self.dm.get("starts") or [])
        dm["starts"] = [t for t in starts if t in tables]
        metrics = list(self.dm.get("metrics") or [])
        kept = {str(x) for x in v.get(self._id("metrics")) or []} if has("metrics") else {str(i) for i in range(len(metrics))}
        dm["metrics"] = [m for i, m in enumerate(metrics) if str(i) in kept]
        dm["hidden"] = {t: ([str(c) for c in v.get(self._id("hide", t)) or []] if has("hide", t) else list((self.dm.get("hidden") or {}).get(t) or []))
                         for t in tables}
        dm["hidden"] = {t: c for t, c in dm["hidden"].items() if c}
        words = dict(self.dm.get("synonyms") or {})
        kept_words = {str(x) for x in v.get(self._id("syn")) or []} if has("syn") else set(words)
        dm["synonyms"] = {f: w for f, w in words.items() if f in kept_words}
        rules = list(self.dm.get("instructions") or [])
        typed = [text("rule", str(i)) if has("rule", str(i)) else (rules[i] if i < len(rules) else "") for i in range(len(rules) + 1)]
        dm["instructions"] = [r for r in typed if r]
        return dm

    def _keep(self, v: dict) -> None:
        """What was typed stays when the form is drawn again (a link or metric added, an AI suggestion merged)."""
        if self.loading or not self.facts["tables"]:
            return
        now = self._collected(v)
        self.dm.update({k: now[k] for k in ("grains", "table_notes", "links", "starts", "metrics", "instructions", "hidden", "synonyms")})
        self.dm["description"] = now["description"] or ""

    # -- the form ---------------------------------------------------------------------------------------------------
    def build(self) -> list[dict]:
        blocks: list[dict] = [{"t": "head", "kicker": KICKER, "title": "Semantic model",
                               "sub": "How your approved tables become one model in Exasol Semantic Views: the grain of each "
                                      "table, the relationships between them, the entry points questions start from, your "
                                      "metrics and your business rules. Save hands it to Semantic Views, which validates it."}]
        if self.loading:
            return blocks + [{"t": "empty", "v": "Reading your column roles…"}]
        if self.error:
            return blocks + [{"t": "msg", "kind": "warn", "v": f"Your column roles could not be read: {self.error}"},
                             {"t": "actions", "items": [{"id": "sv_reload", "label": "Read them again"}]}]
        tables = list(self.facts["tables"])
        if self.facts["missing"]:
            blocks.append({"t": "msg", "kind": "info", "v": "Approve the column roles of " + ", ".join(self.facts["missing"])
                                                              + " above, and the table joins the model."})
        if not tables:
            return blocks
        # 1 · Tables
        rows = []
        for t in tables:
            key = ", ".join((self.facts["tables"][t].get("key") or [])) or "no key"
            rows.append({"id": self._id("t", t), "type": "group", "cols": 2, "fields": [
                {"id": self._id("th", t), "type": "heading", "v": f"{t}  ·  key {key}"},
                {"id": self._id("grain", t), "type": "text", "label": "Grain (one row is)",
                 "value": self.dm["grains"].get(t) or self.facts["tables"][t].get("grain") or "", "placeholder": "one order line"},
                {"id": self._id("note", t), "type": "text", "label": "Description (optional)",
                 "value": self.dm["table_notes"].get(t) or "", "placeholder": "Every order line of the online shop"}]})
        blocks += [{"t": "subhead", "v": "1 · Tables", "tip": "The grain says what one row of a table is. Semantic Views uses "
                    "it so an amount is never counted once per row of another table. The key comes from the column roles."},
                   {"t": "fields", "items": rows}]
        # 2 · Relationships
        blocks.append({"t": "subhead", "v": "2 · Relationships", "tip": "A relationship says: this column holds the key of "
                       "that table. Many-to-one: many rows here, one there (order lines to orders). One-to-one: each value once "
                       "on both sides. Nothing is guessed: add the ones you know, or take the AI's suggestions above."})
        if self.links:
            labels = {"you": "added by you", "ai": "suggested by AI", "values": "found from the values"}
            blocks.append({"t": "fields", "items": [{"id": self._id("links"), "type": "picks", "label": "Relationships (untick to remove)",
                           "value": [str(i) for i in range(len(self.links))],
                           "options": [{"value": str(i), "label": f"{l['from']} → {l['to']}",
                                        "hint": " · ".join(x for x in (labels.get(l.get("by") or "you", "added by you"),
                                                                       self.checked.get(f"{l['from']}={l['to']}")) if x)}
                                       for i, l in enumerate(self.links)]}]})
            blocks.append({"t": "fields", "items": [{"id": self._id("l", str(i)), "type": "group", "cols": 2, "fields": [
                {"id": self._id("lh", str(i)), "type": "heading", "v": f"{l['from']} → {l['to']}"},
                {"id": self._id("ltype", str(i)), "type": "select", "label": "Cardinality", "value": l.get("type") or "MANY_TO_ONE",
                 "options": [{"value": "MANY_TO_ONE", "label": "Many-to-one"}, {"value": "ONE_TO_ONE", "label": "One-to-one"}]},
                {"id": self._id("ljoin", str(i)), "type": "select", "label": "Unmatched rows", "value": l.get("join") or "LEFT",
                 "options": [{"value": "LEFT", "label": "Keep (left join)"}, {"value": "INNER", "label": "Exclude (inner join)"}]},
                {"id": self._id("lfan", str(i)), "type": "select", "label": "Fan-out", "value": l.get("fanout") or "",
                 "options": [{"value": "", "label": "Refuse double counting (default)"}, {"value": "ALLOCATE", "label": "Allocate"},
                             {"value": "DEDUPLICATE", "label": "Deduplicate"}, {"value": "REFERENCE_ONLY", "label": "Reference only"}]},
                {"id": self._id("lnote", str(i)), "type": "text", "label": "Note (optional)",
                 "value": l.get("note") or "", "placeholder": "The order each line belongs to"}]}
                for i, l in enumerate(self.links)]})
        else:
            blocks.append({"t": "p", "muted": True, "v": "No relationships yet." + ("" if len(tables) > 1 else
                                                                                    " Choose a second table above to relate it.")})
        if len(tables) > 1:
            options = [{"value": t, "label": t} for t in tables]
            every = {t: [{"value": c["name"], "label": c["name"]} for c in self.facts["tables"][t]["columns"]] for t in tables}
            keys = {t: [{"value": c["name"], "label": c["name"] + (" (key)" if c["name"] in (self.facts["tables"][t].get("key") or []) else "")}
                        for c in sorted(self.facts["tables"][t]["columns"], key=lambda c: c["name"] not in (self.facts["tables"][t].get("key") or []))]
                    for t in tables}
            blocks += [{"t": "fields", "items": [{"id": "dm_new_link", "type": "group", "cols": 2, "fields": [
                           {"id": "dm_new_link_h", "type": "heading", "v": "Add a relationship"},
                           {"id": "dm_from_table", "type": "select", "label": "From table", "value": tables[0], "options": options},
                           {"id": "dm_from_col", "type": "select", "label": "Column", "options_from": {"field": "dm_from_table", "map": every}},
                           {"id": "dm_to_table", "type": "select", "label": "To table", "value": tables[1], "options": options},
                           {"id": "dm_to_col", "type": "select", "label": "Key", "options_from": {"field": "dm_to_table", "map": keys}},
                           {"id": "dm_link_type", "type": "select", "label": "Cardinality", "value": "MANY_TO_ONE",
                            "options": [{"value": "MANY_TO_ONE", "label": "Many-to-one"}, {"value": "ONE_TO_ONE", "label": "One-to-one"}]}]}]},
                       {"t": "actions", "items": [{"id": "dm_add_link", "label": "Add the relationship"}]
                        + ([{"id": "dm_check", "label": "Check with data", "busy": "Counting…",
                             "tip": "One bounded count per relationship: how many of its values are found in the key. Optional."}]
                           if self.links else [])}]
        # 3 · Entry points
        blocks += [{"t": "subhead", "v": "3 · Entry points", "tip": "Each ticked table becomes a semantic view: a question "
                    "starts there and reaches the related tables. Leave it empty to use the tables with an amount."},
                   {"t": "fields", "items": [{"id": self._id("starts"), "type": "picks", "label": "Questions start from",
                                              "value": list(self.dm.get("starts") or []), "options": [{"value": t, "label": t} for t in tables]}]}]
        # 4 · Metrics
        blocks.append({"t": "subhead", "v": "4 · Metrics", "tip": "Every table already has its row count and the total and "
                       "average of each amount column. Add the ones your business defines, with a condition where one fits: "
                       "completed revenue = sum of AMOUNT where STATUS is COMPLETED."})
        if self.dm.get("metrics"):
            blocks.append({"t": "fields", "items": [{"id": self._id("metrics"), "type": "picks", "label": "Your metrics (untick to remove)",
                           "value": [str(i) for i in range(len(self.dm["metrics"]))],
                           "options": [{"value": str(i), "label": m["name"], "hint": self._said(m)} for i, m in enumerate(self.dm["metrics"])]}]})
        options = [{"value": t, "label": t} for t in tables]
        amounts = {t: [{"value": c["name"], "label": c["name"]} for c in self._of_role(t, ("measure",))] for t in tables}
        groups = {t: [{"value": "", "label": "Every row"}] + [{"value": c["name"], "label": c["name"]}
                                                             for c in self._of_role(t, ("category", "flag", "time", "identifier", "key"))] for t in tables}
        known = "; ".join(f"{c['name']}: {', '.join(c['values'][:6])}" for t in tables for c in self._of_role(t, ("category", "flag")) if c.get("values"))
        blocks += [{"t": "fields", "items": [{"id": "dm_new_metric", "type": "group", "cols": 2, "fields": [
                       {"id": "dm_new_metric_h", "type": "heading", "v": "Add a metric"},
                       {"id": "dm_m_table", "type": "select", "label": "Table", "value": tables[0], "options": options},
                       {"id": "dm_m_name", "type": "text", "label": "Name", "placeholder": "completed_revenue"},
                       {"id": "dm_m_how", "type": "select", "label": "Aggregation", "value": "sum", "options": [{"value": k, "label": l} for k, l in self.HOW]},
                       {"id": "dm_m_column", "type": "select", "label": "Column",
                        "options_from": {"field": "dm_m_table", "map": amounts}, "empty": "This table has no amount column: use Number of rows."},
                       {"id": "dm_m_where", "type": "select", "label": "Filter column", "options_from": {"field": "dm_m_table", "map": groups}},
                       {"id": "dm_m_values", "type": "text", "label": "Filter values (comma-separated)", "placeholder": known[:120] or "COMPLETED"},
                       {"id": "dm_m_about", "type": "text", "label": "Description (optional)", "wide": True,
                        "placeholder": "Revenue of completed orders, tax included"}]}]},
                   {"t": "actions", "items": [{"id": "dm_add_metric", "label": "Add the metric"}]}]
        # 5 · Business rules
        rules = list(self.dm.get("instructions") or []) + [""]
        blocks += [{"t": "subhead", "v": "5 · Business rules", "tip": "What anyone asking your data must know, one sentence "
                    "each. AI tools read them with the fields."},
                   {"t": "fields", "items": [{"id": self._id("rule", str(i)), "type": "text", "wide": True,
                                              "label": f"Rule {i + 1}" if text else "New rule (optional)", "value": text,
                                              "placeholder": "Revenue excludes tax and refunds"} for i, text in enumerate(rules)]
                    + [{"id": self._id("about"), "type": "text", "wide": True, "label": "Model description (optional)",
                        "value": self.dm.get("description") or "", "placeholder": "Orders, their customers and deliveries"}]},
                   {"t": "actions", "items": [{"id": "sv_publish", "label": "Save the semantic model", "primary": True,
                                               "busy": "Saving and validating…"},
                                              {"id": "sv_preview", "label": "Show the statements", "busy": "Building…"}]
                    + ([{"id": "dm_validate", "label": "Validate", "busy": "Semantic Views is validating…",
                         "tip": "Semantic Views validates the model again and lists every problem in its own words."}] if self.saved else [])}]
        if self.result_text:
            blocks.append({"t": "msg", "kind": "ok", "keep": True, "v": self.result_text})
        if self.warnings:
            blocks.append({"t": "msg", "kind": "warn", "keep": True, "v": "Semantic Views said: " + " · ".join(self.warnings)})
        blocks += self._report_blocks()
        if self.preview_text:
            blocks.append({"t": "details", "title": "The statements saving runs", "blocks": [{"t": "pre", "v": self.preview_text}]})
        blocks.append({"t": "details", "title": "Advanced", "blocks": self._advanced_blocks(tables)})
        blocks.append({"t": "code", "code_only": True, "title": "The code behind this card",
                       "v": actions.code("semantic.save_map", **self._save_args(self.dm, preview=False))})
        return blocks

    def _advanced_blocks(self, tables: list[str]) -> list[dict]:
        """What most models do without: hidden columns, synonyms, the same data in two sources, versions and the rest
        of Semantic Views - one closed section."""
        found: list[dict] = []
        hide = [{"id": self._id("hide", t), "type": "picks", "label": t, "value": list((self.dm.get("hidden") or {}).get(t) or []),
                 "options": [{"value": c["name"], "label": c["name"]} for c in self._of_role(t, ("category", "identifier", "key", "flag", "time"))]}
                for t in tables if self._of_role(t, ("category", "identifier", "key", "flag", "time"))]
        if hide:
            found += [{"t": "subhead", "v": "Hidden columns", "tip": "Never shown in an answer, still usable in a filter "
                       "(Semantic Views' MASK policy). A column the column roles mark as personal data is not in the model at all."},
                      {"t": "fields", "items": hide}]
        words = self.dm.get("synonyms") or {}
        found.append({"t": "subhead", "v": "Synonyms", "tip": "Other words people use for a field. Search and AI tools find "
                      "the field by them too."})
        if words:
            found.append({"t": "fields", "items": [{"id": self._id("syn"), "type": "picks", "label": "Synonyms (untick to remove)",
                          "value": list(words), "options": [{"value": f, "label": f, "hint": ", ".join(w)} for f, w in words.items()]}]})
        found += [{"t": "fields", "items": [{"id": "dm_synonyms", "type": "group", "cols": 2, "fields": [
                      {"id": "dm_syn_field", "type": "text", "label": "Field", "placeholder": "total_amount"},
                      {"id": "dm_syn_words", "type": "text", "label": "Synonyms (comma-separated)", "placeholder": "sales, revenue, turnover"}]}]},
                  {"t": "actions", "items": [{"id": "dm_add_words", "label": "Add the synonyms"}]}]
        fusion = self._fusion_blocks()
        if fusion:
            found += [{"t": "subhead", "v": "The same data in two sources"}] + fusion[1:]
        if self.saved:
            found += [{"t": "subhead", "v": "Versions", "tip": "Every save that changed something is a version, kept in the "
                       "model itself. Saving an older one again makes it the newest."},
                      {"t": "actions", "items": [{"id": "dm_versions", "label": "Show the versions", "busy": "Reading…"}]}]
            found += self._version_blocks()
            found += [{"t": "subhead", "v": "More from Semantic Views"}] + self._more_blocks()
        return found

    def _report_blocks(self) -> list[dict]:
        """What Semantic Views found, in its own words: each issue, each metric whose type differs, each suggestion."""
        r = self.report
        if not r:
            return []
        rows = [[i["severity"], f"{i['object_type']} {i['object']}".strip(), i["rule"], i["message"]] for i in r.get("issues") or []]
        rows += [["TYPE", f"{t['object']}.{t['metric']}", "", f"declares {t['declared']}, returns {t['compiled']} {t['error']}".strip()]
                 for t in r.get("types") or []]
        rows += [["SUGGESTION", x["object"], x["reason"], f"{x['type']}: {x['proposed']}"] for x in r.get("suggestions") or []]
        if not rows:
            return [{"t": "msg", "kind": "ok", "keep": True, "v": "Semantic Views checked your data map and finds nothing wrong."}]
        head = (f"Semantic Views finds {r.get('errors', 0)} error{'s' if r.get('errors') != 1 else ''} to fix"
                if r.get("errors") else "Semantic Views has notes on your data map")
        return [{"t": "msg", "kind": "warn" if r.get("errors") else "info", "keep": True, "v": head + ", in its own words:"},
                {"t": "table", "columns": ["Kind", "Where", "Rule", "What it says"], "rows": rows}]

    def _version_blocks(self) -> list[dict]:
        if self.versions is None:
            return []
        if not self.versions:
            return [{"t": "p", "muted": True, "v": "No version is kept in the model yet: the next save that changes something is version 1."}]
        options = [{"value": str(v["version"]), "label": f"v{v['version']} · {v.get('saved_at') or ''}"} for v in self.versions]
        return [{"t": "subhead", "v": "Versions of your data map", "tip": "Kept in the model: what you said and the whole model as "
                 "Semantic Views exported it. Saving an older one again makes it the newest; nothing is lost."},
                {"t": "table", "columns": ["Version", "Saved", "Tables", "Links", "Metrics"],
                 "rows": [[f"v{v['version']}", v.get("saved_at") or "", v["tables"], v["links"], v["metrics"]] for v in self.versions]},
                {"t": "fields", "items": [{"id": "dm_version", "type": "select", "label": "Save this version again",
                                           "value": options[min(1, len(options) - 1)]["value"], "options": options}]},
                {"t": "actions", "items": [{"id": "dm_restore", "label": "Save it again", "busy": "Saving…"}]}]

    def _more_blocks(self) -> list[dict]:
        """Stored totals, views for BI tools, governance, the query log and suggested changes: each a button that reads
        or does one thing, nothing on its own."""
        more, blocks = self.more or {}, []
        table = lambda rows: {"t": "table", "columns": sorted({k for r in rows for k in r})[:7],
                              "rows": [[str(r.get(k, ""))[:80] for k in sorted({k for r in rows for k in r})[:7]] for r in rows[:30]]}
        blocks += [{"t": "subhead", "v": "Suggested changes", "tip": "From feedback on answers (your own SQL instead of the "
                    "compiled one), AI tools and colleagues. Certify or reject each; Semantic Views keeps the decision."},
                   {"t": "actions", "items": [{"id": "dm_suggestions", "label": "Show suggested changes", "busy": "Reading…"}]}]
        if "suggestions" in more:
            rows = more["suggestions"]
            blocks.append(table(rows) if rows else {"t": "p", "muted": True, "v": "No suggestion is waiting."})
            if rows:
                blocks += [{"t": "fields", "items": [{"id": "dm_review", "type": "group", "cols": 3, "fields": [
                               {"id": "dm_review_id", "type": "select", "label": "Suggestion", "value": str(rows[0].get("SUGGESTION_ID")),
                                "options": [{"value": str(r.get("SUGGESTION_ID")), "label": f"{r.get('SUGGESTION_ID')} · {r.get('OBJECT_NAME') or r.get('SUGGESTION_KIND')}"} for r in rows]},
                               {"id": "dm_review_decision", "type": "select", "label": "Decision", "value": "CERTIFIED",
                                "options": [{"value": "CERTIFIED", "label": "Certify"}, {"value": "REJECTED", "label": "Reject"}]},
                               {"id": "dm_review_note", "type": "text", "label": "Review note", "placeholder": "Matches how finance counts it"}]}]},
                           {"t": "actions", "items": [{"id": "dm_review_send", "label": "Record decision", "busy": "Recording…"}]}]
        starts = [t.rsplit(".", 1)[1] for t in (self.dm.get("starts") or list(self.facts["tables"]))]
        blocks += [{"t": "subhead", "v": "Stored totals for speed", "tip": "The metrics by the dimensions, stored once in "
                    "EXAKIT_TOTALS. Semantic Views answers from them when a question fits and they are fresh, and reads the live "
                    "tables otherwise."},
                   {"t": "fields", "items": [{"id": "dm_totals", "type": "group", "cols": 2, "fields": [
                       {"id": "dm_t_view", "type": "select", "label": "Semantic view", "value": starts[0] if starts else "",
                        "options": [{"value": v, "label": v} for v in starts]},
                       {"id": "dm_t_max_age", "type": "select", "label": "Freshness", "value": "1 DAYS",
                        "options": [{"value": x, "label": y} for x, y in (("1 HOURS", "1 hour"), ("6 HOURS", "6 hours"), ("1 DAYS", "1 day"), ("7 DAYS", "7 days"))]},
                       {"id": "dm_t_metrics", "type": "text", "label": "Metrics (comma-separated)", "placeholder": "total_amount, order_lines_count"},
                       {"id": "dm_t_dimensions", "type": "text", "label": "Dimensions (comma-separated)", "placeholder": "ship_state, order_date_month"}]}]},
                   {"t": "actions", "items": [{"id": "dm_totals_store", "label": "Store totals", "busy": "Storing…"},
                                              {"id": "dm_totals_list", "label": "List stored totals", "busy": "Reading…"}]}]
        if "totals" in more:
            blocks.append(table(more["totals"]) if more["totals"] else {"t": "p", "muted": True, "v": "No stored totals yet."})
        blocks += [{"t": "subhead", "v": "Views for BI tools", "tip": "Semantic SQL compiled once and stored as a plain view: "
                    "Tableau or Power BI read it with no preprocessor. When a definition it uses changes, Semantic Views retires it."},
                   {"t": "fields", "items": [{"id": "dm_freeze", "type": "group", "cols": 2, "fields": [
                       {"id": "dm_f_view", "type": "text", "label": "View name (SCHEMA.NAME)", "placeholder": "BI.REVENUE_BY_STATE"},
                       {"id": "dm_f_sql", "type": "text", "label": "Semantic SQL",
                        "placeholder": f"SELECT ship_state, total_amount FROM SEM_ALL_DATA.{starts[0] if starts else 'ORDERS'} GROUP BY ship_state"}]}]},
                   {"t": "actions", "items": [{"id": "dm_freeze_make", "label": "Create the view", "busy": "Compiling…"},
                                              {"id": "dm_frozen_check", "label": "Check view status", "busy": "Checking…"}]}]
        if "frozen" in more:
            blocks.append(table(more["frozen"]) if more["frozen"] else {"t": "p", "muted": True, "v": "No view is frozen from your data map."})
        blocks += [{"t": "subhead", "v": "Governance and the query log", "tip": "OPEN: Semantic Views reports sources read "
                    "without their own row and column policy. GOVERNED: it refuses them. The query log keeps every Semantic SQL statement."},
                   {"t": "fields", "items": [{"id": "dm_gov_mode", "type": "select", "label": "Governance", "value": "OPEN",
                                              "options": [{"value": "OPEN", "label": "Open (report)"}, {"value": "GOVERNED", "label": "Governed (enforce)"}]}]},
                   {"t": "actions", "items": [{"id": "dm_governance", "label": "Apply", "busy": "Setting and checking…"},
                                              {"id": "dm_logging_on", "label": "Enable query log"}, {"id": "dm_logging_off", "label": "Disable query log"},
                                              {"id": "dm_history", "label": "Query history", "busy": "Reading…"}]}]
        if "history" in more:
            rows = (more["history"].get("requests") or []) + (more["history"].get("statements") or [])
            blocks.append(table(rows) if rows else {"t": "p", "muted": True, "v": "Nothing logged yet."})
        return blocks

    def on_dm_suggestions(self, _v: dict) -> None:
        self.more = {**(self.more or {}), "suggestions": list(actions.run("semantic.suggestions") or [])}

    def on_dm_review_send(self, v: dict) -> None:
        if not str(v.get("dm_review_note") or "").strip():
            raise ValueError("Say why, in a few words: Semantic Views keeps it with the decision.")
        actions.run("semantic.review", suggestion=int(v.get("dm_review_id")), decision=str(v.get("dm_review_decision") or "CERTIFIED"),
                    note=str(v.get("dm_review_note")))
        self.on_dm_suggestions(v)

    def on_dm_totals_store(self, v: dict) -> None:
        split = lambda key: [x.strip() for x in str(v.get(key) or "").split(",") if x.strip()]
        if not split("dm_t_metrics"):
            raise ValueError("Name at least one metric, as your data map calls it (total_amount).")
        found = actions.run("semantic.totals_store", view=str(v.get("dm_t_view") or ""), metrics=split("dm_t_metrics"),
                            dimensions=split("dm_t_dimensions"), max_age=str(v.get("dm_t_max_age") or "1 DAYS"))
        self.flash = {"kind": "ok", "v": f"Stored {found['table']}: questions that fit are answered from it while it is fresh."}
        self.on_dm_totals_list(v)

    def on_dm_totals_list(self, _v: dict) -> None:
        self.more = {**(self.more or {}), "totals": list(actions.run("semantic.totals_list") or [])}

    def on_dm_freeze_make(self, v: dict) -> None:
        found = actions.run("semantic.freeze", view=str(v.get("dm_f_view") or ""), sql=str(v.get("dm_f_sql") or ""))
        self.flash = {"kind": "ok", "v": f"{found['view']} is ready for BI tools: plain SQL, no preprocessor needed."}
        self.on_dm_frozen_check(v)

    def on_dm_frozen_check(self, _v: dict) -> None:
        self.more = {**(self.more or {}), "frozen": list(actions.run("semantic.frozen", sync=False) or [])}

    def on_dm_governance(self, v: dict) -> None:
        self.report = dict(actions.run("semantic.governance", mode=str(v.get("dm_gov_mode") or "OPEN")))

    def on_dm_logging_on(self, _v: dict) -> None:
        found = actions.run("semantic.logging", on=True)
        self.flash = {"kind": "ok", "v": f"Query logging: {found.get('effective')}."}

    def on_dm_logging_off(self, _v: dict) -> None:
        found = actions.run("semantic.logging", on=False)
        self.flash = {"kind": "ok", "v": f"Query logging: {found.get('effective')}."}

    def on_dm_history(self, _v: dict) -> None:
        self.more = {**(self.more or {}), "history": dict(actions.run("semantic.history") or {})}

    def on_dm_versions(self, _v: dict) -> None:
        found = actions.run("semantic.versions")
        self.versions = list(found or [])

    def on_dm_restore(self, v: dict) -> None:
        number = str(v.get("dm_version") or "")
        if not number.isdigit():
            raise ValueError("Pick a version.")
        found = actions.run("semantic.restore", version=int(number))
        self.result_text = f"Version {number} saved again as version {found.get('version')}."
        self.versions = None
        self.loading = True
        self._load()

    @staticmethod
    def _said(m: dict) -> str:
        how = {"sum": f"sum of {m.get('column')}", "count": "number of rows", "average": f"average of {m.get('column')}"}[m.get("how", "sum")]
        where = m.get("where") or {}
        cond = f" where {where['column']} is {' or '.join(where.get('values') or [])}" if where.get("column") else ""
        return f"{how}{cond}" + (" · suggested by AI" if m.get("by") == "ai" else "")

    # -- the buttons ------------------------------------------------------------------------------------------------
    def on_sv_reload(self, _v: dict) -> None:
        self.loading = True
        self._load()

    def on_dm_add_link(self, v: dict) -> None:
        source, target = str(v.get("dm_from_table") or ""), str(v.get("dm_to_table") or "")
        column, key = str(v.get("dm_from_col") or ""), str(v.get("dm_to_col") or "")
        if not (source and target and column and key):
            raise ValueError("Pick the table and the column on both sides.")
        if source == target:
            raise ValueError("A link is between two tables: pick another table on one side.")
        pair = (f"{source}.{column}".upper(), f"{target}.{key}".upper())
        self._keep(v)
        if any((l["from"], l["to"]) == pair for l in self.links):
            raise ValueError("That link is in the list already.")
        self.dm["links"] = self.links + [{"from": pair[0], "to": pair[1], "type": str(v.get("dm_link_type") or "MANY_TO_ONE"),
                                          "note": "", "by": "you"}]
        self.n += 1

    def on_dm_add_metric(self, v: dict) -> None:
        import re

        table, how = str(v.get("dm_m_table") or ""), str(v.get("dm_m_how") or "sum")
        name = re.sub(r"_+", "_", re.sub(r"[^a-z0-9_]", "_", str(v.get("dm_m_name") or "").strip().lower())).strip("_")
        if not table or not name:
            raise ValueError("Give the metric a name, such as completed_revenue.")
        column = str(v.get("dm_m_column") or "")
        if how != "count" and not column:
            raise ValueError("Pick the amount column, or use Number of rows.")
        where_column = str(v.get("dm_m_where") or "")
        values = [x.strip() for x in str(v.get("dm_m_values") or "").split(",") if x.strip()]
        if where_column and not values:
            raise ValueError(f"Say which values of {where_column} count, such as COMPLETED.")
        self._keep(v)
        if any(m["name"] == name for m in self.dm.get("metrics") or []):
            raise ValueError(f"There is a metric named {name} already.")
        metric = {"table": table, "name": name, "how": how, **({"column": column} if how != "count" else {}),
                  **({"where": {"column": where_column, "values": values}} if where_column else {}),
                  "about": " ".join(str(v.get("dm_m_about") or "").split())}
        self.dm["metrics"] = list(self.dm.get("metrics") or []) + [metric]
        self.n += 1
        known = next((c.get("values") for c in self._of_role(table, ("category", "flag")) if c["name"] == where_column), None)
        odd = [x for x in values if known and x not in known]
        if odd:
            self.flash = {"kind": "warn", "v": f"Added. {', '.join(odd)} is not among the values the column map saw for "
                                                f"{where_column} ({', '.join(known[:6])}): check the spelling."}

    def on_dm_add_words(self, v: dict) -> None:
        field_name = str(v.get("dm_syn_field") or "").strip().lower()
        words = [w.strip() for w in str(v.get("dm_syn_words") or "").split(",") if w.strip()]
        if not field_name or not words:
            raise ValueError("Name the field and at least one word for it.")
        self._keep(v)
        self.dm["synonyms"] = {**(self.dm.get("synonyms") or {}),
                               field_name: list(dict.fromkeys(list((self.dm.get("synonyms") or {}).get(field_name) or []) + words))}
        self.n += 1

    def on_dm_check(self, v: dict) -> None:
        """One bounded count per ticked link, only now: how many of its values the key holds."""
        self._keep(v)
        pairs = [f"{l['from']}={l['to']}" for l in self.links]
        if not pairs:
            raise ValueError("Add a link first.")
        tables = sorted({p.rsplit(".", 1)[0] for l in self.links for p in (l["from"], l["to"])})
        found = actions.run("semantic.check_link", tables=tables, check=pairs)
        backed = {(l["from"], l["to"]): l for l in found.get("links") or []}
        for l in self.links:
            key = (l["from"], l["to"])
            hit = backed.get(key)
            part = next((p for p in found.get("partial") or [] if (p["from"], p["to"]) == key), None)
            why = next((r["why"] for r in found.get("rejected") or [] if (r["from"], r["to"]) == key), None)
            self.checked[f"{key[0]}={key[1]}"] = (
                f"the data backs it ({hit.get('found')} of {hit.get('checked')} values found)" if hit else
                f"only {part['found']} of {part['checked']} values found" if part else
                f"not backed: {why}" if why else "not backed by the data")
        self.n += 1

    def _save_args(self, dm: dict, preview: bool) -> dict:
        return {"tables": list(self.facts["tables"]), "links": [{k: l[k] for k in ("from", "to", "type", "note", "join", "fanout") if l.get(k)}
                                                       for l in dm.get("links") or []],
                "synonyms": dict(dm.get("synonyms") or {}),
                "table_notes": dict(dm.get("table_notes") or {}), "grains": dict(dm.get("grains") or {}),
                "starts": list(dm.get("starts") or []) or None,
                "metrics": [{k: x for k, x in m.items() if k != "by"} for m in dm.get("metrics") or []],
                "instructions": list(dm.get("instructions") or []), "hidden": dict(dm.get("hidden") or {}),
                "description": dm.get("description") or None, "preview": preview}

    def _save(self, v: dict, preview: bool):
        if not self.facts["tables"]:
            raise ValueError("Approve a column map above first.")
        self._keep(v)
        return actions.run("semantic.save_map", **self._save_args(self.dm, preview))

    def on_sv_preview(self, v: dict) -> None:
        found = self._save(v, preview=True)
        self.preview_text = ";\n\n".join(found.sql) + ";" if getattr(found, "sql", None) else str(found)

    def on_sv_publish(self, v: dict) -> None:
        found = self._save(v, preview=False)
        result = getattr(found, "found", None) or {}
        self.warnings = list(result.get("warnings") or []) + list(result.get("notes") or [])
        self.result_text = (f"Saved and checked by Semantic Views: {', '.join(found.views)}. Ask, dashboards and AI tools "
                            "read it now.")
        self.saved, self.n = True, self.n + 1
        try:
            self.report = dict(actions.run("semantic.validate"))
        except Exception as exc:                # the save stands; the check is said to have failed
            self.report = {"issues": [{"severity": "NOTE", "object_type": "", "object": "", "rule": "",
                                       "message": f"Not checked: {str(exc).splitlines()[0][:200] if str(exc) else type(exc).__name__}"}]}

    def on_dm_validate(self, _v: dict) -> None:
        self.report = dict(actions.run("semantic.validate"))

    def on_session(self, what: str) -> None:
        if what == "ai" and SESSION.ai_model is not None:
            self._merge(SESSION.ai_model.get("draft") or {})
            self.refresh()
            return
        if what in ("source", "dataset", "data"):
            self.loading = True
            self.refresh()
            self._load()

    def _merge(self, draft: dict) -> None:
        """The AI's suggestions where you have said nothing yet; what you said stays. Each is marked as the AI's."""
        dm = self.dm
        for key in ("grains", "table_notes"):
            dm[key] = {**{t: x for t, x in (draft.get(key) or {}).items() if t in self.facts["tables"]}, **(dm.get(key) or {})}
        have = {(l["from"], l["to"]) for l in self.links}
        dm["links"] = self.links + [l for l in draft.get("links") or [] if (l["from"], l["to"]) not in have]
        dm["starts"] = dm.get("starts") or [t for t in draft.get("starts") or [] if t in self.facts["tables"]]
        names = {m["name"] for m in dm.get("metrics") or []}
        dm["metrics"] = list(dm.get("metrics") or []) + [m for m in draft.get("metrics") or [] if m["name"] not in names]
        dm["instructions"] = list(dm.get("instructions") or []) + [i for i in draft.get("instructions") or []
                                                                    if i not in (dm.get("instructions") or [])]
        dm["description"] = dm.get("description") or draft.get("description") or ""
        dm["hidden"] = {**{t: c for t, c in (draft.get("hidden") or {}).items() if t in self.facts["tables"]}, **(dm.get("hidden") or {})}
        self.n += 1

    # -- the same thing in two sources (fusion) ---------------------------------------------------------------------
    def _fusion_blocks(self) -> list[dict]:
        """The same thing in two sources: a table of your data map and its copy in another source, declared one thing
        with two sources (Exasol Semantic Views fusion). Checked against the data first; applied only after that."""
        if not self.saved:
            return []
        every = [{"value": t["table"], "label": t["table"]} for t in self.tables]
        approved = [{"value": t, "label": t} for t in self.facts["tables"]]
        by_table = {t["table"]: [{"value": "", "label": "Same name as the key"}]
                    + [{"value": c, "label": c} for c in self.columns.get(t["table"], [])] for t in self.tables}
        by_table[""] = [{"value": "", "label": "Pick the other table first"}]
        blocks = [{"t": "subhead", "v": "The same thing in two sources"},
                  {"t": "fields", "items": [{"id": "sv_fuse", "type": "group", "fields": [
                      {"id": "sv_fuse_table", "type": "select", "label": "Your table", "value": approved[0]["value"] if approved else "",
                       "options": approved},
                      {"id": "sv_fuse_other", "type": "select", "label": "Other source table", "value": "", "options": every,
                       "placeholder": "Pick the other source's table…"},
                      {"id": "sv_fuse_key", "type": "select", "label": "Its key column (if named differently)",
                       "options_from": {"field": "sv_fuse_other", "map": by_table}, "empty": "Pick the table first."},
                      {"id": "sv_fuse_wins", "type": "select", "label": "Precedence", "value": "model",
                       "options": [{"value": "model", "label": "Your table wins"}, {"value": "other", "label": "The other source wins"}]},
                      {"id": "sv_fuse_how", "type": "select", "label": "Relation", "value": "same",
                       "options": [{"value": "same", "label": "Same rows, same ids"},
                                   {"value": "mapped", "label": "Same rows, different ids (mapping table)"},
                                   {"value": "split", "label": "The other source holds the older rows"}]},
                      {"id": "sv_fuse_xref", "type": "select", "label": "Mapping table", "value": "", "options": every,
                       "show_if": {"field": "sv_fuse_how", "equals": "mapped"}},
                      {"id": "sv_fuse_local", "type": "text", "label": "Mapping: other source id column", "placeholder": "ACCOUNT_ID",
                       "show_if": {"field": "sv_fuse_how", "equals": "mapped"}},
                      {"id": "sv_fuse_semantic", "type": "text", "label": "Mapping: your id column", "placeholder": "CUSTOMER_ID",
                       "show_if": {"field": "sv_fuse_how", "equals": "mapped"}},
                      {"id": "sv_fuse_split_column", "type": "text", "label": "Split date column", "placeholder": "ORDER_DATE",
                       "show_if": {"field": "sv_fuse_how", "equals": "split"}},
                      {"id": "sv_fuse_split_at", "type": "text", "label": "Your table answers from (date)", "placeholder": "2026-01-01",
                       "show_if": {"field": "sv_fuse_how", "equals": "split"}}]}]},
                  {"t": "actions", "items": [{"id": "sv_fuse_check", "label": "Validate against the data", "busy": "Checking (nothing changes)…"}]
                   + ([{"id": "sv_fuse_apply", "label": "Apply", "primary": True, "busy": "Applying…"}]
                      if self.fusion_said and self.fusion_said.get("dry_run") and self.fusion_said.get("status") != "error" else [])}]
        if self.fusion_said:
            ok = self.fusion_said.get("status") != "error"
            blocks.append({"t": "msg", "kind": "ok" if ok else "error", "keep": True,
                           "v": ("Checked: the data backs it, nothing was changed. Apply saves it to your data map."
                                 if ok and self.fusion_said.get("dry_run") else
                                 "Applied: questions are answered from both sources now." if ok else "It was not accepted")
                                + (f" ({self.fusion_said['message']})" if self.fusion_said.get("message") else "")})
        outside = self.fusion_said.get("coverage") if self.fusion_said else None
        if outside:
            blocks.append({"t": "msg", "kind": "warn", "keep": True, "v": "Rows outside their date window, which no answer counts: "
                           + "; ".join(", ".join(f"{k.lower()} {val}" for k, val in r.items()) for r in outside[:5])})
        health = self.fusion_said.get("health") if self.fusion_said else None
        if health:
            blocks.append({"t": "table", "columns": ["Value", "How both are combined", "Rows", "From the first source", "Filled by the other", "Neither has it"],
                           "rows": [[f"{h['entity']}.{h['attribute']}", h["strategy"], h["keys"], h["from_first"], h["filled"], h["unresolved"]]
                                    for h in health]})
        if self.fusion_doc:
            import json

            blocks.append({"t": "details", "title": "The fusion document", "blocks": [{"t": "pre", "v": json.dumps(self.fusion_doc, indent=2)}]})
        return blocks

    def _fusion_inputs(self, v: dict) -> tuple:
        table, other = (str(v.get(k) or "").strip() for k in ("sv_fuse_table", "sv_fuse_other"))
        if not (table and other):
            raise ValueError("Pick your table and the table of the other source that holds the same rows.")
        how, text = str(v.get("sv_fuse_how") or "same"), lambda k: str(v.get(k) or "").strip()
        mapping = split = None
        if how == "mapped":
            if not (text("sv_fuse_xref") and text("sv_fuse_local") and text("sv_fuse_semantic")):
                raise ValueError("Pick the table pairing the ids and name its two columns.")
            mapping = {"table": text("sv_fuse_xref"), "local": text("sv_fuse_local").upper(), "key": text("sv_fuse_semantic").upper()}
        elif how == "split":
            if not (text("sv_fuse_split_column") and text("sv_fuse_split_at")):
                raise ValueError("Name the date both tables hold and the day your table answers from.")
            split = {"column": text("sv_fuse_split_column").upper(), "at": text("sv_fuse_split_at")}
        return ("all_data", table, other, text("sv_fuse_key") or None, str(v.get("sv_fuse_wins") or "model"),
                json_key(mapping), json_key(split))

    def on_sv_fuse_check(self, v: dict) -> None:
        model, table, other, key, wins, mapping, split = self._fusion_inputs(v)
        self.fusion_doc = actions.run("semantic.fusion_doc", model=model, table=table, other=other, key=key, wins=wins,
                                      mapping=dict(mapping) if mapping else None, split=dict(split) if split else None)
        self.fusion_for = (model, table, other, key, wins, mapping, split)
        self.fusion_said = dict(actions.run("semantic.fuse_check", model=model))

    def on_sv_fuse_apply(self, v: dict) -> None:
        if self._fusion_inputs(v) != self.fusion_for or not self.fusion_doc:
            raise ValueError("The picks changed since the check: check again first.")
        self.fusion_said = dict(actions.run("semantic.fuse_apply", model=self.fusion_for[0]))


class AiHelp(Screen):
    """One button for the whole step: the AI model set up for the kit fills in everything it can, for every table
    chosen - each table's column map (the meanings it would change, the other choices, a description per column) - and
    the data map: what one row of each table is, the links with their type, where questions start, metrics with a
    condition, rules for AI tools. It never reads a row and never scans values. It fills the cards below; it
    approves and publishes nothing. Every call is a cell of the quickstart (map.ai_check, semantic.draft)."""
    kind = "card"
    said: list[str] = []
    failed: list[str] = []

    def __init__(self) -> None:
        super().__init__()
        self.said, self.failed = [], []
        SESSION.listen(self)
        self.refresh()

    def on_session(self, what: str) -> None:
        if what == "source":
            self.said, self.failed = [], []
            self.refresh()

    def build(self) -> list[dict]:
        try:
            model = actions.run("kit.model") or {}
        except Exception:
            model = {}
        ready = bool(model.get("configured"))
        tip = ("One click, for every table you chose: it corrects the kit's guesses, sets the other choices, writes a "
               "description for every column, and drafts your data map: what one row of each table is, the links, where "
               "questions start, metrics and rules. "
               "It is shown names, types and what the kit measured, never a row, and not a personal-data column. It "
               "never picks what to predict. It fills the card below: you still approve "
               "and publish."
               if ready else "No AI model is set up yet. Set one up on the Home notebook (AI model, Set up).")
        blocks: list[dict] = [{"t": "head", "kicker": KICKER, "title": "Fill in with AI", "sub": tip}]
        if not ready:
            return blocks + [{"t": "msg", "kind": "info", "v": "No AI model set up. This step works without it."}]
        blocks.append({"t": "actions", "items": [{"id": "ai_all", "label": "Fill everything in with AI", "primary": True,
                                                   "busy": "Asking the model…"}]})
        if self.said:
            blocks.append({"t": "msg", "kind": "ok", "keep": True, "v": "Filled in: " + " · ".join(self.said) + ". Look it over below, then approve."})
        if self.failed:
            blocks.append({"t": "msg", "kind": "warn", "v": "Not filled in: " + "; ".join(self.failed)})
        return blocks

    def on_ai_all(self, _v: dict) -> None:
        if SESSION.source is None:
            raise ValueError("Choose your data in the quickstart first.")
        current = str(SESSION.source.fact_table)
        tables = [e["table"] for e in SESSION.chosen] or [current]
        several = len(tables) > 1
        first = lambda exc: (str(exc).splitlines() or [type(exc).__name__])[0][:200]
        self.said, self.failed = [], []
        changed = described = 0
        # 1. every table is read (its draft, by the kit), so the model can see them next to each other
        if several:
            actions.run("map.reviews")
        read = []
        for table in tables:
            print(f"Reading {table}")
            try:
                if several and str(SESSION.source.fact_table) != table:
                    actions.run("understand.switch", table=table)
                    use_chosen(next(e for e in SESSION.chosen if e["table"] == table))
                actions.run("map.review_keep", table=table) if several else actions.run("map.review")
                read.append(table)
            except Exception as exc:
                self.failed.append(f"{table} ({first(exc)})")
        # 2. each table's column map, filled with the other tables in view (what means the same thing across sources)
        for table in read:
            print(f"Filling in {table}")
            try:
                found = dict((actions.run("map.ai_together", table=table) if several else actions.run("map.ai_check")) or {})
            except Exception as exc:
                self.failed.append(f"{table} ({first(exc)})")
                continue
            SESSION.ai_runs += 1
            SESSION.ai_maps[table] = {"id": SESSION.ai_runs, "items": list(found.get("roles") or []),
                                      "slots": dict(found.get("slots") or {}), "notes": dict(found.get("notes") or {})}
            changed += len(found.get("roles") or [])
            described += len(found.get("notes") or {})
        if several and str(SESSION.source.fact_table) != current:
            actions.run("understand.switch", table=current)
            use_chosen(next(e for e in SESSION.chosen if e["table"] == current))
        done = [t for t in tables if t in SESSION.ai_maps]
        if done:
            self.said.append(f"{len(done)} column map{'s' if len(done) != 1 else ''} ({changed} meaning{'s' if changed != 1 else ''} "
                             f"changed, {described} description{'s' if described != 1 else ''})")
        # 3. the data map: one AI call over the approved tables - names, roles, notes and known values, no query, no
        # value scan. It only suggests: the data map card shows each suggestion marked as the AI's, to keep or change.
        said: dict = {"draft": {}}
        print("Drafting your data map")
        try:
            draft = dict(actions.run("semantic.draft", tables=tables) or {})
            said["draft"] = draft
            parts = [f"{len(draft.get(k) or [])} {label}" for k, label in (("links", "links"), ("metrics", "metrics"),
                                                                         ("instructions", "rules")) if draft.get(k)]
            parts += [f"{len(draft.get('grains') or {})} grains"] if draft.get("grains") else []
            self.said.append("your data map (" + (", ".join(parts) or "nothing to add") + ")")
        except Exception as exc:
            self.failed.append(f"the data map ({first(exc)}; approve the column maps, then press again)")
        SESSION.ai_model = said
        SESSION.changed("source", self)        # the column map card opens the current table again, with its answer
        SESSION.changed("ai", self)


class ExploreChoose(ChooseData):
    """Choose your data, as the first card of the explore notebook: the tables the quickstart chose stay, and what you
    tick here is added beside them (the cards below take it up). The same choices and code as the quickstart's."""
    ADDING = True

    def build(self) -> list[dict]:
        blocks = super().build()
        if blocks and blocks[0].get("t") == "head":
            chosen = ", ".join(e["table"] for e in SESSION.chosen[:4]) + (" and more" if len(SESSION.chosen) > 4 else "")
            blocks[0] = dict(blocks[0], sub=(f"You are working on {chosen}. " if chosen else "")
                             + "Tick more to add them: kit datasets, your own tables and files, external sources. Nothing "
                               "you chose before is taken away.")
        return blocks


def understand():
    """Step 2 in the guided view, on its own: choose your data, the one AI button, then one card with what each column
    means and your data map over the tables chosen."""
    from ..card import show

    return show(ExploreChoose(), AiHelp(), Understand(), SemanticViews(), docs="explore")


# =====================================================================================================
class _MapPart(ColumnMap):
    """The column map as the top of the Understand card: it draws into that card, not a card of its own."""
    owner: "Understand | None" = None

    def refresh(self) -> None:
        if self.owner is not None:
            self.owner.refresh()


class _SourcesPart(ChooseData):
    """Add a source or a table from inside the Understand card: the quickstart's Choose your data, adding to the
    tables already chosen. A new connection's tables join the column maps below."""
    owner: "Understand | None" = None
    ADDING = True

    def refresh(self) -> None:
        if self.owner is not None:
            self.owner.refresh()


class _ViewsPart(SemanticViews):
    """Your data map as the bottom of the Understand card, over the tables chosen above: it draws into that card."""
    owner: "Understand | None" = None

    def refresh(self) -> None:
        if self.owner is not None:
            self.owner.refresh()


def _part(cls, owner):
    part = cls.__new__(cls)
    part.owner = owner          # set before __init__, whose first refresh already draws into the owner
    part.__init__()
    return part


class Understand(Screen):
    """Step 2 in one card: what each column means (the column map) on top, the semantic views below. Approving a
    table's column map publishes it in Exasol Semantic Views (the schema's model) and ticks it for the model over all
    your tables underneath, so both are one job: approve each table, link them, publish. The tables are the ones
    the quickstart chose (nb.open_chosen); a table already drawn up is not read again when you come back to it."""
    help = ColumnMap.help + SemanticViews.help
    kind = "card"

    def __init__(self) -> None:
        self.map = self.views = self.sources = None
        self.adding = False                  # the "add a source or table" part is open
        self.kinds: dict[str, str] = {}      # VS_<NAME> -> its connector's name (nb.sources), for the flow
        self.approved: set[str] = set()      # tables with an approved column map
        self.loading, self.error = True, None
        SESSION.understanding = True
        if not SESSION.chosen:
            SESSION.opened.clear()
        super().__init__()
        SESSION.listen(self)
        self.map = _part(_MapPart, self)
        self.refresh()
        import threading

        threading.Thread(target=self._open, daemon=True).start()

    def _open(self) -> None:
        """This notebook's kernel starts empty: open the tables the quickstart chose (the cell: chosen_tables =
        nb.open_chosen(connection)), else the dataset approved last, and draw up the first one's column map."""
        try:
            with SESSION.lock:
                if not SESSION.chosen:
                    opened = actions.run("understand.open") or {}
                    if opened:
                        tables = list(opened)
                        actions.run("understand.switch", table=tables[0])
                    else:
                        actions.run("understand.default")
                        tables = [str(SESSION.source.fact_table)]
                        from ..actions import Var

                        actions.run("data.keep", table=tables[0], data=Var("chosen_data"))
                    SESSION.chosen = [{"label": table, "table": table, "variable": None, "rows": None, "broken": None}
                                      for table in tables]
                    SESSION.chosen_n += 1
                    use_chosen(SESSION.chosen[0])
                    print(f"Reading {tables[0]}: each column's type, how many values and how they spread")
                    with SESSION.showing_queries():
                        SESSION.changed("source", None)
        except Exception as exc:
            self.error = str(exc).splitlines()[0] if str(exc) else type(exc).__name__
        self.loading = False
        SESSION.opened.set()
        self._read_flow()
        self.refresh()
        SESSION.release()

    def _read_flow(self) -> None:
        """What the flow strip shows, from the kit's own records: each connected source's kind (nb.sources, no
        database) and which tables have an approved column map (the kit's store)."""
        try:
            self.kinds = {str(r.get("schema") or "").upper(): str(r.get("connector_name") or r.get("connector") or "external")
                          for r in actions.run("sources.list") or []}
        except Exception:
            self.kinds = {}
        try:
            self.approved = {str(a["table"]).upper() for a in actions.run("kit.approved") or []}
        except Exception:
            pass

    def on_session(self, what: str) -> None:
        if what in ("dataset", "source"):
            self._read_flow()
            self.refresh()

    def on_src_add(self, _v: dict) -> None:
        """Open the part that adds a source or a table (made the first time: it reads the connectors then)."""
        if self.sources is None:
            self.sources = _part(_SourcesPart, self)
        self.adding = True

    def on_src_close(self, _v: dict) -> None:
        self.adding = False

    def on_use(self, v: dict) -> None:
        """Add what was ticked (the sources part's Use this data), then close the part: the new tables are in the
        flow above and in the column maps below."""
        if self.sources is None:
            raise ValueError("Open Add a source or table first.")
        self.sources.flash = None
        ChooseData.on_use(self.sources, v)
        if self.sources.flash:
            self.flash, self.sources.flash = self.sources.flash, None
        if not self.sources.failed:
            self.adding = False
        self._read_flow()
        added = SESSION.chosen[0]["table"] if SESSION.chosen else ""
        self.flash = self.flash or {"kind": "ok", "v": f"Added. {added} is open below: approve its column map, then link it."}

    def _flow(self) -> dict:
        """The fusion flow: each source with its tables -> column maps -> links -> one semantic model -> clean ->
        ask -> dashboard, each marked done, now or to do."""
        groups: dict[str, list[str]] = {}
        for e in SESSION.chosen:
            groups.setdefault(e["table"].split(".", 1)[0].upper(), []).append(e["table"].upper())
        sources = []
        for schema, tables in groups.items():
            kind = self.kinds.get(schema) or ("external source" if schema.startswith("VS_") else "this database")
            done = sum(1 for t in tables if t in self.approved)
            sources.append({"kind": kind, "label": schema, "state": "done" if done == len(tables) else "now",
                            "sub": f"{len(tables)} table{'s' if len(tables) != 1 else ''} · {done} approved",
                            "tip": ", ".join(t.split(".", 1)[1] for t in tables)})
        every = [t for ts in groups.values() for t in ts]
        approved = sum(1 for t in every if t in self.approved)
        views = self.views
        links = list(views.links) if views is not None else []
        mine = bool(views is not None and views.saved)
        steps = [
            {"kind": "1", "label": "Column maps", "sub": f"{approved} of {len(every)} approved",
             "state": "done" if every and approved == len(every) else "now",
             "tip": "What each column means, per table. Approving one saves it to your data map."},
            {"kind": "2", "label": "Links", "sub": f"{len(links)} added" if links else ("add them below" if approved >= 2 else "after 2 maps"),
             "state": "done" if links else ("now" if approved >= 2 else "todo"),
             "tip": "How the tables of different sources connect: this column holds that table's key, many-to-one or "
                    "one-to-one. You add them, or take the AI's suggestions; they are saved in your data map."},
            {"kind": "3", "label": "Data map", "sub": "saved" if mine else "not saved yet",
             "state": "done" if mine else ("now" if approved else "todo"),
             "tip": "One place that says what every table and column means and how they connect, across all your sources. "
                    "Your questions, dashboards and AI tools read it, so they all give the same numbers."},
            {"kind": "4", "label": "Clean", "sub": "below", "state": "todo", "tip": "Checks and a cleaned view, in the cards below."},
            {"kind": "5", "label": "Ask", "sub": "02_ask_your_data", "state": "todo",
             "tip": "Ask in words or SQL; approve it; table, chart, insights or JSON."},
            {"kind": "6", "label": "Dashboard", "sub": "03_share", "state": "todo",
             "tip": "Pin answers to pages; a multi-page dashboard on Dash Server."},
        ]
        return {"t": "flow", "sources": sources, "steps": steps,
                "add": None if self.adding else {"label": "Add a source or table", "action": "src_add"}}

    def __getattr__(self, name: str):
        """A button of any part: its handler runs on that part, and what it says shows on this card."""
        if name.startswith("on_") and name != "on_session":
            for part in (self.__dict__.get("map"), self.__dict__.get("views"), self.__dict__.get("sources")):
                handler = getattr(type(part), name, None) if part is not None else None
                if handler is not None:
                    def run(values, part=part, handler=handler):
                        part.flash = None
                        try:
                            handler(part, values)
                        finally:
                            if part.flash:
                                self.flash, part.flash = part.flash, None
                    return run
        raise AttributeError(name)

    def build(self) -> list[dict]:
        if self.map is None:
            return [{"t": "head", "kicker": KICKER, "title": "Column roles"}]
        top = self.map.build()
        if self.loading:
            top = top[:1] + [{"t": "empty", "v": "Opening the tables you chose…"}]
        if self.error:
            top = top[:1] + [{"t": "msg", "kind": "warn", "v": f"The chosen tables could not be opened: {self.error}. "
                                                               "Choose your data again above."}]
        if self.map.flash:                    # said by the part's background read: shown with it
            top.insert(1, {"t": "msg", **{k: v for k, v in self.map.flash.items() if k != "said"}})
        return top

    def _adding_blocks(self) -> list[dict]:
        """The add-a-source part, under the flow while it is open: the quickstart's choice of data, without its title."""
        if not self.adding or self.sources is None:
            return []
        blocks = [b for b in self.sources.build() if b.get("t") not in ("head", "next", "code")]
        return ([{"t": "subhead", "v": "Add a source or table",
                  "tip": "Kit datasets, your own tables or files, and external sources (S3, Snowflake, MongoDB, PostgreSQL "
                         "and the rest `exakit connect` knows). What you add joins the tables above; nothing is replaced."}]
                + blocks + [{"t": "actions", "items": [{"id": "src_close", "label": "Close"}]}])


def _publish_note(said: str) -> str:
    """Whether the approval reached the AI agents: the kit rebuilds the schema's Exasol Semantic Views model, which
    agents read over MCP, and says so (or why not) in its own lines."""
    import re

    found = re.search(r"Published in Exasol Semantic Views as (.+?): agents", said or "")
    if found:
        return "Saved to your data map: your questions, dashboards and AI tools read what each column means from it."
    missed = re.search(r"Approved, not published: ([^\n]+?)\. Retry with: (.+)", said or "")
    if missed:
        return f"Not published for AI agents yet ({missed.group(1)}); retry with {missed.group(2).strip()}."
    return ""


def _versions(dataset_id: str) -> tuple[list[dict], int | None]:
    """(every saved version of the dataset's column map, the approved one's number), from the kit's store."""
    history = actions.run("map.versions", dataset_id=dataset_id) or []
    number = next((a["version"] for a in actions.run("kit.approved") if a["id"] == dataset_id), None)
    return history, number


def _next_notebook() -> dict | None:
    """The notebook after this one in the persona's path (nb.notebooks), for the "Next" link."""
    here = Path.cwd().name
    rows = actions.run("kit.notebooks", persona=here) or []
    return rows[1] if len(rows) > 1 else None
