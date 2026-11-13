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

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable

from . import semantic_model as sm
from . import store

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


def approved_tables(schema: str, home: Path | None = None) -> dict[str, dict[str, Any]]:
    """{SCHEMA.TABLE: approved column map} for every table of ``schema`` the store has an approval for."""
    root = (home or store.kit_home()) / store.FOLDER
    found: dict[str, dict[str, Any]] = {}
    if not root.is_dir():
        return found
    for folder in sorted(root.iterdir()):
        name = folder.name
        if not folder.is_dir() or "." not in name or name.split(".", 1)[0].upper() != schema.upper():
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


def keep(spec: dict[str, Any], inputs: dict[str, Any], home: Path | None = None) -> Path:
    path = spec_path(spec["model"], home)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps({"spec": spec, "inputs": inputs}, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(temp, path)
    return path


# --- publishing ---------------------------------------------------------------------------------------------------------------

def build_model(rows: Run, tables: list[str], links: list[dict[str, str]], name: str, *,
                description: str | None = None, docs: dict[str, dict[str, Any]] | None = None,
                home: Path | None = None) -> dict[str, Any]:
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
    inputs = []
    for t in tables:
        version = docs[t].get("version")
        profile = store.read_profile(t, int(version), home) if isinstance(version, int) else None
        inputs.append(sm.table_input(t, docs[t], types.get(t, {}), virtual=t.split(".", 1)[0] in virtual, profile=profile))
    return sm.build(inputs, links, name, description=description)


def publish_model(execute: Callable[[str], Any], rows: Run, spec: dict[str, Any], inputs: dict[str, Any], *,
                  reader: str | None = None, home: Path | None = None, extra: list[tuple[str, str]] | None = None,
                  progress: Callable[[str], None] | None = None) -> dict[str, Any]:
    """Install Semantic Views when needed, rebuild the model, keep its spec. The apply() result."""
    ensure_installed(rows)
    previous = (kept(spec["model"], home) or {}).get("spec")
    result = sm.apply(execute, rows, spec, reader=reader, previous=previous, extra=extra, progress=progress)
    keep(spec, inputs, home)
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
    return result


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
        if inputs.get("schema") or table not in (inputs.get("tables") or []):
            continue
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
    if not found:
        raise sm.ModelRefused(f"The kit has not published a model named {sm.model_name(model)} on this computer.")
    inputs = found["inputs"]
    if inputs.get("schema"):
        return publish_schema(execute, rows, inputs["schema"], reader, home=home)
    spec = build_model(rows, list(inputs["tables"]), list(inputs.get("links") or []), inputs.get("name") or model,
                       description=inputs.get("description"), home=home)
    for entity in spec["entities"]:            # what a person said each table is, kept with the model
        about = (inputs.get("table_notes") or {}).get(f"{entity['schema']}.{entity['table']}".upper())
        if about:
            entity["description"] = about + (" (an external source, read live)" if entity.get("virtual") else "")
    if inputs.get("labels"):
        apply_labels(spec, inputs["labels"])
    extra = [(view, ddl) for view, ddl in inputs.get("extra") or []]
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
