"""The steps both quickstarts share (notebook/notebooks/00_shared): is the database there, what does it hold, and one
loader per way data comes in - a sample dataset the kit ships, your own file, an external source connected as a
virtual schema. Each loader is one cell's call; one that is not set up says so in one line and returns None, so a
notebook runs top to bottom whichever ways the user picked.

    conn = nb.connect()
    nb.check_connection(conn); nb.list_schemas(conn)
    sample = nb.load_sample(conn, "amazon_sales")
    own = nb.load_own_file("~/data/sales.json", "MY_DATA.SALES", {...}, conn=conn, missing_ok=True)
    source = nb.load_source(conn, None)
    ds = nb.first(source, own, sample); nb.show_roles(ds)

Nothing here prints a host, a user or a password.
"""

from __future__ import annotations

import re
import subprocess
import time
from pathlib import Path

from ._kit import exakit_command
from .dataset import Dataset, _locate, dataset
from .own_file import LoadedTable

__all__ = ["check_connection", "connected_sources", "first", "list_schemas", "load_sample", "load_source", "show_roles"]


def _sql(conn, statement: str):
    from . import sql

    return sql(conn, statement)


def check_connection(conn):
    """The database answers: its time, this session's id and its version, as one row (and one line)."""
    frame = _sql(conn, "SELECT CURRENT_TIMESTAMP AS NOW, CURRENT_SESSION AS SESSION_ID, PARAM_VALUE AS DATABASE_VERSION "
                       "FROM SYS.EXA_METADATA WHERE PARAM_NAME = 'databaseProductVersion'")
    if len(frame):
        print(f"Connected: Exasol {frame['DATABASE_VERSION'][0]}, session {frame['SESSION_ID'][0]}.")
    return frame


def list_schemas(conn):
    """Every schema with its number of tables, virtual ones (connected sources) marked."""
    return _sql(conn, """SELECT S.SCHEMA_NAME, S.SCHEMA_IS_VIRTUAL AS VIRTUAL, COUNT(T.TABLE_NAME) AS TABLES
FROM SYS.EXA_SCHEMAS S
LEFT JOIN SYS.EXA_ALL_TABLES T ON T.TABLE_SCHEMA = S.SCHEMA_NAME
GROUP BY S.SCHEMA_NAME, S.SCHEMA_IS_VIRTUAL
ORDER BY S.SCHEMA_NAME""")


def _run_exakit(*args: str) -> int:
    """``exakit <args>``, its output passed on line by line; the exit status (127 when there is no exakit)."""
    command = exakit_command()
    if command is None:
        print("The kit's command line (exakit) is not on PATH, so this cannot run it. In a terminal: exakit " + " ".join(args))
        return 127
    child = subprocess.Popen([*command, *args], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
    assert child.stdout is not None
    for line in child.stdout:
        print(line.rstrip())
    return child.wait()


def load_sample(conn, dataset_id: str | None) -> Dataset | None:
    """A dataset the kit offers (``amazon_sales``, ``fraud_transactions``): used as it is when it is loaded, else loaded
    first with ``exakit data-load <id>`` (the cell waits for it), then checked against the database. None skips it."""
    if not dataset_id:
        print("No sample dataset asked for: skipped.")
        return None
    _locate(dataset_id)                                    # an unknown id stops here, naming the ones there are
    try:
        ds = dataset(conn, dataset_id)
        print(f"{dataset_id} is loaded ({ds.fact_table}).")
        return ds
    except ValueError:
        pass
    print(f"Loading {dataset_id}: exakit data-load {dataset_id} (a few minutes the first time) ...")
    started = time.monotonic()
    code = _run_exakit("data-load", dataset_id)
    if code != 0:
        raise RuntimeError(f"exakit data-load {dataset_id} did not finish (exit {code}): see its output above.")
    ds = dataset(conn, dataset_id)
    print(f"{dataset_id} loaded in {time.monotonic() - started:.0f}s ({ds.fact_table}).")
    return ds


def connected_sources(conn):
    """The virtual schemas in the database (external sources) with their number of tables; empty when there is none."""
    return _sql(conn, """SELECT S.SCHEMA_NAME, COUNT(T.TABLE_NAME) AS TABLES
FROM SYS.EXA_ALL_VIRTUAL_SCHEMAS S
LEFT JOIN SYS.EXA_ALL_TABLES T ON T.TABLE_SCHEMA = S.SCHEMA_NAME
GROUP BY S.SCHEMA_NAME
ORDER BY S.SCHEMA_NAME""")


def _tables(conn, schema: str) -> list[str]:
    frame = _sql(conn, "SELECT TABLE_NAME FROM SYS.EXA_ALL_TABLES WHERE TABLE_SCHEMA = '"
                       + schema.replace("'", "''") + "' ORDER BY TABLE_NAME")
    return [str(name) for name in frame["TABLE_NAME"]]


def _source_alias(schema: str) -> str:
    return schema[3:].lower() if schema.upper().startswith("VS_") else schema.lower()


def _listed(names: list[str], limit: int = 12) -> str:
    return ", ".join(names[:limit]) + (f" and {len(names) - limit} more" if len(names) > limit else "") if names else "none"


CONNECT_HINT = ('Connect one here: nb.connect_source("postgresql", "sales", url="postgres://reader@HOST:5432/DB") '
                "(the password is asked in a hidden box), or in a terminal: exakit connect")


def load_source(conn, descriptor: str | Path | None) -> Dataset | LoadedTable | None:
    """A table in a connected external source (a virtual schema). ``descriptor`` is ``VS_<NAME>.<TABLE>`` (any case,
    the VS_ prefix optional), ``VS_<NAME>`` alone (its one table, or a list of them), or a descriptor file whose
    fact_table is in a source. None skips it and lists the sources there are. A name that cannot be used stops the
    cell with one line naming what is there and how to connect one; the table is read once (one row) to prove it."""
    from .sources import SourceProblem, clean_path, clean_text

    names = [str(name) for name in connected_sources(conn)["SCHEMA_NAME"]]
    given = clean_text(descriptor)
    if not given:
        if names:
            print(f"Connected sources: {', '.join(names)}. Set SOURCE = \"{names[0]}.<TABLE>\" to use one, or "
                  f"\"{names[0]}\" to list its tables.")
        else:
            print("No external source is connected: skipped. " + CONNECT_HINT)
        return None
    if "://" in given or given.lower().startswith("jdbc:"):
        raise SourceProblem("SOURCE is a connection string. Connect it first, then set SOURCE to its table:\n"
                            f'  nb.connect_source("<connector>", "<name>", url=SOURCE)   # e.g. "postgresql", "sales"')
    path = Path(clean_path(given))
    if path.suffix.lower() in (".yaml", ".yml", ".json") or path.is_file():
        if not path.is_file():
            raise SourceProblem(f"No descriptor file at {path}.")
        return _source_descriptor(conn, path, names)
    if not names:
        raise SourceProblem(f"SOURCE = {given!r}, but no external source is connected (no virtual schema in the "
                            "database). " + CONNECT_HINT)
    parts = [part.strip().strip('"') for part in given.split(".")]
    if len(parts) > 2 or not all(parts):
        raise SourceProblem(f"{given!r} is not SCHEMA.TABLE. Connected sources: {', '.join(names)}.")
    by_upper = {name.upper(): name for name in names}
    wanted = parts[0].upper()
    schema = by_upper.get(wanted) or by_upper.get("VS_" + wanted)
    if schema is None:
        raise SourceProblem(f"{parts[0]} is not a connected source. Connected sources: {', '.join(names)}. "
                            "A new one: " + CONNECT_HINT)
    tables = _tables(conn, schema)
    if len(parts) == 1:
        if len(tables) != 1:
            raise SourceProblem(f"{schema} has {len(tables)} tables: {_listed(tables)}. "
                                f"Set SOURCE = \"{schema}.<TABLE>\"." if tables else
                                f"{schema} shows no tables. If the source has some now: exakit source refresh "
                                f"{_source_alias(schema)}")
        parts.append(tables[0])
    match = [t for t in tables if t == parts[1]] or [t for t in tables if t.upper() == parts[1].upper()]
    if not match:
        raise SourceProblem(f"{schema} has no table {parts[1]}. Its tables: {_listed(tables)}.")
    table = f"{schema}.{match[0]}"
    quoted = ".".join('"' + p.replace('"', '""') + '"' for p in (schema, match[0]))
    try:
        _sql(conn, f"SELECT * FROM {quoted} LIMIT 1")
    except Exception as err:                                   # the source is down, a grant is missing, a type fails
        reason = str(err).strip().splitlines()[0][:300] if str(err).strip() else type(err).__name__
        raise SourceProblem(f"{table} could not be read: {reason}\nCheck the source: exakit source check "
                            f"{_source_alias(schema)}") from None
    print(f"{table} is a live source: queries read it through the virtual schema. The next cells propose its roles.")
    ident = re.sub(r"[^a-z0-9]+", "_", table.lower()).strip("_") or "source"
    return LoadedTable(ident, table, Path("."))


def _source_descriptor(conn, path: Path, names: list[str]) -> Dataset:
    ds = dataset(conn, str(path))
    schema = ds.fact_table.split(".", 1)[0]
    if schema not in names:
        print(f"Note: {ds.fact_table} is not in a connected source ({', '.join(names) or 'none'}); "
              "it is used as a plain table.")
    else:
        print(f"{ds.fact_table} is a live source ({ds.source or schema}): every query reads it through the virtual schema.")
    return ds


def first(*candidates: Dataset | LoadedTable | None) -> Dataset | LoadedTable:
    """The first dataset that was loaded, in the order given; says which one is used."""
    for candidate in candidates:
        if candidate is not None:
            print(f"Using {candidate.id} ({candidate.fact_table}).")
            return candidate
    raise ValueError("No data was loaded: set one of the loader cells above (a sample dataset loads with no setup).")


def show_roles(ds: Dataset) -> None:
    """The descriptor's roles, one per line, as the notebook will use them."""
    live = f", a live source ({ds.source})" if ds.source else ""
    print(f"{ds.id}: one row of {ds.fact_table} per observation{live}; descriptor sha256 {ds.digest[:12]}")
    for role, column in ds.roles():
        print(f"  {role:<9} {column}")
