"""Helpers for the Exasol Personal Local Starter Kit's notebooks: ``exakit.nb`` (this module; ``exakit_nb`` is the
same module under its older name).

The connection comes from the kit. Its Jupyter kernel ("Exasol (Starter Kit)") carries two paths: the encrypted
configuration store, and the kit's credential file holding the store's master password, readable by the user only.
These helpers open the database from there, in JupyterLab, Marimo, Positron, VS Code or any front end that runs the
kit's notebook Python. Nothing here prints or returns a host, a user or a password.

    import exakit.nb as nb
    conn = nb.connect()
    df = nb.sql(conn, "SELECT * FROM TPCH.NATION")
    nb.show_sql()
    ds = nb.dataset(conn, "pharma_trials")           # the roles of a dataset, checked against the database
    ds = nb.load_own_file("~/data/sales.json", "MY_DATA.SALES", {"entity": "CUSTOMER", ...})   # or your own file
    with nb.trace(conn, dataset=ds): ...              # model calls as one trace in your Langfuse (opt-in)

The quickstarts' shared steps (check_connection, list_schemas, load_sample, load_source, ...) are in quickstart.py;
the ML Engineer's checks (check_container, check_mlflow, check_bucket) in checks.py.
"""

from __future__ import annotations

import contextlib
import os
from collections.abc import Iterator
from pathlib import Path
from typing import Any

from ._kit import setting
from .checks import check_bucket, check_container, check_mlflow, model_list
from .dataset import Dataset, DescriptorNotApproved, dataset
from .descriptor_store import current_version, descriptor_store_dir, list_versions
from .own_file import load_own_file, save_descriptor
from .quickstart import check_connection, connected_sources, first, list_schemas, load_sample, load_source, show_roles
from .workflow import current_workflow, log_event, log_sql, workflow

__all__ = ["check_bucket", "check_connection", "check_container", "check_mlflow", "confirm_send", "connect", "connected_sources", "current_version", "current_workflow", "Dataset", "dataset", "descriptor_store_dir", "DescriptorNotApproved", "first", "list_schemas", "list_versions", "load_own_file", "load_sample", "load_source", "log_event", "log_sql", "model_client", "model_list", "save_descriptor", "show_roles", "show_sql", "sql", "trace", "tracing", "workflow"]

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
                           "and if the notebook add-on is new: exakit notebook check")
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
    df = pd.DataFrame(result.fetchall(), columns=result.column_names())
    log_sql(conn, statement, len(df))   # the workflow log, when one is active (X-1); a no-op otherwise
    return df


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


def trace_tags(conn, dataset: Dataset | None = None, sql: str | None = None, **metadata: Any) -> dict[str, str]:
    """What a trace carries: exasol.session_id, exasol.sql (the sample SQL; default the last statement sql() ran) and,
    given a dataset, exasol.dataset and exasol.descriptor (its descriptor's SHA-256), plus any metadata given."""
    return {"exasol.session_id": str(conn.session_id()), "exasol.sql": sql if sql is not None else (_last["sql"] or ""),
            **(dataset.tags() if dataset else {}), **{k: str(v) for k, v in metadata.items()}}


@contextlib.contextmanager
def trace(conn, name: str = "exakit-notebook", dataset: Dataset | None = None, sql: str | None = None,
          **metadata: Any) -> Iterator[Any]:
    """Group the model calls made inside the block into one trace in the user's own Langfuse project, tagged with the
    database session, the sample SQL and, given a dataset, its id and descriptor digest (trace_tags). Opt-in: without
    the LANGFUSE_* variables it says so in one line and does nothing else - no exception, no prompt.

    Make the calls with the client model_client() returns (Langfuse's drop-in when tracing is on), so each call's
    input, output, token usage and latency land in the trace without changes to the calling code.
    """
    missing = [variable for variable in LANGFUSE_VARIABLES if not os.environ.get(variable)]
    if missing:
        print(f"Tracing is off ({', '.join(missing)} not set before exakit notebook); the cell runs as usual.")
        yield None
        return
    from langfuse import get_client

    client = get_client()
    tags = trace_tags(conn, dataset, sql, **metadata)
    labels = ["exasol-starter-kit", *(f"{key}={tags[key]}" for key in ("exasol.dataset", "exasol.descriptor", "exasol.session_id")
                                      if tags.get(key))]
    with client.start_as_current_span(name=name) as span:
        span.update_trace(metadata=tags, tags=labels)
        yield span
    client.flush()


def confirm_send(ds: Dataset, rows: int, answer: str | None = None) -> bool:
    """Before sampled rows go to a model endpoint: True at once for a table in the database; for a live source (the
    descriptor names a source) it names the source and asks, and only a yes sends. ``answer`` answers for a script;
    with no one to ask (a headless run) the answer is no."""
    if not ds.source:
        return True
    print(f"{ds.fact_table} is a live source ({ds.source}): its rows are read from there as you query them.")
    if answer is None:
        try:
            answer = input(f"Send {rows} sampled rows from {ds.source} to your model endpoint? [y/N] ")
        except (EOFError, OSError, RuntimeError):
            answer = ""
    if answer.strip().lower() in ("y", "yes"):
        return True
    print("Not sent: the text step is skipped.")
    return False
