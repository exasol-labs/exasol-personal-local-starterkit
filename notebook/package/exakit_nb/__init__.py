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
import hashlib
import json
import os
from collections.abc import Iterator
from pathlib import Path
from typing import Any

from ._kit import setting
from .ask import Proposal, ask
from .checks import check_bucket, check_container, check_mlflow, check_model_compatibility, model_list
from .dash_mcp import DashTools, dash_tools
from .dataset import Dataset, DescriptorNotApproved, dataset
from .describe import Draft, describe
from .descriptor_store import current_version, descriptor_store_dir, list_versions
from .handoff import handoff_from, handoff_is_stale, read_handoff, write_handoff
from .own_file import LoadedTable, load_own_file, save_descriptor
from .quickstart import check_connection, connected_sources, first, list_schemas, load_sample, load_source, show_roles
from .role_picker import RoleReview, review_roles
from .share import ShareDraft, share
from .ml_train import TrainingPlan, prepare_training
from .workflow import TRACE as TRACE_KIND
from .workflow import current_workflow, log_event, log_sql, workflow

__all__ = ['DashTools', 'dash_tools', 'ask', 'check_bucket', 'check_connection', 'check_container', 'check_mlflow', 'check_model_compatibility', 'confirm_send', 'connect', 'connected_sources', 'current_version', 'current_workflow', 'dataset', 'Dataset', 'describe', 'descriptor_store_dir', 'DescriptorNotApproved', 'Draft', 'first', 'handoff_from', 'handoff_is_stale', 'list_schemas', 'list_versions', 'load_own_file', 'load_sample', 'load_source', 'LoadedTable', 'log_event', 'log_sql', 'model_client', 'model_list', 'prepare_training', 'Proposal', 'read_handoff', 'review_roles', 'RoleReview', 'save_descriptor', 'share', 'ShareDraft', 'show_roles', 'show_sql', 'sql', 'trace', 'tracing', 'TrainingPlan', 'workflow', 'write_handoff']

LANGFUSE_VARIABLES = ("LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "LANGFUSE_BASE_URL")
LANGFUSE_HOST_VARIABLE = "LANGFUSE_HOST"      # the SDK 3/4 name of LANGFUSE_BASE_URL; still accepted when BASE_URL is unset
METADATA_LIMIT = 200                           # Langfuse SDK 5: a propagated value is at most 200 characters once JSON-encoded
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


def _langfuse_settings() -> dict[str, str]:
    """The three Langfuse settings as the SDK 5 client takes them (public_key, secret_key, base_url), read from
    LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY and LANGFUSE_BASE_URL - or LANGFUSE_HOST, the SDK 3/4 name, when BASE_URL is
    unset. Only the keys that are set are in the result, so the missing ones can be named."""
    found = {}
    for variable, key in zip(LANGFUSE_VARIABLES, ("public_key", "secret_key", "base_url")):
        value = os.environ.get(variable) or (os.environ.get(LANGFUSE_HOST_VARIABLE) if key == "base_url" else None)
        if value:
            found[key] = value
    return found


def _langfuse_missing() -> list[str]:
    settings = _langfuse_settings()
    return [variable for variable, key in zip(LANGFUSE_VARIABLES, ("public_key", "secret_key", "base_url")) if key not in settings]


def tracing() -> bool:
    """Whether LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY and LANGFUSE_BASE_URL (or LANGFUSE_HOST) are all set, so trace()
    records to the user's Langfuse."""
    return not _langfuse_missing()


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


def _encoded(text: str) -> int:
    """How long Langfuse SDK 5 sees a metadata value: JSON-encoded (quotes and escapes count) before its 200-character
    limit, over which the value is dropped with a warning."""
    return len(json.dumps(text, ensure_ascii=False, separators=(",", ":")))


def _clip(value: Any, limit: int = METADATA_LIMIT) -> str:
    """A metadata value as Langfuse SDK 5 keeps it: a string whose JSON encoding is at most ``limit`` characters, cut
    with ``...`` when longer (the sample SQL; its digest carries the whole statement)."""
    text = str(value)
    if _encoded(text) <= limit:
        return text
    keep = limit - 5                                     # the quotes and the three dots
    while keep > 0 and _encoded(text[:keep] + "...") > limit:
        keep -= 1
    return text[:keep] + "..."


def trace_tags(conn, dataset: Dataset | None = None, sql: str | None = None, **metadata: Any) -> dict[str, str]:
    """What a trace carries: exasol.session_id, exasol.sql (the sample SQL - default the last statement sql() ran - cut
    to 200 characters, the Langfuse limit for a propagated value) with exasol.sql_digest (the SHA-256 of the whole
    statement), exasol.workflow_id when a workflow is active (X-1) and, given a dataset, exasol.dataset and
    exasol.descriptor (its descriptor's SHA-256) with exasol.descriptor_id and exasol.descriptor_version, plus any
    metadata given. Every value is a string of at most 200 characters."""
    statement = sql if sql is not None else (_last["sql"] or "")
    tags = {"exasol.session_id": str(conn.session_id()), "exasol.sql": statement,
            "exasol.sql_digest": hashlib.sha256(statement.encode("utf-8")).hexdigest()}
    workflow_id = current_workflow()
    if workflow_id:
        tags["exasol.workflow_id"] = workflow_id
    if dataset:
        tags.update(dataset.tags())
        tags["exasol.descriptor_id"] = dataset.id
        tags["exasol.descriptor_version"] = str(dataset.version)
    tags.update(metadata)
    return {key: _clip(value) for key, value in tags.items()}


@contextlib.contextmanager
def trace(conn, name: str = "exakit-notebook", dataset: Dataset | None = None, sql: str | None = None,
          **metadata: Any) -> Iterator[Any]:
    """Group the model calls made inside the block into one trace in the user's own Langfuse project, tagged with the
    database session, the sample SQL, the workflow id and, given a dataset, its id, descriptor digest and descriptor
    version (trace_tags). Opt-in: without LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY and LANGFUSE_BASE_URL (LANGFUSE_HOST,
    the SDK 3/4 name, still counts) it says so in one line and does nothing else - no exception, no prompt.

    Langfuse SDK 5: the block is one observation (``Langfuse.start_as_current_observation``) and, right inside it, the
    trace name, session id, tags and metadata are propagated (``langfuse.propagate_attributes``, a module function in
    SDK 5) to it and to every observation opened within, so each call the client model_client() returns makes -
    Langfuse's OpenAI drop-in when tracing is on - lands in this one trace with its input, output, token usage and
    latency, without changes to the calling code. The span is yielded; the client is flushed when the block ends.
    The active workflow's log gets one ``trace`` line with the trace id (X-1), and when the block ends one line is
    printed - ``traced: <trace id> (<url or base URL>)`` - so the trace can be found in Langfuse. Nothing here prints
    or records the secret key.
    """
    if _langfuse_missing():
        print(f"tracing is off (set {', '.join(LANGFUSE_VARIABLES[:-1])} and {LANGFUSE_VARIABLES[-1]} before exakit "
              "notebook); the cell runs as usual.")
        yield None
        return
    from langfuse import Langfuse, propagate_attributes

    settings = _langfuse_settings()
    if not os.environ.get(LANGFUSE_VARIABLES[-1]):
        print(f"{LANGFUSE_HOST_VARIABLE} is the SDK 3 name; Langfuse SDK 5 reads {LANGFUSE_VARIABLES[-1]} - using it as that.")
    client = Langfuse(public_key=settings["public_key"], secret_key=settings["secret_key"], base_url=settings["base_url"])
    tags = trace_tags(conn, dataset, sql, **metadata)
    labels = ["exasol-starter-kit", *(f"{key}={tags[key]}" for key in ("exasol.dataset", "exasol.descriptor", "exasol.descriptor_id",
                                                                       "exasol.descriptor_version", "exasol.session_id",
                                                                       "exasol.workflow_id") if tags.get(key))]
    with client.start_as_current_observation(as_type="span", name=name) as span, \
            propagate_attributes(trace_name=name, session_id=tags["exasol.session_id"], tags=labels, metadata=tags):
        trace_id = str(client.get_current_trace_id() or "")
        log_event(TRACE_KIND, name=name, trace_id=trace_id)
        yield span
    client.flush()
    print(_traced_line(client, trace_id, settings["base_url"]))


def _trace_url(client: Any, trace_id: str) -> str | None:
    """The trace's page in the Langfuse UI, when the SDK can say (SDK 5's ``Langfuse.get_trace_url`` asks the server
    for the project id, so it is None - or fails - against an endpoint that does not answer); else None."""
    get_url = getattr(client, "get_trace_url", None)
    if not callable(get_url) or not trace_id:
        return None
    try:
        url = get_url(trace_id=trace_id)
    except Exception:          # noqa: BLE001 - the line is a courtesy; the trace is already recorded
        return None
    return str(url) if url else None


def _traced_line(client: Any, trace_id: str, base_url: str) -> str:
    """The one line trace() prints when the block ends (AC-DS4.5): the trace id and where to find it - its URL when
    the SDK can build one, else the Langfuse base URL and a pointer to the project. Never the keys."""
    url = _trace_url(client, trace_id)
    where = url or f"{base_url}, project in your Langfuse"
    return f"traced: {trace_id or '(no trace id)'} ({where})"


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
