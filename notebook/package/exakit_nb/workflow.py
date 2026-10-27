"""One workflow id on everything (X-1): ``workflow()`` starts or resumes one, and every helper that does something
appends a line to its log while it is active - a statement, a trace, an MLflow run, a descriptor draft or approval, a
handoff, a dashboard revision, a model put. Without a workflow nothing is written: there are no implicit workflows.

    import exakit.nb as nb
    wf = nb.workflow("churn-baseline")        # Workflow wf-20261027-3f9a1c: log ~/.exasol-starter-kit/workflows/...
    nb.workflow(resume="wf-20261027-3f9a1c")  # later, in another kernel

The id is ``wf-YYYYMMDD-<6 hex>``, kept in the session store and in EXAKIT_WORKFLOW_ID so a child process (a CLI call
from a notebook) inherits it. The log is ``$EXAKIT_HOME/workflows/<id>.jsonl`` (EXAKIT_HOME default
~/.exasol-starter-kit), append-only, one JSON object per line: ``{ts, workflow_id, kind, ...payload}``; the folder is
0700 and the file 0600, each line one O_APPEND write so two kernels on one workflow never interleave. A log that
cannot be written warns and the cell goes on: logging never fails the work it describes.

The log never holds a credential: a secret-named payload key or a DSN containing a password is refused (a
ValueError - the caller's mistake, before anything is written). SQL text is screened rather than refused: a statement
that mentions PASSWORD, API_KEY, IDENTIFIED BY and the like - or carries a DSN with a password - is logged with its
text replaced by ``<redacted: credential-like SQL>`` and ``redacted: true``, its digest kept, and one warning; the
logger never fails the query it records, which has already run. Other SQL text is kept so the user can find the
query again.

``python -m exakit_nb.workflow list|show <id> [--json]`` is what ``exakit workflow`` runs.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import secrets
import sys
import warnings
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ._kit import recall, remember

__all__ = ["DASHBOARD_REVISION", "DESCRIBE_APPROVE", "DESCRIBE_DRAFT", "ENV_VARIABLE", "HANDOFF", "KINDS", "MLFLOW_RUN",
           "MODEL_PUT", "REDACTED_SQL", "SQL", "START", "TRACE", "current_workflow", "list_workflows", "log_event", "log_path",
           "log_sql", "read_log", "workflow"]

ENV_VARIABLE = "EXAKIT_WORKFLOW_ID"
SESSION_KEY = "workflow_id"
ID_PATTERN = re.compile(r"^wf-\d{8}-[0-9a-f]{6}$")

# The kinds a line can carry. A helper logs exactly one of these; the CLI shows them as they are.
START = "start"
DESCRIBE_DRAFT = "describe.draft"
DESCRIBE_APPROVE = "describe.approve"
SQL = "sql"
TRACE = "trace"
MLFLOW_RUN = "mlflow.run"
HANDOFF = "handoff"
DASHBOARD_REVISION = "dashboard.revision"
MODEL_PUT = "model.put"
ASK_APPROVE = "ask.approve"
ASK_ANSWER = "ask.answer"
KINDS = (START, DESCRIBE_DRAFT, DESCRIBE_APPROVE, SQL, TRACE, MLFLOW_RUN, HANDOFF, DASHBOARD_REVISION,
         MODEL_PUT, ASK_APPROVE, ASK_ANSWER)

# What a payload may never be named, and what a value may never look like (user:password@ inside a URL).
_SECRET_KEY = re.compile(r"(^|[^a-z0-9])(password|passwd|token|secret|api_key|apikey)([^a-z0-9]|$)")
_DSN_PASSWORD = re.compile(r"://[^/\s@:]+:[^/\s@]+@")
_SQL_CREDENTIAL = re.compile(r"\b(?:IDENTIFIED\s+BY|PASSWORD|PASSWD|API[_ ]?KEY|ACCESS[_ ]?TOKEN)\b", re.I)
_SQL_KEYS = ("sql", "statement", "query")
REDACTED_SQL = "<redacted: credential-like SQL>"     # what the log holds instead of credential-like statement text


def home() -> Path:
    """The kit's home for the log: EXAKIT_HOME, else ~/.exasol-starter-kit."""
    return Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit").expanduser()


def workflows_dir() -> Path:
    return home() / "workflows"


def log_path(workflow_id: str) -> Path:
    """Where a workflow's log lives, whether or not it exists yet."""
    return workflows_dir() / f"{workflow_id}.jsonl"


def _display(path: Path) -> str:
    """The path with the home folder as ~, for a printed line."""
    try:
        return "~/" + path.relative_to(Path.home()).as_posix()
    except ValueError:
        return str(path)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def new_id(now: datetime | None = None) -> str:
    """A fresh id: the UTC date and six random lowercase hex digits."""
    return f"wf-{(now or datetime.now(timezone.utc)):%Y%m%d}-{secrets.token_hex(3)}"


def _check_id(workflow_id: str) -> str:
    if not isinstance(workflow_id, str) or not ID_PATTERN.match(workflow_id):
        raise ValueError(f"Not a workflow id: {workflow_id!r} (expected wf-YYYYMMDD-xxxxxx, six lowercase hex digits)")
    return workflow_id


def _kit_version() -> str | None:
    """The installed kit's version from its manifest, when the manifest is there and says so."""
    try:
        doc = json.loads((home() / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    for node in ((doc.get("kit") or {}), ((doc.get("components") or {}).get("kit") or {})):
        version = node.get("version") if isinstance(node, dict) else None
        if version:
            return str(version)
    return None


def workflow(name: str | None = None, resume: str | None = None) -> str:
    """Start a workflow (a new id, a ``start`` line in its log) or, with ``resume``, continue an existing one. The id
    becomes the session's and EXAKIT_WORKFLOW_ID's, and is returned. Resuming an id whose log does not exist is a
    ValueError naming the path, so a typo never starts an empty log under a made-up id."""
    if resume is not None:
        workflow_id = _check_id(resume)
        path = log_path(workflow_id)
        if not path.is_file():
            raise ValueError(f"No log for workflow {workflow_id}: {path} does not exist (exakit workflow list)")
    else:
        workflow_id = new_id()
    remember(SESSION_KEY, workflow_id)
    os.environ[ENV_VARIABLE] = workflow_id
    if resume is None:
        log_event(START, name=name, kit_version=_kit_version(),
                  python=platform.python_version(), platform=platform.platform())
    print(f"Workflow {workflow_id}: log {_display(log_path(workflow_id))}")
    return workflow_id


def current_workflow() -> str | None:
    """The active workflow id: the session's, else the one inherited through EXAKIT_WORKFLOW_ID, else None."""
    session = recall(SESSION_KEY)
    if session:
        return str(session)
    inherited = os.environ.get(ENV_VARIABLE, "")
    return inherited if ID_PATTERN.match(inherited) else None


def _screen(payload: dict[str, Any]) -> dict[str, Any]:
    """The payload as the log may hold it. A secret-named key or a DSN with a password in a value is a ValueError
    (the caller named a credential: a programming error, caught before anything is written). Statement text under
    ``sql``/``statement``/``query`` is never refused - the statement has already run, and a logger must not fail the
    call it records: when it looks credential-bearing (PASSWORD, API_KEY, IDENTIFIED BY, a DSN with a password ...)
    the text becomes REDACTED_SQL, ``redacted`` is set, any ``sql_digest`` stays, and one warning says so."""
    screened = dict(payload)
    for key, value in payload.items():
        if _SECRET_KEY.search(str(key).lower()):
            raise ValueError(f"The workflow log never holds a credential: refusing payload key {key!r}")
        if key.lower() in _SQL_KEYS and isinstance(value, str):
            if _SQL_CREDENTIAL.search(value) or _DSN_PASSWORD.search(value):
                screened[key] = REDACTED_SQL
                screened["redacted"] = True
                warnings.warn(f"The workflow log never holds credential-like SQL: {key!r} was logged as {REDACTED_SQL} "
                              "(its digest is kept)", RuntimeWarning, stacklevel=3)
            continue
        _refuse_dsn(value, key)
    return screened


def _refuse_dsn(value: Any, key: str) -> None:
    if isinstance(value, str):
        if _DSN_PASSWORD.search(value):
            raise ValueError(f"The workflow log never holds a credential: {key!r} looks like a DSN with a password in it")
    elif isinstance(value, dict):
        for inner_key, inner in value.items():
            _refuse_dsn(inner, f"{key}.{inner_key}")
    elif isinstance(value, (list, tuple)):
        for item in value:
            _refuse_dsn(item, key)


def log_event(kind: str, **payload: Any) -> None:
    """Append one line to the active workflow's log; nothing when no workflow is active. A credential-named payload
    key or a DSN with a password is a ValueError (the caller's mistake); credential-like statement text is logged
    redacted with a warning (never an exception: the statement already ran); a log that cannot be written is a warning
    (the environment's)."""
    workflow_id = current_workflow()
    if workflow_id is None:
        return
    payload = _screen(payload)
    line = json.dumps({"ts": _now(), "workflow_id": workflow_id, "kind": kind, **payload}, default=str) + "\n"
    path = log_path(workflow_id)
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)
    except OSError as error:
        warnings.warn(f"Workflow {workflow_id}: could not append to {path} ({error}); the step ran, the line is lost",
                      RuntimeWarning, stacklevel=2)


def _statement_id(conn) -> str | None:
    """The id of the statement that just ran on this connection. Exasol numbers a session's statements in order, so the
    one before the lookup's own CURRENT_STATEMENT is the caller's (exasol-mlflow wraps the training SELECT to read it
    inline; a query whose columns the caller keeps cannot be wrapped, hence the lookup)."""
    try:
        current = conn.execute("SELECT CURRENT_STATEMENT").fetchval()
        return str(int(current) - 1)
    except Exception:          # noqa: BLE001 - lineage is best effort; the statement itself already succeeded
        return None


def log_sql(conn, statement: str, rows: int | None, statement_id: str | None = None) -> None:
    """Log a statement sql() ran: the session and statement ids that find it in the database's audit log, the
    statement's SHA-256 (what traces and runs carry), how many rows came back, and the statement text - redacted, with
    a warning, when it looks credential-bearing (a PASSWORD or API_KEY column, say); this never raises, the query has
    already run. No-op without a workflow; the statement id is looked up on the connection unless given."""
    if current_workflow() is None:
        return
    try:
        session_id = str(conn.session_id())
    except Exception:          # noqa: BLE001 - a fake or closed connection still gets its statement logged
        session_id = None
    if statement_id is None:
        statement_id = _statement_id(conn)
    digest = hashlib.sha256(statement.encode("utf-8")).hexdigest()
    log_event(SQL, session_id=session_id, statement_id=statement_id, sql_digest=digest, rows=rows, sql=statement)


def read_log(workflow_id: str) -> list[dict]:
    """Every line of a workflow's log, in order. A missing log is a FileNotFoundError naming the path."""
    path = log_path(_check_id(workflow_id))
    if not path.is_file():
        raise FileNotFoundError(f"No log for workflow {workflow_id}: {path}")
    events = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                events.append(json.loads(line))
    return events


def list_workflows() -> list[dict]:
    """One summary per log in the workflows folder, oldest first: id, name (from its start line), started, last
    (first and last timestamps) and events (the line count). An unreadable log is skipped."""
    folder = workflows_dir()
    if not folder.is_dir():
        return []
    found = []
    for path in sorted(folder.glob("wf-*.jsonl")):
        workflow_id = path.stem
        if not ID_PATTERN.match(workflow_id):
            continue
        try:
            events = read_log(workflow_id)
        except (OSError, ValueError):
            continue
        if not events:
            continue
        start = next((event for event in events if event.get("kind") == START), {})
        found.append({"id": workflow_id, "name": start.get("name"), "started": events[0].get("ts"),
                      "last": events[-1].get("ts"), "events": len(events)})
    return found


# --- the command line: what `exakit workflow` runs through the kit's notebook Python ---------------------------------

USAGE = "usage: python -m exakit_nb.workflow list|show <id> [--json]"


def _print_list(rows: list[dict], as_json: bool) -> None:
    if as_json:
        print(json.dumps(rows, indent=2))
        return
    if not rows:
        print("No workflows yet: start one in a notebook with nb.workflow('name').")
        return
    width = max(len(str(row["name"] or "")) for row in rows)
    print(f"{'ID':<19}  {'STARTED':<20}  {'LAST':<20}  {'EVENTS':>6}  NAME")
    for row in rows:
        print(f"{row['id']:<19}  {row['started'] or '':<20}  {row['last'] or '':<20}  {row['events']:>6}  "
              f"{(row['name'] or ''):<{width}}".rstrip())


def _print_show(events: list[dict], as_json: bool) -> None:
    if as_json:
        print(json.dumps(events, indent=2))
        return
    for event in events:
        rest = {k: v for k, v in event.items() if k not in ("ts", "workflow_id", "kind")}
        summary = "  ".join(f"{k}={_short(v)}" for k, v in rest.items() if v is not None)
        print(f"{event.get('ts', ''):<20}  {event.get('kind', ''):<18}  {summary}".rstrip())


def _short(value: Any, limit: int = 80) -> str:
    text = value if isinstance(value, str) else json.dumps(value, default=str)
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit - 3] + "..."


def main(argv: list[str] | None = None) -> int:
    """list|show <id> [--json]; exit 0, 1 when the workflow does not exist, 2 on bad arguments."""
    args = list(sys.argv[1:] if argv is None else argv)
    as_json = False
    words = []
    for arg in args:
        if arg in ("--json", "-j"):
            as_json = True
        elif arg.startswith("-"):
            print(f"Unknown option {arg!r}. {USAGE}", file=sys.stderr)
            return 2
        else:
            words.append(arg)
    if not words or words[0] not in ("list", "show"):
        print(USAGE, file=sys.stderr)
        return 2
    if words[0] == "list":
        if len(words) != 1:
            print(f"list takes no argument. {USAGE}", file=sys.stderr)
            return 2
        _print_list(list_workflows(), as_json)
        return 0
    if len(words) != 2:
        print(f"show needs exactly one workflow id. {USAGE}", file=sys.stderr)
        return 2
    try:
        events = read_log(words[1])
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    except FileNotFoundError as error:
        print(str(error), file=sys.stderr)
        return 1
    _print_show(events, as_json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
