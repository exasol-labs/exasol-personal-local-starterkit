"""Step 5 of the descriptor plan: where agents read the roles and the links - an Exasol Semantic Views model.

Approving a table's column map, or a schema's map of links, rebuilds that schema's semantic model (semantic_model.py):
every table of the schema with an approved column map becomes an entity, every approved link a relationship, and the
roles become the model's dimensions, facts and metrics. The model is named after the schema (TPCH -> tpch) and
published as views in SEM_<SCHEMA> (SEM_TPCH), which the read-only MCP user may read. The user's own schema and
tables are never commented or altered.

Exasol Semantic Views is a marketplace add-on (semantic-views). When the database does not have it yet, publishing
installs it first, as ``exakit marketplace semantic-views`` would (an install that fails leaves the approval standing,
unpublished, with the command to run).

The spec each publish built is kept in ~/.exasol-starter-kit/semantic/<model>.json: a rebuild that fails puts the
last published one back, and ``refresh`` rebuilds a model from it with the column maps approved since.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable

from . import semantic_model as sm
from . import store


def flow_table(table: str) -> str:
    """SCHEMA.TABLE as the database spells it (flow.table_name: a source's lower-case table keeps its spelling)."""
    from . import flow

    return flow.table_name(table)

FOLDER = "semantic"

Run = Callable[[str], list[dict[str, Any]]]


def literal(text: str) -> str:
    return sm.literal(text)


# --- the add-on ------------------------------------------------------------------------------------------------------------

def _exakit() -> str | None:
    found = shutil.which("exakit")
    if found:
        return found
    for name in ("exakit", "exakit.cmd", "exakit.ps1"):
        candidate = store.kit_home() / "bin" / name
        if candidate.is_file():
            return str(candidate)
    return None


def install_addon() -> bool:
    """``exakit marketplace semantic-views``, its output shown as it comes; True when it exited 0."""
    command = _exakit()
    if not command:
        print("exakit is not on PATH here, so Semantic Views cannot be installed from this process. "
              "Fix: exakit marketplace semantic-views", file=sys.stderr)
        return False
    argv = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", command] if command.endswith(".ps1") else [command]
    print("Installing Exasol Semantic Views into the database (as `exakit marketplace semantic-views` would):",
          file=sys.stderr, flush=True)
    try:
        process = subprocess.Popen(argv + ["marketplace", sm.ADDON], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, text=True)
    except OSError as err:
        print(f"exakit could not be started: {err}", file=sys.stderr)
        return False
    assert process.stdout is not None
    for line in process.stdout:
        print("  " + line.rstrip(), file=sys.stderr, flush=True)
    return process.wait() == 0


INSTALL: Callable[[], bool] = install_addon        # the tests replace it


def ensure_installed(rows: Run) -> str:
    """The Semantic Views version in the database, installing the add-on first when it is not there."""
    version = sm.installed(rows)
    if version:
        return version
    if not INSTALL():
        raise RuntimeError("Exasol Semantic Views did not install (the lines above say why). "
                           "Fix: exakit marketplace semantic-views")
    version = sm.installed(rows)
    if not version:
        raise RuntimeError("Exasol Semantic Views reported installed, but SEMANTIC_CATALOG is not readable. "
                           "Fix: exakit marketplace semantic-views --validate")
    return version


# --- what a schema holds ----------------------------------------------------------------------------------------------------

def _load(text: str) -> dict[str, Any]:
    from . import flow

    return flow.load(text)


def approved_tables(schema: str | None, home: Path | None = None) -> dict[str, dict[str, Any]]:
    """{SCHEMA.TABLE: approved column map} for every table of ``schema`` (None: of every schema) the store has an
    approval for."""
    root = (home or store.kit_home()) / store.FOLDER
    found: dict[str, dict[str, Any]] = {}
    if not root.is_dir():
        return found
    for folder in sorted(root.iterdir()):
        name = folder.name
        if not folder.is_dir() or "." not in name or (schema is not None and name.split(".", 1)[0].upper() != schema.upper()):
            continue
        text = store.current(name, home)
        if text:
            try:
                found[name] = _load(text)
            except Exception:                         # a file that does not parse is no approval
                continue
    return found


def column_types(rows: Run, tables: list[str]) -> tuple[dict[str, dict[str, str]], set[str]]:
    """({SCHEMA.TABLE: {COLUMN: TYPE}}, the virtual schemas among them), from the database's own catalog."""
    schemas = sorted({t.split(".", 1)[0] for t in tables})
    if not schemas:
        return {}, set()
    where = ", ".join(sm.literal(s) for s in schemas)
    types: dict[str, dict[str, str]] = {}
    for row in rows("SELECT COLUMN_SCHEMA, COLUMN_TABLE, COLUMN_NAME, COLUMN_TYPE FROM SYS.EXA_ALL_COLUMNS "
                    f"WHERE COLUMN_SCHEMA IN ({where}) ORDER BY COLUMN_ORDINAL_POSITION"):
        types.setdefault(f"{row['COLUMN_SCHEMA']}.{row['COLUMN_TABLE']}", {})[str(row["COLUMN_NAME"])] = str(row["COLUMN_TYPE"])
    virtual = {str(r["SCHEMA_NAME"]) for r in rows(
        f"SELECT SCHEMA_NAME FROM SYS.EXA_SCHEMAS WHERE SCHEMA_IS_VIRTUAL AND SCHEMA_NAME IN ({where})")}
    return types, virtual


def source_origins(home: Path | None = None) -> dict[str, dict[str, str]]:
    """{VS_<NAME>: {connector, connector_name, source}} for every source `exakit connect` keeps on this computer (its
    config.json under sources/), the connector's name from the kit's connector catalog. Names only: a source's
    settings and secrets are never read into a model."""
    root = (home or store.kit_home()) / "sources"
    names: dict[str, str] = {}
    try:
        catalog = json.loads((Path(__file__).resolve().parents[2] / "virtual-schemas" / "catalog.json").read_text(encoding="utf-8"))
        names = {str(c.get("id")): str(c.get("name") or c.get("id")) for c in catalog.get("connectors") or []}
    except (OSError, ValueError):
        pass
    found: dict[str, dict[str, str]] = {}
    for config in sorted(root.glob("*/config.json")) if root.is_dir() else []:
        try:
            doc = json.loads(config.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        schema = str((doc.get("objects") or {}).get("schema") or "").upper()
        connector = str(doc.get("connector") or "")
        if schema and connector:
            found[schema] = {"connector": connector, "connector_name": names.get(connector, connector),
                             "source": str(doc.get("id") or config.parent.name)}
    return found


def schema_links(schema: str, home: Path | None = None) -> list[dict[str, str]]:
    """The approved schema map's links as {from: SCHEMA.TABLE.COLUMN, to: SCHEMA.TABLE.KEY}."""
    from . import schema as schemas

    doc = schemas.current(schema, home) or {}
    return [{"from": f"{schemas.schema_name(schema)}.{link['from']}", "to": f"{schemas.schema_name(schema)}.{link['to']}"}
            for link in doc.get("relations") or []]


# --- the kept spec ----------------------------------------------------------------------------------------------------------

def spec_path(model: str, home: Path | None = None) -> Path:
    return (home or store.kit_home()) / FOLDER / f"{sm.model_name(model)}.json"


def kept(model: str, home: Path | None = None) -> dict[str, Any] | None:
    try:
        return json.loads(spec_path(model, home).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def keep(spec: dict[str, Any], inputs: dict[str, Any], home: Path | None = None,
         governance: dict[str, Any] | None = None) -> Path:
    """Keep what a model was built from and published as, beside it: the spec (to change it in place next time),
    the inputs (to rebuild it), and what people added to it - verified questions, instructions, the fusion document -
    so a rebuild can put them back."""
    path = spec_path(spec["model"], home)
    path.parent.mkdir(parents=True, exist_ok=True)
    if governance is None:
        before = kept(spec["model"], home) or {}
        governance = {k: before[k] for k in ("verified", "instructions", "fusion") if before.get(k)}
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps({"spec": spec, "inputs": inputs, **{k: v for k, v in governance.items() if v}},
                               indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(temp, path)
    return path


# --- publishing ---------------------------------------------------------------------------------------------------------------

def build_model(rows: Run, tables: list[str], links: list[dict[str, str]], name: str, *,
                description: str | None = None, docs: dict[str, dict[str, Any]] | None = None,
                home: Path | None = None, grains: dict[str, str] | None = None,
                starts: list[str] | None = None) -> dict[str, Any]:
    """The spec of a model over ``tables`` (SCHEMA.TABLE, any schemas), from their approved column maps (``docs``,
    else the store's). A table with no approved column map is refused: approve it first."""
    docs = dict(docs or {})
    missing = []
    for table in tables:
        if table not in docs:
            text = store.current(table, home)
            if text:
                docs[table] = _load(text)
            else:
                missing.append(table)
    if missing:
        raise sm.ModelRefused(f"No approved column map for {', '.join(missing)}: approve each first "
                              "(exakit describe SCHEMA.TABLE, then exakit describe SCHEMA.TABLE --approve).")
    types, virtual = column_types(rows, tables)
    origins = source_origins(home)
    inputs = []
    for t in tables:
        version = docs[t].get("version")
        profile = store.read_profile(t, int(version), home) if isinstance(version, int) else None
        schema = t.split(".", 1)[0]
        inputs.append(sm.table_input(t, docs[t], types.get(t, {}), virtual=schema in virtual, profile=profile,
                                     origin=origins.get(schema.upper())))
    spec = sm.build(inputs, links, name, description=description, grains=grains, starts=starts)
    # Each table's approved column map goes into the model with it (sm.column_map_statements): the text as the store
    # holds that version, so the model alone is enough to put the store back.
    for entity in spec["entities"]:
        table = f"{entity['schema']}.{entity['table']}"
        doc = docs.get(table) or next((d for t, d in docs.items() if t.upper() == table.upper()), None)
        version = (doc or {}).get("version")
        if isinstance(version, int):
            try:
                text = store.read(table, version, home)
            except (OSError, ValueError):
                text = None
            if text:
                entity["map"] = {"table": table, "version": version, "text": text}
    return spec


def extensions(rows: Run, model: str, pattern: str) -> list[dict[str, Any]]:
    """The kit's records kept in a model, read with Semantic Views' own GET_CUSTOM_EXTENSIONS (vendor exakit): each
    whose name matches ``pattern`` (column_map_v3, data_map_v12), as {name, scope_type, scope_name, data}. [] when
    the model has none or cannot be read."""
    name = sm.model_name(model)
    try:
        found = rows(sm._script("GET_CUSTOM_EXTENSIONS", name, None, None, "exakit"))
    except Exception:                       # noqa: BLE001 - an older product: its catalog view, this model's rows
        try:
            found = [r for r in rows("SELECT * FROM SEMANTIC_CATALOG.CUSTOM_EXTENSIONS")
                     if any(isinstance(v, str) and v.upper() == name.upper() for v in r.values())]
        except Exception:                   # noqa: BLE001
            return []
    out = []
    for row in found:
        r = {str(k).upper(): v for k, v in row.items()}
        ext = str(r.get("EXTENSION_NAME") or next((v for v in r.values() if isinstance(v, str) and re.fullmatch(pattern, v)), ""))
        if not re.fullmatch(pattern, ext):
            continue
        data = r.get("DATA_JSON")
        if data is None:
            data = next((v for v in r.values() if isinstance(v, str) and v.strip().startswith("{")), None)
        try:
            data = json.loads(data) if isinstance(data, str) else data
        except ValueError:
            pass
        out.append({"name": ext, "scope_type": str(r.get("SCOPE_TYPE") or "MODEL"), "scope_name": r.get("SCOPE_NAME"), "data": data})
    return out


def remember_inputs(model: str, inputs: dict[str, Any], version: Any, home: Path | None = None) -> Path:
    """This computer's copy of what a data map was saved with, put back from the model (no spec: the next save
    builds it again from the column maps)."""
    path = spec_path(sm.model_name(model), home)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"spec": None, "inputs": inputs, "version": version}, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8")
    return path


def _versioned(execute: Callable[[str], Any], rows: Run, model: str, inputs: dict[str, Any], carried: list[dict[str, Any]],
               rebuilt: bool) -> tuple[int | None, list[str]]:
    """The model is the record, with its history: after a rebuild (which drops a model's extensions) every version
    kept in it before is put back; then, when what was said changed, the next data_map_v<N> is added - the inputs
    and the whole model as Semantic Views exports it (EXPORT_SEMANTIC_DEFINITION). (the version, warnings)."""
    said: list[str] = []
    if rebuilt:
        for ext in carried:
            scope = None if ext["scope_type"] == "MODEL" else ext["scope_name"]
            try:
                execute(sm._script("ADD_CUSTOM_EXTENSION", model, ext["scope_type"], scope, "exakit",
                                   json.dumps(ext["data"], ensure_ascii=False, default=str), "EXAKIT", ext["name"]))
            except Exception:                   # noqa: BLE001 - a version of a table no longer in the model
                said.append(f"{ext['name']} of {scope or model} could not be kept: its part is no longer in the model")
                continue
            if ext["name"].startswith("totals_") and isinstance(ext["data"], dict):
                try:                            # stored totals: registered with the rebuilt model again
                    for sql in sm.materialization_statements(model, ext["data"]):
                        execute(sql)
                except Exception as err:        # noqa: BLE001
                    said.append(f"stored totals {ext['data'].get('name')} are not used until stored again: "
                                f"{' '.join(str(err).split())[:160]}")
    versions = [x["data"] for x in carried if x["name"].startswith("data_map_v") and isinstance(x["data"], dict)]
    latest = max(versions, key=lambda d: d.get("version") or 0, default=None)
    same = lambda a, b: json.dumps(a or {}, sort_keys=True, default=str) == json.dumps(b or {}, sort_keys=True, default=str)
    if latest and same(latest.get("inputs"), inputs):
        return latest.get("version"), said
    number = int((latest or {}).get("version") or 0) + 1
    try:
        definition = [str({str(k).upper(): v for k, v in r.items()}.get("DEFINITION_SQL") or "")
                      for r in rows(sm._script("EXPORT_SEMANTIC_DEFINITION", model, None, None))]
    except Exception:                       # noqa: BLE001 - an older product: the inputs alone
        definition = []
    record = {"version": number, "saved_at": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
              "inputs": inputs, "definition": [d for d in definition if d]}
    try:
        execute(sm._script("ADD_CUSTOM_EXTENSION", model, "MODEL", None, "exakit", json.dumps(record, ensure_ascii=False, default=str),
                           "EXAKIT", f"data_map_v{number}"))
    except Exception as err:                # noqa: BLE001
        said.append(f"version {number} could not be kept in the model: {' '.join(str(err).split())[:200]}")
        return None, said
    return number, said


def publish_model(execute: Callable[[str], Any], rows: Run, spec: dict[str, Any], inputs: dict[str, Any], *,
                  reader: str | None = None, home: Path | None = None, extra: list[tuple[str, str]] | None = None,
                  progress: Callable[[str], None] | None = None) -> dict[str, Any]:
    """Install Semantic Views when needed, publish the model, keep its record in the model itself (a numbered
    data_map_v<N> on each change, the history carried across a rebuild) and a copy on this computer. The apply()
    result, with "version"."""
    ensure_installed(rows)
    before = kept(spec["model"], home) or {}
    previous = before.get("spec")
    governance = {k: before[k] for k in ("verified", "instructions", "fusion") if before.get(k)}
    carried = extensions(rows, spec["model"], r"(data_map|column_map)_v\d+|totals_\w+") if sm.existing(rows, spec["model"]) else []
    result = sm.apply(execute, rows, spec, reader=reader, previous=previous, extra=extra, progress=progress,
                      kept=governance, previous_extra=(before.get("inputs") or {}).get("extra"))
    version, said = _versioned(execute, rows, spec["model"], inputs, carried, result.get("mode") == "rebuilt")
    result["version"] = version
    result["warnings"] = list(result.get("warnings") or []) + said
    keep(spec, inputs, home, governance)
    return result


def publish_schema(execute: Callable[[str], Any], rows: Run, schema: str, reader: str | None, *,
                   docs: dict[str, dict[str, Any]] | None = None, home: Path | None = None) -> dict[str, Any]:
    """Rebuild the semantic model of ``schema`` from its approved column maps and its approved links."""
    tables = approved_tables(schema, home)
    tables.update(docs or {})
    links = schema_links(schema, home)
    spec = build_model(rows, sorted(tables), links, schema, docs=tables, home=home)
    result = publish_model(execute, rows, spec, {"tables": sorted(tables), "links": links, "name": schema,
                                                 "schema": schema}, reader=reader, home=home)
    result["view"] = f"semantic model {result['model']} ({result['published_schema']})"
    return result


def publish(execute: Callable[[str], Any], rows: Run, doc: dict[str, Any], reader: str | None,
            home: Path | None = None) -> dict[str, Any]:
    """Publish an approved column map: its schema's semantic model, rebuilt with this approval in it."""
    table = doc["source"]["object"]
    result = publish_schema(execute, rows, table.split(".", 1)[0], reader, docs={table: doc}, home=home)
    result["refreshed"] = refresh_including(execute, rows, table, reader, home=home, warnings=result.setdefault("warnings", []))
    try:
        everything = publish_all(execute, rows, reader, home=home)
        if everything:
            result["refreshed"].append(everything["model"])
    except Exception as err:                       # the approval and its schema's model stand
        result["warnings"].append(f"the model of all your data ({ALL_MODEL}) was not updated: {' '.join(str(err).split())[:200]} "
                                  f"(again: exakit describe --model {ALL_MODEL} --refresh)")
    return result


ALL_MODEL = "all_data"
ALL_ABOUT = ("Every table with an approved column map, from every source: sample data, your own tables and files, "
             "and every external source, read live where it lives.")


def all_tables(rows: Run, home: Path | None = None) -> list[str]:
    """Every table the store has an approved column map for that the database still has (a table dropped, or a source
    disconnected, since it was approved is left out)."""
    approved = sorted(approved_tables(None, home))
    if not approved:
        return []
    types, _virtual = column_types(rows, approved)
    present = {t.upper() for t in types}
    return [t for t in approved if t.upper() in present]


def your_definitions(spec: dict[str, Any], metrics: list | None, instructions: list | None,
                     hidden: dict[str, list[str]] | None = None,
                     synonyms: dict[str, list[str]] | None = None) -> list[tuple[str, str]]:
    """Your metrics as Semantic Views definitions (sm.user_metrics), your instructions and the columns you hide in
    answers (sm.field_policies) on the spec; what cannot be one is said in the spec's notes. [(view, definition)]."""
    extra, refused = sm.user_metrics(spec, metrics or [])
    spec["policies"], hide_refused = sm.field_policies(spec, hidden)
    spec["synonym_calls"], words_refused = sm.user_synonyms(spec, synonyms, metrics)
    refused += hide_refused + words_refused
    spec["instructions"] = list(spec.get("instructions") or []) + sm.user_instructions(spec, instructions or [])
    spec["notes"] = list(spec.get("notes") or []) + refused
    return extra


def all_spec(rows: Run, *, home: Path | None = None, tables: list[str] | None = None,
             links: list[dict[str, Any]] | None = None, table_notes: dict[str, str] | None = None,
             description: str | None = None, labels: dict[str, Any] | None = None,
             extra: list | None = None, grains: dict[str, str] | None = None, starts: list[str] | None = None,
             metrics: list | None = None, instructions: list | None = None,
             replace_links: bool = False, hidden: dict[str, list[str]] | None = None,
             synonyms: dict[str, list[str]] | None = None) -> tuple[dict[str, Any], dict[str, Any], list] | None:
    """(the spec of the model over all your data, its inputs, its extra definitions), as publish_all would build it;
    None when nothing is approved. Nothing is written."""
    kept_inputs = (kept(ALL_MODEL, home) or {}).get("inputs") or {}
    every = all_tables(rows, home)
    every += [t for t in tables or [] if t not in every]
    if not every:
        return None
    joins: list[dict[str, Any]] = []
    for link in list(links or []) + ([] if replace_links else list(kept_inputs.get("links") or [])):
        if not any(j["from"] == link["from"] for j in joins):
            joins.append(link)
    for schema in sorted({t.split(".", 1)[0] for t in every}):
        for link in schema_links(schema, home):
            if not any(j["from"] == link["from"] for j in joins):
                joins.append(link)
    joins = [j for j in joins if j["from"].rsplit(".", 1)[0] in every and j["to"].rsplit(".", 1)[0] in every]
    notes = {**(kept_inputs.get("table_notes") or {}), **{k.upper(): v for k, v in (table_notes or {}).items()}}
    about = description or kept_inputs.get("description") or ALL_ABOUT
    grains = {**(kept_inputs.get("grains") or {}), **{k.upper(): v for k, v in (grains or {}).items()}}
    starts = list(starts if starts is not None else kept_inputs.get("starts") or [])
    metrics = list(metrics if metrics is not None else kept_inputs.get("metrics") or [])
    instructions = list(instructions if instructions is not None else kept_inputs.get("instructions") or [])
    hidden = {str(k).upper(): list(v) for k, v in (hidden if hidden is not None else kept_inputs.get("hidden") or {}).items() if v}
    synonyms = {str(k): list(v) for k, v in (synonyms if synonyms is not None else kept_inputs.get("synonyms") or {}).items() if v}
    spec = build_model(rows, every, joins, ALL_MODEL, description=about, home=home, grains=grains, starts=starts)
    for entity in spec["entities"]:
        said = notes.get(f"{entity['schema']}.{entity['table']}".upper())
        if said:
            entity["description"] = said.rstrip(".") + ". " + sm.where_from(entity.get("origin") or {}, entity["schema"],
                                                                           bool(entity.get("virtual")))
    labels = {**(kept_inputs.get("labels") or {}), **(labels or {})}
    if labels:
        apply_labels(spec, labels)
    extra = [tuple(x) for x in (extra if extra is not None else kept_inputs.get("extra") or [])]
    cross = [j for j in joins if j["from"].split(".", 1)[0] != j["to"].split(".", 1)[0] or j.get("evidence")]
    inputs = {"tables": every, "links": cross, "name": ALL_MODEL, "all": True,
              "description": about if about != ALL_ABOUT else None, "table_notes": notes,
              "labels": labels, "extra": [list(x) for x in extra], "grains": grains, "starts": starts,
              "metrics": metrics, "instructions": instructions, "hidden": hidden, "synonyms": synonyms}
    extra = extra + your_definitions(spec, metrics, instructions, hidden, synonyms)
    return spec, inputs, extra


def publish_all(execute: Callable[[str], Any], rows: Run, reader: str | None, *, home: Path | None = None,
                tables: list[str] | None = None, links: list[dict[str, Any]] | None = None,
                table_notes: dict[str, str] | None = None, description: str | None = None,
                labels: dict[str, Any] | None = None, extra: list | None = None,
                progress: Callable[[str], None] | None = None, grains: dict[str, str] | None = None,
                starts: list[str] | None = None, metrics: list | None = None,
                instructions: list | None = None, replace_links: bool = False,
                hidden: dict[str, list[str]] | None = None,
                synonyms: dict[str, list[str]] | None = None) -> dict[str, Any] | None:
    """The one model over all your data (ALL_MODEL): every approved table of every source, each schema's approved
    links, and the links across sources you confirmed for it (kept beside it), its fusion and verified questions with
    it. Built or changed in place on every approval; EXAKIT_ALL_DATA_MODEL=0 turns it off. None when nothing is
    approved. ``tables`` and the rest add to what is kept (the Semantic views card publishing under this name)."""
    if os.environ.get("EXAKIT_ALL_DATA_MODEL", "1").strip() == "0":
        return None
    built = all_spec(rows, home=home, tables=tables, links=links, table_notes=table_notes, description=description,
                     labels=labels, extra=extra, grains=grains, starts=starts, metrics=metrics, instructions=instructions,
                     replace_links=replace_links, hidden=hidden, synonyms=synonyms)
    if built is None:
        return None
    spec, inputs, extra = built
    result = publish_model(execute, rows, spec, inputs, reader=reader, home=home, extra=extra, progress=progress)
    result["view"] = f"semantic model {result['model']} ({result['published_schema']})"
    return result


def planned(rows: Run, spec: dict[str, Any], home: Path | None = None) -> list[str]:
    """The statements publishing ``spec`` would run, in order, as SQL a person can read and edit: the change to the
    model published before when it can be made in place, else the whole model (after dropping the one there)."""
    previous = (kept(spec["model"], home) or {}).get("spec")
    found = sm.existing(rows, spec["model"])
    step = sm.changes(previous, spec) if found else None
    if step is not None:
        return step
    drop = [sm._script("DROP_MODEL_IF_EXISTS", spec["model"])] if found else []
    return drop + sm.statements(spec)


def run_statements(execute: Callable[[str], Any], rows: Run, model: str, statements: list[str], reader: str | None,
                   home: Path | None = None) -> dict[str, Any]:
    """Run a model's statements as a person edited them, in order, after the same checks a publish makes: Semantic
    Views is installed, and a model of that name someone else made is left alone. Only Semantic Views' own scripts
    and Semantic SQL are taken. The model is then marked edited by hand, so the next approval rebuilds it from the
    column maps (an edit is not merged into a later change). The read-only user can read it."""
    import re

    ensure_installed(rows)
    name = sm.model_name(model)
    found = sm.existing(rows, name)
    if found and not found["kit"]:
        raise sm.ModelRefused(f"A semantic model named {found['name']} already exists and the kit did not build it; it is left alone.")
    allowed = re.compile(r"(?is)^\s*(EXECUTE\s+SCRIPT\s+SEMANTIC_ADMIN\.|ALTER\s+SEMANTIC\s+VIEW\s|ALTER\s+SESSION\s)")
    wrong = [s for s in statements if not allowed.match(str(s))]
    if wrong:
        raise sm.ModelRefused("Only Semantic Views' own statements run here (EXECUTE SCRIPT SEMANTIC_ADMIN..., ALTER SEMANTIC "
                              f"VIEW ...), not: {' '.join(str(wrong[0]).split())[:120]}")
    for statement in statements:
        execute(str(statement).strip().rstrip(";"))
    warnings = []
    if reader:
        warnings += sm.grant_reader(execute, name, reader)
    before = kept(name, home)
    if before:
        before["spec"] = dict(before.get("spec") or {}, edited=True, model=name, description="edited by hand")
        path = spec_path(name, home)
        path.write_text(json.dumps(before, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return {"model": name, "statements": len(statements), "mode": "your statements", "warnings": warnings,
            "view": f"semantic model {name} ({sm.published_schema(name)})", "views": [], "counts": {}, "notes": []}


def refresh_including(execute: Callable[[str], Any], rows: Run, table: str, reader: str | None, *,
                      home: Path | None = None, warnings: list[str] | None = None) -> list[str]:
    """Rebuild every multi-source model the kit published that has ``table`` in it, so a changed column map reaches
    each model it is part of. The names of the models rebuilt; one that fails is a warning, never an error."""
    folder = (home or store.kit_home()) / FOLDER
    done = []
    for path in sorted(folder.glob("*.json")) if folder.is_dir() else []:
        try:
            inputs = json.loads(path.read_text(encoding="utf-8"))["inputs"]
        except (OSError, ValueError, KeyError):
            continue
        if inputs.get("schema") or inputs.get("all") or table not in (inputs.get("tables") or []):
            continue                                # (the model of all your data is updated by publish_all)
        try:
            refresh(execute, rows, path.stem, reader, home=home)
            done.append(path.stem)
        except Exception as err:                   # the approval and its schema's model stand
            if warnings is not None:
                warnings.append(f"the model {path.stem} was not refreshed: {' '.join(str(err).split())[:200]} "
                                f"(again: exakit describe --model {path.stem} --refresh)")
    return done


def refresh(execute: Callable[[str], Any], rows: Run, model: str, reader: str | None, *,
            home: Path | None = None) -> dict[str, Any]:
    """Rebuild a model the kit published before, from what it was built on and the column maps approved since."""
    found = kept(model, home)
    if not found and sm.model_name(model) == ALL_MODEL:
        result = publish_all(execute, rows, reader, home=home)
        if result is None:
            raise sm.ModelRefused("No table has an approved column map yet, so there is no model of all your data.")
        return result
    if not found:
        raise sm.ModelRefused(f"The kit has not published a model named {sm.model_name(model)} on this computer.")
    inputs = found["inputs"]
    if inputs.get("schema"):
        return publish_schema(execute, rows, inputs["schema"], reader, home=home)
    if inputs.get("all"):
        return publish_all(execute, rows, reader, home=home)
    spec = build_model(rows, list(inputs["tables"]), list(inputs.get("links") or []), inputs.get("name") or model,
                       description=inputs.get("description"), home=home, grains=inputs.get("grains"),
                       starts=inputs.get("starts"))
    for entity in spec["entities"]:            # what a person said each table is, kept with the model
        about = (inputs.get("table_notes") or {}).get(f"{entity['schema']}.{entity['table']}".upper())
        if about:
            entity["description"] = about + (" (an external source, read live)" if entity.get("virtual") else "")
    if inputs.get("labels"):
        apply_labels(spec, inputs["labels"])
    extra = [(view, ddl) for view, ddl in inputs.get("extra") or []]
    extra += your_definitions(spec, inputs.get("metrics"), inputs.get("instructions"), inputs.get("hidden"), inputs.get("synonyms"))
    result = publish_model(execute, rows, spec, inputs, reader=reader, home=home, extra=extra)
    result["view"] = f"semantic model {result['model']} ({result['published_schema']})"
    return result


def apply_labels(spec: dict[str, Any], labels: dict[str, Any]) -> dict[str, Any]:
    """Display names, comments and synonyms for named elements ({name: {display, comment, synonyms}}): only text,
    so a label can never break a model. The model description too, under the key "model"."""
    for obj in spec["objects"]:
        for element in obj["dimensions"] + obj["facts"] + obj["metrics"]:
            label = labels.get(element["name"])
            if not isinstance(label, dict):
                continue
            if str(label.get("display") or "").strip():
                element["display"] = " ".join(str(label["display"]).split())[:120]
            if str(label.get("comment") or "").strip():
                element["comment"] = " ".join(str(label["comment"]).split())[:500]
            if isinstance(label.get("synonyms"), list):
                words = [" ".join(str(s).split())[:60] for s in label.get("synonyms") or [] if str(s).strip()]
                element["synonyms"] = sorted(set(words), key=words.index)[:8]
    about = labels.get("model")
    if isinstance(about, str) and about.strip():
        spec["description"] = " ".join(about.split())[:400] + " " + sm.MARK
    return spec


def model_of(rows: Run, table: str) -> str | None:
    """The semantic model the kit built that has ``table`` (SCHEMA.TABLE) as an entity, when there is one."""
    schema, name = table.split(".", 1)
    try:
        found = rows("SELECT E.MODEL_NAME, M.PUBLISHED_SCHEMA, M.DESCRIPTION FROM SEMANTIC_CATALOG.ENTITIES E "
                     "JOIN SEMANTIC_CATALOG.MODELS M ON M.MODEL_ID = E.MODEL_ID "
                     f"WHERE E.SOURCE_SCHEMA = {sm.literal(schema)} AND E.SOURCE_OBJECT = {sm.literal(name)} "
                     "AND E.STATUS = 'ACTIVE'")
    except Exception:
        return None
    for row in found:
        if sm.MARK in str(row.get("DESCRIPTION") or ""):
            return f"semantic model {row['MODEL_NAME']} ({row.get('PUBLISHED_SCHEMA')})"
    return None


# --- the data map as a person fills it in: what Semantic Views needs, read from your approvals --------------------------

def data_map_inputs(tables: list[str], model: str = ALL_MODEL, home: Path | None = None) -> dict[str, Any]:
    """Everything the data map card shows, from this computer only (the approved column maps and what was saved with
    the model before; no query): per table its key, grain and columns (role, note, the known values of a column to
    group by), and what you said before - grains, table notes, links with their type, metrics, starting points,
    instructions, the description."""
    found: dict[str, Any] = {"tables": {}, "missing": []}
    for table in tables:
        name = flow_table(str(table))
        text = store.current(name, home) or store.current(str(table), home)
        if not text:
            found["missing"].append(name)
            continue
        doc = _load(text)
        version = doc.get("version")
        profile = store.read_profile(name, int(version), home) if isinstance(version, int) else None
        shaped = sm.table_input(name, doc, {}, profile=profile)
        found["tables"][name] = {
            "key": shaped["key"], "grain": shaped["grain"],
            "columns": [{"name": c["name"], "role": c["role"], "note": c["note"],
                         **({"values": c["values"]} if c["role"] in sm.DIMENSION_ROLES and c["values"] else {})}
                        for c in shaped["columns"] if not c["sensitive"]]}
    had = kept(model, home)
    found["saved"] = had is not None
    saved = (had or {}).get("inputs") or {}
    inside = lambda column: str(column).rsplit(".", 1)[0].upper() in {t.upper() for t in found["tables"]}
    found.update({
        "grains": {t: g for t, g in (saved.get("grains") or {}).items() if t in found["tables"]},
        "table_notes": {t: n for t, n in (saved.get("table_notes") or {}).items() if t in found["tables"]},
        "links": [{"from": l["from"], "to": l["to"], "type": l.get("cardinality") or "MANY_TO_ONE",
                   "join": l.get("join_type") or "LEFT", "fanout": l.get("fanout"),
                   "note": "" if (l.get("evidence") or {}).get("note") in (None, "given by a person", "given with --link")
                   else l["evidence"]["note"], "by": (l.get("evidence") or {}).get("proposed_by") or "you"}
                  for l in saved.get("links") or [] if inside(l["from"]) and inside(l["to"])],
        "metrics": [m for m in saved.get("metrics") or [] if str(m.get("table") or "").upper() in found["tables"]],
        "starts": [t for t in saved.get("starts") or [] if t in found["tables"]],
        "instructions": list(saved.get("instructions") or []),
        "hidden": {t: list(c) for t, c in (saved.get("hidden") or {}).items() if t in found["tables"]},
        "synonyms": {f: list(w) for f, w in (saved.get("synonyms") or {}).items()},
        "description": saved.get("description") or ""})
    return found


DRAFT_INSTRUCTIONS = """You draft a data map (an Exasol Semantic Views model) for a person to check. Below are tables with
their key, what one row is (grain), and their columns: name, role and note, and for a column to group by its known
values. You never see a row. Answer with ONE JSON object and nothing else:
{"description": "<what the data is about, one sentence>",
 "table_notes": {"SCHEMA.TABLE": "<what the table is>"},
 "grains": {"SCHEMA.TABLE": "one row is <...>"},
 "links": [{"from": "SCHEMA.TABLE.COLUMN", "to": "SCHEMA.TABLE.KEY", "type": "MANY_TO_ONE|ONE_TO_ONE", "note": "<why>"}],
 "starts": ["SCHEMA.TABLE"],
 "metrics": [{"table": "SCHEMA.TABLE", "name": "lower_snake", "how": "sum|count|average", "column": "<an amount column>",
              "where": {"column": "<a column to group by>", "values": ["<known values>"]}, "about": "<what it means>"}],
 "instructions": ["<a rule an analyst must know, such as what an amount includes>"],
 "hidden": {"SCHEMA.TABLE": ["<a column to group by that holds a person's name, email, phone or address>"]}}
A link goes from a column of one table to the key of ANOTHER table, many-to-one unless both sides hold each value once.
Starts are the tables questions begin from: the ones with amounts. A metric's where is optional and uses known values
only. Use only the names given. Leave out what you are unsure of."""


def draft_data_map(tables: list[str], chat: Callable[[str], str], home: Path | None = None) -> dict[str, Any]:
    """One AI call drafts the whole data map from names, roles, notes and known values (never a row): grains, table
    notes, links with their type, starting points, metrics, instructions, a description. Only what names a real
    table and column is kept, each marked as the AI's; nothing is saved. {..., refused: [what was dropped and why]}."""
    facts = data_map_inputs(tables, home=home)
    known = facts["tables"]
    if not known:
        raise sm.ModelRefused("None of these tables has an approved column map yet: approve one first.")
    text = chat(DRAFT_INSTRUCTIONS + "\n\nTables: " + json.dumps(known, ensure_ascii=False, default=str)).strip()
    try:
        answer = json.loads(text[text.find("{"):text.rfind("}") + 1])
    except ValueError as err:
        raise sm.ModelRefused(f"The AI's answer was not JSON ({str(err)[:120]}); press the button again.") from None
    answer = answer if isinstance(answer, dict) else {}
    columns = {t: {c["name"].upper(): c for c in v["columns"]} for t, v in known.items()}
    canon_of = {t.upper(): t for t in known}             # a source's lower-case table keeps its own spelling
    canon = lambda text: canon_of.get(str(text).upper(), str(text).upper())
    column_of = lambda full: (lambda t, c: columns.get(canon(t), {}).get(c.upper()))(*(str(full).rsplit(".", 1) + [""])[:2])
    refused: list[str] = []
    said = lambda key: {canon(t): " ".join(str(v).split())[:300] for t, v in (answer.get(key) or {}).items()
                        if canon(t) in known and str(v).strip()} if isinstance(answer.get(key), dict) else {}
    links = []
    for link in answer.get("links") or []:
        if not isinstance(link, dict):
            continue
        source, target = str(link.get("from") or ""), str(link.get("to") or "")
        source = f"{canon(source.rsplit('.', 1)[0])}.{(column_of(source) or {}).get('name', source.rsplit('.', 1)[-1])}" if "." in source else source
        target = f"{canon(target.rsplit('.', 1)[0])}.{(column_of(target) or {}).get('name', target.rsplit('.', 1)[-1])}" if "." in target else target
        kind = str(link.get("type") or "MANY_TO_ONE").upper().replace("-", "_")
        if not column_of(source) or not column_of(target) or source.rsplit(".", 1)[0] == target.rsplit(".", 1)[0]:
            refused.append(f"link {source} -> {target}: not a column of one table and a column of another")
            continue
        links.append({"from": source, "to": target, "type": kind if kind in ("MANY_TO_ONE", "ONE_TO_ONE") else "MANY_TO_ONE",
                      "note": " ".join(str(link.get("note") or "").split())[:300], "by": "ai"})
    metrics = []
    for m in answer.get("metrics") or []:
        if not isinstance(m, dict):
            continue
        table, how = canon(m.get("table") or ""), str(m.get("how") or "sum").lower()
        column = columns.get(table, {}).get(str(m.get("column") or "").upper())
        where = m.get("where") if isinstance(m.get("where"), dict) else {}
        by = columns.get(table, {}).get(str(where.get("column") or "").upper()) if where else None
        if table not in known or how not in sm.HOW or (how != "count" and (not column or column["role"] != "measure")):
            refused.append(f"metric {m.get('name')}: not an amount of a table given")
            continue
        if where and (not by or by["role"] not in sm.DIMENSION_ROLES):
            refused.append(f"metric {m.get('name')}: its condition is not on a column to group by")
            continue
        metrics.append({"table": table, "name": sm.identifier(m.get("name") or "", "metric"), "how": how,
                        **({"column": column["name"]} if column and how != "count" else {}),
                        **({"where": {"column": by["name"], "values": [str(v) for v in where.get("values") or []][:10]}} if by else {}),
                        "about": " ".join(str(m.get("about") or "").split())[:300], "by": "ai"})
    return {"description": " ".join(str(answer.get("description") or "").split())[:300],
            "table_notes": said("table_notes"), "grains": said("grains"), "links": links,
            "starts": [canon(t) for t in answer.get("starts") or [] if canon(t) in known],
            "metrics": metrics,
            "instructions": [" ".join(str(i).split())[:500] for i in answer.get("instructions") or [] if str(i).strip()][:10],
            "hidden": {t: [columns[t][str(c).upper()]["name"] for c in cs if str(c).upper() in columns.get(t, {})]
                       for t, cs in ((canon(t), cs) for t, cs in (answer.get("hidden") or {}).items()
                                     if isinstance(answer.get("hidden"), dict) and isinstance(cs, list)) if t in known},
            "refused": refused}
