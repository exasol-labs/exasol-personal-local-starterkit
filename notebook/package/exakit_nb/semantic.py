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

__all__ = ["SemanticModel", "adopt_view", "data_map_inputs", "draft_data_map", "validate_data_map", "explain_metric", "data_map_versions", "restore_data_map", "store_totals", "refresh_totals", "totals_status", "list_totals", "freeze_view", "frozen_views", "governance_mode", "derived_composition", "query_logging", "query_history", "propose_change", "suggestions", "review_change", "import_databricks", "import_osi", "compile_request", "find_links", "column_maps_in_model", "fuse", "fusion", "fusion_document", "model_fields", "restore_column_maps", "model_notes",
           "refresh_semantic", "semantic_model", "semantic_models", "semantic_sql", "verified_questions", "verify_question"]

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
    def sql(self) -> list[str]:
        """The statements publishing runs (a preview's), or the ones that ran: SQL to read, copy and edit."""
        return list(self.found.get("sql") or [])

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
            if self.sql:
                lines += ["", f"The {len(self.sql)} statements publishing runs:", ""] + [statement + ";" for statement in self.sql]
        return "\n".join(lines)

    __repr__ = __str__

    def _repr_html_(self) -> str:
        body = "".join(f"<div>{escape(line)}</div>" for line in str(self).splitlines())
        return f'<div style="font:13px/1.5 system-ui,sans-serif;white-space:pre-wrap">{body}</div>'


def find_links(conn, schemas: list[str] | None = None, *, tables: list[str] | None = None, ai: bool | None = None,
               check: list[str] | None = None, show: bool = True, rules: dict[str, Any] | None = None) -> dict[str, Any]:
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
    found = service.find_links(conn, list(schemas or []), ai=use_ai, check=list(check or []), tables=list(tables or []) or None,
                               rules=rules or None)
    if show:
        print(service.links_text(found))
    return found


def semantic_model(conn, name: str, tables: list[str] | None = None, links: list | None = None, *,
                   schemas: list[str] | None = None, find: bool = False, ai: bool | None = None,
                   description: str | None = None, preview: bool = False,
                   table_notes: dict[str, str] | None = None, sql: list[str] | str | None = None,
                   grains: dict[str, str] | None = None, starts: list[str] | None = None, metrics: list | None = None,
                   instructions: list | None = None, replace_links: bool = False,
                   hidden: dict[str, list[str]] | None = None) -> SemanticModel:
    """Build (or with ``preview=True`` only show) an Exasol Semantic Views model over ``tables`` - SCHEMA.TABLE of any
    schemas, each with an approved column map - joined along each schema's approved links and ``links``
    (SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY). ``schemas`` takes every table of those schemas that has an approved column
    map; ``find=True`` finds the links between the schemas from their values (nb.find_links) and uses the ones the
    data backs. A link may also be one of nb.find_links' own ({"from", "to", ...}): its evidence is stored in the
    model with it, and a "note" you add says in your words why the two belong together. ``table_notes`` ({SCHEMA.TABLE:
    text}) says what each table is. ``ai`` (default: when a model is configured) lets your model propose the
    fields' business names, synonyms and extra metrics.

    What Semantic Views needs from you: ``grains`` ({SCHEMA.TABLE: "one row is one order line"}), each link's "type"
    (MANY_TO_ONE, or ONE_TO_ONE when both sides hold each value once), ``starts`` (the tables questions start from),
    ``metrics`` ([{"table", "name", "how": "sum"|"count"|"average", "column", "where": {"column", "values"}, "about"}])
    ``instructions`` (rules for AI tools, as text or {"table", "text"}) and ``hidden`` ({SCHEMA.TABLE: [COLUMN]}:
    never shown in answers - Semantic Views' MASK policy - but usable in filters). nb.draft_data_map drafts them with AI;
    Semantic Views checks them when they are saved. Publishing installs Semantic Views when the database does not
    have it, replaces the model the kit built before under that name, and grants it to the read-only MCP user."""
    from .workflow import log_event

    service = _service()
    use_ai = _model_configured() if ai is None else bool(ai)
    if not preview:
        ensure_semantic_views(conn)
    tables = list(tables or [])
    statements = None
    if sql:
        statements = [p.strip() for p in (sql.split(";\n") if isinstance(sql, str) else sql) if str(p).strip()]
    found = service.semantic_model(conn, name, tables, list(links or []), ai=use_ai, dry_run=preview and not statements,
                                   description=description, schemas=list(schemas or []), discover=bool(find),
                                   table_notes=dict(table_notes or {}), statements=statements,
                                   grains=dict(grains or {}), starts=list(starts) if starts is not None else None,
                                   metrics=list(metrics) if metrics is not None else None,
                                   instructions=list(instructions) if instructions is not None else None,
                                   replace_links=bool(replace_links),
                                   hidden=dict(hidden) if hidden is not None else None)
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
    """Bring a model the kit published up to date with the column maps and links approved since (``exakit describe
    --model NAME --refresh``): changed in place, or built again from the kit's store when the model is gone from the
    database - with its verified questions and fusion put back. Approving a column map refreshes every model it is
    in by itself."""
    ensure_semantic_views(conn)
    found = _service().refresh_model(conn, name)
    print(f"Refreshed {found.get('view')}")
    for line in found.get("warnings") or []:
        print(f"Warning: {line}")
    return found


def model_fields(conn, model: str):
    """Every metric and dimension of a published model, in one read: object, kind, name, business name, what it is."""
    rows = _service().model_fields(conn, model)
    try:
        import pandas as pd

        return pd.DataFrame(rows)
    except ImportError:
        return rows


def compile_request(conn, request: dict[str, Any], *, show: bool = True) -> dict[str, Any]:
    """Compile a structured request - {"model", "object", "metrics": [...], "dimensions": [...], "filters": [{"field",
    "op", "value"}], "order_by": [{"field", "direction"}], "limit"} - into the SQL the semantic layer stands behind
    (COMPILE_REQUEST_JSON). Returns {status, sql, plan, clarification, request_id, error}; nothing of the data is read.
    A question the model finds ambiguous comes back with ``clarification``: the choices to pick from."""
    found = _service().compile_request(conn, request)
    if show:
        print(found["sql"] if found["status"] == "ok" else f"Refused: {found['error']}")
    return found


def verify_question(conn, model: str, object_name: str, name: str, question: str, request: dict[str, Any], *,
                    onboarding: bool = False) -> dict[str, Any]:
    """Keep an approved question in the model as a verified query: the next time anyone asks it - here, or an AI
    client over MCP - the reviewed request is used, with no new draft. Compiled first; kept beside the model too."""
    from .workflow import log_event

    found = _service().verify_question(conn, model, object_name, name, question, request, onboarding=onboarding)
    log_event("semantic.verified", model=model, name=name, question=question)
    print(f"Kept as a verified question of {model}: {name}")
    return found


def verified_questions(conn, model: str):
    """The model's verified questions: name, question, request and the SQL it compiles to."""
    return _service().verified_questions(conn, model)


def fuse(conn, model: str, declaration: dict[str, Any], *, dry_run: bool = True) -> dict[str, Any]:
    """The same thing in several sources, declared once (APPLY_FUSION_DECLARATION): ``dry_run=True`` (the default)
    checks it against the data and changes nothing; ``dry_run=False`` applies it and keeps the exported document
    beside the model, so a rebuild puts it back. Build the document with nb.fusion_document(...)."""
    from .workflow import log_event

    found = _service().fuse(conn, model, declaration, dry_run=dry_run)
    if not dry_run and found["status"] != "error":
        log_event("semantic.fusion", model=model, entities=sorted(declaration.get("entities") or {}))
    print(("Checked (nothing changed): " if dry_run else "Applied: ") + (found["status"] or "")
          + (f" - {found['message']}" if found["message"] else ""))
    return found


def data_map_inputs(tables: list[str], model: str = "all_data", connection=None) -> dict[str, Any]:
    """What your data map holds for these tables: each table's key, grain and columns from its approved column map,
    and what you said before - grains, notes, links with their type, metrics, starting points, instructions, hidden
    columns. Read from this computer; with ``connection``, what this computer does not have (a new computer, a deleted
    folder) is put back from the model first, which is the record."""
    return _service().data_map_inputs(list(tables), model, connection)


def data_map_versions(conn, model: str = "all_data") -> list[dict[str, Any]]:
    """Every saved version of your data map, from the model itself, newest first: {version, saved_at, tables, links,
    metrics, definitions}. Each holds what you said and the whole model as Semantic Views exported it."""
    return _service().data_map_versions(conn, model)


def restore_data_map(conn, version: int, model: str = "all_data") -> dict[str, Any]:
    """Save an earlier version of your data map again (it becomes the newest version)."""
    return _service().restore_data_map(conn, version, model)


def draft_data_map(tables: list[str]) -> dict[str, Any]:
    """The AI set up for the kit drafts the data map for these tables in one call: what one row of each is, what each
    is, the links with their type, the tables questions start from, metrics (with a condition where one fits) and
    instructions. It sees names, roles, notes and known values, never a row; nothing is saved. Check it, change it,
    then pass it to nb.semantic_model."""
    return _service().draft_data_map(list(tables))


def validate_data_map(conn, model: str = "all_data") -> dict[str, Any]:
    """What Semantic Views finds wrong with your data map, in its own words: every issue of a fresh validation run
    (severity, the part, its rule code, the message), metrics whose result type differs from what they declare, and
    the keys it suggests. {issues, types, suggestions, errors}."""
    return _service().validate_model(conn, model)


def explain_metric(conn, object_name: str, metric: str, model: str = "all_data") -> list[dict[str, str]]:
    """A metric as Semantic Views explains it: its definition, where it comes from, what it can be grouped by and
    whether it validates. [{section, item, detail}]."""
    return _service().explain_metric(conn, model, object_name, metric)


def adopt_view(conn, model: str, view: str, *, dry_run: bool = False) -> dict[str, Any]:
    """A view you already wrote (SCHEMA.VIEW over one table: plain columns grouped, SUM / COUNT / AVG / MIN / MAX)
    made a semantic view of ``model`` (ADOPT_VIEW): plain columns become dimensions, aggregates metrics, comments
    their descriptions. Adopt it again after the view changes. ``dry_run=True`` shows the view and the statement only.
    A model the kit builds from your column maps is refused: give the adopted view a model of its own."""
    from .workflow import log_event

    found = _service().adopt_view(conn, model, view, dry_run=dry_run)
    if dry_run:
        print(f"{view}:\n{found['view_sql']}\n\nAdopting it runs:\n{found['sql']}")
        return found
    log_event("semantic.adopt", model=found["model"], view=view)
    print(f"Adopted {view} into {found['model']} as {found['object']}: {found['dimensions']} dimensions, {found['metrics']} metrics.")
    return found


def fusion_document(conn, model: str, table: str, other: str, *, key: str | None = None, wins: str = "model") -> dict[str, Any]:
    """The fusion document saying ``other`` (a table of another source) holds the same thing as ``table`` (an entity
    of the published ``model``), at the same grain: a second copy of the entity, matched by its key (``key``: its
    column in ``other`` when it is named differently), every field bound there (a column of the same name, else
    empty), and the values of a field both hold reconciled - ``wins="model"`` keeps the model's copy authoritative,
    ``wins="other"`` makes the other one win. Nothing is written: check it with nb.fuse(connection, model, document)."""
    if wins not in ("model", "other"):
        raise ValueError('wins is "model" (the model\'s own copy wins) or "other".')
    return _service().fusion_document(conn, model, table, other, key=key, wins=wins)


def column_maps_in_model(conn, model: str) -> dict[str, dict[str, Any]]:
    """The approved column maps the model carries, the newest version of each table: {SCHEMA.TABLE: {version, text}}.
    Every model the kit publishes keeps each table's approved column map on its entity, one per version."""
    return _service().column_maps_in_model(conn, model)


def restore_column_maps(conn, model: str, *, write: bool = False) -> list[dict[str, Any]]:
    """Put the kit's store back from the model (a computer replaced, the store deleted): each table whose store has
    no column map, or an older one, gets the model's. ``write=False`` (the default) only says what it would write.
    The other way round - the model lost, the store kept - is nb.refresh_semantic(connection, model)."""
    found = _service().restore_column_maps(conn, model, write=write)
    for row in found:
        print(f"{row['table']}: v{row['version']} in the model, "
              f"{'v' + str(row['store_version']) if row['store_version'] else 'none'} in the store - {row['action']}")
    return found


def fusion(conn, model: str) -> dict[str, Any] | None:
    """The model's whole fusion layer, exported as one document (None when it has none)."""
    return _service().fusion(conn, model)


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


# -- the rest of Semantic Views, each a thin call to the kit's service ---------------------------------------------------

def store_totals(conn, object_name: str, metrics: list[str], dimensions: list[str], *, name: str | None = None,
                 max_age: str = "1 DAYS", model: str = "all_data") -> dict[str, Any]:
    """Pre-built totals for speed: the metrics by the dimensions, stored once in EXAKIT_TOTALS and registered with your
    data map; Semantic Views answers from them when a question fits, and reads the live tables once they are older
    than ``max_age``. Refresh with nb.refresh_totals."""
    return _service().store_totals(conn, model, object_name, list(metrics), list(dimensions), name=name, max_age=max_age)


def refresh_totals(conn, name: str, model: str = "all_data") -> dict[str, Any]:
    """Fill stored totals again from the live tables."""
    return _service().refresh_totals(conn, model, name)


def totals_status(conn, name: str, status: str, model: str = "all_data") -> dict[str, Any]:
    """Turn stored totals off (INACTIVE), on (ACTIVE), or mark them STALE."""
    return _service().totals_status(conn, model, name, status)


def list_totals(conn, model: str = "all_data") -> list[dict[str, Any]]:
    """Your data map's stored totals, with their state and freshness, as Semantic Views keeps them."""
    return _service().list_totals(conn, model)


def freeze_view(conn, view: str, semantic_sql: str) -> dict[str, Any]:
    """A view for BI tools: Semantic SQL compiled once by Semantic Views and stored as plain SQL (SCHEMA.NAME)."""
    return _service().freeze_view(conn, view, semantic_sql)


def frozen_views(conn, model: str = "all_data", *, sync: bool = False) -> list[dict[str, Any]]:
    """The views frozen from your data map and whether each still matches it; ``sync`` retires the stale ones."""
    return _service().frozen_views(conn, model, sync=sync)


def governance_mode(conn, mode: str, model: str = "all_data") -> dict[str, Any]:
    """OPEN (Semantic Views reports unprotected sources) or GOVERNED (it refuses them); then what validation says."""
    return _service().governance_mode(conn, model, mode)


def derived_composition(conn, allowed: bool, model: str = "all_data") -> dict[str, Any]:
    """Whether your semantic views may be joined like tables in ordinary SQL."""
    return _service().derived_composition(conn, model, allowed)


def query_logging(conn, on: bool | None = None, scope: str = "DEPLOYMENT") -> dict[str, Any]:
    """Semantic Views' log of Semantic SQL statements: on, off, or None to read the setting."""
    return _service().query_logging(conn, on, scope)


def query_history(conn, limit: int = 50) -> dict[str, list[dict[str, Any]]]:
    """What was asked of your data map, newest first: requests and Semantic SQL statements, as Semantic Views logged them."""
    return _service().query_history(conn, limit)


def propose_change(conn, kind: str, object_type: str, object_name: str | None, change: dict[str, Any], rationale: str,
                   model: str = "all_data") -> dict[str, Any]:
    """A suggested change to your data map, kept by Semantic Views for review; nothing changes until it is certified."""
    return _service().propose_change(conn, model, kind, object_type, object_name, change, rationale)


def suggestions(conn, model: str = "all_data", pending_only: bool = True) -> list[dict[str, Any]]:
    """The suggested changes waiting for review: from feedback on answers, AI tools and colleagues."""
    return _service().suggestions(conn, model, pending_only)


def review_change(conn, suggestion_id: int, decision: str, note: str) -> dict[str, Any]:
    """Certify or reject a suggested change, with a note."""
    return _service().review_change(conn, suggestion_id, decision, note)


def import_databricks(conn, model: str, yaml_text: str, *, apply: bool = False) -> dict[str, Any]:
    """A Databricks metric view (its YAML) as a model of your own: shown first, created only with ``apply``."""
    return _service().import_databricks(conn, model, yaml_text, apply=apply)


def import_osi(conn, plan: dict[str, Any]) -> list[dict[str, Any]]:
    """An import plan from another semantic layer (OSI's normalized form), applied and validated."""
    return _service().import_osi(conn, plan)
