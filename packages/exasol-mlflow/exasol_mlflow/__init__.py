"""exasol-mlflow: train inside Exasol, log the run to your MLflow from the client.

The database trains (a Python UDF that follows the result contract in ``contract.py``); this package runs the training
query, checks what came back, and logs the parameters, the metrics, the training SQL, the model and the lineage tags
``exasol.session_id``, ``exasol.statement_id`` and ``exasol.deployment`` to MLflow - from the client process, so the
UDF needs no MLflow credentials and no network.

    import exasol_mlflow
    run = exasol_mlflow.log_training(conn, training_sql, experiment="trials")
    run.run_id, run.artifact_uri, run.metrics

The tracking server is MLflow's own MLFLOW_TRACKING_URI; without it the run goes to a local MLflow store - a SQLite
database and an artifacts folder in ``tracking_dir`` (default ``./mlflow``) - that ``mlflow ui --backend-store-uri``
opens.
"""

from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .contract import COLUMNS, ResultContractError, TrainingResult, check
from .udf import DEFAULT_PARAMS, call, create_script

__all__ = ["COLUMNS", "DEFAULT_PARAMS", "ResultContractError", "TrainingRun", "call", "create_script", "log_training", "run_training"]
__version__ = "0.1.0"


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


def log_training(conn, training_sql: str, *, experiment: str, run_name: str | None = None,
                 params: dict[str, Any] | None = None, tags: dict[str, str] | None = None,
                 tracking_dir: str | os.PathLike | None = None) -> TrainingRun:
    """Train (``training_sql``), check the result, and log one MLflow run: the UDF's params (with ``params`` on top),
    its metrics, ``training.sql``, the model file and the lineage tags. A result that breaks the contract raises
    ResultContractError and logs nothing."""
    import mlflow

    trained = run_training(conn, training_sql)
    lineage = {"exasol.session_id": str(conn.session_id()), "exasol.statement_id": trained.statement_id,
               "exasol.deployment": _deployment(conn), "exasol.model_format": str(trained.model.get("format")),
               "exasol.udf_python": str(trained.model.get("python", "")), "exasol.udf_sklearn": str(trained.model.get("sklearn", ""))}
    all_tags = {**lineage, **(tags or {})}
    uri = _use_tracking(mlflow, experiment, tracking_dir)
    with mlflow.start_run(run_name=run_name) as run:
        mlflow.log_params({**trained.params, **(params or {})})
        mlflow.log_metrics(trained.metrics)
        mlflow.set_tags(all_tags)
        mlflow.log_text(training_sql.strip() + "\n", "training.sql")
        with tempfile.TemporaryDirectory() as folder:
            model = Path(folder) / "model.pkl"
            model.write_bytes(trained.model_bytes)
            mlflow.log_artifact(str(model), artifact_path="model")
        return TrainingRun(run.info.run_id, run.info.experiment_id, uri, run.info.artifact_uri, trained.metrics, all_tags)
