"""The semantic layer of the kit: an Exasol Semantic Views model built from approved column maps and links.

The kit no longer writes a semantic layer of its own. An approved column map (a table's roles) and an approved
schema map (the links between tables) become one model in Exasol Semantic Views, the database-native semantic
layer the semantic-views add-on installs (SEMANTIC_ADMIN, SEMANTIC_CATALOG, SEMANTIC_AGENT):

    table                      ->  entity (its alias, its key, its grain)
    link  ORDERS.O_CUSTKEY     ->  relationship ORDERS -> CUSTOMER, MANY_TO_ONE, with its key mapping
    role  time, category, flag ->  dimension (a time column also gives <column>_month)
    role  measure              ->  fact, and the metrics total_<column> (SUM) and average_<column> (per row)
    every entity               ->  a private row fact and the metric <entity>_count
    a table with measures      ->  one semantic view (object), rooted at it, with the dimensions of every table its
                                   links reach along exactly one many-to-one path

A model can span any number of schemas: sample datasets, the user's own loaded files and connected external sources
(a virtual schema becomes a VIRTUAL_SCHEMA representation in Semantic Views). One model per schema is built when a
column map or a schema map is approved; ``spec()`` with tables from several schemas builds a multi-source one.

    build(tables, links, name)       the model as a plain dict (the spec): no database
    statements(spec)                 the admin scripts and Semantic SQL that create it, in order
    apply(execute, rows, spec, ...)  rebuild it in the database, publish it, grant it to the read-only user

A model the kit builds says so in its description (MARK); the kit rebuilds only those and refuses to touch a model of
the same name that someone else made. Names follow the product's rules: identifiers, unique across the model, never
an SQL keyword. Sensitive columns are never exposed: a sensitive measure is a private fact and a sensitive dimension
is left out. Nothing here reads a row of the user's data.
"""

from __future__ import annotations

import json
import re
from typing import Any, Callable, Iterable

MARK = "[built by exakit]"
PUBLISHED_PREFIX = "SEM_"
ADDON = "semantic-views"
MAX_DEPTH = 3
_IDENT = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
_PLAIN_COLUMN = re.compile(r"^[A-Z][A-Z0-9_]*$")
_NUMERIC = ("DECIMAL", "DOUBLE", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "FLOAT", "NUMBER", "NUMERIC", "REAL")
DIMENSION_ROLES = ("time", "category", "flag")
# SQL words a name may not be (Exasol reserves many more; these are the ones a column is commonly called).
RESERVED = frozenset("""absolute action add all alter and any are as asc at authorization avg begin between bit both by
call cascade case cast char character check close collate column commit connect connection constraint continue count
create cross current current_date current_time current_timestamp current_user cursor date day deallocate dec decimal
declare default delete desc describe distinct do double drop else end escape except exception exec execute exists
external extract false fetch first float for foreign found from full function get global go goto grant group having
hour identity if immediate in index inner input insert int integer intersect interval into is join key language last
leading left level like limit local lower match max min minute module month name names natural nchar next no not null
nullif numeric object of on only open option or order outer output partition position precision prepare primary
prior privileges procedure public read real references relative restrict revoke right role rollback row rows schema
scroll second section select session session_user set size smallint some space sql state status substring sum
system_user table temporary then time timestamp to trailing transaction translate trim true union unique unknown update
upper usage user using value values varchar view when whenever where with work write year zone""".split())


class ModelRefused(RuntimeError):
    """A model of that name exists and the kit did not build it, or nothing could be modelled."""


# --- names ---------------------------------------------------------------------------------------------------------------

def identifier(text: str, fallback: str = "x") -> str:
    """A name the product accepts: lower case letters, digits and _, starting with a letter, not an SQL keyword."""
    name = re.sub(r"_+", "_", re.sub(r"[^a-z0-9_]", "_", str(text).strip().lower())).strip("_")
    if not name or not name[0].isalpha():
        name = f"{fallback}_{name}".strip("_")
    if name in RESERVED:
        name = f"{name}_{fallback}"
    return name[:100]


def model_name(text: str) -> str:
    return identifier(text, "model")


def published_schema(model: str) -> str:
    return PUBLISHED_PREFIX + model.upper()


def literal(text: Any) -> str:
    return "'" + str(text).replace("'", "''") + "'"


def _null_or(text: Any) -> str:
    return "NULL" if text in (None, "") else literal(text)


def column_sql(alias: str, column: str) -> str:
    """alias.COLUMN, quoted when the name is not a plain upper-case identifier or is an SQL keyword."""
    if _PLAIN_COLUMN.match(column) and column.lower() not in RESERVED:
        return f"{alias}.{column}"
    return f'{alias}."{column.replace(chr(34), chr(34) * 2)}"'


def sql_type(column_type: str) -> str:
    """The column's type as a RETURNS clause takes it: VARCHAR(100) UTF8 -> VARCHAR(100)."""
    text = re.sub(r"\s+(UTF8|ASCII)\b", "", str(column_type or "VARCHAR(2000000)").upper()).strip()
    return text or "VARCHAR(2000000)"


def numeric(column_type: str) -> bool:
    return sql_type(column_type).startswith(_NUMERIC)


def _sum_type(column_type: str) -> str:
    """What SUM of a column returns, wide enough not to overflow."""
    text = sql_type(column_type)
    match = re.match(r"DECIMAL\((\d+),\s*(\d+)\)", text)
    if match:
        return f"DECIMAL(36,{match.group(2)})"
    if text.startswith(("INTEGER", "BIGINT", "SMALLINT", "TINYINT")):
        return "DECIMAL(36,0)"
    return "DOUBLE"


def _words(name: str) -> str:
    """A display name from a column or element name: O_TOTALPRICE -> Totalprice, ship_mode -> Ship Mode."""
    text = re.sub(r"^[A-Za-z]{1,2}_(?=[A-Za-z]{3})", "", str(name))
    return " ".join(part.capitalize() for part in text.split("_") if part) or str(name)


# --- the spec: no database ------------------------------------------------------------------------------------------------

def table_input(table: str, doc: dict[str, Any], types: dict[str, str], *, virtual: bool = False,
                profile: dict[str, Any] | None = None) -> dict[str, Any]:
    """One table for build(): its approved column map (doc), its column types ({COLUMN: TYPE}) and, when kept, the
    profile the map came from (a category's most frequent values, for an AI's filters; never a sensitive column's)."""
    top = {str(c.get("column")): [str(t[0]) for t in c.get("top") or [] if t and t[0] is not None][:10]
           for c in (profile or {}).get("columns") or [] if isinstance(c, dict)}
    columns = []
    for name, entry in (doc.get("columns") or {}).items():
        sensitive = bool(entry.get("sensitive"))
        columns.append({"name": str(name), "type": types.get(str(name), "VARCHAR(2000000)"),
                        "role": str(entry.get("role") or "other"), "sensitive": sensitive,
                        "note": str(entry.get("note") or "").strip(),
                        "values": [] if sensitive else top.get(str(name), [])})
    slots = doc.get("slots") or {}
    key = [slots["key"]] if slots.get("key") else [c["name"] for c in columns if c["role"] == "key"][:1]
    return {"table": table, "columns": columns, "key": key, "grain": str(doc.get("grain") or "").strip(),
            "virtual": virtual or (doc.get("source") or {}).get("kind") == "virtual",
            "version": doc.get("version")}


def _paths(root: str, edges: dict[str, list[tuple[str, str]]]) -> dict[str, list[list[str]]]:
    """Every entity reachable from root along many-to-one relationships (up to MAX_DEPTH), with each path to it."""
    found: dict[str, list[list[str]]] = {}
    frontier = [(root, [root])]
    for _ in range(MAX_DEPTH):
        following = []
        for entity, path in frontier:
            for target, _relationship in edges.get(entity, []):
                if target in path:
                    continue
                found.setdefault(target, []).append(path + [target])
                following.append((target, path + [target]))
        frontier = following
    return found


def build(tables: Iterable[dict[str, Any]], links: Iterable[dict[str, str]], name: str, *,
          description: str | None = None) -> dict[str, Any]:
    """The model as a dict. ``tables`` from table_input(); ``links`` as {"from": "SCHEMA.TABLE.COLUMN",
    "to": "SCHEMA.TABLE.KEY"} (many-to-one: the key side is unique). A link naming a table that is not modelled is
    left out, and so is a table whose schema or name the product cannot take; ``notes`` says what was left out."""
    model = model_name(name)
    notes: list[str] = []
    entities: list[dict[str, Any]] = []
    by_table: dict[str, dict[str, Any]] = {}
    used: set[str] = set()                        # every name in the model: entities, dimensions, facts, metrics, objects
    tables = list(tables)
    short_names = [t["table"].split(".", 1)[1].upper() for t in tables]
    for index, table in enumerate(tables, 1):
        schema, object_name = table["table"].split(".", 1)
        if not (_IDENT.match(schema) and _IDENT.match(object_name)):
            notes.append(f"{table['table']} is left out: Semantic Views takes a schema and table named as identifiers")
            continue
        base = object_name if short_names.count(object_name.upper()) == 1 else f"{schema}_{object_name}"
        entity = identifier(base, "entity")
        while entity in used:
            entity = f"{entity}_{index}"
        used.add(entity)
        record = {"name": entity, "schema": schema.upper(), "table": object_name.upper(), "alias": f"t{index}",
                  "key": [k for k in table.get("key") or [] if k], "virtual": bool(table.get("virtual")),
                  "grain": table.get("grain") or f"one row of {schema}.{object_name}",
                  "description": table.get("description") or f"{schema}.{object_name}"
                  + (" (an external source, read live)" if table.get("virtual") else ""),
                  "columns": table["columns"]}
        entities.append(record)
        by_table[f"{schema}.{object_name}".upper()] = record

    relationships: list[dict[str, Any]] = []
    edges: dict[str, list[tuple[str, str]]] = {}
    for link in links:
        source, _, from_column = str(link["from"]).rpartition(".")
        target, _, to_column = str(link["to"]).rpartition(".")
        a, b = by_table.get(source.upper()), by_table.get(target.upper())
        if not a or not b or a is b:
            continue
        name_ = identifier(f"{a['name']}_to_{b['name']}", "rel")
        while name_ in used:
            name_ = f"{name_}_{len(relationships) + 1}"
        used.add(name_)
        relationships.append({"name": name_, "from": a["name"], "to": b["name"], "from_column": from_column,
                              "to_column": to_column,
                              "join": f"{column_sql(a['alias'], from_column)} = {column_sql(b['alias'], to_column)}"})
        edges.setdefault(a["name"], []).append((b["name"], name_))

    def free(wanted: str, *prefixes: str) -> str:
        """A name not yet in the model: the wanted one, else prefixed with its entity (or view); never a keyword."""
        base = re.sub(r"_+", "_", re.sub(r"[^a-z0-9_]", "_", str(wanted).lower())).strip("_") or "field"
        candidates = [base] + [f"{identifier(p, 'x')}_{base}" for p in prefixes] + [f"field_{base}"]
        for candidate in candidates:
            candidate = candidate[:100]
            if candidate[0].isalpha() and candidate not in RESERVED and candidate not in used:
                used.add(candidate)
                return candidate
        candidate, n = candidates[-1], 2
        while f"{candidate}_{n}" in used:
            n += 1
        used.add(f"{candidate}_{n}")
        return f"{candidate}_{n}"

    entity_by_name = {e["name"]: e for e in entities}
    facts_of: dict[str, list[dict[str, Any]]] = {}
    for e in entities:
        row = free(f"{e['name']}_row")
        facts = [{"name": row, "entity": e["name"], "expression": "1", "type": "DECIMAL(1,0)", "private": True,
                  "display": "Row", "comment": f"One per row of {e['schema']}.{e['table']}", "row": True}]
        for column in e["columns"]:
            if column["role"] != "measure":
                continue
            expression = column_sql(e["alias"], column["name"])
            kind = sql_type(column["type"])
            if not numeric(column["type"]):                 # a number a source sends as text (PostgreSQL NUMERIC)
                expression, kind = f"CAST({expression} AS DOUBLE)", "DOUBLE"
            facts.append({"name": free(column["name"], e["name"]), "entity": e["name"], "expression": expression,
                          "type": kind, "private": column["sensitive"], "column": column["name"],
                          "display": _words(column["name"].lower()),
                          "comment": column["note"] or f"{column['name']} of {e['schema']}.{e['table']}"})
        facts_of[e["name"]] = facts

    def dimensions_of(e: dict[str, Any], owner: str) -> list[dict[str, Any]]:
        found = []
        for column in e["columns"]:
            if column["role"] not in DIMENSION_ROLES or column["sensitive"]:
                continue
            expression, kind = column_sql(e["alias"], column["name"]), sql_type(column["type"])
            comment = column["note"] or f"{column['name']} of {e['schema']}.{e['table']}"
            found.append({"name": free(column["name"], e["name"], owner), "entity": e["name"], "expression": expression,
                          "type": kind, "display": _words(column["name"].lower()), "comment": comment,
                          "column": column["name"], "role": column["role"],
                          "values": column.get("values") or [] if column["role"] in ("category", "flag") else []})
            if column["role"] == "time" and kind.startswith(("DATE", "TIMESTAMP")):
                found.append({"name": free(f"{column['name']}_month", e["name"], owner), "entity": e["name"],
                              "expression": f"CAST(DATE_TRUNC('month', {expression}) AS DATE)", "type": "DATE",
                              "display": _words(column["name"].lower()) + " (month)",
                              "comment": f"Calendar month of {column['name']}", "column": column["name"],
                              "role": "time"})
        return found

    objects: list[dict[str, Any]] = []
    roots = [e for e in entities if any(not f.get("row") for f in facts_of[e["name"]])] or list(entities)
    covered: set[str] = set()
    # The tables with measures first; then every table no view reached yet gets a view of its own (its row count and
    # its dimensions), so a table without measures and without a link is still asked about.
    pending = list(roots) + [e for e in entities if e not in roots]
    for root in pending:
        if root not in roots and root["name"] in covered:
            continue
        object_name = root["name"].upper()           # one view per root entity: entity names are unique
        reach = _paths(root["name"], edges)
        joined = [entity_by_name[target] for target, paths in reach.items() if len(paths) == 1]
        for target, paths in reach.items():
            if len(paths) > 1:
                notes.append(f"{object_name}: {target} is reached along {len(paths)} paths "
                             f"({'; '.join(' > '.join(p) for p in paths)}), so its columns are not dimensions of this view")
        dimensions = dimensions_of(root, object_name.lower())
        for e in joined:
            dimensions += dimensions_of(e, object_name.lower())
        if not dimensions:
            notes.append(f"{root['schema']}.{root['table']} has no time, category or flag column to group by: no view")
            continue
        metrics = []
        row_fact = next(f for f in facts_of[root["name"]] if f.get("row"))
        count = free(f"{root['name']}_count")
        metrics.append({"name": count, "expression": f"SUM({row_fact['name']})", "type": "DECIMAL(36,0)",
                        "kind": "ADDITIVE", "display": f"Number of {_words(root['name'])} rows",
                        "comment": f"Rows of {root['schema']}.{root['table']} ({root['grain']})", "synonyms": []})
        for fact in facts_of[root["name"]]:
            if fact.get("row") or fact["private"]:
                continue
            total = free(f"total_{fact['name']}")
            metrics.append({"name": total, "expression": f"SUM({fact['name']})", "type": _sum_type(fact["type"]),
                            "kind": "ADDITIVE", "display": f"Total {fact['display']}",
                            "comment": f"Sum of {fact['column']}", "synonyms": [fact["name"].replace("_", " ")]})
            metrics.append({"name": free(f"average_{fact['name']}"), "expression": f"{total} / NULLIF({count}, 0)",
                            "type": "DOUBLE", "kind": "RATIO", "display": f"Average {fact['display']}",
                            "comment": f"Average {fact['column']} per row", "synonyms": []})
        covered.update([root["name"]] + [e["name"] for e in joined])
        objects.append({"name": object_name, "root": root["name"], "dimensions": dimensions,
                        "facts": [f for f in facts_of[root["name"]]], "metrics": metrics,
                        "description": f"{_words(root['name'])}: {root['grain']}"})
    if not objects:
        raise ModelRefused("Nothing to model: no approved table has a time, category or flag column to group by.")
    schemas = sorted({e["schema"] for e in entities})
    about = description or f"{'Multi-source model over ' if len(schemas) > 1 else 'Model of '}{', '.join(schemas)}"
    return {"model": model, "published_schema": published_schema(model), "description": f"{about} {MARK}",
            "entities": [{k: v for k, v in e.items() if k != "columns"} for e in entities],
            "relationships": relationships, "objects": objects, "notes": notes, "schemas": schemas}


# --- the statements -------------------------------------------------------------------------------------------------------

def _script(name: str, *args: Any) -> str:
    def value(arg: Any) -> str:
        if arg is None:
            return "NULL"
        if isinstance(arg, bool):
            return "TRUE" if arg else "FALSE"
        if isinstance(arg, int):
            return str(arg)
        return literal(arg)

    return f"EXECUTE SCRIPT SEMANTIC_ADMIN.{name}({', '.join(value(a) for a in args)})"


def _text(text: Any) -> str:
    return literal(" ".join(str(text).split())[:1000])


def definition(spec: dict[str, Any], obj: dict[str, Any]) -> str:
    """The Semantic SQL that gives one view its dimensions, facts and metrics."""
    dims = [f"  DIMENSION {d['name']}\n    ON ENTITY {d['entity']}\n    AS {d['expression']}\n    RETURNS {d['type']}"
            f"\n    DISPLAY {_text(d['display'])}\n    COMMENT {_text(d['comment'])}"
            + (f"\n    SYNONYMS ({', '.join(_text(s) for s in d['synonyms'])})" if d.get("synonyms") else "")
            for d in obj["dimensions"]]
    facts = [f"  FACT {f['name']}\n    ON ENTITY {f['entity']}\n    AS {f['expression']}\n    RETURNS {f['type']}"
             f"\n    ADDITIVE\n    DISPLAY {_text(f['display'])}\n    COMMENT {_text(f['comment'])}"
             f"\n    {'PRIVATE' if f['private'] else 'PUBLIC'}" for f in obj["facts"]]
    metrics = [f"  METRIC {m['name']}\n    AS {m['expression']}\n    ON ENTITY {obj['root']}\n    RETURNS {m['type']}"
               + (f"\n    FILTER (WHERE {m['filter']})" if m.get("filter") else "")
               + f"\n    DISPLAY {_text(m['display'])}\n    COMMENT {_text(m['comment'])}"
               + (f"\n    SYNONYMS ({', '.join(_text(s) for s in m['synonyms'])})" if m.get("synonyms") else "")
               + f"\n    {m['kind']} PUBLIC" for m in obj["metrics"]]
    return (f"ALTER SEMANTIC VIEW {spec['model']}.{obj['name']}\nREPLACE DIMENSIONS (\n" + ",\n".join(dims)
            + "\n)\nREPLACE FACTS (\n" + ",\n".join(facts) + "\n)\nREPLACE METRICS (\n" + ",\n".join(metrics) + "\n)")


def statements(spec: dict[str, Any]) -> list[str]:
    """Everything that creates the model, in order (it must not exist yet): the model, its entities and their keys,
    the relationships and their key mappings, the views and their definitions, then the publish."""
    model = spec["model"]
    found = [_script("CREATE_MODEL", model, spec["published_schema"], spec["description"], None)]
    for e in spec["entities"]:
        found.append(_script("ADD_ENTITY", model, e["name"], e["schema"], e["table"], e["alias"],
                             ", ".join(column_sql(e["alias"], k) for k in e["key"]) or None, e["grain"], e["description"]))
        if e["key"]:
            found.append(_script("ADD_UNIQUE_KEY_WITH_COLUMNS", model, e["name"], f"{e['name']}_pk", "PRIMARY",
                                 f"Key of {e['schema']}.{e['table']}", "NATIVE",
                                 json.dumps([{"column_name": k, "ordinal_position": i} for i, k in enumerate(e["key"], 1)])))
    for r in spec["relationships"]:
        found.append(_script("ADD_RELATIONSHIP", model, r["name"], r["from"], r["to"], r["join"], "MANY_TO_ONE", "LEFT", None))
        found.append(_script("ADD_RELATIONSHIP_KEY_MAPPING", model, r["name"], r["from_column"], None, r["to_column"], None, 1))
    for obj in spec["objects"]:
        found.append(_script("ADD_SEMANTIC_OBJECT", model, obj["name"], obj["root"], obj["description"]))
        found.append(_script("APPLY_SEMANTIC_DEFINITION_OR_FAIL", definition(spec, obj), False))
    found.append(_script("PUBLISH_MODEL", model))
    return found


# --- the database ---------------------------------------------------------------------------------------------------------

Run = Callable[[str], list[dict[str, Any]]]


def installed(rows: Run) -> str | None:
    """The Semantic Views version in this database, or None when it is not installed."""
    try:
        found = rows("SELECT DISPLAY_VERSION FROM SEMANTIC_CATALOG.PRODUCT_VERSION")
    except Exception:
        return None
    return str(found[0].get("DISPLAY_VERSION") or "installed") if found else "installed"


def existing(rows: Run, model: str) -> dict[str, Any] | None:
    """The model of that name in the catalog: {name, description, kit} or None."""
    try:
        found = rows("SELECT MODEL_NAME, DESCRIPTION, PUBLISHED_SCHEMA FROM SEMANTIC_CATALOG.MODELS "
                     f"WHERE UPPER(MODEL_NAME) = UPPER({literal(model)})")
    except Exception:
        return None
    if not found:
        return None
    about = str(found[0].get("DESCRIPTION") or "")
    return {"name": str(found[0]["MODEL_NAME"]), "description": about, "kit": MARK in about,
            "published_schema": str(found[0].get("PUBLISHED_SCHEMA") or "")}


def models(rows: Run) -> list[dict[str, Any]]:
    """Every model in the catalog with its views, entities and counts; [] when Semantic Views is not installed."""
    try:
        found = rows("SELECT MODEL_NAME, PUBLISHED_SCHEMA, DESCRIPTION, STATUS FROM SEMANTIC_CATALOG.MODELS ORDER BY MODEL_NAME")
    except Exception:
        return []
    return [{"model": str(r["MODEL_NAME"]), "published_schema": str(r.get("PUBLISHED_SCHEMA") or ""),
             "description": str(r.get("DESCRIPTION") or "").replace(MARK, "").strip(),
             "kit": MARK in str(r.get("DESCRIPTION") or ""), "status": str(r.get("STATUS") or "")} for r in found]


def apply(execute: Callable[[str], Any], rows: Run, spec: dict[str, Any], *, reader: str | None = None,
          previous: dict[str, Any] | None = None, extra: list[tuple[str, str]] | None = None,
          progress: Callable[[str], None] | None = None) -> dict[str, Any]:
    """Rebuild the model in the database and publish it. A model of that name the kit did not build is refused
    (ModelRefused). A statement that fails drops the half-built model and, when ``previous`` (the spec that was
    published before) is given, puts that one back; the error is raised. ``extra`` is [(view, Semantic SQL)] tried
    one at a time after the build (a refused one is skipped and named in the result's warnings: the product rolls it
    back). The read-only user, when given, gets SEMANTIC_USER and SELECT on the published schema."""
    say = progress or (lambda _line: None)
    model = spec["model"]
    found = existing(rows, model)
    if found and not found["kit"]:
        raise ModelRefused(f"A semantic model named {found['name']} already exists and the kit did not build it; it is "
                           "left alone. Choose another name (name=...).")
    if found:
        say(f"Replacing semantic model {model}")
        execute(_script("DROP_MODEL_IF_EXISTS", model))
    sent = statements(spec)
    try:
        for index, sql in enumerate(sent, 1):
            say(f"Semantic model {model}: step {index} of {len(sent)}")
            execute(sql)
    except Exception:
        try:
            execute(_script("DROP_MODEL_IF_EXISTS", model))
            if previous:
                for sql in statements(previous):
                    execute(sql)
        except Exception:
            pass
        raise
    warnings: list[str] = []
    for view, ddl in extra or []:
        try:
            execute(_script("APPLY_SEMANTIC_DEFINITION_OR_FAIL", ddl, False))
        except Exception as err:
            warnings.append(f"{view}: {' '.join(str(err).split())[:300]} (skipped; the model is unchanged by it)")
    if extra:
        try:
            execute(_script("PUBLISH_MODEL", model))
        except Exception as err:
            warnings.append(f"publish after the extra definitions: {' '.join(str(err).split())[:300]}")
    if reader:
        for sql in (f'GRANT SEMANTIC_USER TO "{reader}"', f'GRANT SELECT ON SCHEMA {spec["published_schema"]} TO "{reader}"'):
            try:
                execute(sql)
            except Exception as err:
                warnings.append(f"the read-only user {reader}: {' '.join(str(err).split())[:200]}")
    counts = {"views": len(spec["objects"]), "entities": len(spec["entities"]),
              "relationships": len(spec["relationships"]),
              "dimensions": sum(len(o["dimensions"]) for o in spec["objects"]),
              "facts": sum(len(o["facts"]) for o in spec["objects"]),
              "metrics": sum(len(o["metrics"]) for o in spec["objects"])}
    return {"model": model, "published_schema": spec["published_schema"],
            "views": [f"{spec['published_schema']}.{o['name']}" for o in spec["objects"]], "counts": counts,
            "statements": len(sent), "notes": list(spec.get("notes") or []), "warnings": warnings}


def summary(spec: dict[str, Any]) -> str:
    """One paragraph a person reads before a model is built."""
    lines = [f"Semantic model {spec['model']} (published as {spec['published_schema']}), over "
             f"{', '.join(spec['schemas'])}: {len(spec['entities'])} entities, {len(spec['relationships'])} relationships."]
    for obj in spec["objects"]:
        lines.append(f"  view {obj['name']}: {len(obj['dimensions'])} dimensions "
                     f"({', '.join(d['name'] for d in obj['dimensions'][:8])}{', ...' if len(obj['dimensions']) > 8 else ''}), "
                     f"{len(obj['metrics'])} metrics ({', '.join(m['name'] for m in obj['metrics'][:6])}"
                     f"{', ...' if len(obj['metrics']) > 6 else ''})")
    lines += [f"  note: {n}" for n in spec.get("notes") or []]
    return "\n".join(lines)


# --- an AI's proposal, checked ---------------------------------------------------------------------------------------------

_TOKEN = re.compile(r"\s*(?:([A-Za-z_][A-Za-z0-9_]*)|(\d+(?:\.\d+)?)|([-+*/(),]))")
_FUNCTIONS = {"SUM", "NULLIF"}
_FILTER = re.compile(r"^\s*([a-z][a-z0-9_]*)\s*(=|<>|IN)\s*(\(.*\)|'(?:[^']|'')*')\s*$", re.IGNORECASE)


def ai_facts(spec: dict[str, Any]) -> dict[str, Any]:
    """What a model is shown to propose labels and metrics: names, types, grains, column notes and, for a category,
    its most frequent values (as the column map's profile kept them). Never a row; nothing sensitive is in a spec."""
    return {"model": spec["model"], "description": spec["description"].replace(MARK, "").strip(),
            "entities": [{"name": e["name"], "table": f"{e['schema']}.{e['table']}", "grain": e["grain"],
                          "external_source": e["virtual"]} for e in spec["entities"]],
            "relationships": [f"{r['from']}.{r['from_column']} -> {r['to']}.{r['to_column']}" for r in spec["relationships"]],
            "views": [{"view": o["name"], "root": o["root"],
                       "dimensions": [{k: d[k] for k in ("name", "entity", "type", "comment") if d.get(k)}
                                      | ({"values": d["values"][:10]} if d.get("values") else {}) for d in o["dimensions"]],
                       "facts": [{k: f[k] for k in ("name", "type", "comment")} for f in o["facts"] if not f["private"]],
                       "metrics": [{k: m[k] for k in ("name", "expression", "kind")} for m in o["metrics"]]}
                      for o in spec["objects"]]}


AI_INSTRUCTIONS = """You are designing an Exasol Semantic Views model for business users and AI agents.
From the model below (metadata only), answer with ONE JSON object and nothing else:
{"model": "<one sentence: what this model answers>",
 "labels": {"<existing dimension, fact or metric name>": {"display": "<business name>", "comment": "<one sentence>",
            "synonyms": ["<words a person would ask with>"]}},
 "metrics": [{"view": "<view>", "name": "<new lower_snake name>", "expression": "<see rules>",
              "kind": "ADDITIVE|DERIVED|RATIO", "type": "DOUBLE|DECIMAL(36,2)", "filter": "<optional>",
              "display": "<business name>", "comment": "<one sentence>", "synonyms": ["..."]}]}
Rules for a new metric: ADDITIVE is SUM(<a fact of that view>) with an optional filter; DERIVED combines metrics of
that view with + - * and numbers; RATIO is <metric> / NULLIF(<metric>, 0). A filter is <dimension> = '<value>' or
<dimension> IN ('<value>', ...) with a dimension of that view and values from its "values" list only.
Propose at most 8 metrics, only ones a business user of this data would ask for. Never invent a column."""


def _expression_ok(expression: str, facts: set[str], metrics: set[str]) -> tuple[bool, set[str], set[str]]:
    """Whether an expression uses only the allowed tokens, and the facts and metrics it names."""
    position, used_facts, used_metrics = 0, set(), set()
    text = expression.strip()
    while position < len(text):
        match = _TOKEN.match(text, position)
        if not match or match.end() == position:
            return False, used_facts, used_metrics
        word = match.group(1)
        if word:
            if word.upper() in _FUNCTIONS:
                pass
            elif word in facts:
                used_facts.add(word)
            elif word in metrics:
                used_metrics.add(word)
            else:
                return False, used_facts, used_metrics
        position = match.end()
    return bool(text), used_facts, used_metrics


def ai_accept(spec: dict[str, Any], answer: dict[str, Any]) -> tuple[dict[str, Any], list[tuple[str, str]], list[str]]:
    """(labels, [(view, Semantic SQL)] for the new metrics, what was refused and why) from a model's answer: names
    must be new identifiers, expressions may name only that view's facts and metrics, filters only its dimensions
    and their known values. Labels are text and always kept (for names that exist)."""
    known = {e["name"] for o in spec["objects"] for e in o["dimensions"] + o["facts"] + o["metrics"]}
    labels: dict[str, Any] = {}
    for name, label in (answer.get("labels") or {}).items() if isinstance(answer.get("labels"), dict) else []:
        if name in known and isinstance(label, dict):
            labels[name] = {k: label[k] for k in ("display", "comment", "synonyms") if k in label}
    if isinstance(answer.get("model"), str):
        labels["model"] = answer["model"]
    extra, refused = [], []
    taken = set(known) | {e["name"] for e in spec["entities"]}
    views = {o["name"]: o for o in spec["objects"]}
    accepted: dict[str, set[str]] = {}           # per view: the proposed metrics accepted so far, usable by the next
    for metric in (answer.get("metrics") or [])[:8] if isinstance(answer.get("metrics"), list) else []:
        if not isinstance(metric, dict):
            continue
        view, name = views.get(str(metric.get("view") or "").upper()), str(metric.get("name") or "")
        why = None
        if view is None:
            why = f"no view {metric.get('view')}"
        elif not re.match(r"^[a-z][a-z0-9_]{0,99}$", name) or name in RESERVED or name in taken:
            why = f"'{name}' is not a new lower_snake name"
        if why:
            refused.append(f"metric {name or '?'}: {why}")
            continue
        facts = {f["name"] for f in view["facts"] if not f["private"]}
        metrics = {m["name"] for m in view["metrics"]} | accepted.get(view["name"], set())
        expression = " ".join(str(metric.get("expression") or "").split())
        ok, used_facts, used_metrics = _expression_ok(expression, facts, metrics)
        kind = str(metric.get("kind") or "").upper()
        if ok and used_facts and not used_metrics and re.fullmatch(r"SUM\(\s*[a-z][a-z0-9_]*\s*\)", expression, re.I):
            kind = "ADDITIVE"
        elif ok and used_metrics and not used_facts:
            kind = "RATIO" if "/" in expression else "DERIVED"
        else:
            refused.append(f"metric {name}: '{expression}' is not SUM(<fact>), nor arithmetic over this view's metrics")
            continue
        flt = str(metric.get("filter") or "").strip()
        if flt:
            match = _FILTER.match(flt)
            dims = {d["name"]: d for d in view["dimensions"]}
            values = re.findall(r"'((?:[^']|'')*)'", match.group(3)) if match else []
            dim = dims.get(match.group(1)) if match else None
            if kind != "ADDITIVE" or not dim or not values or not dim.get("values") or any(
                    v.replace("''", "'") not in [str(x) for x in dim["values"]] for v in values):
                refused.append(f"metric {name}: the filter '{flt}' is not a dimension of {view['name']} compared with its known values")
                continue
        rtype = str(metric.get("type") or "DOUBLE").upper().replace(" ", "")
        if not re.fullmatch(r"DOUBLE|DECIMAL\(\d{1,2},\d{1,2}\)", rtype):
            rtype = "DOUBLE"
        taken.add(name)
        accepted.setdefault(view["name"], set()).add(name)
        synonyms = [" ".join(str(s).split())[:60] for s in metric.get("synonyms") or [] if str(s).strip()][:6]
        ddl = (f"ALTER SEMANTIC VIEW {spec['model']}.{view['name']}\nADD OR REPLACE METRIC {name}\n  AS {expression}\n"
               f"  ON ENTITY {view['root']}\n  RETURNS {rtype}" + (f"\n  FILTER (WHERE {flt})" if flt else "")
               + f"\n  DISPLAY {_text(metric.get('display') or _words(name))}\n  COMMENT {_text(metric.get('comment') or name)}"
               + (f"\n  SYNONYMS ({', '.join(_text(s) for s in synonyms)})" if synonyms else "") + f"\n  {kind} PUBLIC")
        extra.append((view["name"], ddl))
    return labels, extra, refused
