"""The optional settings, set from a notebook cell: your model and Langfuse (use_model), the MLflow server (use_mlflow).

They are the environment variables `exakit notebook` already reads (EXAKIT_MODEL_ID, EXAKIT_PROVIDER_BASE_URL,
EXAKIT_PROVIDER_API_KEY, LANGFUSE_*, MLFLOW_TRACKING_URI), so a cell is one more way to give them, not another kind of
setting. The plain values come from the cell. The keys are asked for in a hidden prompt and kept in this kernel's
environment only: never in the notebook, its outputs or on disk, and gone when the kernel stops. A key already set (by
the shell that started JupyterLab, or an earlier run of the cell) is not asked again - unless the address it was for
changed. Empty values change nothing, so a cell left as shipped is a no-op and a headless run never waits on a prompt.
"""

from __future__ import annotations

import getpass
import os
from typing import Callable

from . import model_config

LANGFUSE_BASE_URL = "LANGFUSE_BASE_URL"
LANGFUSE_PUBLIC_KEY = "LANGFUSE_PUBLIC_KEY"
LANGFUSE_SECRET_KEY = "LANGFUSE_SECRET_KEY"
MLFLOW_TRACKING_URI = "MLFLOW_TRACKING_URI"
MLFLOW_USERNAME = "MLFLOW_TRACKING_USERNAME"
MLFLOW_PASSWORD = "MLFLOW_TRACKING_PASSWORD"

Ask = Callable[[str], str]


def _put(name: str, value: str) -> bool:
    """Set ``name`` from a cell value; True when that changed what was there."""
    value = (value or "").strip()
    if not value or os.environ.get(name) == value:
        return False
    os.environ[name] = value
    return True


def _secret(name: str, prompt: str, ask: Ask, notes: list[str]) -> None:
    """Ask for ``name`` (hidden) when it is not set yet. A prompt this front end cannot show is said, not fatal."""
    if os.environ.get(name):
        return
    try:
        value = (ask(prompt) or "").strip()
    except Exception as err:                       # no stdin here (a headless run, a front end without prompts)
        notes.append(f"{name} could not be asked for here ({type(err).__name__}): set it in the terminal before "
                     "`exakit notebook`, then start it again.")
        return
    if "\r" in value or "\n" in value:
        notes.append(f"{name} must be one line; it was not set.")
    elif value:
        os.environ[name] = value


def use_model(model_id: str = "", provider_base_url: str = "", langfuse_base_url: str = "", *,
              ask: Ask | None = None) -> dict:
    """Your model and Langfuse tracing for this kernel. ``model_id`` and ``provider_base_url`` (a Chat Completions base
    URL) set the model and ask for its API key (Enter for none: a local server); ``langfuse_base_url`` turns tracing on
    and asks for its two keys. Prints what is in use, never a key; returns that summary."""
    ask = ask or getpass.getpass
    notes: list[str] = []
    if (model_id or "").strip() or (provider_base_url or "").strip():
        _put(model_config.MODEL_ID, model_id)
        if _put(model_config.BASE_URL, provider_base_url):
            os.environ.pop(model_config.API_KEY, None)      # a key belongs to the endpoint it was given for
        base = os.environ.get(model_config.BASE_URL, "")
        if base and not model_config.clear_text_ok(base):
            notes.append(f"{model_config.BASE_URL} is plain http:// to a host outside this machine and your network: "
                         "no key is asked for, it would travel in clear text. Use its https:// address.")
        elif base:
            _secret(model_config.API_KEY, "API key for the model (hidden; Enter for none): ", ask, notes)
    if (langfuse_base_url or "").strip():
        if _put(LANGFUSE_BASE_URL, langfuse_base_url):
            os.environ.pop(LANGFUSE_PUBLIC_KEY, None)
            os.environ.pop(LANGFUSE_SECRET_KEY, None)
        if not model_config.clear_text_ok(os.environ[LANGFUSE_BASE_URL]):
            notes.append(f"{LANGFUSE_BASE_URL} is plain http:// to a host outside this machine and your network: no "
                         "key is asked for. Use its https:// address.")
        else:
            _secret(LANGFUSE_PUBLIC_KEY, "Langfuse public key: ", ask, notes)
            _secret(LANGFUSE_SECRET_KEY, "Langfuse secret key (hidden): ", ask, notes)
    summary = _model_summary(notes)
    for line in summary["lines"] + notes:
        print(line)
    return summary


def _model_summary(notes: list[str]) -> dict:
    try:
        config = model_config.resolve()
    except ValueError as err:
        config, problem = None, str(err)
    else:
        problem = None
    if config:
        key = "API key set" if config.api_key else "no API key"
        model_line = f"model: {config.model_id} at {config.base_url} ({key})."
    elif problem:
        model_line = f"model: not usable - {problem}."
    else:
        model_line = "model: off, so the AI steps skip."
    missing = [name for name in (LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, LANGFUSE_BASE_URL)
               if not (os.environ.get(name) or (name == LANGFUSE_BASE_URL and os.environ.get("LANGFUSE_HOST")))]
    if not missing:
        base = os.environ.get(LANGFUSE_BASE_URL) or os.environ.get("LANGFUSE_HOST")
        tracing_line = f"Langfuse: tracing to {base}."
    elif len(missing) == 3:
        tracing_line = "Langfuse: off."
    else:
        tracing_line = f"Langfuse: off - {', '.join(missing)} not set."
    # One line, read at a glance: "model: off, so the AI steps skip. Langfuse: off."
    return {"model": bool(config), "tracing": not missing, "lines": [f"{model_line} {tracing_line}"],
            "problem": problem, "notes": list(notes)}


def use_mlflow(tracking_uri: str = "", login: bool = False, *, ask: Ask | None = None) -> dict:
    """The MLflow server this kernel records runs to: ``tracking_uri`` (empty: the kit's own MLflow, or what the shell
    set); ``login=True`` asks for the server's username and password (hidden). Prints where runs go, never a password."""
    ask = ask or getpass.getpass
    notes: list[str] = []
    if _put(MLFLOW_TRACKING_URI, tracking_uri):
        os.environ.pop(MLFLOW_USERNAME, None)
        os.environ.pop(MLFLOW_PASSWORD, None)
    uri = os.environ.get(MLFLOW_TRACKING_URI, "")
    if login:
        if uri.startswith("http://") and not model_config.clear_text_ok(uri):
            notes.append(f"{MLFLOW_TRACKING_URI} is plain http:// to a host outside this machine and your network: no "
                         "password is asked for. Use its https:// address.")
        else:
            _secret(MLFLOW_USERNAME, "MLflow username: ", ask, notes)
            _secret(MLFLOW_PASSWORD, "MLflow password (hidden): ", ask, notes)
    shown = _redacted(uri) if uri else "the kit's own MLflow (exakit mlflow start; exakit mlflow url opens it)"
    lines = [f"MLflow: runs are recorded to {shown}"
             + (" as " + os.environ[MLFLOW_USERNAME] if os.environ.get(MLFLOW_USERNAME) else "")]
    for line in lines + notes:
        print(line)
    return {"tracking_uri": uri or None, "login": bool(os.environ.get(MLFLOW_USERNAME)), "lines": lines,
            "notes": notes}


def _redacted(uri: str) -> str:
    """The URI without a user or password written into it."""
    from urllib.parse import urlsplit, urlunsplit

    parts = urlsplit(uri)
    if parts.username or parts.password:
        netloc = (parts.hostname or "") + (f":{parts.port}" if parts.port else "")
        return urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment))
    return uri
