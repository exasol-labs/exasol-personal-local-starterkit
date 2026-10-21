"""Helpers for the Exasol Personal Local Starter Kit's notebooks.

The connection comes from the kit. Its Jupyter kernel ("Exasol (Starter Kit)") carries two paths: the encrypted
configuration store, and the kit's credential file holding the store's master password, readable by the user only.
These helpers open the database from there, in any JupyterLab, VS Code or other Jupyter front end that runs that
kernel. Nothing here prints or returns a host, a user or a password.

    import exakit_nb
    conn = exakit_nb.connect()
    df = exakit_nb.sql(conn, "SELECT * FROM TPCH.NATION")
    exakit_nb.show_sql()
    ds = exakit_nb.dataset(conn, "pharma_trials")     # the roles of a dataset, checked against the database
    ds = exakit_nb.load_own_file("~/data/sales.csv", "MY_DATA.SALES", {"entity": "CUSTOMER", ...})   # or your own file
"""

from __future__ import annotations

import contextlib
import os
from collections.abc import Iterator
from pathlib import Path
from typing import Any

from ._kit import setting
from .dataset import Dataset, dataset
from .own_file import load_own_file

__all__ = ["Dataset", "connect", "dataset", "load_own_file", "model_client", "show_sql", "sql", "trace"]

LANGFUSE_VARIABLES = ("LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "LANGFUSE_HOST")
MODEL_VARIABLE = "EXAKIT_NB_MODEL"            # the model name; the endpoint and key are the OpenAI client's own OPENAI_* variables
_last: dict[str, str | None] = {"sql": None}


def _store():
    from exasol.nb_connector.secret_store import Secrets

    path, password = setting("EXAKIT_NB_STORE"), None
    master = setting("EXAKIT_NB_MASTER_FILE")
    if path and master and Path(master).is_file():
        password = Path(master).read_text(encoding="utf-8").strip()
    if not path or not password or not Path(path).is_file():
        raise RuntimeError("No connection to the kit's database was found. Run this with the kit's notebook Python "
                           "(the kernel 'Exasol (Starter Kit)', or ~/.exasol-starter-kit/notebook-venv/bin/python), "
                           "and if the notebook add-on is new: exakit notebook --check")
    return Secrets(Path(path), password)


def connect(**kwargs: Any):
    """A pyexasol connection to the local database, opened from the kit's encrypted store."""
    from exasol.nb_connector.connections import open_pyexasol_connection

    return open_pyexasol_connection(_store(), **kwargs)


def sql(conn, statement: str, params: dict | None = None):
    """Run a query and return its rows as a pandas DataFrame; the statement is remembered for show_sql().

    The rows come over the normal connection rather than pyexasol's HTTP export, which needs the database to connect
    back to this machine - not a given through the local VM or Podman.
    """
    import pandas as pd

    _last["sql"] = statement
    result = conn.execute(statement, params) if params else conn.execute(statement)
    return pd.DataFrame(result.fetchall(), columns=result.column_names())


def show_sql() -> None:
    """Print the last statement sql() ran, so a result can always be traced to the query behind it."""
    print(_last["sql"] or "No statement has run yet.")


def tracing() -> bool:
    """Whether the LANGFUSE_* variables are all set, so trace() records to the user's Langfuse."""
    return all(os.environ.get(name) for name in LANGFUSE_VARIABLES)


def model_client():
    """(client, model) for the user's own OpenAI-compatible model endpoint, or None (with one line saying why) when
    EXAKIT_NB_MODEL is not set. The endpoint and key are the client's own OPENAI_BASE_URL and OPENAI_API_KEY; a local
    endpoint (Ollama, LM Studio) needs only the base URL. With tracing on, the client is Langfuse's drop-in, so its
    calls are recorded in the trace."""
    model = os.environ.get(MODEL_VARIABLE)
    if not model:
        print(f"No model endpoint ({MODEL_VARIABLE} not set before exakit notebook); the text step is skipped.")
        return None
    if tracing():
        from langfuse.openai import OpenAI
    else:
        from openai import OpenAI
    key = os.environ.get("OPENAI_API_KEY") or "not-needed"        # a local endpoint takes any key
    return OpenAI(api_key=key), model


@contextlib.contextmanager
def trace(conn, name: str, dataset: Dataset | None = None, **metadata: Any) -> Iterator[Any]:
    """Group the model calls made inside the block into one trace in the user's own Langfuse project, tagged with the
    database session, the last SQL and, given a dataset, its id and descriptor digest. Opt-in: without the LANGFUSE_*
    variables it says so and does nothing else.

    Make the calls with the client model_client() returns (Langfuse's drop-in when tracing is on).
    """
    missing = [name for name in LANGFUSE_VARIABLES if not os.environ.get(name)]
    if missing:
        print(f"Tracing is off ({', '.join(missing)} not set before exakit notebook); the cell runs as usual.")
        yield None
        return
    from langfuse import get_client

    client = get_client()
    tags = {"exasol.session_id": str(conn.session_id()), "exasol.sql": _last["sql"] or "", **(dataset.tags() if dataset else {}),
            **{k: str(v) for k, v in metadata.items()}}
    with client.start_as_current_span(name=name) as span:
        span.update_trace(metadata=tags, tags=["exasol-starter-kit"])
        yield span
    client.flush()
