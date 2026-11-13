"""The optional settings, set from a notebook cell: your model and Langfuse (use_model), the MLflow server (use_mlflow).

They are the environment variables `exakit notebook` already reads (EXAKIT_MODEL_ID, EXAKIT_PROVIDER_BASE_URL,
EXAKIT_PROVIDER_API_KEY, LANGFUSE_*, MLFLOW_TRACKING_URI), so a cell is one more way to give them, not another kind of
setting. The plain values come from the cell. The keys are asked for in a hidden prompt and kept in this kernel's
environment only: never in the notebook or its outputs, and gone when the kernel stops - unless ``remember=True``,
which saves them beside the kit's credentials (readable by this user only, 0600) so every notebook's kernel has them
(``import exakit.nb`` loads them; ``forget_model()`` deletes them). A key already set (by
the shell that started JupyterLab, or an earlier run of the cell) is not asked again - unless the address it was for
changed. Empty values change nothing, so a cell left as shipped is a no-op and a headless run never waits on a prompt.
"""

from __future__ import annotations

import getpass
import os
import platform
import sys
from pathlib import Path
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
              effort: str | None = None, ask: Ask | None = None, remember: bool = False) -> dict:
    """Your model and Langfuse tracing for this kernel. ``model_id`` and ``provider_base_url`` (a Chat Completions base
    URL) set the model and ask for its API key (Enter for none: a local server); ``effort`` sets how hard a reasoning
    model thinks ("low", "medium", "high"; "" for the model's default; nb.effort_levels says which a model takes);
    ``langfuse_base_url`` turns tracing on and asks for its two keys. Prints what is in use, never a key; returns that summary."""
    ask = ask or getpass.getpass
    notes: list[str] = []
    if effort is not None:
        chosen = str(effort).strip().lower()
        if chosen and chosen not in model_config.EFFORTS:
            raise ValueError(f"effort must be one of {', '.join(model_config.EFFORTS)}, or '' for the model's default.")
        if chosen:
            os.environ[model_config.EFFORT] = chosen
        else:
            os.environ.pop(model_config.EFFORT, None)
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
    if remember and not notes:
        _remember(model=bool((model_id or "").strip() or (provider_base_url or "").strip() or effort is not None),
                  langfuse=bool((langfuse_base_url or "").strip()))
        notes_saved = "Saved for every notebook of this kit (readable by you only); forget_model() deletes it."
    else:
        notes_saved = ""
    summary = _model_summary(notes)
    for line in summary["lines"] + notes + ([notes_saved] if notes_saved else []):
        print(line)
    return summary


# -- remembered for every notebook (opt-in: use_model(..., remember=True)) --------------------------------------------
_REMEMBERED = {  # file in the kit's credentials folder -> the variable it holds
    "notebook_model_id": model_config.MODEL_ID, "notebook_model_base_url": model_config.BASE_URL,
    "notebook_model_api_key": model_config.API_KEY, "notebook_model_effort": model_config.EFFORT,
    "notebook_langfuse_base_url": LANGFUSE_BASE_URL,
    "notebook_langfuse_public_key": LANGFUSE_PUBLIC_KEY, "notebook_langfuse_secret_key": LANGFUSE_SECRET_KEY,
}
_MODEL_FILES = ("notebook_model_id", "notebook_model_base_url", "notebook_model_api_key", "notebook_model_effort")
_LANGFUSE_FILES = ("notebook_langfuse_base_url", "notebook_langfuse_public_key", "notebook_langfuse_secret_key")


def _credentials() -> Path:
    from .descriptor_store import kit_home

    return kit_home() / "credentials"


def _write_private(path: Path, text: str) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _remember(*, model: bool, langfuse: bool) -> None:
    for name in (_MODEL_FILES if model else ()) + (_LANGFUSE_FILES if langfuse else ()):
        value = os.environ.get(_REMEMBERED[name], "")
        if value:
            _write_private(_credentials() / name, value)
        else:
            (_credentials() / name).unlink(missing_ok=True)


def forget_model(model: bool = True, langfuse: bool = True) -> None:
    """Delete what use_model(..., remember=True) saved (the model, Langfuse, or both) and clear it from this kernel."""
    for name in (_MODEL_FILES if model else ()) + (_LANGFUSE_FILES if langfuse else ()):
        (_credentials() / name).unlink(missing_ok=True)
        os.environ.pop(_REMEMBERED[name], None)
    print("Forgotten: " + " and ".join(x for x, on in (("the AI model", model), ("Langfuse", langfuse)) if on) + ".")


def load_remembered() -> list[str]:
    """Put the remembered settings into this kernel where it has none of its own; the variables it set."""
    done = []
    for name, variable in _REMEMBERED.items():
        path = _credentials() / name
        if os.environ.get(variable) or not path.is_file():
            continue
        value = path.read_text(encoding="utf-8").strip()
        if value:
            os.environ[variable] = value
            done.append(variable)
    return done


def _model_summary(notes: list[str]) -> dict:
    try:
        config = model_config.resolve()
    except ValueError as err:
        config, problem = None, str(err)
    else:
        problem = None
    if config:
        key = "API key set" if config.api_key else "no API key"
        effort = os.environ.get(model_config.EFFORT, "").strip()
        model_line = f"model: {config.model_id} at {config.base_url} ({key}{', effort ' + effort if effort else ''})."
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
    # One line, read at a glance: "model: off, so the AI steps skip. Langfuse: off." - and, while something is
    # still off, where the how-to is, so nobody has to find it.
    hint = "" if config and not missing else f" {HOW}"
    return {"model": bool(config), "tracing": not missing, "lines": [f"{model_line} {tracing_line}{hint}"],
            "problem": problem, "notes": list(notes)}


HOW = "How to set them on this machine: nb.model_setup()"
NAMES = (model_config.MODEL_ID, model_config.BASE_URL, model_config.API_KEY,
         LANGFUSE_BASE_URL, LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY)
SECRETS = frozenset((model_config.API_KEY, LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY))
EXAMPLE_MODEL, EXAMPLE_URL, EXAMPLE_LANGFUSE = "claude-opus-5-5", "https://api.anthropic.com/v1/", "https://cloud.langfuse.com"


def this_machine() -> str:
    """``windows``, ``mac``, ``wsl`` or ``linux``: which terminal lines apply here."""
    system = platform.system().lower()
    if system == "windows":
        return "windows"
    if system == "darwin":
        return "mac"
    try:
        if "microsoft" in Path("/proc/version").read_text(encoding="utf-8", errors="replace").lower():
            return "wsl"
    except OSError:
        pass
    return "linux"


def _settings_file() -> Path:
    return Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit").expanduser() / "exakit.env"


def _terminal_lines(machine: str) -> list[str]:
    """The lines to type, for one machine. A key is typed into a hidden prompt: never part of a command."""
    if machine == "windows":
        hidden = '[Net.NetworkCredential]::new("", (Read-Host "{0}" -AsSecureString)).Password'
        return [f'$env:{model_config.MODEL_ID} = "{EXAMPLE_MODEL}"',
                f'$env:{model_config.BASE_URL} = "{EXAMPLE_URL}"',
                f"$env:{model_config.API_KEY} = " + hidden.format("Model API key"),
                f'$env:{LANGFUSE_BASE_URL} = "{EXAMPLE_LANGFUSE}"',
                f"$env:{LANGFUSE_PUBLIC_KEY} = " + hidden.format("Langfuse public key"),
                f"$env:{LANGFUSE_SECRET_KEY} = " + hidden.format("Langfuse secret key"),
                "exakit notebook"]
    hidden = "printf '{0}: '; read -rs {1}; echo; export {1}"
    return [f'export {model_config.MODEL_ID}="{EXAMPLE_MODEL}"',
            f'export {model_config.BASE_URL}="{EXAMPLE_URL}"',
            hidden.format("Model API key", model_config.API_KEY),
            f'export {LANGFUSE_BASE_URL}="{EXAMPLE_LANGFUSE}"',
            hidden.format("Langfuse public key", LANGFUSE_PUBLIC_KEY),
            hidden.format("Langfuse secret key", LANGFUSE_SECRET_KEY),
            "exakit notebook"]


TERMINAL = {"windows": "Windows: in PowerShell", "mac": "Mac: in Terminal", "linux": "Linux: in a terminal",
            "wsl": "WSL: in the WSL terminal (the Linux one, not PowerShell)"}


def _in_notebook() -> bool:
    """True inside a running notebook (JupyterLab or Marimo), where a prompt can be shown; False in a script or test,
    which must never wait on one."""
    marimo = sys.modules.get("marimo")
    if marimo is not None:
        try:
            if marimo.running_in_notebook():
                # Only while someone edits it: `marimo run`, `marimo export` and a script have nobody to answer.
                return marimo.app_meta().mode == "edit"
        except Exception:
            return False
    try:
        shell = get_ipython()  # type: ignore[name-defined]  # noqa: F821 - defined only inside IPython
    except NameError:
        return False
    return getattr(shell, "kernel", None) is not None


def _ask_missing(read: Ask, secret: Ask) -> list[str]:
    """Ask for what is not set yet: the model id and address and the Langfuse address as plain text, then the keys in
    a hidden box (through use_model). Enter skips a value. Returns notes; raises when this front end has no prompt."""
    model_id = os.environ.get(model_config.MODEL_ID, "")
    base = os.environ.get(model_config.BASE_URL, "")
    langfuse = os.environ.get(LANGFUSE_BASE_URL, "")
    if not model_id:
        model_id = (read(f"Model ID (Enter to skip; for example {EXAMPLE_MODEL}): ") or "").strip()
    if model_id and not base:
        base = (read(f"Model API address (for example {EXAMPLE_URL}; Ollama: its /v1/ address): ") or "").strip()
    if not langfuse:
        langfuse = (read(f"Langfuse address (Enter to skip; for example {EXAMPLE_LANGFUSE}): ") or "").strip()
    if not (model_id or langfuse):
        return []
    summary = use_model(model_id, base, langfuse, ask=secret)
    return list(summary.get("notes") or [])


def model_setup(machine: str | None = None, show: bool = True, *, ask: bool | None = None,
                read: Ask | None = None, secret: Ask | None = None) -> dict:
    """Set up your model and Langfuse for this kernel, and say how to set them for every notebook. Inside a notebook
    (JupyterLab or Marimo) it first asks for what is missing - the model id and address, the Langfuse address, then
    each key in a hidden box; Enter skips one. ``ask=False`` only reports; a script or test never waits on a prompt.
    Then it prints what is set and, for anything still missing, the terminal lines for this machine (Windows, Mac,
    Linux or WSL). Prints values, never a key; returns {"machine", "set", "missing", "lines", "asked"}."""
    machine = machine or this_machine()
    asked = False
    if (ask if ask is not None else _in_notebook()) and any(not os.environ.get(name) for name in NAMES):
        try:
            for note in _ask_missing(read or input, secret or getpass.getpass):
                print(note)
            asked = True
        except Exception as err:                    # a front end without prompts, a headless run
            print(f"Could not ask here ({type(err).__name__}); the lines below set them instead.")
    state = {name: bool(os.environ.get(name)) for name in NAMES}
    lines = ["Your AI model and Langfuse - what this kernel has:"]
    for name in NAMES:
        if not state[name]:
            shown = "not set"
        elif name in SECRETS:
            shown = "set (hidden)"
        else:
            shown = os.environ[name]
        lines.append(f"  {name:<26} {shown}")
    missing = [name for name in NAMES if not state[name]]
    summary = _model_summary([])
    lines.append("  " + summary["lines"][0].replace(f" {HOW}", ""))
    if not missing:
        lines.append("Everything is set. Nothing to do.")
    else:
        lines += ["",
                  "1. Set them here, in this kernel (gone when it stops): run nb.model_setup() and answer, or:",
                  f'   nb.use_model("{EXAMPLE_MODEL}", "{EXAMPLE_URL}", "{EXAMPLE_LANGFUSE}")',
                  "   A hidden box asks for each key; Enter skips one. Only the model: leave the Langfuse address out.",
                  "   A server on your own machine (Ollama): its /v1/ address, and Enter at the key.",
                  "",
                  f"2. Or once for every notebook. {TERMINAL[machine]}, type these, then start the notebooks from it:"]
        lines += ["   " + line for line in _terminal_lines(machine)]
        lines += ["   Each key goes into a hidden prompt: it is in no command and not in the shell's history.",
                  "   Already running? exakit notebook stop, then exakit notebook, in that terminal: the server reads",
                  "   these when it starts, and a kernel restart does not.",
                  f"   The model's id and address can stay in {_settings_file()} (its {model_config.MODEL_ID} and",
                  f"   {model_config.BASE_URL} lines, remove the '# '); that file takes no key and no LANGFUSE_* name.",
                  "",
                  "Next: run nb.model_setup() again to check.",
                  "Set only what you use: no model means the AI steps skip and say so; no Langfuse means no tracing.",
                  "MODEL-PROVIDERS.md beside the Data Scientist notebooks lists the providers (Claude, Ollama, LM Studio, vLLM, Gemini)."]
    if show:
        print("\n".join(lines))
    return {"machine": machine, "set": [name for name in NAMES if state[name]], "missing": missing, "lines": lines,
            "asked": asked}


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
