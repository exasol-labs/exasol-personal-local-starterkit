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


# =====================================================================================================
class ChooseData(Screen):
    """Choose the data: a kit dataset, your own (a table already in the database, or a new file or folder), or an
    external source (one connected, or a new connection). Every option and every step is one cell of the
    quickstart's code section (actions: data.*)."""

    kind = "card"
    step, connector, src_name, conn_n, tip = "connection", None, "", 0, ""
    preset, settings_step, typed_storage = None, False, ""   # a source's settings (a Lakehouse's catalog and files)

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
        self.step = "connection"               # a new connection is entered one step at a time (Back / Next)
        self.connector: str | None = None      # the data source chosen for it
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
                "sub": "Pick what you want to work on. You can change it at any time."}
        if self.loading:
            return [head, {"t": "empty", "v": "Looking at what's available…"}]
        samples = [{"value": s["id"], "label": s["label"], "hint": "Loaded" if s["loaded"] else "Downloads the first time"}
                   for s in self.samples]
        own_options = [{"value": o["value"], "label": o["label"]} for o in self.own] + [{"value": "__new__", "label": "Load a new file…"}]
        new_only = {"field": "own", "equals": "__new__"}
        conn = self._cf()
        connect_only = {"field": conn, "equals": "__connect__"}
        options = [
            {"value": "sample", "title": "A kit dataset", "text": "Ready-made data that comes with the kit.",
             "disabled": not samples, "disabled_reason": "The kit lists no dataset with a column map.",
             "fields": [{"id": "sample", "type": "select", "label": "Dataset", "value": samples[0]["value"] if samples else "",
                         "options": samples}]},
            {"value": "file", "title": "Your own data", "text": "A table in the database, or a new file or folder.",
             "fields": [{"id": "own", "type": "select", "label": "Data", "value": own_options[0]["value"], "options": own_options},
                        {"id": "path", "type": "text", "label": "File or folder (CSV, Excel, Parquet, JSON)", "placeholder": "~/Downloads/sales.xlsx", "show_if": new_only},
                        {"id": "schema", "type": "text", "label": "Save it under (optional)", "placeholder": "MY_DATA", "show_if": new_only}]},
            {"value": "source", "title": "An external source", "text": "Live data in another system, read where it is.",
             "fields": self._source_fields(connect_only)},
        ]
        # A new connection is entered one step at a time (Back / Next); its last step tests and connects.
        steps = self._steps()
        at = steps.index(self.step) if self.step in steps else 0
        last = at == len(steps) - 1
        connecting = [{"field": "kind", "equals": "source"}, connect_only]
        use = {"id": "use", "label": "Use this data", "primary": True, "busy": "Loading…"}
        items = []
        if at > 0:
            items.append({"id": "src_back", "label": "Back", "show_if": connecting, "no_secret": True})
        if not last:
            items.append({"id": "src_next", "label": "Next", "primary": True, "busy": "Reading…", "show_if": connecting, "no_secret": True})
            # Other data is used straight away; a new connection first reaches its last step.
            items += [{**use, "show_if": {"field": "kind", "in": ["sample", "file"]}},
                      {**use, "show_if": [{"field": "kind", "equals": "source"}, {"field": conn, "in": list(self.sources)}]}]
        else:
            items += [{"id": "test_source", "label": "Test connection", "busy": "Testing…", "show_if": connecting, "no_secret": True},
                      {**use, "label": "Connect and use this data", "show_if": connecting},
                      {**use, "show_if": {"field": "kind", "in": ["sample", "file"]}}]
        blocks = [head, {"t": "choice", "id": "kind", "value": "sample" if samples else "file", "options": options, "below": True,
                         "actions": items}]     # the buttons sit inside the picked option's box
        if self.done and SESSION.source is not None:
            rows = f" · {SESSION.source_rows} rows" if SESSION.source_rows else ""
            blocks.append({"t": "msg", "kind": "ok", "v": f"Using {SESSION.source_label}{rows}. Check the column map below."})
        if self.kit_said:
            blocks.append({"t": "details", "title": "What the kit said", "blocks": [{"t": "pre", "v": self.kit_said}]})
        if SESSION.code:
            blocks.append({"t": "code", "code_only": True, "title": "The code behind this step", "v": "\n".join(SESSION.code)})
        return blocks

    def on_use(self, v: dict) -> None:
        from ..actions import Var

        kind = v.get("kind") or "sample"
        SESSION.broken = None
        if not SESSION.get("workflow_id"):      # guide.start() began one; a screen shown on its own begins it here
            actions.run("data.workflow")
        if kind == "sample":
            dataset_id = str(v.get("sample") or "").strip()
            if not dataset_id:
                raise ValueError("Pick a kit dataset.")
            variable, label = self._open("data.sample", "sample_data", dataset_id=dataset_id), dataset_id
            label = next((s["label"] for s in self.samples if s["id"] == dataset_id), dataset_id)
        elif kind == "file":
            own = str(v.get("own") or "__new__")
            if own.startswith("ds:"):
                variable, label = self._open("data.approved", "own_data", dataset_id=own[3:]), own[3:]
            elif own.startswith("tbl:"):
                variable, label = self._open("data.table", "own_data", table=own[4:]), own[4:]
            else:
                path = str(v.get("path") or "").strip()
                if not path:
                    raise ValueError("Enter the path to a file or folder.")
                schema = str(v.get("schema") or "").strip() or None
                variable, label = self._open("data.own_file", "own_data", path=path, schema=schema), Path(path).expanduser().name
        else:
            schema = str(v.get(self._cf()) or "").strip()
            connected = schema == "__connect__"
            if connected:
                schema = self._connect(v)
                self.step, self.conn_n = "connection", self.conn_n + 1     # the next one starts from the list again
            table = str(v.get(self._tid(schema)) or v.get("table") or "").strip()
            source = f"{schema}.{table}" if table and "." not in table else (table or schema)
            variable, label = self._open("data.source", "source_data", source=source), source
        actions.run("data.choose", data=Var(variable))
        if SESSION.source is None:
            raise ValueError("Nothing was loaded. The kit's note is under 'What the kit said'.")
        SESSION.source_label = f"{label} ({SESSION.source.fact_table})"
        SESSION.source_rows = self.rows.get(str(SESSION.source.fact_table).upper())
        SESSION.review, SESSION.dataset = None, None
        self.done = True
        if kind == "file" or (kind == "source" and connected):     # what was just loaded or connected can be picked
            self._load_options()
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

    def _steps(self) -> list[str]:
        """The steps of a new connection, for the data source chosen: only the ones it has."""
        form = self.forms.get(self.connector or "") or {}
        needed, rest = self._groups(self.connector) if form else ([], [])
        return (["connection", "source"] + (["settings"] if self.settings_step else [])
                + (["string"] if form.get("forms") else []) + ["name"]
                + (["needed"] if needed else []) + (["optional"] if rest else []))

    def _source_fields(self, connect_only: dict) -> list[dict]:
        """An external source, one step at a time: the connections there are (and the table to read from one), or a
        new connection - the data source, its connection string where it has one, the name, what is still needed (the
        password with it), then the optional settings (a CA file, a port ...). Every question, label, default and
        choice is `exakit connect`'s own (nb.connectors, nb.connector_inputs, nb.read_connection_string)."""
        steps = self._steps()
        step = self.step if self.step in steps else "connection"
        cid = self.connector or ""
        form, read = self.forms.get(cid) or {}, self.parsed.get(cid)
        if step == "connection":
            tables = self.source_tables or {}
            fields: list[dict] = [{"id": self._cf(), "type": "select", "label": "Connection",
                                   "value": self.sources[0] if self.sources else "__connect__",
                                   "options": [{"value": x, "label": x, "hint": f"{len(tables.get(x, []))} tables" if tables.get(x) else ""}
                                               for x in self.sources] + [{"value": "__connect__", "label": "New connection…"}]}]
            for schema in self.sources:
                found, only = tables.get(schema, []), {"field": self._cf(), "equals": schema}
                fields.append({"id": self._tid(schema), "type": "select", "label": "Table", "value": found[0]["value"],
                               "options": found, "show_if": only} if found else
                              {"id": self._tid(schema), "type": "text", "label": "Table (empty: its one table, or the list of them)",
                               "placeholder": "ORDERS", "show_if": only})
            fields.append({"id": "src_new", "type": "note", "show_if": connect_only,
                           "v": "Next asks for the data source, then its details, one step at a time."})
            return fields
        # Where this is, and what was settled so far.
        titles = {"source": "Data source", "settings": "Settings", "string": "Connection string", "name": "Name", "needed": "Details",
                  "optional": "Optional settings"}
        new = steps[1:]
        so_far = [form["name"]] if form and step != "source" else []
        if form and step != "source":
            so_far += self._setting_labels(form)
        if read and step != "string":
            so_far.append(read["masked"])
        if self.src_name and step != "name":
            so_far.append(f"name {self.src_name}")
        fields = [{"id": f"src_step_{step}", "type": "note", "show_if": connect_only,
                   # Before the data source is chosen its steps are not known yet: no "of N" there.
                   "v": f"New connection · step {new.index(step) + 1}" + (f" of {len(new)}" if step != "source" else "")
                        + f" · {titles[step]}"
                        + (f" · {' · '.join(so_far)}" if so_far else "")}]
        if step == "source":
            connectors = []
            for c in self.connectors:
                connectors.append({"value": c["id"], "label": c["name"] + (" (not available yet)" if c.get("gate") else ""),
                                   "hint": c.get("summary") or ""})
                # A connector with several kinds of source in one: its settings as a tree under it, as the kit's
                # connect menu shows them (a Lakehouse's catalog, and under each the files it can read).
                for node in (self.forms.get(c["id"]) or {}).get("tree", []):
                    connectors.append({"value": self._pick(c["id"], node["set"]), "label": "\u00a0\u00a0\u00a0\u2514 " + node["label"]})
                    connectors += [{"value": self._pick(c["id"], child["set"]),
                                    "label": "\u00a0" * 8 + "\u2514 " + child["label"]} for child in node.get("children", [])]
            fields.append({"id": "connector", "type": "select", "label": "Data source",
                           "value": self._pick(cid, self.preset or {}) if cid else (connectors[0]["value"] if connectors else ""),
                           "options": connectors})
        elif step == "settings":
            for spec in self._pending(form):
                labels = spec.get("choice_labels") or spec["choices"]
                fields.append({"id": self._fid(cid, "set_" + spec["name"]), "type": "select",
                               "label": spec["label"].split(" - ")[0] + " *", "value": spec["default"] or spec["choices"][0],
                               "options": [{"value": value, "label": label} for value, label in zip(spec["choices"], labels)]})
            for said in sorted({line for spec in self._pending(form) for line in spec.get("disabled") or []}):
                fields.append({"id": self._fid(cid, "set_note"), "type": "note", "v": said})
        elif step == "string":
            how = self._fid(cid, "how")
            fields.append({"id": how, "type": "select", "label": "How to connect", "value": "string",
                           "options": [{"value": "string", "label": "Connection string", "hint": "paste it, the kit reads it"},
                                       {"value": "manual", "label": "Manual configuration", "hint": "type each detail"}]})
            fields.append({"id": self._fid(cid, "url"), "type": "text", "by": {"field": how, "equals": "string"},
                           "label": f"Connection string ({' or '.join(form['forms'][:2])})", "placeholder": form["forms"][0]})
            fields.append({"id": self._fid(cid, "hint"), "type": "note", "by": {"field": how, "equals": "string"},
                           "v": "Paste it and press Next: the kit reads it and asks only for what it does not hold."})
            fields.append({"id": self._fid(cid, "manual"), "type": "note", "by": {"field": how, "equals": "manual"},
                           "v": "Next asks for each detail: the host, the database, the account and so on."})
        elif step == "name":
            fields.append({"id": "src_name", "type": "text", "placeholder": "sales",
                           "label": self._name_label() + " * (lower case; its tables appear as VS_<NAME>)"})
        elif step == "needed":
            fields += self._groups(cid)[0]
        elif step == "optional":
            fields.append({"id": self._fid(cid, "rest"), "type": "note",
                           "v": ("Filled in from the string or the kit's default." if read else "The kit's defaults.")
                                + " Change one only to use another value."})
            fields += self._groups(cid)[1]
        if step == steps[-1]:
            said = ([f"Access the reader needs: {form['access']}."] if form.get("access") else []) + form.get("tips", [])[:1]
            if said:
                fields.append({"id": self._fid(cid, "note"), "type": "note", "v": " ".join(said)})
            if self.tip:
                fields.append({"id": "src_tip", "type": "note", "v": self.tip})
        for field in fields[1:]:
            field["show_if"] = [connect_only, field.pop("by")] if "by" in field else connect_only
        return fields

    def on_src_back(self, _v: dict) -> None:
        steps = self._steps()
        at = steps.index(self.step) if self.step in steps else 0
        self.step = steps[max(at - 1, 0)]

    def on_src_next(self, v: dict) -> None:
        """Next: check this step's answer, then show the next one. The connection string is read here, the way
        `exakit connect --url` reads it, so the steps after it ask only for what it did not give."""
        steps = self._steps()
        step = self.step if self.step in steps else "connection"
        if step == "source":
            connector, preset = self._picked(str(v.get("connector") or "").strip())
            form = self.forms.get(connector)
            if not form:
                raise ValueError("Choose the data source first.")
            if form.get("gate"):
                raise ValueError(f"{form['name']} is not available yet: {form['gate']}")
            self.connector, self.preset = connector, preset
            if form.get("tree"):
                # What this combination asks, from the kit's engine (`exakit connect lakehouse --set catalog=...`).
                form = self._settle(connector, preset)
            self.settings_step = bool(self._pending(form))
        elif step == "settings":
            form = self.forms.get(self.connector) or {}
            chosen = {spec["name"]: str(v.get(self._fid(self.connector, "set_" + spec["name"])) or spec["default"])
                      for spec in self._pending(form)}
            self.preset = {**(self.preset or {}), **chosen}
            if self._pending(self._settle(self.connector, self.preset)):
                return                                       # that choice brought a further setting: ask it here
        elif step == "string":
            manual = v.get(self._fid(self.connector, "how")) == "manual"
            text = "" if manual else str(v.get(self._fid(self.connector, "url")) or "").strip()
            if not text and not manual:
                raise ValueError("Paste the connection string, or choose Manual configuration.")
            if text:
                read = self.parsed.get(self.connector)
                if not read or read.get("text") != text:
                    self._read_string(self.connector, text)
                    self.kit_said = SESSION.said or self.kit_said
            else:
                self.parsed.pop(self.connector, None)        # no string: every input is asked
        elif step == "name":
            name = str(v.get("src_name") or "").strip().lower()
            if not re.fullmatch(r"[a-z][a-z0-9_]*", name):
                raise ValueError("Give the connection a name: lower-case letters, digits and _ (e.g. sales).")
            self.src_name = name
        elif step == "needed":
            self._source_inputs(v, needed_only=True)
        steps = self._steps()                                # the string read may have changed what is left
        self.step = steps[min(steps.index(step) + 1, len(steps) - 1)]

    @staticmethod
    def _pick(connector: str, settings: dict) -> str:
        """A row of the Data source list as one value: the connector, and the settings a tree row under it gives."""
        return "|".join([connector] + [f"{key}={value}" for key, value in settings.items()])

    @staticmethod
    def _picked(value: str) -> tuple[str, dict]:
        connector, *pairs = value.split("|")
        return connector, dict(pair.split("=", 1) for pair in pairs if "=" in pair)

    def _pending(self, form: dict) -> list[dict]:
        """The connector's setting questions the tree pick did not answer (a Lakehouse's catalog login)."""
        return [spec for spec in form.get("setting_inputs", []) if spec["name"] not in (self.preset or {})]

    def _setting_labels(self, form: dict) -> list[str]:
        chosen = self.preset or {}
        return [dict(zip(spec["choices"], spec.get("choice_labels") or spec["choices"])).get(chosen[spec["name"]], chosen[spec["name"]])
                for spec in form.get("setting_inputs", []) if spec["name"] in chosen]

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
                self.typed_storage = str(raw or "")         # the second secret: its own file, never the password's way
                if spec["name"] in required and not self.typed_storage and not needed_only:
                    missing.append(spec["label"].split(" - ")[0])
            elif spec["kind"] == "secret":
                password = str(raw or "") or password
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
    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.kit_said = ""
        self.first: dict | None = None
        self.leaks: list[str] = []
        SESSION.listen(self)
        self.refresh()

    # -- loading the proposal ---------------------------------------------------------
    def on_session(self, what: str) -> None:
        if what == "source":
            self._review()
        self.refresh()

    def _review(self) -> None:
        from ..actions import Var

        self.first, self.leaks = None, []
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
                         "leak": c in self.leaks, "avoid": _avoid(raw), "plain": bool(PLAIN_NAME.match(c)), "raw": raw})
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
        if rv.draft.status == "approved" and not role_changes and not slot_changes and not SESSION.broken:
            actions.run("map.keep")
            self.flash = {"kind": "ok", "v": f"Kept the approved choices (version {SESSION.dataset.version})."}
        else:
            self._check({**sugg, **roles}, {**drafted, **slots})
            kit_sugg = rv.suggestions()
            self._save({c: r for c, r in {**sugg, **roles}.items() if r != kit_sugg.get(c)} or None, {**drafted, **slots})
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

    def _save(self, choices: dict | None, slots: dict) -> None:
        try:
            actions.run("map.approve", choices=choices, slots=slots)
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
    approval shows up here as "approved vN, published"."""

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


def understand():
    """Step 1 in the guided view: choose the data, approve what each column means, and see it on the map of all your data."""
    from ..card import show

    return show(ChooseData(), ColumnMap(), DataMap(), docs="guides/approve-column-map")


def _publish_note(said: str) -> str:
    """Whether the approval reached the AI agents: the kit publishes the roles as column comments on a view in
    EXAKIT_SEMANTIC, which agents read over MCP, and says so (or why not) in its own lines."""
    import re

    found = re.search(r"Published as (\S+?)[:.]?(?:\s|$)", said or "")
    if found:
        return f"Published as {found.group(1)}: AI agents read the roles from it."
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
