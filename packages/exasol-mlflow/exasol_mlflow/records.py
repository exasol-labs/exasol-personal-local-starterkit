"""The spool and the replay (design §6): what a run logs is written to ``$EXAKIT_HOME/mlflow/spool/<run_key>-<id>.json``
BEFORE MLflow sees it and removed once the run is logged, so a server that dies mid-run loses nothing - ``replay()``
(``python -m exasol_mlflow replay``, ``exakit mlflow replay``) logs every pending record with the same params,
metrics, tags and artefacts, then removes it.

A record holds the run's params, metrics, tags, the training SQL, the model (base64 inline, or the host path of the
file the UDF wrote with its SHA-256, checked again on replay) and the extras. It never holds a tracking URI or a
credential: replay resolves the server the way start_run() does.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import tracking
from .contract import ContractError

SPOOL_VERSION = 1
COEFFICIENTS_FILE = "coefficients.json"
EXTRAS_FILE = "extras.json"
MODEL_FILE = "model.pkl"


def spool_dir() -> Path:
    return tracking.mlflow_dir() / "spool"


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def record(*, run_key: str, experiment: str, run_name: str | None, params: dict[str, Any], metrics: dict[str, float],
           tags: dict[str, str], training_sql: str, model_bytes: bytes | None, model_host_path: str | None,
           model_sha256: str | None, extras: dict[str, Any]) -> dict[str, Any]:
    """One spool record (JSON-ready)."""
    return {"spool_version": SPOOL_VERSION, "run_key": run_key, "experiment": experiment, "run_name": run_name,
            "written_at": _now(), "params": params, "metrics": metrics, "tags": tags, "training_sql": training_sql,
            "model": {"b64": base64.b64encode(model_bytes).decode("ascii") if model_bytes is not None else None,
                      "host_path": model_host_path, "sha256": model_sha256},
            "extras": extras}


def spool_path(run_key: str, record_id: str | None = None) -> Path:
    """A fresh name per training attempt, so an offline rerun cannot overwrite a pending record."""
    return spool_dir() / f"{run_key}-{record_id or uuid.uuid4().hex}.json"


def write_spool(doc: dict[str, Any]) -> Path:
    """Write the record (0600 in a 0700 folder, whole-file replace) and return its path."""
    folder = spool_dir()
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = spool_path(doc["run_key"])
    tmp = path.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, default=str)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)
    return path


def read_spool(path: Path) -> dict[str, Any]:
    doc = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(doc, dict) or doc.get("spool_version") != SPOOL_VERSION or "run_key" not in doc:
        raise ValueError(f"{path} is not an exasol-mlflow spool record (spool_version {SPOOL_VERSION})")
    return doc


def pending() -> list[Path]:
    """The spool files waiting for a replay, oldest first."""
    folder = spool_dir()
    if not folder.is_dir():
        return []
    return sorted((p for p in folder.glob("*.json") if p.is_file()), key=lambda p: (p.stat().st_mtime, p.name))


def status() -> list[dict[str, Any]]:
    """``[{run_key, experiment, written_at, path}]`` for every pending record (a file that is not a record is listed with
    its error)."""
    rows = []
    for path in pending():
        try:
            doc = read_spool(path)
            rows.append({"run_key": doc["run_key"], "experiment": doc.get("experiment"), "written_at": doc.get("written_at"),
                         "path": str(path)})
        except (OSError, ValueError) as err:
            rows.append({"run_key": path.stem, "experiment": None, "written_at": None, "path": str(path), "error": str(err)})
    return rows


def model_bytes_of(doc: dict[str, Any]) -> bytes | None:
    """The model bytes a record carries: decoded from the inline base64, or read from the host file and checked against
    the recorded SHA-256 (ContractError on a mismatch or a missing file)."""
    model = doc.get("model") or {}
    if model.get("b64"):
        return base64.b64decode(model["b64"])
    if model.get("host_path"):
        path = Path(model["host_path"])
        try:
            blob = path.read_bytes()
        except OSError as err:
            raise ContractError(f"the model file {path} cannot be read ({err}); the UDF wrote it under /buckets") from err
        digest = hashlib.sha256(blob).hexdigest()
        if digest != model.get("sha256"):
            raise ContractError(f"model_sha256 does not match the file {path}: the UDF said {model.get('sha256')}, "
                                f"the file has {digest}")
        return blob
    return None


def use_tracking(mlflow, experiment: str, target: tracking.Tracking) -> None:
    """Point the mlflow module at the target and select the experiment (a local store gets its artifact folder beside
    the database)."""
    mlflow.set_tracking_uri(target.uri)
    if target.source == tracking.LOCAL_STORE and target.artifacts:
        Path(target.artifacts).parent.mkdir(parents=True, exist_ok=True)
        if mlflow.get_experiment_by_name(experiment) is None:
            mlflow.create_experiment(experiment, artifact_location=Path(target.artifacts).as_uri())
    mlflow.set_experiment(experiment)


def log_record(mlflow, doc: dict[str, Any], model_bytes: bytes | None, stack=None):
    """Log one record as one MLflow run - params, metrics, tags, ``training.sql``, ``model/model.pkl``,
    ``coefficients.json`` when the extras carry coefficients, ``extras.json`` - and return the run (mlflow's ActiveRun).
    With ``stack`` (an ExitStack) the run stays open on it; without, it is ended here."""
    started = mlflow.start_run(run_name=doc.get("run_name"))
    run = stack.enter_context(started) if stack is not None else started.__enter__()
    try:
        mlflow.log_params(doc["params"])
        if doc["metrics"]:
            mlflow.log_metrics(doc["metrics"])
        mlflow.set_tags(doc["tags"])
        mlflow.log_text(doc["training_sql"], "training.sql")
        if model_bytes is not None:
            with tempfile.TemporaryDirectory() as folder:
                model = Path(folder) / MODEL_FILE
                model.write_bytes(model_bytes)
                mlflow.log_artifact(str(model), artifact_path="model")
                versions_text = doc["tags"].get("exasol.package_versions", "{}")
                try:
                    versions = json.loads(versions_text)
                except (TypeError, ValueError):
                    versions = {}
                provenance = {
                    "sha256": hashlib.sha256(model_bytes).hexdigest(),
                    "run_id": run.info.run_id,
                    "workflow_id": doc["tags"].get("exasol.workflow_id"),
                    "python": versions.get("python"),
                    "scikit-learn": versions.get("scikit-learn"),
                }
                sidecar = Path(folder) / (MODEL_FILE + ".provenance.json")
                sidecar.write_text(json.dumps(provenance, sort_keys=True), encoding="utf-8")
                mlflow.log_artifact(str(sidecar), artifact_path="model")
        extras = doc.get("extras") or {}
        if isinstance(extras.get("coefficients"), dict):
            mlflow.log_dict(extras["coefficients"], COEFFICIENTS_FILE)
        if extras:
            mlflow.log_dict(extras, EXTRAS_FILE)
    except BaseException:
        if stack is None:
            started.__exit__(*sys.exc_info())
        raise
    if stack is None:
        started.__exit__(None, None, None)
    return run


def replay(tracking_uri: str | None = None, tracking_dir: str | os.PathLike | None = None, timeout: float = 3.0) -> list[str]:
    """Log every pending spool record and remove it; returns the new run ids. The server is checked first
    (TrackingUnavailable, nothing removed); a record that cannot be logged stays, and the error is raised after the ones
    before it were logged and removed."""
    import mlflow

    files = pending()
    if not files:
        return []
    target = tracking.Tracking(tracking_uri.strip(), tracking.ENV_URI) if tracking_uri else tracking.resolve(tracking_dir)
    tracking.check(target, timeout)
    done: list[str] = []
    for path in files:
        doc = read_spool(path)
        blob = model_bytes_of(doc)
        use_tracking(mlflow, doc["experiment"], target)
        run = log_record(mlflow, doc, blob)
        done.append(run.info.run_id)
        path.unlink()
    return done
