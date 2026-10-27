"""exasol-mlflow: train inside Exasol, log the run to your MLflow from the client.

The database trains (a Python UDF that emits the run contract in ``contract.py``: udf/templates/train_model.sql in the
kit, or this package's own text classifier); this package checks the server is there BEFORE any SQL runs, runs the
training query, validates every field of what came back, spools it, and logs the parameters, the metrics, the
training SQL, the model, the coefficients and the environment tags to MLflow - from the client process, so the UDF
needs no MLflow credentials and no network.

    import exasol_mlflow
    with exasol_mlflow.start_run(conn, params={"C": 1.0}, experiment="trials", handoff=handoff) as run:
        run.execute(training_sql)
    run.run_id, run.artifact_uri, run.metrics

What can go wrong, and what the cell sees:

- the tracking server does not answer -> ``TrackingUnavailable`` before any SQL (``exakit mlflow start``);
- a field of the UDF's answer is wrong -> ``ContractError("row 1: metrics is not JSON: ...")``, nothing logged;
- the database connection drops while the statement runs (a restart) -> the MLflow run is ended FAILED with the
  reason, no spool is left, and ``DatabaseRestarted("database restarted - re-run the cell")`` is raised;
- the server dies after the result arrived -> the record stays in ``$EXAKIT_HOME/mlflow/spool`` and a warning names
  ``exakit mlflow replay`` (``python -m exasol_mlflow replay``), which logs it with the same metrics and tags.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import subprocess
import warnings
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import records, tracking
from .contract import COLUMNS, INLINE_LIMIT, STATEMENT_COLUMN, ContractError, ResultContractError, TrainingResult, parse
from .records import replay, status
from .tracking import Tracking, TrackingUnavailable, kit_home, resolve
from .udf import DEFAULT_PARAMS, call, create_script

__all__ = [
    "COLUMNS",
    "DEFAULT_PARAMS",
    "INLINE_LIMIT",
    "ContractError",
    "DatabaseRestarted",
    "ResultContractError",
    "Run",
    "TrackingUnavailable",
    "TrainingRun",
    "call",
    "create_script",
    "kit_home",
    "log_training",
    "replay",
    "resolve",
    "run_training",
    "start_run",
    "status",
]
__version__ = "0.3.0"

DEFAULT_EXPERIMENT = "exasol-mlflow"
TAG = "exasol."
_CONNECTION_LOSS = re.compile(r"Connection|Communication|Socket|Closed|BrokenPipe|Disconnect", re.IGNORECASE)
_local_store_noted = False


class DatabaseRestarted(RuntimeError):
    """The database connection dropped while the training statement ran: the run was ended FAILED; re-run the cell."""


@dataclass(frozen=True)
class TrainingRun:
    """What was logged: the MLflow run, where its artifacts are, and the numbers."""

    run_id: str
    experiment_id: str
    tracking_uri: str
    artifact_uri: str
    metrics: dict[str, float]
    tags: dict[str, str]
    run_key: str = ""
    spool: str | None = None      # the record's path while it waits for a replay (logging failed); None once logged


# --- the training statement ------------------------------------------------------------------------------------------

def wrap(training_sql: str) -> str:
    """The training query inside a SELECT that adds the statement's id, so the run names the exact statement that trained."""
    return f"SELECT CURRENT_STATEMENT AS {STATEMENT_COLUMN}, T.* FROM (\n{training_sql.strip().rstrip(';')}\n) T"


def is_connection_loss(err: BaseException) -> bool:
    """Whether an error from the driver means the connection is gone (pyexasol's ExaConnectionError and
    ExaCommunicationError, a websocket closed, a socket error) rather than a statement that failed."""
    if isinstance(err, (ConnectionError, BrokenPipeError, EOFError, OSError)):
        return True
    for cls in type(err).__mro__:
        if cls is Exception:
            break
        if _CONNECTION_LOSS.search(cls.__name__) and not cls.__name__.endswith(("QueryError", "AbortError", "TimeoutError")):
            return True
    return False


def run_training(conn, training_sql: str) -> list[TrainingResult]:
    """Run the training query and check its rows against the contract: one TrainingResult per run key. A dropped
    connection raises DatabaseRestarted; a broken answer ContractError."""
    try:
        result = conn.execute(wrap(training_sql))
        columns = [str(c).upper() for c in result.column_names()]
        rows = list(result.fetchall())
    except Exception as err:
        if is_connection_loss(err):
            raise DatabaseRestarted(f"database restarted - re-run the cell ({_reason(err)})") from err
        raise
    return parse(columns, rows)


def _reason(err: BaseException) -> str:
    message = getattr(err, "message", None) or next((line.strip() for line in str(err).splitlines() if line.strip()), "")
    return f"{type(err).__name__}: {str(message).splitlines()[0][:300]}" if message else type(err).__name__


# --- the environment tags ---------------------------------------------------------------------------------------------

def _manifest() -> dict[str, Any]:
    try:
        doc = json.loads((kit_home() / "manifest.json").read_text(encoding="utf-8"))
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


def kit_version(manifest: dict[str, Any] | None = None) -> str | None:
    doc = _manifest() if manifest is None else manifest
    for node in (doc.get("kit"), (doc.get("components") or {}).get("kit")):
        if isinstance(node, dict) and node.get("version"):
            return str(node["version"])
    return None


def launcher_version(manifest: dict[str, Any] | None = None, timeout: float = 10.0) -> str | None:
    """The Exasol launcher's version: from the manifest's runtime record, else ``exasol version`` when it is on PATH."""
    doc = _manifest() if manifest is None else manifest
    runtime = doc.get("runtime") if isinstance(doc.get("runtime"), dict) else {}
    for key in ("version", "deployment_version"):
        if runtime.get(key):
            return str(runtime[key])
    exe = runtime.get("launcher") if runtime.get("launcher") and Path(str(runtime["launcher"])).is_file() else "exasol"
    try:
        done = subprocess.run([str(exe), "version"], capture_output=True, text=True, timeout=timeout, check=False,
                              stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None
    said = (done.stdout or "").strip().splitlines()
    return said[0].strip()[:40] if done.returncode == 0 and said else None


def db_version(conn) -> dict[str, str]:
    """``{db_version, deployment}`` from EXA_METADATA (``unknown`` when the lookup fails)."""
    try:
        rows = conn.execute("SELECT PARAM_NAME, PARAM_VALUE FROM SYS.EXA_METADATA "
                            "WHERE PARAM_NAME IN ('databaseProductName', 'databaseProductVersion')").fetchall()
        found = {str(name): str(value) for name, value in rows}
    except Exception:  # noqa: BLE001 - the tag is best effort; the training statement decides
        found = {}
    version = found.get("databaseProductVersion", "unknown")
    return {"db_version": version, "deployment": f"{found.get('databaseProductName', 'exasol')} {version}".strip().lower()}


def workflow_id() -> str | None:
    """The active workflow (exakit.nb.workflow) when the notebook package is importable, else EXAKIT_WORKFLOW_ID."""
    try:
        import importlib

        module = importlib.import_module("exakit_nb.workflow")
        found = module.current_workflow()
        if found:
            return str(found)
    except Exception:  # noqa: BLE001 - optional dependency
        pass
    value = os.environ.get("EXAKIT_WORKFLOW_ID", "")
    return value if re.match(r"^wf-\d{8}-[0-9a-f]{6}$", value) else None


def _log_workflow_event(**payload: Any) -> None:
    try:
        import importlib

        module = importlib.import_module("exakit_nb.workflow")
        module.log_event(module.MLFLOW_RUN, **payload)
    except Exception:  # noqa: BLE001 - optional, never in the way of the run
        pass


def _load_handoff(handoff: Any) -> dict[str, Any] | None:
    if handoff is None:
        return None
    if isinstance(handoff, dict):
        return handoff
    try:
        doc = json.loads(Path(handoff).expanduser().read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as err:
        raise ValueError(f"handoff must be the record exakit.nb.read_handoff() returns or the path of one ({err})") from err
    return doc if isinstance(doc, dict) else None


def handoff_tags(handoff: dict[str, Any] | None) -> dict[str, str]:
    """``exasol.descriptor_id``, ``exasol.descriptor_version``, ``exasol.descriptor_digest``, ``exasol.data_digest``,
    ``exasol.handoff_written_at`` from a handoff record (design §4)."""
    if not handoff:
        return {}
    descriptor = handoff.get("descriptor") if isinstance(handoff.get("descriptor"), dict) else {}
    tags = {}
    for tag, value in (("descriptor_id", descriptor.get("id")), ("descriptor_version", descriptor.get("version")),
                       ("descriptor_digest", descriptor.get("digest")), ("data_digest", handoff.get("data_digest")),
                       ("handoff_written_at", handoff.get("written_at"))):
        if value not in (None, ""):
            tags[TAG + tag] = str(value)
    return tags


def _clip(value: Any, limit: int = 5000) -> str:
    text = value if isinstance(value, str) else json.dumps(value, sort_keys=True, default=str)
    return text if len(text) <= limit else text[:limit - 3] + "..."


def _refuse_secrets(tags: dict[str, str]) -> None:
    for key, value in tags.items():
        if re.search(r"(password|passwd|token|secret|api_key|apikey)", key, re.IGNORECASE):
            raise ValueError(f"a tag never holds a credential: refusing {key!r}")
        for name in ("MLFLOW_TRACKING_PASSWORD", "MLFLOW_TRACKING_TOKEN"):
            secret = os.environ.get(name)
            if secret and secret in str(value):
                raise ValueError(f"a tag never holds a credential: {key!r} contains the value of {name}")


# --- the model file the UDF wrote (over 1 MB) -------------------------------------------------------------------------

def bucket_mapping(timeout: float = 120.0) -> tuple[Path, str]:
    """(host folder, the /buckets root UDFs read it under) for the local deployment, from exakit.nb.checks.model_list()
    (``exakit model list --json``) - the same source check_bucket uses."""
    try:
        import importlib

        doc = importlib.import_module("exakit_nb.checks").model_list(timeout=timeout)
    except ImportError:
        exe = _exakit()
        if exe is None:
            raise RuntimeError("the kit's command line (exakit) is not on PATH, so the bucket directory cannot be named") from None
        done = subprocess.run([exe, "model", "list", "--json"], capture_output=True, text=True, timeout=timeout, check=False,
                              stdin=subprocess.DEVNULL)
        if done.returncode != 0:
            raise RuntimeError(f"exakit model list exited {done.returncode}")
        doc = json.loads(done.stdout)
    if not doc.get("bucket_dir") or not doc.get("udf_root"):
        raise RuntimeError("exakit model list --json names no bucket_dir and udf_root")
    return Path(str(doc["bucket_dir"])), str(doc["udf_root"]).rstrip("/")


def _exakit() -> str | None:
    import shutil

    found = shutil.which("exakit")
    if found:
        return found
    candidate = Path(os.environ.get("EXAKIT_BIN_DIR") or Path.home() / ".local" / "bin") / "exakit"
    return str(candidate) if candidate.is_file() else None


def host_path(model_path: str) -> Path:
    """The host file behind a /buckets path the UDF wrote."""
    folder, root = bucket_mapping()
    if not (model_path == root or model_path.startswith(root + "/")):
        raise ContractError(f"model_path {model_path} is not under the deployment's bucket root {root}")
    return folder / model_path[len(root):].lstrip("/")


# --- the run ----------------------------------------------------------------------------------------------------------

class Run:
    """One MLflow run around one training statement: ``run.execute(sql)`` trains, checks, spools and logs; the run
    stays open until the ``with`` block ends, so the block can log more (``mlflow.log_metric``), and an error in it
    marks the run failed. Before execute() the run holds nothing; after it, run_id, metrics, tags and artifact_uri are
    filled in (``runs`` lists every run key's result when the statement grouped by more than one)."""

    def __init__(self, conn, stack: contextlib.ExitStack | None, *, experiment: str, run_name: str | None,
                 params: dict[str, Any] | None, tags: dict[str, str] | None, tracking_dir: str | os.PathLike | None,
                 handoff: Any = None, target: Tracking | None = None):
        self._conn, self._stack = conn, stack
        self._options = {"experiment": experiment, "run_name": run_name, "tracking_dir": tracking_dir}
        self._target = target
        self.params, self.tags = dict(params or {}), dict(tags or {})
        self.handoff = _load_handoff(handoff)
        self.result: TrainingRun | None = None
        self.runs: list[TrainingRun] = []
        self.failed_run_id: str | None = None

    # the tracking target, resolved once (start_run() checked it before yielding)
    @property
    def target(self) -> Tracking:
        if self._target is None:
            self._target = resolve(self._options["tracking_dir"])
        return self._target

    def _base_tags(self) -> dict[str, str]:
        """Everything known before the statement runs: kit, launcher and database versions, session, workflow, handoff."""
        manifest = _manifest()
        tags = {TAG + "kit_version": kit_version(manifest) or "unknown",
                TAG + "launcher_version": launcher_version(manifest) or "unknown"}
        tags.update({TAG + k: v for k, v in db_version(self._conn).items()})
        try:
            tags[TAG + "session_id"] = str(self._conn.session_id())
        except Exception:  # noqa: BLE001
            tags[TAG + "session_id"] = "unknown"
        found = workflow_id()
        if found:
            tags[TAG + "workflow_id"] = found
        tags.update(handoff_tags(self.handoff))
        return tags

    def _result_tags(self, trained: TrainingResult) -> dict[str, str]:
        return {TAG + "statement_id": trained.statement_id, TAG + "run_key": trained.run_key,
                TAG + "language": trained.language, TAG + "container_digest": trained.container_digest,
                TAG + "package_versions": _clip(trained.versions), TAG + "model_format": "sklearn-pickle",
                TAG + "model_sha256": trained.model_sha256 or "",
                TAG + "model_inline": "true" if trained.model_bytes is not None else "false",
                **({TAG + "coefficients": records.COEFFICIENTS_FILE} if isinstance(trained.extras.get("coefficients"), dict) else {})}

    def execute(self, training_sql: str) -> TrainingRun:
        """Run the training statement, check its answer against the contract, spool it, and log the run. A broken answer
        raises ContractError and logs nothing; a dropped connection ends the run FAILED and raises DatabaseRestarted;
        a second statement in the same run is refused (start another run)."""
        if self.result is not None:
            raise RuntimeError("This run already logged a training statement; start another run for the next one.")
        import mlflow

        target = self.target
        base = self._base_tags()
        try:
            results = run_training(self._conn, training_sql)
        except DatabaseRestarted as err:
            self._mark_failed(mlflow, target, base, str(err))
            raise
        docs: list[tuple[dict[str, Any], bytes | None]] = []
        for number, trained in enumerate(results, start=1):
            if not trained.has_model:
                raise ContractError(f"row {number}: model_b64 and model_path are both NULL: {trained.error}")
            blob, host = trained.model_bytes, None
            if trained.model_path is not None:
                host = host_path(trained.model_path)
                blob = records.model_bytes_of({"model": {"host_path": str(host), "sha256": trained.model_sha256}})
            tags = {**base, **self._result_tags(trained), **self.tags}
            _refuse_secrets(tags)
            metrics = dict(trained.metrics)
            if trained.error:
                tags[TAG + "warning"] = trained.error[:5000]
            name = self._options["run_name"] if len(results) == 1 or self._options["run_name"] is None \
                else f"{self._options['run_name']}/{trained.run_key}"
            docs.append((records.record(run_key=trained.run_key, experiment=self._options["experiment"], run_name=name,
                                        params={**trained.params, **self.params}, metrics=metrics, tags=tags,
                                        training_sql=training_sql.strip() + "\n", model_bytes=blob,
                                        model_host_path=None if host is None else str(host),
                                        model_sha256=trained.model_sha256, extras=trained.extras), blob))
        spooled = [records.write_spool(doc) for doc, _ in docs]           # BEFORE anything reaches the server
        self.runs = []
        for (doc, blob), path in zip(docs, spooled):
            try:
                records.use_tracking(mlflow, doc["experiment"], target)
                # Keep a single run open for callers that log extra metrics inside the with-block.
                # Grouped statements produce several independent runs; each must end before the next starts.
                run = records.log_record(mlflow, doc, blob, stack=self._stack if len(results) == 1 else None)
            except Exception as err:
                left = [str(p) for p in spooled[len(self.runs):]]
                warnings.warn(f"MLflow logging failed ({_reason(err)}); the run is kept in {', '.join(left)} - "
                              "log it with: exakit mlflow replay (python -m exasol_mlflow replay)", RuntimeWarning, stacklevel=2)
                raise TrackingUnavailable(f"MLflow logging failed ({_reason(err)}); the run waits in {left[0]}: "
                                          "exakit mlflow replay logs it once the server is back") from err
            path.unlink(missing_ok=True)
            self.runs.append(TrainingRun(run.info.run_id, run.info.experiment_id, tracking.redacted(target.uri),
                                         run.info.artifact_uri, doc["metrics"], doc["tags"], doc["run_key"]))
            _log_workflow_event(run_id=run.info.run_id, experiment=doc["experiment"], run_key=doc["run_key"],
                                tracking=target.source, statement_id=doc["tags"].get(TAG + "statement_id"))
        self.result = self.runs[0]
        self.tags = dict(self.result.tags)
        return self.result

    def _mark_failed(self, mlflow, target: Tracking, base: dict[str, str], reason: str) -> None:
        """AC-ML2.7: the database went away mid-statement - one FAILED run with the reason, no spool."""
        try:
            records.use_tracking(mlflow, self._options["experiment"], target)
            run = mlflow.start_run(run_name=self._options["run_name"])
            try:
                if self.params:
                    mlflow.log_params(self.params)
                mlflow.set_tags({**base, **self.tags, TAG + "failure_reason": reason[:5000]})
            finally:
                mlflow.end_run(status="FAILED")
            self.failed_run_id = run.info.run_id
        except Exception as err:  # noqa: BLE001 - the restart is the news; a server hiccup must not hide it
            warnings.warn(f"could not mark the MLflow run FAILED ({_reason(err)})", RuntimeWarning, stacklevel=3)

    def _done(self) -> TrainingRun:
        if self.result is None:
            raise RuntimeError("Nothing is logged yet: call run.execute(training_sql) first.")
        return self.result

    @property
    def run_id(self) -> str:
        """The MLflow run's id."""
        return self._done().run_id

    @property
    def artifact_uri(self) -> str:
        """Where the run's artifacts (training.sql, model/model.pkl, coefficients.json) are."""
        return self._done().artifact_uri

    @property
    def tracking_uri(self) -> str:
        """The MLflow store the run went to (without any user:password part)."""
        return self._done().tracking_uri

    @property
    def metrics(self) -> dict[str, float]:
        """The UDF's metrics, as logged."""
        return self._done().metrics


def _note_local_store(target: Tracking) -> None:
    global _local_store_noted
    if target.source != tracking.LOCAL_STORE or _local_store_noted:
        return
    _local_store_noted = True
    print(f"MLflow: no server (MLFLOW_TRACKING_URI unset, exakit mlflow start not running) - logging to the local store "
          f"{target.uri}; exakit mlflow start serves it")


@contextlib.contextmanager
def start_run(conn, *, params: dict[str, Any] | None = None, experiment: str = DEFAULT_EXPERIMENT, run_name: str | None = None,
              tags: dict[str, str] | None = None, tracking_dir: str | os.PathLike | None = None, handoff: Any = None,
              timeout: float = 3.0) -> Iterator[Run]:
    """``with start_run(conn, params=..., handoff=handoff) as run: run.execute(sql)`` - one MLflow run for one
    in-database training statement. The tracking server is checked first (TrackingUnavailable before any SQL);
    ``handoff`` (the record exakit.nb.read_handoff() returns, or its path) adds the descriptor and data-digest tags."""
    target = resolve(tracking_dir)
    tracking.check(target, timeout)
    _note_local_store(target)
    with contextlib.ExitStack() as stack:
        yield Run(conn, stack, experiment=experiment, run_name=run_name, params=params, tags=tags, tracking_dir=tracking_dir,
                  handoff=handoff, target=target)


def log_training(conn, training_sql: str, *, experiment: str, run_name: str | None = None,
                 params: dict[str, Any] | None = None, tags: dict[str, str] | None = None,
                 tracking_dir: str | os.PathLike | None = None, handoff: Any = None) -> TrainingRun:
    """start_run() and execute() in one call: train (``training_sql``), check the result, and log one MLflow run."""
    with start_run(conn, params=params, experiment=experiment, run_name=run_name, tags=tags, tracking_dir=tracking_dir,
                   handoff=handoff) as run:
        return run.execute(training_sql)
