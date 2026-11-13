"""Your own CSV, Parquet or JSON file as a dataset: loaded into a table over the kit's connection, described by a few
role assignments, and checked by the same rules as a kit dataset - so the notebooks run on it unchanged.

    ds = nb.load_own_file("~/data/transactions.csv", "MY_DATA.TRANSACTIONS",
                          {"entity": "CUSTOMER_ID", "category": "MERCHANT_TYPE", "date": "BOOKED_ON",
                           "label": "DISPUTED", "text": ["MEMO"]})

The descriptor is that mapping of role to column, a descriptor mapping (``schema_version``, ``id``, ``fact_table``,
``roles``), or a descriptor file - YAML or JSON; ``data/datasets/<id>/descriptor.yaml`` in the kit shows the shape -
whose fact_table then names the table (``table`` may be None). Given as a mapping of roles, they become a
schema_version 2 **draft** (version 1, drafted by the user, owned by EXAKIT_DESCRIPTOR_OWNER or the OS user, its
``source`` the file) and are written beside the file as ``<name>.descriptor.yaml`` (when no descriptor is there yet),
so ``DATASET = "<the file>"`` in a notebook opens it again with that one assignment; approving it (the quickstart's
approve(), or exakit describe <id> --approve) is what the training and question steps wait for, exploring does not.
The rows travel over pyexasol's import on the open connection: no
host, user or password here, as everywhere in exakit.nb. Column types come from the file; the date role's column
becomes a DATE and a true/false column 0 or 1; a JSON file is an array of records or one record per line, its nested
values kept as JSON text. The table is marked as loaded from the file (its comment holds the file's SHA-256), so
running the cell again loads nothing when the file is unchanged and reloads it when it changed; a table of the same
name that this did not create is refused unless ``replace=True``.
"""

from __future__ import annotations

import datetime as dt
import getpass
import hashlib
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .dataset import Dataset, _rules, checked

__all__ = ["LoadedTable", "descriptor_beside", "descriptor_owner", "load_own_file", "save_descriptor"]


@dataclass(frozen=True)
class LoadedTable:
    """A file that has been loaded but has not yet received an approved descriptor."""

    id: str
    fact_table: str
    path: Path

OWNER_VARIABLE = "EXAKIT_DESCRIPTOR_OWNER"      # who a descriptor written here belongs to; the OS user otherwise

FORMATS = {".csv": "csv", ".parquet": "parquet", ".pq": "parquet", ".json": "json", ".jsonl": "json", ".ndjson": "json"}
BESIDE = (".descriptor.yaml", ".descriptor.yml", ".descriptor.json")   # <file name without its extension><one of these>
MARK = "exakit_nb.load_own_file sha256="       # the table comment that says which file a table was loaded from
MAX_VARCHAR = 2000000


def _digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            sha.update(block)
    return sha.hexdigest()


def descriptor_beside(file: str | Path) -> Path | None:
    """The descriptor that describes a data file: ``<name>.descriptor.yaml`` beside it, else its folder's
    descriptor.yaml; None when there is neither."""
    file = Path(file).expanduser()
    for suffix in BESIDE:
        if (file.parent / f"{file.stem}{suffix}").is_file():
            return file.parent / f"{file.stem}{suffix}"
    return _rules().descriptor_file(file.parent)


def _read_doc(path: Path) -> Any:
    """The document in a descriptor file (or in a dataset folder's), YAML or JSON, not yet validated."""
    rules, path = _rules(), Path(path).expanduser()
    if path.is_dir():
        found = rules.descriptor_file(path)
        if found is None:
            raise ValueError(f"{path} holds no descriptor.yaml.")
        path = found
    text = path.read_text(encoding="utf-8-sig")
    try:
        return json.loads(text) if text.lstrip().startswith("{") else rules.load_yaml(text)
    except ValueError as err:
        raise rules.BadInput(f"The descriptor {path} cannot be read ({err}).") from err


def descriptor_owner() -> str:
    """Who owns a descriptor written here: EXAKIT_DESCRIPTOR_OWNER when set, else the OS user."""
    given = os.environ.get(OWNER_VARIABLE, "").strip()
    if given:
        return given
    try:
        return getpass.getuser()
    except (OSError, KeyError, ImportError):
        return "unknown"


def _now() -> str:
    """The time now, ISO-8601 in UTC to the second, as a descriptor's ``created``."""
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _record(status: str, source: str | None) -> dict[str, Any]:
    """The schema_version 2 record of a descriptor drafted here from roles given by hand: version 1, by the user."""
    if status not in _rules().STATUSES:
        raise ValueError(f"status must be draft or approved, not '{status}'.")
    record: dict[str, Any] = {"version": 1, "status": status, "owner": descriptor_owner(), "created": _now(),
                              "drafted_by": "user", "digest": None}
    if source:
        record["source"] = source
    return record


def _descriptor_doc(descriptor: Any, table: str | None, file: Path | None = None) -> dict[str, Any]:
    """A full descriptor document from a descriptor file, a full document, or a mapping of role to column(s) of
    ``table`` - the last a schema_version 2 draft whose source is ``file`` when given."""
    if isinstance(descriptor, (str, Path)):
        doc = _read_doc(Path(descriptor))
        if not isinstance(doc, dict):
            raise ValueError(f"The descriptor {descriptor} is not a mapping of keys to values.")
        return doc
    if not isinstance(descriptor, dict):
        raise ValueError("The descriptor is a mapping of role to column, e.g. {'entity': 'CUSTOMER_ID', ...}, or a file path.")
    if "roles" in descriptor or "descriptor" in descriptor:       # a whole document, either shape
        return descriptor
    if table is None:
        raise ValueError("Name the table to load the file into (SCHEMA.TABLE): the roles alone do not say which.")

    def ref(column: Any) -> Any:
        return {"table": table, "column": column} if isinstance(column, str) else column

    name = re.sub(r"_+", "_", table.split(".", 1)[-1].lower()).strip("_")
    return {"schema_version": _rules().SCHEMA_VERSION, "id": name, "fact_table": table,
            **_record("draft", f"file:{file}" if file is not None else None),
            "roles": {role: [ref(c) for c in value] if isinstance(value, list) else ref(value) for role, value in descriptor.items()}}


def _yaml_scalar(value: Any) -> str:
    """A value as the descriptor reader reads it back: null, true/false and numbers plain, a plain SQL or dataset name
    plain, any other text quoted."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    text = str(value)
    # A number-like string ("0", "1e3") must stay a string: plain, the reader would take it as a number.
    if re.fullmatch(r"-?\d+(\.\d+)?([eE][+-]?\d+)?", text):
        return json.dumps(text)
    return text if re.fullmatch(r"[A-Za-z0-9_.-]+", text) and text not in ("null", "true", "false") else json.dumps(text)


def _yaml_flow(value: Any) -> str:
    """A mapping or list inline, ``{k: v, ...}`` / ``[a, ...]``, its scalars as _yaml_scalar writes them."""
    if isinstance(value, dict):
        return "{" + ", ".join(f"{_yaml_scalar(k)}: {_yaml_flow(v)}" for k, v in value.items()) + "}"
    if isinstance(value, (list, tuple)):
        return "[" + ", ".join(_yaml_flow(v) for v in value) + "]"
    return _yaml_scalar(value)


def _yaml_block(key: str, value: Any, indent: str = "") -> list[str]:
    """``key:`` and its value as block lines: a mapping one key per line (a long flat nested mapping on lines of its
    own, the rest inline), a list one ``- {...}`` per item, an empty one or a scalar inline."""
    if isinstance(value, dict) and value:
        lines = [f"{indent}{_yaml_scalar(key)}:"]
        for k, v in value.items():
            if isinstance(v, dict) and len(v) > 4 and all(not isinstance(x, (dict, list, tuple)) for x in v.values()):
                lines += _yaml_block(k, v, indent + "  ")
            else:
                lines.append(f"{indent}  {_yaml_scalar(k)}: {_yaml_flow(v)}")
        return lines
    if isinstance(value, (list, tuple)) and value:
        return [f"{indent}{_yaml_scalar(key)}:"] + [f"{indent}  - {_yaml_flow(item)}" for item in value]
    return [f"{indent}{_yaml_scalar(key)}: {_yaml_flow(value)}"]


def save_descriptor(doc: dict[str, Any], path: str | Path, about: str = "", *, status: str | None = None,
                    source: str | None = None) -> Path:
    """Write a descriptor document as YAML, in the layout of the kit's own descriptor.yaml files - always as
    schema_version 2: a schema_version 1 document (or one without the record keys) is written as version 1 with
    ``status`` (draft unless the document, or ``status``, says approved), the owner (EXAKIT_DESCRIPTOR_OWNER, else the
    OS user), created now, drafted by the user and, when given, ``source`` (``file:<path>`` for a file's descriptor).
    What the document already records is kept as it is."""
    def ref(item: dict[str, Any]) -> str:
        return f"{{table: {_yaml_scalar(item['table'])}, column: {_yaml_scalar(item['column'])}}}"

    rules = _rules()
    record = dict(_record(status or "draft", source), **{k: v for k, v in doc.items()
                                                         if k in rules.RECORD_KEYS + ("digest", "drafted_by") and v is not None})
    if status is not None:
        record["status"] = status
    if source is not None:
        record["source"] = source
    elif doc.get("source"):                      # a schema_version 1 source is a live source's bare alias: vs:<alias> in 2
        record["source"] = doc["source"] if doc.get("schema_version") != 1 else f"{rules._LIVE}{doc['source']}"
    lines = [f"# {about or 'Which column plays which role (exakit.nb).'}", f"schema_version: {rules.SCHEMA_VERSION}",
             f"id: {_yaml_scalar(doc['id'])}", f"fact_table: {_yaml_scalar(doc['fact_table'])}"]
    if record.get("source"):
        lines.append(f"source: {_yaml_scalar(record['source'])}")
    lines += [f"{key}: {_yaml_scalar(record[key])}" for key in ("version", "status", "owner", "created", "drafted_by", "digest")]
    lines.append("roles:")
    for role, value in doc["roles"].items():
        if isinstance(value, list):
            lines.append(f"  {role}:")
            lines += [f"    - {ref(item)}" for item in value]
        else:
            lines.append(f"  {role}: {ref(value)}")
    for key in ("evidence", "notes", "missing"):
        if key in doc and doc[key] is not None:
            lines += _yaml_block(key, doc[key])
    target = Path(path).expanduser()
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return target


def _read_json(pd, path: Path):
    """A JSON file as a DataFrame: an array of records, or one record per line (.jsonl, .ndjson, or a .json written that
    way). Nested objects and lists become their JSON text, so they load as text columns."""
    lines = path.suffix.lower() in (".jsonl", ".ndjson")
    try:
        frame = pd.read_json(path, lines=lines, dtype=False)
    except ValueError:
        if lines:
            raise
        frame = pd.read_json(path, lines=True, dtype=False)
    for name in frame.columns:
        if frame[name].map(lambda v: isinstance(v, (dict, list))).any():
            frame[name] = frame[name].map(lambda v: json.dumps(v) if isinstance(v, (dict, list)) else v)
    return frame


def _read(path: Path):
    """The file as a DataFrame with upper-case column names that are plain SQL names."""
    import pandas as pd

    kind = FORMATS.get(path.suffix.lower())
    if kind is None:
        raise ValueError(f"{path.name} is not a file load_own_file reads (the types are: {', '.join(sorted(FORMATS))}).")
    try:
        if kind == "parquet":
            frame = pd.read_parquet(path)
        elif kind == "json":
            frame = _read_json(pd, path)
        else:
            frame = pd.read_csv(path, low_memory=False)
    except ImportError as err:
        raise RuntimeError(f"Reading {path.name} needs pyarrow in the kernel's Python: exakit update notebook") from err
    names = [re.sub(r"\W", "_", str(c).strip()).upper() or f"COLUMN_{i + 1}" for i, c in enumerate(frame.columns)]
    names = [n if re.match(r"[A-Z]", n) else f"C_{n}" for n in names]
    twice = sorted({n for n in names if names.count(n) > 1})
    if twice:
        raise ValueError(f"{path.name} has columns that are the same name in SQL: {', '.join(twice)}. Rename them in the file.")
    frame.columns = names
    if frame.empty:
        raise ValueError(f"{path.name} holds no rows.")
    return frame


def _prepare(frame, descriptor=None) -> list[tuple[str, str]]:
    """Make each column loadable (in place) and return (column, SQL type) in file order: the date role a DATE, a
    true/false column 0 or 1, whole numbers DECIMAL, text VARCHAR as wide as its longest value."""
    import pandas as pd
    from pandas.api import types

    date = None
    if descriptor is not None:
        missing = [f"{role} ({ref.column})" for role, ref in descriptor.references() if ref.column not in frame.columns]
        if missing:
            raise ValueError(f"The file has no column for: {', '.join(missing)}. Its columns: {', '.join(frame.columns)}.")
        if "date" in descriptor.roles:
            date = descriptor.column("date").column
            try:
                frame[date] = pd.to_datetime(frame[date]).dt.date
            except (ValueError, TypeError) as err:
                raise ValueError(f"The date role's column {date} holds values that are not dates ({err}).") from err
    else:
        # First load precedes profiling. Preserve likely dates as DATE so the draft and later notebooks agree on
        # the column type, without asking the user to map roles before the role picker appears.
        for name in frame.columns:
            column = frame[name]
            if not types.is_object_dtype(column) or column.dropna().empty:
                continue
            sample = column.dropna().astype(str).head(1000)
            if not sample.str.contains(r"[-/:]", regex=True).mean() >= 0.9:
                continue
            parsed = pd.to_datetime(sample, errors="coerce")
            if parsed.notna().mean() >= 0.9:
                frame[name] = pd.to_datetime(column, errors="coerce").dt.date
                date = name
                break
    out = []
    for name in frame.columns:
        column = frame[name]
        if name == date:
            out.append((name, "DATE"))
        elif types.is_bool_dtype(column):
            frame[name] = column.astype("Int64")
            out.append((name, "DECIMAL(1,0)"))
        elif types.is_numeric_dtype(column) and column.dropna().eq(column.dropna().round()).all():
            frame[name] = column.astype("Int64")
            out.append((name, "DECIMAL(18,0)"))
        elif types.is_numeric_dtype(column):
            out.append((name, "DOUBLE"))
        elif types.is_datetime64_any_dtype(column):
            out.append((name, "TIMESTAMP"))
        else:
            frame[name] = column.where(column.isna(), column.astype(str))
            lengths = frame[name].dropna().str.len()
            width = int(lengths.max()) if len(lengths) else 1      # a column with no value at all is still a column
            out.append((name, f"VARCHAR({min(max(width, 1), MAX_VARCHAR)})"))
    return out


def _comment(conn, table: str) -> str | None:
    """The table's comment ('' when it has none), or None when there is no such table."""
    schema, name = table.split(".")
    rows = conn.execute(f"SELECT COALESCE(TABLE_COMMENT, '') FROM SYS.EXA_ALL_TABLES "
                        f"WHERE TABLE_SCHEMA = '{schema}' AND TABLE_NAME = '{name}'").fetchall()
    return str(rows[0][0]) if rows else None


def _quoted(name: str) -> str:
    """A column name as a quoted SQL identifier."""
    return '"' + name.replace('"', '""') + '"'


def _load(conn, frame, columns: list[tuple[str, str]], table: str, mark: str) -> None:
    schema, name = table.split(".")
    conn.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
    # Quoted: a file's header is not bound to avoid SQL's reserved words (DATE, USER, SELECT, ...). The names are
    # already upper case with only letters, digits and _, so the quoted name is the name the descriptor uses.
    conn.execute(f"CREATE OR REPLACE TABLE {table} ({', '.join(f'{_quoted(c)} {t}' for c, t in columns)})")
    # pyexasol 2.4.1 parses releaseVersion with packaging.Version while
    # preparing its IMPORT. Personal reports e.g. 2026.2.0-nano.3, which is
    # not a PEP 440 version. Normalize only for that import, then restore the
    # server's actual login metadata for the rest of the session.
    login = getattr(conn, "login_info", None)
    release = login.get("releaseVersion") if isinstance(login, dict) else None
    match = re.fullmatch(r"(\d+\.\d+\.\d+)-nano\.\d+", release) if isinstance(release, str) else None
    if match:
        login["releaseVersion"] = match.group(1)
    try:
        conn.import_from_pandas(frame, (schema, name))
    finally:
        if match:
            login["releaseVersion"] = release
    conn.execute(f"COMMENT ON TABLE {table} IS '{mark}'")


def _keep_roles(file: Path, doc: dict[str, Any]) -> None:
    """The roles given as a mapping, saved beside the file when it has no descriptor yet (one line either way)."""
    beside = file.parent / f"{file.stem}{BESIDE[0]}"
    try:
        save_descriptor(doc, beside, f"Which column of {file.name} plays which role; written by exakit.nb.load_own_file.")
    except OSError as err:
        print(f"The roles could not be saved beside the file ({err.strerror or err}); pass them again next time.")
        return
    print(f"Roles saved in {beside}: DATASET = {str(file)!r} in a notebook opens this file again.")


DEFAULT_SCHEMA = "MY_DATA"                # where your own data loads when no schema is named
LOADABLE = (".csv", ".parquet", ".json", ".geojson")   # what `exakit data-load` takes from a folder


def _sql_name(text: str) -> str:
    """A folder's or a file's name as a plain SQL name, as `exakit data-load` names a table: upper case, anything but
    letters, digits and _ as _, no _ at either end or twice in a row; T_ in front when it starts with a digit."""
    name = re.sub(r"_+", "_", re.sub(r"[^A-Z0-9_]", "_", text.upper())).strip("_")
    return name if not name or name[0].isalpha() else f"T_{name}"


def _schema_and_table(table: str | None, folder: Path | None = None) -> tuple[str, str]:
    """``table`` as (SCHEMA, TABLE or ""): SCHEMA alone or SCHEMA.TABLE, plain SQL names. Empty means the folder's
    name (``folder``: the folder loaded, or the one the file is in), else MY_DATA."""
    default = (_sql_name(folder.resolve().name) if folder is not None else "") or DEFAULT_SCHEMA
    named = str(table or "").strip().strip("\"'").upper() or default
    schema, _, wanted = named.partition(".")
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", schema) or (wanted and not re.fullmatch(r"[A-Z][A-Z0-9_]*", wanted)):
        raise ValueError(f"'{table}' is not a schema name (letters, digits and _, starting with a letter), "
                         "for example MY_DATA.")
    return schema, wanted


def _load_folder(folder: Path, table: str | None, conn, replace: bool) -> LoadedTable | None:
    """A folder goes through `exakit data-load`, the kit's own loader (exapump): every CSV, Parquet and JSON file at
    its top level becomes one table, named after the file, in the schema (the folder's name when none is named); a file loaded
    before is skipped, so running the cell again is safe. Returns the table to describe next: the one ``table`` names,
    else the first file's."""
    from . import kit_commands

    schema, wanted = _schema_and_table(table, folder)
    run = kit_commands.exakit("data-load", str(folder), env={"EXAKIT_SCHEMA": schema,
                                                             "EXAKIT_ON_EXISTING": "replace" if replace else "skip"})
    if not run.ok:
        raise RuntimeError(f"exakit data-load {folder} stopped (exit {run.code}); the lines above say why.")
    if conn is None:
        from . import connect

        conn = connect()
    rows = conn.execute("SELECT TABLE_NAME FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA = {schema} ORDER BY TABLE_NAME",
                        {"schema": schema}).fetchall()
    tables = {str(row[0]) for row in rows}
    files = [f for f in sorted(folder.iterdir()) if f.is_file() and f.suffix.lower() in LOADABLE]
    loaded = [(f, _table_from_file(f)) for f in files if _table_from_file(f) in tables]
    if wanted:
        pick = next(((f, t) for f, t in loaded if t == wanted), (folder, wanted) if wanted in tables else None)
    else:
        pick = loaded[0] if loaded else None
    if pick is None:
        print(f"{schema} has these tables: {', '.join(sorted(tables)) or 'none'}. Nothing from {folder} to describe.")
        return None
    source, name = pick
    if len(loaded) > 1:
        print(f"Loaded into {schema}: {', '.join(t for _, t in loaded)}. Describing {name} next; to describe "
              "another, set MY_DATA to its file and run the cell again.")
    target = f"{schema}.{name}"
    return LoadedTable(re.sub(r"_+", "_", target.replace(".", "_").lower()).strip("_"), target, source)


def _table_from_file(file: Path) -> str:
    """The table `exakit data-load` names after a file (exakit_table_name_from_path): its name without the extension,
    upper case, anything but letters, digits and _ as _, no _ at either end or twice in a row."""
    name = re.sub(r"_+", "_", re.sub(r"[^A-Z0-9_]", "_", file.stem.upper())).strip("_")
    return name or "MY_TABLE"


def load_own_file(path: str | Path, table: str | None, descriptor: Any = None, *, conn=None, replace: bool = False,
                  missing_ok: bool = False) -> Dataset | LoadedTable | None:
    """Load your own data and return it as a Dataset the notebooks run on (or a LoadedTable whose roles are reviewed
    next). ``path`` is a CSV, Parquet or JSON file, or a folder of them (loaded by `exakit data-load`, exapump, one
    table per file). ``table`` is the schema the tables go into (empty: the folder's name), each named after its file; or
    SCHEMA.TABLE to name the file's table, or the folder's table to describe next.
    ``descriptor`` (a file only) maps each role to a column of the file (``text`` may name several), or is a
    descriptor mapping or file (YAML or JSON; its fact_table names the table when ``table`` is None). ``conn``
    defaults to a new exakit.nb.connect(). With ``missing_ok``, a path that is not there says so in one line and
    returns None."""
    from .sources import clean_path

    path = clean_path(path)
    if not path:
        if missing_ok:
            print("No file or folder named: nothing of your own loaded.")
            return None
        raise ValueError("Name a CSV, Parquet or JSON file, or a folder of them, to load.")
    rules, file = _rules(), Path(path).expanduser()
    if file.is_dir():
        if descriptor is not None:
            raise ValueError("A descriptor describes one file: load the folder without one, then review the roles.")
        return _load_folder(file, table, conn, replace)
    if not file.is_file():
        if missing_ok:
            print(f"Nothing at {file}: set it to your CSV, Parquet or JSON file, or a folder of them - skipped.")
            return None
        raise ValueError(f"{file} is not a file or a folder.")
    # An Excel sheet or a CSV in another encoding is made loadable first (spreadsheet.loadable): a CSV or a UTF-8
    # copy beside it, the original untouched, each change said in one line. The table keeps the original's name.
    from .spreadsheet import loadable

    original = file
    file, notes = loadable(file)
    for note in notes:
        print(note)
    table = str(table or "").strip().strip("\"'") or None
    if descriptor is None and (table is None or "." not in table):
        # A schema, or nothing: the folder's name. The table is named after the file, as `exakit data-load` does.
        schema, _ = _schema_and_table(table, original.parent)
        table = f"{schema}.{_sql_name(original.stem) or 'MY_TABLE'}"
    named = rules.qualified_table(table) if table is not None else None
    if table is not None and named is None:
        raise ValueError(f"'{table}' is not SCHEMA.TABLE (plain SQL names).")
    if descriptor is None and named is None:
        raise ValueError("Name the table to load the file into (SCHEMA.TABLE); the role picker follows the load.")
    doc = _descriptor_doc(descriptor, named, file) if descriptor is not None else None
    raw = json.dumps(doc, indent=2, sort_keys=True).encode("utf-8") if doc is not None else None
    parsed = rules.parse_descriptor(raw.decode("utf-8"), source="The descriptor") if raw is not None else None
    target = named or parsed.fact_table
    if parsed is not None and parsed.fact_table != target:
        raise ValueError(f"The descriptor describes {parsed.fact_table}; the file loads into {target}. Name the same table.")
    if conn is None:
        from . import connect

        conn = connect()
    mark = f"{MARK}{_digest(file)} file={file.name}"[:2000]
    found = _comment(conn, target)
    if found is not None and not found.startswith(MARK) and not replace:
        raise ValueError(f"{target} already exists and was not loaded by load_own_file. Name another table, or pass "
                         "replace=True to replace it with the file.")
    if found != mark:
        frame = _read(file)
        _load(conn, frame, _prepare(frame, parsed), target, mark.replace("'", "''"))
    if parsed is None:
        return LoadedTable(re.sub(r"_+", "_", target.replace(".", "_").lower()).strip("_"), target, file)
    beside = Path(descriptor).expanduser() if isinstance(descriptor, (str, Path)) else None
    ds = checked(conn, raw, file, remedy="Correct the descriptor's roles or the file.",
                 descriptor_path=beside if beside is not None and beside.is_file() else None,
                 origin="beside" if beside is not None else "explicit")
    if isinstance(descriptor, dict) and not {"roles", "descriptor"} & set(descriptor) and descriptor_beside(file) is None:
        _keep_roles(file, doc)
    return ds


def _plain(name: str) -> str:
    """A file column's plain SQL name, the loader's rule: non-word characters to _, upper case, a letter first."""
    plain = re.sub(r"\W", "_", str(name).strip()).upper() or "COLUMN"
    return plain if re.match(r"[A-Z]", plain) else f"C_{plain}"


def use_table(conn, table: str) -> LoadedTable:
    """A table already in the database, to describe next (review_roles): ``SCHEMA.TABLE``. A table whose columns kept
    their file's names ("Won", "Opportunity ID") cannot be read by unquoted queries, so it gets a view with plain
    names over it in the prepared schema, said in one line; the table itself is never changed."""
    from .prepare import SCHEMA as PREPARED

    schema, _, name = str(table).strip().partition(".")
    schema, name = schema.strip('"'), name.strip('"')
    if not schema or not name:
        raise ValueError(f"'{table}' is not SCHEMA.TABLE.")
    literal = lambda v: "'" + v.replace("'", "''") + "'"
    columns = [r[0] for r in conn.execute(
        "SELECT COLUMN_NAME FROM SYS.EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA = " + literal(schema)
        + " AND COLUMN_TABLE = " + literal(name) + " ORDER BY COLUMN_ORDINAL_POSITION").fetchall()]
    if not columns:
        raise ValueError(f"{schema}.{name} is not a table in the database (or it has no columns).")
    use = f"{schema}.{name}"
    if not all(re.fullmatch(r"[A-Z][A-Z0-9_]*", c) for c in columns):
        plain, seen = [], set()
        for column in columns:
            new = _plain(column)
            while new in seen:
                new += "_2"
            seen.add(new)
            plain.append(new)
        use = f"{PREPARED}.{schema}__{name}__PLAIN"
        select = ",\n       ".join(f'"{c.replace(chr(34), chr(34) * 2)}" AS {n}' for c, n in zip(columns, plain))
        conn.execute(f"CREATE SCHEMA IF NOT EXISTS {PREPARED}")
        conn.execute(f'CREATE OR REPLACE VIEW {use} AS\nSELECT {select}\nFROM {schema}."{name}"')
        print(f"{schema}.{name} has column names with spaces or small letters, which the kit's queries cannot read: "
              f"a view with plain names, {use}, is used instead. The table is unchanged.")
    return LoadedTable(re.sub(r"[^a-z0-9]+", "_", use.lower()).strip("_"), use, Path("."))
