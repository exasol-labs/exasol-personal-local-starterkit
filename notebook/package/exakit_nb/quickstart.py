"""The steps both quickstarts share (notebook/notebooks/00_shared): is the database there, what does it hold, and one
loader per way data comes in - a sample dataset the kit ships, your own file, an external source connected as a
virtual schema. Each loader is one cell's call; one that is not set up says so in one line and returns None, so a
notebook runs top to bottom whichever ways the user picked.

    conn = nb.connect()
    nb.check_connection(conn); nb.list_schemas(conn)
    sample = nb.load_sample(conn, "pharma_trials")
    own = nb.load_own_file("~/data/sales.json", "MY_DATA.SALES", {...}, conn=conn, missing_ok=True)
    source = nb.load_source(conn, None)
    ds = nb.first(source, own, sample); nb.show_roles(ds)

Nothing here prints a host, a user or a password.
"""

from __future__ import annotations

import subprocess
import time
from pathlib import Path

from ._kit import exakit_command
from .dataset import Dataset, _locate, dataset

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
    """A dataset the kit ships (``pharma_trials``, ``banking_complaints``): used as it is when it is loaded, else loaded
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


def load_source(conn, descriptor: str | Path | None) -> Dataset | None:
    """A table in a connected external source (a virtual schema), described by ``descriptor`` (a descriptor file whose
    fact_table is in that schema; its ``source`` names the source). With no virtual schema in the database it says so
    and returns None, as it does when no descriptor is given (then it lists the sources there are)."""
    names = [str(name) for name in connected_sources(conn)["SCHEMA_NAME"]]
    if not names:
        print("No external source is connected (there is no virtual schema in the database): skipped.")
        return None
    if not descriptor:
        print(f"Connected sources: {', '.join(names)}. To use a table of one, set SOURCE to a descriptor.yaml whose "
              "fact_table is that table and whose source names it.")
        return None
    ds = dataset(conn, descriptor)
    schema = ds.fact_table.split(".", 1)[0]
    if schema not in names:
        print(f"Note: {ds.fact_table} is not in a connected source ({', '.join(names)}); it is used as a plain table.")
    else:
        print(f"{ds.fact_table} is a live source ({ds.source or schema}): every query reads it through the virtual schema.")
    return ds


def first(*candidates: Dataset | None) -> Dataset:
    """The first dataset that was loaded, in the order given."""
    for candidate in candidates:
        if candidate is not None:
            return candidate
    raise ValueError("No data was loaded: set one of the loader cells above (a sample dataset loads with no setup).")


def show_roles(ds: Dataset) -> None:
    """The descriptor's roles, one per line, as the notebook will use them."""
    live = f", a live source ({ds.source})" if ds.source else ""
    print(f"{ds.id}: one row of {ds.fact_table} per observation{live}; descriptor sha256 {ds.digest[:12]}")
    for role, column in ds.roles():
        print(f"  {role:<9} {column}")
