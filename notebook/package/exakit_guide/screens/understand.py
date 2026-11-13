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
        if self.done and SESSION.source is not None:
            rows = f" · {SESSION.source_rows} rows" if SESSION.source_rows else ""
            if len(SESSION.chosen) > 1:
                others = ", ".join(e["table"] for e in SESSION.chosen)
                blocks.append({"t": "msg", "kind": "ok", "keep": True,
                               "v": f"Using {len(SESSION.chosen)} tables: {others}. The column map below opens on "
                                    f"{SESSION.source.fact_table}; move between the tables there, then link them under "
                                    "Semantic views."})
            else:
                blocks.append({"t": "msg", "kind": "ok", "v": f"Using {SESSION.source_label}{rows}. Check the column map below."})
        if self.failed:
            blocks.append({"t": "msg", "kind": "warn", "v": "Not loaded: " + "; ".join(self.failed)})
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
                    tables = _listed(v.get("table")) or [""]
                else:
                    tables = _listed(v.get(self._tid(schema))) or _listed(v.get("table")) or [""]
                for table in tables:
                    source = f"{schema}.{table}" if table and "." not in table else (table or schema)
                    wanted.append(("data.source", "source_data", {"source": source}, source))
        return wanted, connected

    def on_use(self, v: dict) -> None:
        from ..actions import Var

        SESSION.broken = None
        self.failed = []
        if not SESSION.get("workflow_id"):      # guide.start() began one; a screen shown on its own begins it here
            actions.run("data.workflow")
        wanted, connected = self._wanted(v)
        if not wanted:
            raise ValueError("Tick at least one dataset, table or source.")
        several = len(wanted) > 1
        if several:
            actions.run("data.several")
        chosen: list[dict] = []
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
        if not chosen:
            SESSION.broken = None
            raise ValueError("Nothing was loaded. The kit's note is under 'What the kit said'.")
        if several:
            actions.run("data.switch", table=chosen[0]["table"])
        else:
            actions.run("data.choose", data=Var(chosen[0]["variable"]))
        if SESSION.source is None:
            raise ValueError("Nothing was loaded. The kit's note is under 'What the kit said'.")
        SESSION.chosen, SESSION.chosen_n = chosen, SESSION.chosen_n + 1
        use_chosen(chosen[0])
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

    def _review(self) -> None:
        from ..actions import Var

        self.first, self.leaks = None, []
        self.ai = SESSION.ai_maps.get(str(SESSION.source.fact_table)) if SESSION.source is not None else None
        actions.run("map.review")
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
                           "text": "Link them and publish one model over them under Semantic views, below."})
        return blocks

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
        actions.run("data.switch", table=table)
        use_chosen(entry)
        self._review()
        SESSION.changed("source", self)

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
        head = {"t": "head", "kicker": KICKER, "title": "What each column means",
                "sub": "The kit looked at every column. Answer three questions, then approve. You can change your mind later."}
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
                                "The model step leaves it out automatically."})
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
        nxt = _next_notebook()
        if nxt:
            out.append({"t": "next", "v": f"Next: {nxt['title']}", "path": nxt["file"]})
        return out

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
        SESSION.changed("dataset", self)

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
                       {"t": "p", "muted": True, "v": "A possible link or shared dimension only shares a name: check it before a join."},
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


class SemanticViews(Screen):
    """The semantic layer, built by hand in one place: one Exasol Semantic Views model over the tables you tick.

    1. The tables: every schema with its tables under it - sample data, your files, external sources. The tables
       chosen in "Choose your data" start ticked; a table needs an approved column map to go in. Each ticked table
       takes a sentence saying what it is.
    2. How they connect: Find links compares the values of the ticked tables - two tables of one schema too - and
       lists each link with its evidence; the ones the data backs are ticked, a link between plain numbers is left
       for you. A link of your own is picked from lists (table and column on each side) and checked against the data
       before it is added. Each link takes a sentence saying why the two belong together.
    3. The model: its name and what it is about; a preview before anything is written; publish.

    What you say here is stored in the model - each table's description, each link with its evidence and your note -
    so an AI client or a colleague reading the model sees how the tables connect and why. Every step is a cell of the
    quickstart (actions: semantic.*)."""
    help = (('Build a semantic model', 'explore/semantic-views#one-model-across-sources'),
            ('Find links across sources', 'explore/semantic-views#links-across-sources'),)

    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.tables: list[dict] = []              # every table: {table, schema, origin, approved, rows}
        self.columns: dict[str, list[str]] = {}   # {SCHEMA.TABLE: its columns}, for the link pickers
        self.models: list[dict] = []
        self.links: list[dict] | None = None      # found and added links, each as nb.find_links returns it
        self.links_note = ""
        self.preview_text = ""
        self.result_text = ""
        self.error = None
        self.loading = True
        self.ticked: set[str] = self._chosen_tables()    # the tables chosen above start ticked
        self.gen = 0                                     # a new choice above: the ticks start from it again
        self.link_gen = 0                                # a new search: the link ticks start from its result
        SESSION.listen(self)
        self.refresh()
        import threading

        threading.Thread(target=self._load, daemon=True).start()

    links_note, preview_text, result_text, link_gen, gen = "", "", "", 0, 0
    fill: dict | None = None        # what the AI said: {"tables": {T: text}, "links": {"A=B": text}, "name", "about"}
    fill_n = 0

    @staticmethod
    def _chosen_tables() -> set[str]:
        return {e["table"].upper() for e in SESSION.chosen}

    def _tid(self, table: str) -> str:
        return f"svt{self.gen}:{table}" if self.gen else "svt:" + table

    def _lid(self, link: dict) -> str:
        return f"svl{self.link_gen}:{link['from']}={link['to']}"

    def _fid(self, name: str) -> str:
        """A text box's name: a new one after the AI filled the card in, so its answer shows in the box."""
        return f"{name}#{self.fill_n}" if self.fill_n else name

    def _load(self) -> None:
        try:
            found = actions.run("data.map")
            self.tables = [{"table": r["table"], "schema": r["table"].split(".", 1)[0], "origin": r["origin_label"],
                            "approved": str(r.get("map", "")).startswith("approved"), "rows": r.get("rows_shown") or ""}
                           for r in found.table_rows]
            columns: dict[str, list[str]] = {}
            for c in found.column_rows:
                columns.setdefault(c["table"], []).append(c["column"])
            self.columns = columns
            try:
                listed = actions.run("semantic.models")
                self.models = listed.to_dict("records") if hasattr(listed, "to_dict") else list(listed or [])
            except Exception:
                self.models = []
            self.error = None
        except Exception as exc:
            self.error = str(exc).splitlines()[0] if str(exc) else type(exc).__name__
        self.loading = False
        self.refresh()
        SESSION.release()

    def _picked(self, v: dict) -> dict:
        """What the card holds when a button is pressed: the ticked tables (with an approved column map), what was
        said about each, the links in use with their notes, the model's name and description, and the AI tick."""
        tables = [t["table"] for t in self.tables if t["approved"] and v.get(self._tid(t["table"]))]
        notes = {t: " ".join(str(v.get(self._fid("svd:" + t)) or "").split()) for t in tables}
        links = []
        for link in self.links or []:
            if not v.get(self._lid(link)):
                continue
            if link["from"].rsplit(".", 1)[0] not in tables or link["to"].rsplit(".", 1)[0] not in tables:
                continue                               # a link of a table that is no longer ticked
            note = " ".join(str(v.get(self._fid(f"svn:{link['from']}={link['to']}")) or "").split())
            links.append({**{k: w for k, w in link.items() if k != "note"}, **({"note": note} if note else {})})
        return {"tables": tables, "table_notes": {t: text for t, text in notes.items() if text}, "links": links,
                "name": str(v.get(self._fid("sv_name")) or "").strip() or "my_data",
                "description": " ".join(str(v.get(self._fid("sv_about")) or "").split()) or None, "ai": bool(v.get("sv_ai"))}

    def build(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Semantic views",
                "sub": "One model over the tables you pick, from any of your sources: which tables, how they connect, "
                       "and what each is. AI clients and notebooks query it by its business names. What you write here "
                       "is stored in the model."}
        if self.loading:
            return [head, {"t": "empty", "v": "Reading the tables and which have an approved column map…"}]
        if self.error:
            return [head, {"t": "msg", "kind": "warn", "v": f"The tables could not be read: {self.error}"},
                    {"t": "actions", "items": [{"id": "sv_reload", "label": "Read it again"}]}]
        blocks = [head]
        if self.models:
            blocks += [{"t": "subhead", "v": "Models in the database"},
                       {"t": "table", "columns": ["Model", "Published as", "Built by", "About"],
                        "rows": [[m.get("model"), m.get("published_schema"), "the kit" if m.get("kit") else "someone else",
                                  m.get("description")] for m in self.models]}]
            kit_models = [m for m in self.models if m.get("refreshable")]
            if kit_models:
                blocks += [{"t": "fields", "items": [{"id": "sv_refresh_name", "label": "Refresh a model", "type": "select",
                                                      "value": kit_models[0]["model"],
                                                      "options": [{"value": m["model"], "label": m["model"]} for m in kit_models]}]},
                           {"t": "actions", "items": [{"id": "sv_refresh", "label": "Refresh it", "busy": "Rebuilding…"}]}]
        # 1 · the tables, under their schemas
        groups: dict[str, dict] = {}
        for t in self.tables:
            g = groups.setdefault(t["schema"], {"schema": t["schema"], "origin": t["origin"], "tables": []})
            g["tables"].append({"id": self._tid(t["table"]), "note_id": self._fid("svd:" + t["table"]), "table": t["table"],
                                "note": ((self.fill or {}).get("tables") or {}).get(t["table"].upper(), ""),
                                "name": t["table"].split(".", 1)[1], "approved": t["approved"], "rows": t["rows"],
                                "value": t["approved"] and t["table"].upper() in self.ticked})
        blocks += [{"t": "subhead", "v": "1 · The tables", "tip": "Tick the tables the model is about, from as many schemas "
                    "as you like. The ones you chose above start ticked. A table needs an approved column map. Say in a "
                    "sentence what each ticked table is."},
                   {"t": "schematree", "groups": sorted(groups.values(), key=lambda g: (g["origin"], g["schema"]))}]
        if not any(t["approved"] for t in self.tables):
            blocks.append({"t": "msg", "kind": "info", "v": "No table has an approved column map yet. Approve one above "
                           "(What each column means), and it can be ticked here."})
        # 2 · how they connect
        usable = [t["table"] for t in self.tables if t["approved"]]
        blocks += [{"t": "subhead", "v": "2 · How they connect", "tip": "A link says: this column of one table points at that "
                    "column of another. Find links compares the values of the ticked tables, two tables of one schema "
                    "too. Hover a link's label to see what the data says."},
                   {"t": "checks", "items": [{"id": "sv_ai", "label": "Use AI", "value": bool(self.fill),
                                              "tip": "Your AI model proposes links from what the columns mean, and business "
                                                     "names, synonyms and metrics for the model. It sees names, types and "
                                                     "notes, never a row. Every proposed link is checked against the data."}]},
                   {"t": "actions", "items": [{"id": "sv_find", "label": "Find links", "busy": "Comparing values…"}]}]
        if self.links is not None:
            if self.links:
                blocks.append({"t": "linklist", "items": [
                    {"id": self._lid(l), "note_id": self._fid(f"svn:{l['from']}={l['to']}"), "from": l["from"], "to": l["to"],
                     "evidence": l.get("evidence_text") or "", "confidence": l.get("confidence") or "",
                     "by": l.get("proposed_by") or "values", "value": l.get("confidence") == "high" or l.get("proposed_by") == "you",
                     "note": l.get("note") or ((self.fill or {}).get("links") or {}).get(f"{l['from']}={l['to']}".upper(), "")}
                    for l in self.links]})
            else:
                blocks.append({"t": "p", "muted": True, "v": "No column of one ticked table points at a key of another. "
                                                             "Add a link below if you know one."})
            if self.links_note:
                blocks.append({"t": "pre", "v": self.links_note})
        if len(usable) >= 2:
            tables = [{"value": t, "label": t} for t in usable]
            by_table = {t: [{"value": c, "label": c} for c in self.columns.get(t, [])] for t in usable}
            blocks += [{"t": "subhead", "v": "A link of your own", "tip": "Pick the table and column on each side. The column "
                        "on the right must hold each value once. The pair is checked against the data before it is added."},
                       {"t": "fields", "items": [{"id": "sv_own", "type": "group", "fields": [
                           {"id": "sv_from_table", "type": "select", "label": "From table", "value": usable[0], "options": tables},
                           {"id": "sv_to_table", "type": "select", "label": "To table", "value": usable[1], "options": tables},
                           {"id": "sv_from_col", "type": "select", "label": "From column",
                            "options_from": {"field": "sv_from_table", "map": by_table}, "empty": "That table's columns are not known yet."},
                           {"id": "sv_to_col", "type": "select", "label": "To column (one row per value)",
                            "options_from": {"field": "sv_to_table", "map": by_table}, "empty": "That table's columns are not known yet."}]}]},
                       {"t": "actions", "items": [{"id": "sv_add", "label": "Check and add", "busy": "Checking…"}]}]
        # 3 · the model
        blocks += [{"t": "subhead", "v": "3 · The model"},
                   {"t": "fields", "items": [{"id": "sv_model", "type": "group", "fields": [
                       {"id": self._fid("sv_name"), "label": "Model name", "value": (self.fill or {}).get("name") or "my_data",
                        "placeholder": "sales_360", "type": "text"},
                       {"id": self._fid("sv_about"), "label": "What it is about (optional)", "value": (self.fill or {}).get("about") or "", "type": "text",
                        "placeholder": "Orders with their delivery times and targets, by state"}]}]},
                   {"t": "actions", "items": [{"id": "sv_preview", "label": "Preview", "busy": "Building the preview…"},
                                              {"id": "sv_publish", "label": "Publish the model", "primary": True,
                                               "busy": "Publishing…"}]}]
        if self.preview_text:
            blocks += [{"t": "subhead", "v": "Preview"}, {"t": "pre", "v": self.preview_text}]
        if self.result_text:
            blocks += [{"t": "msg", "kind": "ok", "keep": True, "v": self.result_text}]
        example = usable[:3] or ["MY_DATA.ORDERS", "VS_SALES.CUSTOMERS"]
        blocks.append({"t": "code", "code_only": True, "title": "The code behind this card",
                       "v": "\n".join([actions.code("semantic.links_tables", tables=example, ai=True),
                                       'model_links = [link for link in found_links["links"] if link["confidence"] == "high"]',
                                       actions.code("semantic.publish_tables", name="sales_360", tables=example,
                                                    table_notes={}, description=None, ai=True)])})
        return blocks

    def on_sv_reload(self, _v: dict) -> None:
        self.loading = True
        self._load()

    def on_sv_find(self, v: dict) -> None:
        picked = self._picked(v)
        if len(picked["tables"]) < 2:
            raise ValueError("Tick at least two tables: a link is between two tables.")
        found = actions.run("semantic.links_tables", tables=picked["tables"], ai=picked["ai"])
        own = [l for l in self.links or [] if l.get("proposed_by") == "you"]
        fresh = [l for l in found.get("links") or [] if not any((o["from"], o["to"]) == (l["from"], l["to"]) for o in own)]
        self.links, self.link_gen = own + fresh, self.link_gen + 1
        notes = [f"{p['from']} ~ {p['to']}: {p['found']} of {p['checked']} sampled values match. Not a link: look at the "
                 "spellings first." for p in found.get("partial") or []]
        if found.get("ai"):
            notes.append(f"AI: {found['ai']}.")
        notes.append(f"{found['checked']} pairs checked with {found['statements']} bounded statements"
                     + (f"; {found['not_checked']} more were not checked." if found.get("not_checked") else "."))
        self.links_note = "\n".join(notes)

    def on_sv_add(self, v: dict) -> None:
        """A link of your own, picked from the lists: checked against the data (nb.find_links with check=) and added
        with its evidence when the data backs it; refused, with what the data showed, when it does not."""
        source, target = str(v.get("sv_from_table") or ""), str(v.get("sv_to_table") or "")
        column, key = str(v.get("sv_from_col") or ""), str(v.get("sv_to_col") or "")
        if not (source and target and column and key):
            raise ValueError("Pick the table and the column on both sides.")
        if source == target:
            raise ValueError("A link is between two tables: pick another table on one side.")
        pair = (f"{source}.{column}".upper(), f"{target}.{key}".upper())
        if any((l["from"], l["to"]) == pair for l in self.links or []):
            raise ValueError("That link is in the list already.")
        found = actions.run("semantic.check_link", tables=[source, target], check=[f"{pair[0]}={pair[1]}"])
        link = next((l for l in found.get("links") or [] if (l["from"], l["to"]) == pair), None)
        if link is None:
            part = next((p for p in found.get("partial") or [] if (p["from"], p["to"]) == pair), None)
            why = (f"only {part['found']} of {part['checked']} sampled values of {pair[0]} are in {pair[1]}: look at the spellings"
                   if part else next((r["why"] for r in found.get("rejected") or [] if (r["from"], r["to"]) == pair),
                                     "the data does not back it"))
            raise ValueError(f"Not added: {pair[0]} -> {pair[1]}: {why}. The column on the right must hold each value once.")
        self.links = (self.links or []) + [{**link, "proposed_by": "you"}]
        self.flash = {"kind": "ok", "v": f"Added: {link.get('evidence_text') or pair[0] + ' -> ' + pair[1]}"}

    def _build(self, v: dict, action: str):
        picked = self._picked(v)
        if not picked["tables"]:
            raise ValueError("Tick at least one table with an approved column map.")
        SESSION.set("model_links", picked["links"])       # the cell's model_links: the links in use, evidence and notes with them
        return actions.run(action, name=picked["name"], tables=picked["tables"], table_notes=picked["table_notes"],
                           description=picked["description"], ai=picked["ai"])

    def on_sv_preview(self, v: dict) -> None:
        found = self._build(v, "semantic.preview_tables")
        self.preview_text, self.result_text = str(found), ""

    def on_sv_publish(self, v: dict) -> None:
        found = self._build(v, "semantic.publish_tables")
        self.preview_text = str(found)
        self.result_text = (f"Published {', '.join(found.views)}. AI clients query it over MCP; a notebook with "
                            "nb.semantic_sql. Approving a column map in it refreshes it by itself.")
        self.loading = True
        self._load()

    def on_sv_refresh(self, v: dict) -> None:
        name = str(v.get("sv_refresh_name") or "")
        found = actions.run("semantic.refresh", name=name)
        self.result_text = f"Refreshed {found.get('view')}."
        self.loading = True
        self._load()

    def on_session(self, what: str) -> None:
        if what == "ai" and SESSION.ai_model is not None:
            # the one AI button: the links it found between the chosen tables, and what it said about each part
            said = SESSION.ai_model
            self.fill, self.fill_n = dict(said.get("notes") or {}), self.fill_n + 1
            if said.get("links") is not None:
                own = [l for l in self.links or [] if l.get("proposed_by") == "you"]
                self.links = own + [l for l in said["links"] if not any((o["from"], o["to"]) == (l["from"], l["to"]) for o in own)]
                self.link_gen += 1
                self.links_note = said.get("links_note") or ""
            self.refresh()
            return
        if what in ("source", "dataset", "data"):
            import threading

            now = self._chosen_tables()
            if what == "source" and now != self.ticked:
                self.ticked, self.gen = now, self.gen + 1
                self.links, self.links_note = None, ""
            self.loading = True
            self.refresh()
            threading.Thread(target=self._load, daemon=True).start()


class AiHelp(Screen):
    """One button for the whole step: the AI model set up for the kit fills in everything it can, for every table
    chosen - each table's column map (the meanings it would change, the other choices, a description per column), the
    links between the tables, and a sentence for each table, each link and the model. It fills the cards below; it
    approves and publishes nothing. Every call is a cell of the quickstart (map.ai_check, semantic.links_tables,
    semantic.ai_notes)."""
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
               "description for every column, finds the links between your tables and says what each table and link is. "
               "It is shown names, types and what the kit measured, never a row, and not a personal-data column. It "
               "never picks what to predict. Choose your data below first. It fills the cards below: you still approve "
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
            raise ValueError("Choose your data below first.")
        current = str(SESSION.source.fact_table)
        tables = [e["table"] for e in SESSION.chosen] or [current]
        several = len(tables) > 1
        first = lambda exc: (str(exc).splitlines() or [type(exc).__name__])[0][:200]
        self.said, self.failed = [], []
        changed = described = 0
        # 1. every table is read (its draft, by the kit), so the model can see them next to each other
        same: list[str] = []
        if several:
            actions.run("map.reviews")
        read = []
        for table in tables:
            print(f"Reading {table}")
            try:
                if several and str(SESSION.source.fact_table) != table:
                    actions.run("data.switch", table=table)
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
            for here, other in found.get("same_as") or []:          # a reading of meaning: checked against the data below
                same += [pair for pair in (f"{here}={other}", f"{other}={here}") if pair not in same]
        if several and str(SESSION.source.fact_table) != current:
            actions.run("data.switch", table=current)
            use_chosen(next(e for e in SESSION.chosen if e["table"] == current))
        done = [t for t in tables if t in SESSION.ai_maps]
        if done:
            self.said.append(f"{len(done)} column map{'s' if len(done) != 1 else ''} ({changed} meaning{'s' if changed != 1 else ''} "
                             f"changed, {described} description{'s' if described != 1 else ''})")
        # 2. the links between the tables, 3. what each table, each link and the model is
        said: dict = {"links": None, "notes": {}}
        if several:
            print("Finding the links between the tables")
            try:
                found = (actions.run("semantic.links_checked", tables=tables, check=same[:40], ai=True) if same
                         else actions.run("semantic.links_tables", tables=tables, ai=True))
                said["links"] = list(found.get("links") or [])
                said["links_note"] = ((f"The AI read {len(same) // 2} pair{'s' if len(same) != 2 else ''} of columns as meaning the same thing "
                                       "across your tables; each was checked against the data. " if same else "")
                                      + f"{found.get('checked', 0)} pairs checked with {found.get('statements', 0)} bounded statements."
                                      + (f" AI: {found['ai']}." if found.get("ai") else ""))
                self.said.append(f"{len(said['links'])} link{'s' if len(said['links']) != 1 else ''} found")
            except Exception as exc:
                self.failed.append(f"the links ({first(exc)})")
        print("Describing the tables and the model")
        try:
            pairs = [f"{l['from']}={l['to']}" for l in said["links"] or []]
            said["notes"] = dict(actions.run("semantic.ai_notes", tables=tables, links=pairs) or {})
            count = len(said["notes"].get("tables") or {})
            if count:
                self.said.append(f"{count} table description{'s' if count != 1 else ''}")
        except Exception as exc:
            self.failed.append(f"the descriptions ({first(exc)})")
        SESSION.ai_model = said
        SESSION.changed("source", self)        # the column map card opens the current table again, with its answer
        SESSION.changed("ai", self)


def understand():
    """Step 1 in the guided view: one button to have the AI fill everything in, then choose the data, approve what
    each column means, see it on the map of all your data, and build the semantic views AI clients and notebooks
    query."""
    from ..card import show

    return show(AiHelp(), ChooseData(), ColumnMap(), DataMap(), SemanticViews(), docs="explore")


def _publish_note(said: str) -> str:
    """Whether the approval reached the AI agents: the kit rebuilds the schema's Exasol Semantic Views model, which
    agents read over MCP, and says so (or why not) in its own lines."""
    import re

    found = re.search(r"Published in Exasol Semantic Views as (.+?): agents", said or "")
    if found:
        return f"Published in Exasol Semantic Views as {found.group(1)}: AI agents read the fields from it."
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
