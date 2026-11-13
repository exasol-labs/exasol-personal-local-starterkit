"""Semantic views from a notebook: Exasol Semantic Views models over any of your data.

    model = nb.semantic_model(connection, "sales_360",
                              tables=["AMAZON_SALES.ORDER_LINES", "MY_DATA.TARGETS", "VS_LOGISTICS.COURIER_DAILY"],
                              links=["AMAZON_SALES.ORDER_LINES.STATE=VS_LOGISTICS.STATE_LOGISTICS.STATE"],
                              preview=True)            # what it would build, and what the AI proposes; nothing written
    model = model.publish()                             # build it in the database (Semantic Views installed if needed)
    nb.find_links(connection, ["AMAZON", "VS_LOGISTICS", "MY_DATA"])     # links across sources, from the values
    found = nb.find_links(connection, tables=["AMAZON_SALES.ORDER_LINES", "AMAZON_SALES.RETURNS", "MY_DATA.TARGETS"])
    nb.semantic_model(connection, "sales_360", tables=[...], links=found["links"],        # links with their evidence
                      table_notes={"MY_DATA.TARGETS": "The monthly sales target per state."})
    nb.semantic_model(connection, "all_data", schemas=["AMAZON", "VS_LOGISTICS", "MY_DATA"], find=True)
    nb.semantic_models(connection)                      # every model in the database
    nb.refresh_semantic(connection, "sales_360")        # rebuild it after a column map or a link changed
    nb.semantic_sql(connection, "SELECT order_month, total_revenue FROM SEM_SALES_360.ORDER_LINES GROUP BY order_month")

A model spans as many schemas as you give it: sample datasets, your own loaded files and folders, and any number of
connected external sources (virtual schemas, read live). Every table needs an approved column map first: its roles
decide the model's fields - time, category and flag columns become dimensions, measures become facts with total_ and
average_ metrics, every table gets a row count. The approved links of each schema are used, and ``links`` adds the
ones across schemas (SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY, the key side unique).

With ``ai=True`` (the default when a model is configured: nb.model_setup) your model proposes business names,
comments and synonyms for every field and the metrics people will ask for - from names, types, grains, column notes
and a category's top values only, never a row and never a sensitive column. Every proposed metric is checked before
it is offered, and the product validates it again when it is applied: a refused one is skipped and named.

The work is the kit's describe service (the one ``exakit describe --model`` runs), loaded from the kit copy. A model
the kit builds is marked as such; one of the same name somebody else made is never touched.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from html import escape
from typing import Any

__all__ = ["SemanticModel", "find_links", "model_notes", "refresh_semantic", "semantic_model", "semantic_models", "semantic_sql"]

ADDON = "semantic-views"


def _service():
    from .describe import describe_service

    service = describe_service()
    if service is None:
        raise RuntimeError("The kit's describe service was not found (no kit copy beside this Python). Use the command "
                           "line: exakit describe --model NAME --table SCHEMA.TABLE ...")
    return service


def _installed(conn) -> bool:
    try:
        conn.execute("SELECT DISPLAY_VERSION FROM SEMANTIC_CATALOG.PRODUCT_VERSION")
        return True
    except Exception:
        return False


def ensure_semantic_views(conn, show: bool = True) -> None:
    """Install Exasol Semantic Views into the database when it is not there (``exakit marketplace semantic-views``)."""
    if _installed(conn):
        return
    from .kit_commands import addon_ready

    addon_ready(ADDON, start=False, show=show)


def _model_configured() -> bool:
    import os

    return bool(os.environ.get("EXAKIT_MODEL_ID", "").strip() and os.environ.get("EXAKIT_PROVIDER_BASE_URL", "").strip())


@dataclass
class SemanticModel:
    """A semantic model: what it holds (``spec``), what the AI proposed, and - once published - its views."""

    name: str
    tables: list[str]
    links: list
    description: str | None
    ai: bool
    found: dict[str, Any] = field(default_factory=dict)
    conn: Any = None
    schemas: list[str] = field(default_factory=list)
    find: bool = False
    table_notes: dict[str, str] = field(default_factory=dict)

    @property
    def status(self) -> str:
        return str(self.found.get("status") or "")

    @property
    def views(self) -> list[str]:
        return list(self.found.get("views") or [])

    @property
    def spec(self) -> dict[str, Any]:
        return dict(self.found.get("spec") or {})

    @property
    def fields(self):
        """One row per dimension and metric: view, kind, name, display name, what it is."""
        rows = []
        for obj in self.spec.get("objects") or []:
            for kind, items in (("dimension", obj["dimensions"]), ("metric", obj["metrics"])):
                for item in items:
                    rows.append({"view": obj["name"], "kind": kind, "name": item["name"],
                                 "display": item.get("display"), "about": item.get("comment"),
                                 "synonyms": ", ".join(item.get("synonyms") or [])})
        try:
            import pandas as pd

            return pd.DataFrame(rows)
        except ImportError:
            return rows

    def publish(self, conn=None) -> "SemanticModel":
        """Build the previewed model in the database (the AI's proposal is asked again only if none was kept)."""
        return semantic_model(conn or self.conn, self.name, self.tables, self.links, ai=self.ai,
                              description=self.description, schemas=self.schemas, find=self.find,
                              table_notes=self.table_notes)

    def __str__(self) -> str:
        found = self.found
        lines = [found.get("summary") or self.name]
        for link in found.get("links") or []:
            why = (link.get("evidence") or {}).get("evidence_text") or (link.get("evidence") or {}).get("note") or ""
            lines.append(f"  link {link['from']} -> {link['to']}" + (f": {why}" if why else ""))
        ai = found.get("ai") or {}
        if ai.get("error"):
            lines.append(f"AI: {ai['error']}")
        lines += [f"AI proposed: {' '.join(ddl.split())[:200]}" for ddl in found.get("proposed_metrics") or []]
        lines += [f"AI proposal refused: {r}" for r in ai.get("refused") or []]
        if self.status == "published":
            lines.append(f"Published: {', '.join(self.views)}")
            lines += [f"Note: {n}" for n in found.get("notes") or []]
            lines += [f"Warning: {w}" for w in found.get("warnings") or []]
            lines.append(f"Ask it with nb.semantic_sql(connection, \"SELECT ... FROM {self.views[0] if self.views else '...'} "
                         "GROUP BY ...\"), or from an AI client through the Exasol MCP server.")
        else:
            lines.append("Preview only: nothing was written. Publish it: model.publish()")
        return "\n".join(lines)

    __repr__ = __str__

    def _repr_html_(self) -> str:
        body = "".join(f"<div>{escape(line)}</div>" for line in str(self).splitlines())
        return f'<div style="font:13px/1.5 system-ui,sans-serif;white-space:pre-wrap">{body}</div>'


def find_links(conn, schemas: list[str] | None = None, *, tables: list[str] | None = None, ai: bool | None = None,
               check: list[str] | None = None, show: bool = True) -> dict[str, Any]:
    """The links between tables of different schemas - sample data, your files, external sources - where no foreign
    key says so and the names differ, found from the values, each with its evidence (``exakit describe --links``).
    ``tables`` (SCHEMA.TABLE) searches a selection of tables instead of whole schemas, and then two tables of the
    same schema are compared too.
    Bounded reads only; nothing is written. ``ai`` (default: when a model is configured) lets your model propose more
    pairs from names, types and notes; ``check`` is pairs you have in mind ("S.T.COL=S.T.KEY"); each is checked against
    the data and comes back with its evidence or under "rejected". Returns {links, partial, ...}; a link's
    ``confidence`` is "low" for plain numbers, which match by chance: confirm those before using them."""
    service = _service()
    use_ai = _model_configured() if ai is None else bool(ai)
    if not schemas and not tables:
        raise ValueError("Name the schemas, or tables=[...], to find the links between.")
    found = service.find_links(conn, list(schemas or []), ai=use_ai, check=list(check or []), tables=list(tables or []) or None)
    if show:
        print(service.links_text(found))
    return found


def semantic_model(conn, name: str, tables: list[str] | None = None, links: list | None = None, *,
                   schemas: list[str] | None = None, find: bool = False, ai: bool | None = None,
                   description: str | None = None, preview: bool = False,
                   table_notes: dict[str, str] | None = None) -> SemanticModel:
    """Build (or with ``preview=True`` only show) an Exasol Semantic Views model over ``tables`` - SCHEMA.TABLE of any
    schemas, each with an approved column map - joined along each schema's approved links and ``links``
    (SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY). ``schemas`` takes every table of those schemas that has an approved column
    map; ``find=True`` finds the links between the schemas from their values (nb.find_links) and uses the ones the
    data backs. A link may also be one of nb.find_links' own ({"from", "to", ...}): its evidence is stored in the
    model with it, and a "note" you add says in your words why the two belong together. ``table_notes`` ({SCHEMA.TABLE:
    text}) says what each table is. ``ai`` (default: when a model is configured) lets your model propose the
    fields' business names, synonyms and extra metrics. Publishing installs Semantic Views when the database does not
    have it, replaces the model the kit built before under that name, and grants it to the read-only MCP user."""
    from .workflow import log_event

    service = _service()
    use_ai = _model_configured() if ai is None else bool(ai)
    if not preview:
        ensure_semantic_views(conn)
    tables = list(tables or [])
    found = service.semantic_model(conn, name, tables, list(links or []), ai=use_ai, dry_run=preview,
                                   description=description, schemas=list(schemas or []), discover=bool(find),
                                   table_notes=dict(table_notes or {}))
    model = SemanticModel(name, tables, list(links or []), description, use_ai, found, conn,
                          schemas=list(schemas or []), find=bool(find), table_notes=dict(table_notes or {}))
    if not preview:
        log_event("semantic.model", model=found.get("model"), views=found.get("views"), tables=list(tables))
    return model


def semantic_models(conn):
    """Every semantic model in the database: name, published schema, whether the kit built it (and can refresh it)."""
    rows = _service().list_models(conn)
    try:
        import pandas as pd

        return pd.DataFrame(rows)
    except ImportError:
        return rows


def refresh_semantic(conn, name: str) -> dict[str, Any]:
    """Rebuild a model the kit published, with the column maps and links approved since (``exakit describe --model
    NAME --refresh``). Approving a column map refreshes every model it is in by itself."""
    ensure_semantic_views(conn)
    found = _service().refresh_model(conn, name)
    print(f"Refreshed {found.get('view')}")
    for line in found.get("warnings") or []:
        print(f"Warning: {line}")
    return found


def semantic_sql(conn, query: str):
    """Run Semantic SQL (a query over a published semantic view: its metrics with GROUP BY its dimensions) on this
    connection: Semantic SQL is switched on for the session first. A read only, shown before its result."""
    from . import sql

    conn.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
    return sql(conn, query)


NOTES_RULES = ("You document a data model for people who do not know these tables. From each table's name and its "
               "columns (name, type and, where known, role), write: tables - one plain sentence of at most 20 words "
               "saying what one row of the table is; links - for each link given, one plain sentence saying why the "
               "two belong together; name - a short lower-case name for the model with underscores (letters, digits, "
               "_), such as sales_360; about - one sentence saying what the whole model is about. Do not guess "
               "numbers or values you were not shown. Answer as JSON only: {\"tables\": {\"SCHEMA.TABLE\": \"...\"}, "
               "\"links\": {\"FROM=TO\": \"...\"}, \"name\": \"...\", \"about\": \"...\"}.")


def model_notes(conn, tables: list[str], links: list | None = None, *, show: bool = True) -> dict[str, Any]:
    """Ask the AI model set up for the kit to say what a model's parts are, in a sentence each: {"tables":
    {SCHEMA.TABLE: text}, "links": {"FROM=TO": text}, "name": a name for the model, "about": what it is about}. It
    is shown each table's name and its columns' names, types and roles - never a row - and the links as you give them
    ("S.T.COL=S.T.KEY", or nb.find_links' own). Only an answer about a table or a link you named is kept. Nothing is
    written: pass them on (nb.semantic_model(..., table_notes=..., description=...)). Raises ValueError when no model
    is set up."""
    import json
    import re

    from . import model_config, tracing
    from .data_map import data_map
    from .model_config import sampling

    config = model_config.resolve()
    if config is None:
        raise ValueError("No AI model is set up: nb.model_setup() says how (the Home card's AI model row does it).")
    wanted = [str(t).upper() for t in tables]
    pairs = [f"{l['from']}={l['to']}".upper() if isinstance(l, dict) else str(l).upper() for l in links or []]
    found = data_map(conn)
    shown: dict[str, list[dict[str, str]]] = {t: [] for t in wanted}
    for column in found.column_rows:
        table = str(column["table"]).upper()
        if table in shown:
            shown[table].append({"column": column["column"], "type": column["type"], **({"role": column["role"]} if column.get("role") else {})})
    client = model_config.create_client(config, traced=tracing())
    try:
        answer = client.chat.completions.create(model=config.model_id, messages=[
            {"role": "system", "content": "Return only one JSON object. No Markdown."},
            {"role": "user", "content": json.dumps({"rules": NOTES_RULES, "tables": shown, "links": pairs})}], **sampling())
    finally:
        try:
            client.close()
        except Exception:                                   # noqa: BLE001 - closing is a courtesy
            pass
    text = answer.choices[0].message.content or ""
    match = re.search(r"\{.*\}", text, re.S)
    try:
        said = json.loads(match.group(0)) if match else {}
    except ValueError:
        said = {}
    said = said if isinstance(said, dict) else {}
    line = lambda value, limit: " ".join(str(value or "").split())[:limit]
    by_upper = lambda value: {str(k).upper(): v for k, v in value.items()} if isinstance(value, dict) else {}
    name = re.sub(r"[^a-z0-9_]+", "_", line(said.get("name"), 60).lower()).strip("_")
    notes = {"tables": {t: line(by_upper(said.get("tables")).get(t), 300) for t in wanted if line(by_upper(said.get("tables")).get(t), 300)},
             "links": {p: line(by_upper(said.get("links")).get(p), 300) for p in pairs if line(by_upper(said.get("links")).get(p), 300)},
             "name": name if re.fullmatch(r"[a-z][a-z0-9_]{0,40}", name or "") else "", "about": line(said.get("about"), 300)}
    if show:
        print(f"Asked {config.model_id} about {len(wanted)} tables and {len(pairs)} links (names, types and roles; no rows).")
        for table, about in notes["tables"].items():
            print(f"  {table}: {about}")
        for pair, why in notes["links"].items():
            print(f"  {pair}: {why}")
        if notes["name"] or notes["about"]:
            print(f"  model {notes['name'] or '(no name)'}: {notes['about']}")
    return notes
