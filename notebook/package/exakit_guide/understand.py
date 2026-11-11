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

from . import store
from .card import Screen
from .kitinfo import DATASET_TITLES
from .session import SESSION, quiet

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
# The kit's own rule (descriptor_rules.SLOT_ROLES): these three slots need exactly this role.
SLOT_REQUIRED = {"key": "key", "time": "time", "text": "text"}
# category and entity accept any role in the kit; these are the roles that make sense there (a warning, not a block).
SLOT_SENSIBLE = {"category": ["category", "identifier", "flag"], "entity": ["category", "identifier", "flag", "key"]}
SLOT_ROLES = {**{k: [v] for k, v in SLOT_REQUIRED.items()}, **SLOT_SENSIBLE}
PLAIN_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")


def _kit_samples() -> list[dict]:
    """The kit's datasets the quickstart can open (they have a descriptor)."""
    from .kitinfo import _kit_json

    status = _kit_json("status", "--json")
    loaded = list(status.get("datasets_loaded") or [])
    ids = []
    for d in loaded + ["amazon_sales", "fraud_transactions"]:
        if d in ids:
            continue
        try:
            from exakit_nb.dataset import _locate

            _locate(d)
            ids.append(d)
        except Exception:
            continue
    return [{"value": d, "label": DATASET_TITLES.get(d, d.replace("_", " ").capitalize()),
             "hint": "Loaded" if d in loaded else "Downloads the first time"} for d in ids]


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


def _plain_name(name: str) -> str:
    """The kit's own rule for file columns (own_file._read): non-word characters -> _, upper case, starts with a letter."""
    n = re.sub(r"\W", "_", str(name).strip()).upper() or "COLUMN"
    return n if re.match(r"[A-Z]", n) else f"C_{n}"


def _plain_names_view(conn, table: str) -> tuple[str, str | None]:
    """(table to use, CREATE VIEW sql or None). A table loaded with its file's own column names ("Won",
    "Opportunity ID") breaks the kit's unquoted queries; a view with plain names over it fixes that."""
    schema, name = table.split(".", 1)
    cols = [r[0] for r in conn.execute(
        f"SELECT COLUMN_NAME FROM SYS.EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA = '{schema}' AND COLUMN_TABLE = '{name}' "
        f"ORDER BY COLUMN_ORDINAL_POSITION").fetchall()]
    if not cols or all(re.fullmatch(r"[A-Z][A-Z0-9_]*", c) for c in cols):
        return table, None
    plain, seen = [], set()
    for c in cols:
        n = _plain_name(c)
        while n in seen:
            n += "_2"
        seen.add(n)
        plain.append(n)
    view = f'EXAKIT_PREPARED."{schema}__{name}__PLAIN"'
    select = ",\n       ".join(f'"{c.replace(chr(34), chr(34) * 2)}" AS {n}' for c, n in zip(cols, plain))
    sql = f"CREATE OR REPLACE VIEW {view} AS\nSELECT {select}\nFROM {schema}.\"{name}\""
    conn.execute("CREATE SCHEMA IF NOT EXISTS EXAKIT_PREPARED")
    conn.execute(sql)
    return f'EXAKIT_PREPARED.{schema}__{name}__PLAIN', sql


def _free_name(target: Path, tag: str) -> Path:
    """target itself if it doesn't exist yet, else target with a tag (never overwrite someone's file)."""
    if not target.exists():
        return target
    for i in range(1, 100):
        alt = target.with_name(f"{target.stem}{tag}{'' if i == 1 else f'-{i}'}{target.suffix}")
        if not alt.exists():
            return alt
    raise ValueError(f"Too many converted copies next to {target.name}. Remove some and try again.")


def _utf8_copy(path: Path) -> tuple[Path | None, str]:
    """The kit reads strict UTF-8. A CSV saved in another encoding (or with Windows line ends and a BOM that
    trip some readers) gets a clean UTF-8 copy beside it; the original stays untouched."""
    raw = path.read_bytes()
    try:
        raw.decode("utf-8")
        return None, ""
    except UnicodeDecodeError:
        pass
    for enc in ("cp1252", "latin-1"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    out = _free_name(path.with_name(path.stem + ".utf8" + path.suffix), "")
    out.write_text(text.replace("\r\n", "\n"), encoding="utf-8")
    return out, f"{path.name} wasn't saved as UTF-8 (the kit needs that), so a UTF-8 copy, {out.name}, was loaded instead."


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
# The kinds of source `exakit connect` takes (setup/virtual-schemas/catalog.json), as the card offers them.
CONNECTORS = [{"value": v, "label": l} for v, l in (
    ("postgresql", "PostgreSQL"), ("mysql", "MySQL"), ("sqlserver", "SQL Server"), ("oracle", "Oracle"),
    ("snowflake", "Snowflake"), ("bigquery", "Google BigQuery"), ("databricks", "Databricks"),
    ("s3", "Amazon S3"), ("azure-blob", "Azure Blob Storage"), ("lakehouse", "Lakehouse (Iceberg on AWS Glue)"),
    ("iceberg-rest", "Iceberg REST catalog"), ("unity", "Unity Catalog"), ("mongodb", "MongoDB"))]


class ChooseData(Screen):
    kind = "card"

    def __init__(self) -> None:
        super().__init__()
        self.samples: list[dict] = []
        self.own: list[dict] = []
        self.sources: list[str] = []
        self.kit_said = ""
        self.done = False
        self.loading = True
        SESSION.listen(self)
        self.refresh()
        import threading

        threading.Thread(target=self._load_options, daemon=True).start()

    def _load_options(self) -> None:
        """What can be picked: kit datasets, your data already loaded, connected sources (read-only)."""
        try:
            self.samples = _kit_samples()
        except Exception:
            self.samples = []
        try:
            import exakit.nb as nb

            conn = SESSION.connection()
            self.own = store.own_datasets(conn)
            with quiet():
                frame = nb.connected_sources(conn)
            self.sources = [str(x) for x in frame["SCHEMA_NAME"]]
        except Exception:
            pass
        self.loading = False
        self.refresh()
        SESSION.release()

    def build(self) -> list[dict]:
        head = {"t": "head", "kicker": KICKER, "title": "Choose your data",
                "sub": "Pick what you want to work on. You can change it at any time."}
        if self.loading:
            return [head, {"t": "empty", "v": "Looking at what's available…"}]
        default = next((s["value"] for s in self.samples if s["value"] == "amazon_sales"),
                       self.samples[0]["value"] if self.samples else "")
        own_options = [{"value": o["value"], "label": o["label"]} for o in self.own] + [{"value": "__new__", "label": "Load a new file…"}]
        new_only = {"field": "own", "equals": "__new__"}
        connect_only = {"field": "src_schema", "equals": "__connect__"}
        options = [
            {"value": "sample", "title": "A kit dataset", "text": "Ready-made data that comes with the kit.",
             "fields": [{"id": "sample", "type": "select", "label": "Dataset", "value": default, "options": self.samples}]},
            {"value": "file", "title": "Your own data",
             "text": (f"{len(self.own)} already in the database, or load a new file." if self.own
                      else "A CSV, Excel, Parquet or JSON file, or a folder of them."),
             "fields": [{"id": "own", "type": "select", "label": "Data", "value": own_options[0]["value"], "options": own_options},
                        {"id": "path", "type": "text", "label": "File or folder (CSV, Excel, Parquet, JSON)", "placeholder": "~/Downloads/sales.xlsx", "show_if": new_only},
                        {"id": "schema", "type": "text", "label": "Save it under (optional)", "placeholder": "MY_DATA", "show_if": new_only}]},
            {"value": "source", "title": "An external source",
             "text": (f"Live data from another system, read where it is. {len(self.sources)} connected, or connect another."
                      if self.sources else "Live data from another system, read where it is: connect one here."),
             "fields": [{"id": "src_schema", "type": "select", "label": "Source",
                         "value": self.sources[0] if self.sources else "__connect__",
                         "options": [{"value": x, "label": x} for x in self.sources]
                                    + [{"value": "__connect__", "label": "Connect a new source…"}]},
                        {"id": "table", "type": "text", "label": "Table (empty: list its tables)", "placeholder": "ORDERS"},
                        {"id": "connector", "type": "select", "label": "Kind of source", "value": "postgresql",
                         "options": CONNECTORS, "show_if": connect_only},
                        {"id": "src_name", "type": "text", "label": "Name for it (becomes VS_<NAME>)", "placeholder": "sales",
                         "show_if": connect_only},
                        {"id": "src_url", "type": "text", "label": "Connection string, without the password",
                         "placeholder": "postgres://reader@db.example.com:5432/shop", "show_if": connect_only},
                        {"id": "src_password", "type": "password", "label": "Password (sent to the kit only, never shown or saved here)",
                         "show_if": connect_only}]},
        ]
        blocks = [head, {"t": "choice", "id": "kind", "value": "sample", "options": options},
                  {"t": "actions", "items": [{"id": "use", "label": "Use this data", "primary": True, "busy": "Loading…"}]}]
        if self.done and SESSION.source is not None:
            rows = f" · {SESSION.source_rows:,} rows" if SESSION.source_rows is not None else ""
            blocks.append({"t": "msg", "kind": "ok", "v": f"Using {SESSION.source_label}{rows}. Check the column map below."})
        if self.kit_said:
            blocks.append({"t": "details", "title": "What the kit said", "blocks": [{"t": "pre", "v": self.kit_said}]})
        if SESSION.code:
            blocks.append({"t": "code", "code_only": True, "title": "The kit calls behind this step", "v": "\n".join(SESSION.code)})
        return blocks

    def on_use(self, v: dict) -> None:
        import exakit.nb as nb
        from exakit_nb.own_file import LoadedTable

        kind = v.get("kind") or "sample"
        conn = SESSION.connection()
        note = None
        with quiet() as out:
            SESSION.workflow_id = nb.workflow("data-scientist-quickstart")
            nb.check_connection(conn)
            if kind == "sample":
                ds_id = str(v.get("sample") or "").strip()
                if not ds_id:
                    raise ValueError("Pick a kit dataset.")
                SESSION.broken = None
                try:
                    source = nb.load_sample(conn, ds_id)
                except ValueError as exc:
                    # The saved column map can't be used (for example, what to predict isn't 0/1).
                    # Open the table itself so the column map can be fixed here.
                    table = store.current(ds_id).get("table")
                    if not table:
                        raise
                    source = LoadedTable(ds_id, table, Path("."))
                    SESSION.broken = {"id": ds_id, "reason": str(exc).splitlines()[0]}
                code, label = f'data = nb.load_sample(connection, "{ds_id}")', DATASET_TITLES.get(ds_id, ds_id)
            elif kind == "file":
                own = str(v.get("own") or "__new__")
                if own.startswith("ds:"):
                    ds_id = own[3:]
                    try:
                        source = nb.dataset(conn, ds_id)
                        code, label = f'data = nb.dataset(connection, "{ds_id}")', ds_id
                    except Exception as exc:
                        # An approved map the kit can't read back, because the table keeps its file's own column
                        # names ("Won"); fall back to a view with plain names over the same table.
                        table = (store.current(ds_id) or {}).get("table")
                        if not table or "." not in table or "not found" not in str(exc):
                            raise
                        use, made = _plain_names_view(conn, table)
                        if not made and use == table:
                            raise
                        ds_id = re.sub(r"[^a-z0-9]+", "_", use.lower()).strip("_")
                        source = LoadedTable(ds_id, use, Path("."))
                        note = (f"{table} has column names with spaces or small letters, which the kit's queries can't read. "
                                f"The guided view uses a view with plain names, {use}. Your table is unchanged.")
                        code, label = f'data = LoadedTable("{ds_id}", "{use}", Path("."))', table
                elif own.startswith("tbl:"):
                    table = own[4:]
                    ds_id = re.sub(r"[^a-z0-9]+", "_", table.lower()).strip("_")
                    use, made = _plain_names_view(conn, table)
                    if made:   # its own id, so an earlier attempt on the raw table (other column names) can't mix in
                        ds_id = re.sub(r"[^a-z0-9]+", "_", use.lower()).strip("_")
                    if made:
                        note = (f"{table} has column names with spaces or small letters, which the kit's queries can't read. "
                                f"The guided view made a view with plain names, {use}, and uses that. Your table is unchanged.")
                        SESSION.log(f"# view with plain column names over {table}:\n{made}")
                    source = LoadedTable(ds_id, use, Path("."))
                    code, label = f'data = LoadedTable("{ds_id}", "{use}", Path("."))   # a table already in the database', table
                else:
                    path = str(v.get("path") or "").strip()
                    if not path:
                        raise ValueError("Enter the path to a file or folder.")
                    if not Path(path).expanduser().exists():
                        raise ValueError(f"Couldn't find {path}. Check the path and try again.")
                    schema, note = store.safe_schema(conn, v.get("schema"))
                    load_path = path
                    if Path(path).suffix.lower() in (".xlsx", ".xlsm"):
                        # The kit's loader takes CSV, Parquet and JSON: turn the Excel sheet into a CSV beside it first.
                        from .xlsx import to_csv

                        made = to_csv(path, out=_free_name(Path(path).expanduser().with_suffix(".csv"), ".from-excel"))
                        load_path = made["csv"]
                        bits = [f"Turned the Excel sheet “{made['sheet']}” into {Path(made['csv']).name} "
                                f"({made['rows']:,} rows, {made['columns']} columns) and loaded that."]
                        if made["dates"]:
                            bits.append(f"Excel day numbers in {', '.join(made['dates'])} became real dates.")
                        if made["other_sheets"]:
                            bits.append(f"Other sheets were not loaded: {', '.join(made['other_sheets'])}.")
                        note = " ".join(bits + ([note] if note else []))
                        SESSION.log(f'exakit_guide.xlsx.to_csv("{path}")   # -> {made["csv"]}')
                    if Path(load_path).suffix.lower() in (".csv", ".txt", ".tsv"):
                        fixed, why = _utf8_copy(Path(load_path).expanduser())
                        if fixed:
                            load_path = str(fixed)
                            note = " ".join(x for x in (note, why) if x)
                    source = nb.load_own_file(load_path, schema, conn=conn)
                    code, label = f'data = nb.load_own_file("{load_path}", "{schema}", conn=connection)', Path(path).expanduser().name
            else:
                table = str(v.get("table") or "").strip()
                schema = str(v.get("src_schema") or "").strip()
                if schema == "__connect__":
                    schema = self._connect(v)
                if not table:
                    # The source alone: its one table, or the kit stops with the list of them - pick one, then
                    # Use this data again.
                    table = schema
                elif "." not in table and schema:
                    table = f"{schema}.{table}"
                source = nb.load_source(conn, table)
                code, label = f'data = nb.load_source(connection, "{table}")', table
        self.kit_said = out.text
        if source is None:
            raise ValueError("Nothing was loaded. The kit's note is under 'What the kit said'.")
        SESSION.log("import exakit.nb as nb", "connection = nb.connect()", 'workflow_id = nb.workflow("data-scientist-quickstart")', code)
        SESSION.source, SESSION.source_label = source, f"{label} ({source.fact_table})"
        SESSION.review, SESSION.dataset = None, None
        try:
            SESSION.source_rows = int(conn.execute(f"SELECT COUNT(*) FROM {source.fact_table}").fetchone()[0])
        except Exception:
            SESSION.source_rows = None
        self.done = True
        if note:
            self.flash = {"kind": "info", "v": note}
        if kind == "file":
            self.own = store.own_datasets(conn)
        SESSION.changed("source", self)

    def _connect(self, v: dict) -> str:
        """Connect an external source with the kit's own `exakit connect` (nb.connect_source): the password goes to it
        on standard input, never into a cell, a log or this card. Returns the new schema (VS_<NAME>)."""
        import exakit.nb as nb

        connector = str(v.get("connector") or "").strip()
        name = str(v.get("src_name") or "").strip().lower()
        url = str(v.get("src_url") or "").strip()
        if not (connector and name and url):
            raise ValueError("To connect a source, choose its kind, give it a name and paste its connection string.")
        typed = str(v.get("src_password") or "")
        with quiet() as out:
            # The card's box answers the kit's own password question (a source without one: Enter, empty).
            schema = nb.connect_source(connector, name, url=url, secret=lambda _question: typed, show=False)
        self.kit_said = getattr(out, "text", "") or self.kit_said
        SESSION.log(f'nb.connect_source("{connector}", "{name}", url="{url}")   # asks the password in a hidden box')
        if schema and schema not in self.sources:
            self.sources.append(schema)
        return schema

    def on_session(self, what: str) -> None:
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
        import exakit.nb as nb

        self.first, self.leaks = None, []
        with quiet() as out:
            SESSION.review = nb.review_roles(SESSION.connection(), SESSION.source)
        self.kit_said = out.text
        SESSION.log("review = nb.review_roles(connection, data)")
        try:
            with quiet():
                draft = SESSION.review.dataset(draft_ok=True)
                self.leaks = nb.leakage_check(SESSION.connection(), draft, show=False)
        except Exception:
            self.leaks = []
        if SESSION.review.draft.status == "approved":
            try:
                with quiet():
                    SESSION.dataset = SESSION.review.dataset()
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
        for h in store.versions(draft.id):   # what the kit measured before someone overrode it ("set by you")
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
        hist = store.versions(rv.draft.id)
        number = store.current(rv.draft.id).get("version")
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
        hist = store.versions(ds_id)
        number = SESSION.dataset.version if SESSION.dataset is not None else store.current(ds_id).get("version")
        cur = next((h for h in hist if h["version"] == number), None)
        first = hist[0] if hist else None
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
        out.append({"t": "next", "v": "Next: explore and predict", "path": "starter-kit-notebooks/data-scientist/01_explore.ipynb"})
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
            with quiet():
                SESSION.dataset = rv.dataset()
            SESSION.log("dataset = review.dataset()")
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
        self.kit_said = ""      # this approval's own lines: _publish_note reads them
        try:
            with quiet() as out:
                SESSION.review.approve(choices, slots)
                SESSION.dataset = SESSION.review.dataset()
        except ValueError as exc:
            raise ValueError(_plain_kit_error(str(exc))) from exc
        self.kit_said = (self.kit_said + "\n" + out.text).strip()
        SESSION.log(f"dataset = review.approve({choices!r}, {slots!r})")

    def on_revert(self, _v: dict) -> None:
        ds_id = SESSION.dataset.id if SESSION.dataset is not None else SESSION.review.draft.id
        hist = store.versions(ds_id)
        if not hist:
            raise ValueError("There is no earlier version to go back to.")
        self._restore(hist[0])

    def on_restore(self, v: dict) -> None:
        ds_id = SESSION.dataset.id if SESSION.dataset is not None else SESSION.review.draft.id
        want = int(v.get("restore_to") or 0)
        target = next((h for h in store.versions(ds_id) if h["version"] == want), None)
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

            from .card import _logger

            _logger().error("first look failed: %r\n%s", exc, traceback.format_exc())
            lines = [l for l in str(exc).splitlines() if l.strip()]
            why = lines[0][:200] if lines else exc.__class__.__name__
            self.first = {"error": f"The first look couldn't be drawn with these choices ({why}). The details are in the guided-view log."}

    def _first_result(self) -> None:
        """The quickstart's first result: rows per group, with the outcome's rate when there is one."""
        import exakit.nb as nb

        ds = SESSION.dataset
        conn = SESSION.connection()
        missing = {m["role"]: m["reason"] for m in ds.missing}
        group_role, group_col = ds.group_by()
        has_label = ds.has("label") and group_role != "label"
        group_h, count_h = nb.name(group_col), nb.count_name(ds)
        pct_h = nb.name(ds.col("label"), "PCT") if has_label else None
        rate_sql = f",\n       ROUND(100 * AVG({ds.col('label')}), 1) AS {pct_h}" if pct_h else ""
        sql = (f"SELECT {group_col} AS {group_h},\n       COUNT(*) AS {count_h}{rate_sql}\n"
               f"FROM {ds.fact_table}\nGROUP BY {group_col}\nORDER BY {count_h} DESC\nLIMIT 10")
        with quiet():
            frame = nb.sql(conn, sql)
            overall = nb.sql(conn, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({ds.col('label')}), 1) AS PCT FROM {ds.fact_table}") if pct_h else None
            note = nb.note_groups(frame, ds, group_h, count_h, pct_h,
                                  overall=(overall["N"][0], overall["PCT"][0]) if pct_h else None)
        SESSION.log(f"first_rows = nb.sql(connection, '''{sql}''')")
        label_name = (ds.col("label") or "").strip('"').split(".")[-1] if has_label else ""
        if pct_h:
            items = [{"label": "(no value)" if r[group_h] is None else str(r[group_h]), "value": float(r[pct_h] or 0) / 100, "rows": int(r[count_h])}
                     for _, r in frame.iterrows() if int(r[count_h]) >= 30]   # the kit's rule: below 30 rows a % isn't trustworthy
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
        import exakit.nb as nb

        try:
            with quiet():
                found = nb.data_map(SESSION.connection())
            self.rows = [[r["origin_label"], r["table"], r["rows_shown"], r["columns"], r["map"], r["summary"]]
                         for r in found.table_rows]
            self.links = [[f"{k['from_table']}.{k['from_column']}", f"{k['to_table']}.{k['to_column']}", k["kind"],
                           k["origins"]] for k in found.link_rows]
            self.error = None
            SESSION.log("nb.data_map(connection)")
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
        blocks.append({"t": "code", "code_only": True, "title": "The kit call behind this card", "v": "nb.data_map(connection)"})
        return blocks

    def on_reload(self, _v: dict) -> None:
        self.loading = True
        self._load()

    def on_session(self, what: str) -> None:
        if what in ("source", "dataset"):
            import threading

            self.loading = True
            self.refresh()
            threading.Thread(target=self._load, daemon=True).start()


def understand():
    """Step 1 in the guided view: choose the data, approve what each column means, and see it on the map of all your data."""
    from .card import show

    return show(ChooseData(), ColumnMap(), DataMap())


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
