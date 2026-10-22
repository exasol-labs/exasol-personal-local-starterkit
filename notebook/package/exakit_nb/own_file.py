"""Your own CSV, Parquet or JSON file as a dataset: loaded into a table over the kit's connection, described by a few
role assignments, and checked by the same rules as a kit dataset - so the notebooks run on it unchanged.

    ds = nb.load_own_file("~/data/transactions.csv", "MY_DATA.TRANSACTIONS",
                          {"entity": "CUSTOMER_ID", "category": "MERCHANT_TYPE", "date": "BOOKED_ON",
                           "label": "DISPUTED", "text": ["MEMO"]})

The descriptor is that mapping of role to column, a descriptor mapping (``schema_version``, ``id``, ``fact_table``,
``roles``), or a descriptor file - YAML or JSON; ``data/datasets/<id>/descriptor.yaml`` in the kit shows the shape -
whose fact_table then names the table (``table`` may be None). Given as a mapping of roles, they are also written
beside the file as ``<name>.descriptor.yaml`` (when no descriptor is there yet), so ``DATASET = "<the file>"`` in a
notebook opens it again with that one assignment. The rows travel over pyexasol's import on the open connection: no
host, user or password here, as everywhere in exakit.nb. Column types come from the file; the date role's column
becomes a DATE and a true/false column 0 or 1; a JSON file is an array of records or one record per line, its nested
values kept as JSON text. The table is marked as loaded from the file (its comment holds the file's SHA-256), so
running the cell again loads nothing when the file is unchanged and reloads it when it changed; a table of the same
name that this did not create is refused unless ``replace=True``.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

from .dataset import Dataset, _rules, checked

__all__ = ["descriptor_beside", "load_own_file", "save_descriptor"]

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


def _descriptor_doc(descriptor: Any, table: str | None) -> dict[str, Any]:
    """A full descriptor document from a descriptor file, a full document, or a mapping of role to column(s) of ``table``."""
    if isinstance(descriptor, (str, Path)):
        doc = _read_doc(Path(descriptor))
        if not isinstance(doc, dict):
            raise ValueError(f"The descriptor {descriptor} is not a mapping of keys to values.")
        return doc
    if not isinstance(descriptor, dict):
        raise ValueError("The descriptor is a mapping of role to column, e.g. {'entity': 'CUSTOMER_ID', ...}, or a file path.")
    if "roles" in descriptor:
        return descriptor
    if table is None:
        raise ValueError("Name the table to load the file into (SCHEMA.TABLE): the roles alone do not say which.")

    def ref(column: Any) -> Any:
        return {"table": table, "column": column} if isinstance(column, str) else column

    name = re.sub(r"_+", "_", table.split(".", 1)[-1].lower()).strip("_")
    return {"schema_version": 1, "id": name, "fact_table": table,
            "roles": {role: [ref(c) for c in value] if isinstance(value, list) else ref(value) for role, value in descriptor.items()}}


def _yaml_scalar(value: Any) -> str:
    """A value as the descriptor reader reads it back: plain when it is a plain SQL or dataset name, else quoted."""
    text = str(value)
    return text if re.fullmatch(r"[A-Za-z0-9_.-]+", text) else json.dumps(text)


def save_descriptor(doc: dict[str, Any], path: str | Path, about: str = "") -> Path:
    """Write a descriptor document as YAML, in the layout of the kit's own descriptor.yaml files."""
    def ref(item: dict[str, Any]) -> str:
        return f"{{table: {_yaml_scalar(item['table'])}, column: {_yaml_scalar(item['column'])}}}"

    lines = [f"# {about or 'Which column plays which role (exakit.nb).'}", f"schema_version: {doc['schema_version']}",
             f"id: {_yaml_scalar(doc['id'])}", f"fact_table: {_yaml_scalar(doc['fact_table'])}"]
    if doc.get("source"):
        lines.append(f"source: {_yaml_scalar(doc['source'])}")
    lines.append("roles:")
    for role, value in doc["roles"].items():
        if isinstance(value, list):
            lines.append(f"  {role}:")
            lines += [f"    - {ref(item)}" for item in value]
        else:
            lines.append(f"  {role}: {ref(value)}")
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


def _prepare(frame, descriptor) -> list[tuple[str, str]]:
    """Make each column loadable (in place) and return (column, SQL type) in file order: the date role a DATE, a
    true/false column 0 or 1, whole numbers DECIMAL, text VARCHAR as wide as its longest value."""
    import pandas as pd
    from pandas.api import types

    missing = [f"{role} ({ref.column})" for role, ref in descriptor.references() if ref.column not in frame.columns]
    if missing:
        raise ValueError(f"The file has no column for: {', '.join(missing)}. Its columns: {', '.join(frame.columns)}.")
    date = descriptor.column("date").column
    try:
        frame[date] = pd.to_datetime(frame[date]).dt.date
    except (ValueError, TypeError) as err:
        raise ValueError(f"The date role's column {date} holds values that are not dates ({err}).") from err
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
    conn.import_from_pandas(frame, (schema, name))
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


def load_own_file(path: str | Path, table: str | None, descriptor: Any, *, conn=None, replace: bool = False,
                  missing_ok: bool = False) -> Dataset | None:
    """Load a CSV, Parquet or JSON file into ``table`` (SCHEMA.TABLE) and return it as a Dataset the notebooks run on.
    ``descriptor`` maps each role to a column of the file (``text`` may name several), or is a descriptor mapping or
    file (YAML or JSON; its fact_table names the table when ``table`` is None). ``conn`` defaults to a new
    exakit.nb.connect(). With ``missing_ok``, a path that is not a file says so in one line and returns None."""
    rules, file = _rules(), Path(path).expanduser()
    if not file.is_file():
        if missing_ok:
            print(f"No file at {file}: set it to your CSV, Parquet or JSON file to load that - skipped.")
            return None
        raise ValueError(f"{file} is not a file.")
    named = rules.qualified_table(table) if table is not None else None
    if table is not None and named is None:
        raise ValueError(f"'{table}' is not SCHEMA.TABLE (plain SQL names).")
    doc = _descriptor_doc(descriptor, named)
    raw = json.dumps(doc, indent=2, sort_keys=True).encode("utf-8")
    parsed = rules.parse_descriptor(raw.decode("utf-8"), source="The descriptor")
    target = named or parsed.fact_table
    if parsed.fact_table != target:
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
    ds = checked(conn, raw, file, remedy="Correct the descriptor's roles or the file.")
    if isinstance(descriptor, dict) and "roles" not in descriptor and descriptor_beside(file) is None:
        _keep_roles(file, doc)
    return ds
