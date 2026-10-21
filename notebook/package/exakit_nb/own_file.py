"""Your own CSV or Parquet file as a dataset: loaded into a table over the kit's connection, described by a few role
assignments, and checked by the same rules as a kit dataset - so the notebooks run on it unchanged.

    ds = exakit_nb.load_own_file("~/data/transactions.csv", "MY_DATA.TRANSACTIONS",
                                 {"entity": "CUSTOMER_ID", "category": "MERCHANT_TYPE", "date": "BOOKED_ON",
                                  "label": "DISPUTED", "text": ["MEMO"]})

The descriptor is that mapping of role to column, or a descriptor file (data/datasets/README.md has the schema). The
rows travel over pyexasol's import on the open connection: no host, user or password here, as everywhere in exakit_nb.
Column types come from the file; the date role's column becomes a DATE and a true/false column 0 or 1. The table is
marked as loaded from the file (its comment holds the file's SHA-256), so running the cell again loads nothing when the
file is unchanged and reloads it when it changed; a table of the same name that this did not create is refused unless
``replace=True``.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

from .dataset import Dataset, _rules, checked

__all__ = ["load_own_file"]

FORMATS = {".csv": "csv", ".parquet": "parquet", ".pq": "parquet"}
MARK = "exakit_nb.load_own_file sha256="       # the table comment that says which file a table was loaded from
MAX_VARCHAR = 2000000


def _digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            sha.update(block)
    return sha.hexdigest()


def _descriptor_doc(descriptor: Any, table: str) -> dict[str, Any]:
    """A full descriptor document from a descriptor file, a full document, or a mapping of role to column(s) of ``table``."""
    if isinstance(descriptor, (str, Path)):
        return json.loads(Path(descriptor).expanduser().read_text(encoding="utf-8"))
    if not isinstance(descriptor, dict):
        raise ValueError("The descriptor is a mapping of role to column, e.g. {'entity': 'CUSTOMER_ID', ...}, or a file path.")
    if "roles" in descriptor:
        return descriptor

    def ref(column: Any) -> Any:
        return {"table": table, "column": column} if isinstance(column, str) else column

    name = re.sub(r"_+", "_", table.split(".", 1)[-1].lower()).strip("_")
    return {"schema_version": 1, "id": name, "fact_table": table,
            "roles": {role: [ref(c) for c in value] if isinstance(value, list) else ref(value) for role, value in descriptor.items()}}


def _read(path: Path):
    """The file as a DataFrame with upper-case column names that are plain SQL names."""
    import pandas as pd

    kind = FORMATS.get(path.suffix.lower())
    if kind is None:
        raise ValueError(f"{path.name} is not a file load_own_file reads (the types are: {', '.join(sorted(FORMATS))}).")
    try:
        frame = pd.read_parquet(path) if kind == "parquet" else pd.read_csv(path, low_memory=False)
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
            width = int(frame[name].dropna().str.len().max() or 1)
            out.append((name, f"VARCHAR({min(max(width, 1), MAX_VARCHAR)})"))
    return out


def _comment(conn, table: str) -> str | None:
    """The table's comment ('' when it has none), or None when there is no such table."""
    schema, name = table.split(".")
    rows = conn.execute(f"SELECT COALESCE(TABLE_COMMENT, '') FROM SYS.EXA_ALL_TABLES "
                        f"WHERE TABLE_SCHEMA = '{schema}' AND TABLE_NAME = '{name}'").fetchall()
    return str(rows[0][0]) if rows else None


def _load(conn, frame, columns: list[tuple[str, str]], table: str, mark: str) -> None:
    schema, name = table.split(".")
    conn.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
    conn.execute(f"CREATE OR REPLACE TABLE {table} ({', '.join(f'{c} {t}' for c, t in columns)})")
    conn.import_from_pandas(frame, (schema, name))
    conn.execute(f"COMMENT ON TABLE {table} IS '{mark}'")


def load_own_file(path: str | Path, table: str, descriptor: Any, *, conn=None, replace: bool = False) -> Dataset:
    """Load a CSV or Parquet file into ``table`` (SCHEMA.TABLE) and return it as a Dataset the notebooks run on.
    ``descriptor`` maps each role to a column of the file (``text`` may name several), or is a descriptor file.
    ``conn`` defaults to a new exakit_nb.connect()."""
    rules, file = _rules(), Path(path).expanduser()
    target = rules.qualified_table(table)
    if target is None:
        raise ValueError(f"'{table}' is not SCHEMA.TABLE (plain SQL names).")
    if not file.is_file():
        raise ValueError(f"{file} is not a file.")
    doc = _descriptor_doc(descriptor, target)
    raw = json.dumps(doc, indent=2, sort_keys=True).encode("utf-8")
    parsed = rules.parse_descriptor(raw.decode("utf-8"), source="The descriptor")
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
    return checked(conn, raw, file, remedy="Correct the descriptor's roles or the file.")
