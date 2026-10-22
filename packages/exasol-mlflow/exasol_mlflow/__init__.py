"""exasol-mlflow: train inside Exasol, log the run to your MLflow from the client.

The database trains (a Python UDF that follows the result contract in ``contract.py``); this package runs the training
query, checks what came back, and logs the parameters, the metrics, the training SQL, the model and the lineage tags
``exasol.session_id``, ``exasol.statement_id`` and ``exasol.deployment`` to MLflow - from the client process, so the
UDF needs no MLflow credentials and no network.

    import exasol_mlflow
    with exasol_mlflow.start_run(conn, params={"C": 1.0}, experiment="trials") as run:
        run.execute(training_sql)
    run.run_id, run.artifact_uri, run.metrics

``log_training(conn, training_sql, experiment=...)`` does the same in one call. The tracking server is MLflow's own
MLFLOW_TRACKING_URI; without it the run goes to a local MLflow store - a SQLite database and an artifacts folder in
``tracking_dir`` (default ``./mlflow``) - that ``mlflow ui --backend-store-uri`` opens.
"""

from __future__ import annotations

import contextlib
import os
import tempfile
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .contract import COLUMNS, ResultContractError, TrainingResult, check
from .udf import DEFAULT_PARAMS, call, create_script

__all__ = [
    "COLUMNS",
    "DEFAULT_PARAMS",
    "ResultContractError",
    "Run",
    "TrainingRun",
    "call",
    "create_script",
    "log_training",
    "run_training",
    "start_run",
]
__version__ = "0.2.0"


@dataclass(frozen=True)
class TrainingRun:
    """What was logged: the MLflow run, where its artifacts are, and the numbers."""

    run_id: str
    experiment_id: str
    tracking_uri: str
    artifact_uri: str
    metrics: dict[str, float]
    tags: dict[str, str]


def run_training(conn, training_sql: str) -> TrainingResult:
    """Run the training query (its rows: PART, CHUNK, TRAINING_RESULT) and check them against the contract. The query runs
    inside a SELECT that adds the statement's id, so the run names the exact statement that trained."""
    wrapped = f"SELECT CURRENT_STATEMENT AS EXASOL_STATEMENT_ID, T.* FROM (\n{training_sql.strip().rstrip(';')}\n) T"
    result = conn.execute(wrapped)
    columns = [str(c).upper() for c in result.column_names()]
    return check(columns, list(result.fetchall()))


def _deployment(conn) -> str:
    """What trained: the database product and version, e.g. ``exasol 2025.1.8``."""
    rows = conn.execute("SELECT PARAM_NAME, PARAM_VALUE FROM SYS.EXA_METADATA "
                        "WHERE PARAM_NAME IN ('databaseProductName', 'databaseProductVersion')").fetchall()
    found = {str(name): str(value) for name, value in rows}
    return f"{found.get('databaseProductName', 'exasol')} {found.get('databaseProductVersion', 'unknown')}".strip().lower()


LOCAL_DIR = "mlflow"
DEFAULT_EXPERIMENT = "exasol-mlflow"


def _use_tracking(mlflow, experiment: str, tracking_dir: str | os.PathLike | None) -> str:
    """Point MLflow at MLFLOW_TRACKING_URI when it is set; else at a local store - ``mlflow.db`` (SQLite) and an
    ``artifacts`` folder in ``tracking_dir`` - creating the experiment there so its artifacts stay beside the database.
    Returns the tracking URI."""
    if os.environ.get("MLFLOW_TRACKING_URI"):
        uri = os.environ["MLFLOW_TRACKING_URI"]
        mlflow.set_tracking_uri(uri)
        mlflow.set_experiment(experiment)
        return uri
    folder = Path(tracking_dir or LOCAL_DIR).expanduser().resolve()
    folder.mkdir(parents=True, exist_ok=True)
    uri = f"sqlite:///{folder / 'mlflow.db'}"
    mlflow.set_tracking_uri(uri)
    if mlflow.get_experiment_by_name(experiment) is None:
        mlflow.create_experiment(experiment, artifact_location=(folder / "artifacts").as_uri())
    mlflow.set_experiment(experiment)
    return uri


def _lineage(conn, trained: TrainingResult) -> dict[str, str]:
    """The tags that find the training statement again: the session, the statement, the database, and what the UDF ran."""
    return {"exasol.session_id": str(conn.session_id()), "exasol.statement_id": trained.statement_id,
            "exasol.deployment": _deployment(conn), "exasol.model_format": str(trained.model.get("format")),
            "exasol.udf_python": str(trained.model.get("python", "")), "exasol.udf_sklearn": str(trained.model.get("sklearn", ""))}


class Run:
    """One MLflow run around one training statement: ``run.execute(sql)`` trains, checks and logs; the run stays open
    until the ``with`` block ends, so the block can log more (``mlflow.log_metric``), and an error in it marks the run
    failed. Before execute() the run holds nothing; after it, run_id, metrics, tags and artifact_uri are filled in."""

    def __init__(self, conn, stack: contextlib.ExitStack, *, experiment: str, run_name: str | None, params: dict[str, Any] | None,
                 tags: dict[str, str] | None, tracking_dir: str | os.PathLike | None):
        self._conn, self._stack = conn, stack
        self._options = {"experiment": experiment, "run_name": run_name, "tracking_dir": tracking_dir}
        self.params, self.tags = dict(params or {}), dict(tags or {})
        self.result: TrainingRun | None = None

    def execute(self, training_sql: str) -> TrainingRun:
        """Run the training statement, check its answer against the contract, and log the run. A broken answer raises
        ResultContractError and logs nothing; a second statement in the same run is refused (start another run)."""
        if self.result is not None:
            raise RuntimeError("This run already logged a training statement; start another run for the next one.")
        import mlflow

        trained = run_training(self._conn, training_sql)
        self.tags = {**_lineage(self._conn, trained), **self.tags}
        uri = _use_tracking(mlflow, self._options["experiment"], self._options["tracking_dir"])
        run = self._stack.enter_context(mlflow.start_run(run_name=self._options["run_name"]))
        mlflow.log_params({**trained.params, **self.params})
        mlflow.log_metrics(trained.metrics)
        mlflow.set_tags(self.tags)
        mlflow.log_text(training_sql.strip() + "\n", "training.sql")
        with tempfile.TemporaryDirectory() as folder:
            model = Path(folder) / "model.pkl"
            model.write_bytes(trained.model_bytes)
            mlflow.log_artifact(str(model), artifact_path="model")
        self.result = TrainingRun(run.info.run_id, run.info.experiment_id, uri, run.info.artifact_uri, trained.metrics, self.tags)
        return self.result

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
        """Where the run's artifacts (training.sql, model/model.pkl) are."""
        return self._done().artifact_uri

    @property
    def tracking_uri(self) -> str:
        """The MLflow store the run went to."""
        return self._done().tracking_uri

    @property
    def metrics(self) -> dict[str, float]:
        """The UDF's metrics, as logged."""
        return self._done().metrics


@contextlib.contextmanager
def start_run(conn, *, params: dict[str, Any] | None = None, experiment: str = DEFAULT_EXPERIMENT, run_name: str | None = None,
              tags: dict[str, str] | None = None, tracking_dir: str | os.PathLike | None = None) -> Iterator[Run]:
    """``with start_run(conn, params=...) as run: run.execute(sql)`` - one MLflow run for one in-database training
    statement: ``params`` (on top of the UDF's own), the metrics, ``training.sql``, the model file and the lineage tags
    ``exasol.session_id``, ``exasol.statement_id`` and ``exasol.deployment``."""
    with contextlib.ExitStack() as stack:
        yield Run(conn, stack, experiment=experiment, run_name=run_name, params=params, tags=tags, tracking_dir=tracking_dir)


def log_training(conn, training_sql: str, *, experiment: str, run_name: str | None = None,
                 params: dict[str, Any] | None = None, tags: dict[str, str] | None = None,
                 tracking_dir: str | os.PathLike | None = None) -> TrainingRun:
    """start_run() and execute() in one call: train (``training_sql``), check the result, and log one MLflow run. A result
    that breaks the contract raises ResultContractError and logs nothing."""
    with start_run(conn, params=params, experiment=experiment, run_name=run_name, tags=tags, tracking_dir=tracking_dir) as run:
        return run.execute(training_sql)
