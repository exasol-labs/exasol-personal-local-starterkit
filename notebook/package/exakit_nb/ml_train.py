"""Prepare the ML Engineer's in-database training from an approved, fresh handoff (ML-3, design 7).

    handoff = nb.ml_train.training_handoff(conn, ds)               # explore's file (stale: refused), else built from the descriptor
    plan = nb.prepare_training(conn, ds, handoff, seed=0)          # refuses a stale handoff or an unasked-for random split
    conn.execute(plan.create_script); run.execute(plan.training_sql)
    path = nb.ml_train.export_coefficients(run, handoff)           # <id>-v<n>.coefficients.json beside the handoff

Determinism (AC-ML3.4): the plan is a pure function of the handoff and the options - the features keep the handoff's
order (the input schema, which the feature view fixes), a constant feature is dropped by a MIN/MAX query whose answer
depends on the data alone, and the rendered UDF trains ``LogisticRegression(random_state=seed, solver="lbfgs")`` over
rows it sorts first - so the same handoff, seed and data give the same metrics and the same coefficients.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse
from urllib.request import url2pathname

from ._kit import setting
from .dataset import Dataset
from .handoff import SPLITS, feature_view, handoff_from, handoff_is_stale, handoffs_dir, read_handoff, training_sql

__all__ = ["COEFFICIENTS_FILE", "TrainingPlan", "coefficients_of", "coefficients_path", "export_coefficients",
           "prepare_training", "training_handoff", "write_coefficients"]

COEFFICIENTS_FILE = "coefficients.json"                 # the MLflow artefact exasol_mlflow logs from the UDF's extras
COEFFICIENTS_SUFFIX = ".coefficients.json"              # <id>-v<n>.coefficients.json in the handoffs folder (02_rust_score reads it)
COEFFICIENT_KEYS = ("features", "coef", "intercept", "classes")


@dataclass(frozen=True)
class TrainingPlan:
    view: str
    features: tuple[str, ...]
    create_script: str
    training_sql: str
    params: dict[str, Any]
    handoff: dict[str, Any]


def _renderer():
    kit = setting("EXAKIT_NB_KIT")
    candidates = [Path(__file__).resolve().parents[3] / "udf/templates/render.py"] + (
        [Path(kit) / "udf/templates/render.py"] if kit else [])
    for path in candidates:
        if path.is_file():
            spec = importlib.util.spec_from_file_location("exakit_udf_renderer", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    raise RuntimeError("The kit's UDF template renderer was not found; update the notebook add-on: exakit update notebook")


def _nonconstant(conn, view: str, features: list[str]) -> list[str]:
    """Keep informative features, in handoff order. A constant is dropped before fitting."""
    if not features:
        raise ValueError("The handoff has no feature columns to train on.")
    if any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name) for name in features):
        raise ValueError("A feature name in the handoff is not a plain column name.")
    statement = "SELECT " + ", ".join(f'MIN("{name}"), MAX("{name}")' for name in features) + f" FROM {view}"
    print(statement)
    row = conn.execute(statement).fetchall()[0]
    kept = [name for index, name in enumerate(features) if row[2 * index] != row[2 * index + 1]]
    if not kept:
        raise ValueError(f"Every feature in {view} is constant; review the descriptor or choose another dataset.")
    return kept


def training_handoff(conn, ds: Dataset, *, name: str | None = None, split: str | None = None) -> dict[str, Any]:
    """The handoff 01_train starts from (requirements 2.2 step 4): the file explore wrote for ``ds`` (``name``: a path,
    ``<id>-v<n>``, default the descriptor's latest), refused when it is stale; when there is no file at all, one built
    now from the approved descriptor with handoff_from (said in one line; nothing is written - explore stays the
    writer). ``split`` passes through to the build ("random" when there is no date role)."""
    ds.require_approved("training")
    wanted = name if name is not None else ds.id
    try:
        record = read_handoff(wanted)
    except FileNotFoundError:
        if name is not None:
            raise
        record = handoff_from(conn, ds, split=split, written_by="01_train")
        print(f"no handoff file for {ds.id} in {handoffs_dir()}: built from the approved descriptor v{ds.version} "
              "(not from 01_explore; run data-scientist/01_explore to write one)")
        return record
    stale = handoff_is_stale(conn, record, ds)
    if stale:
        raise ValueError(stale)
    print(f"handoff: {_handoff_file(wanted)}")
    return record


def _handoff_file(name: str) -> Path:
    """The file read_handoff(name) just read: a path as given, ``<id>-v<n>``, or the id's highest version."""
    given = Path(name).expanduser()
    if given.is_file():
        return given
    if (match := re.fullmatch(r"(?P<id>[a-z0-9]+([-_][a-z0-9]+)*)-v(?P<version>[1-9][0-9]*)", name)):
        return handoffs_dir() / f"{match.group('id')}-v{match.group('version')}.json"
    versions = [(int(m.group(1)), p) for p in handoffs_dir().glob(f"{name}-v*.json")
                if (m := re.fullmatch(re.escape(name) + r"-v([1-9][0-9]*)\.json", p.name))]
    return max(versions)[1]


def _split_refusal(handoff: dict[str, Any], ds: Dataset) -> str | None:
    """None when the handoff's split may train; else why not (design 7): a random split only when the handoff says it
    was asked for (``split.explicit``), never one a missing date role fell back to."""
    split = handoff.get("split") if isinstance(handoff.get("split"), dict) else {}
    kind = split.get("kind")
    if kind not in SPLITS:
        return f"the handoff's split kind {kind!r} is not one of {', '.join(SPLITS)}: re-run 01_explore to write it again."
    if kind == "random" and split.get("explicit") is not True:
        return ("the handoff's split is random without having been asked for (split.explicit is not true), and a time "
                "split needs a date role: write the handoff with the random split named - nb.write_handoff(conn, ds, "
                f"split=\"random\") - or add a date role to the descriptor and approve it (exakit describe {ds.id}), "
                "then re-run 01_explore.")
    return None


def prepare_training(conn, ds: Dataset, handoff: dict[str, Any], *, schema: str = "EXASOL_MLFLOW",
                     name: str = "TRAIN_FROM_HANDOFF", seed: int = 0, C: float = 1.0,
                     max_iter: int = 1000, model_dir: str | None = None) -> TrainingPlan:
    """Refuse stale input, create the view, drop constant features and render the UDF and training SELECT.

    The caller creates ``create_script`` then passes ``training_sql`` to exasol_mlflow.start_run().
    ``model_dir`` is the UDF-visible /buckets directory; small models are returned inline.
    """
    ds.require_approved("training")
    stale = handoff_is_stale(conn, handoff, ds)
    if stale:
        raise ValueError(stale)
    refused = _split_refusal(handoff, ds)
    if refused:
        raise ValueError(refused)
    view = handoff["feature_view"]
    expected = feature_view(conn, ds)
    if view != expected or handoff.get("training_sql") != training_sql(expected["name"], ds, handoff["split"]):
        raise ValueError("The handoff's view or training SQL differs from the descriptor; re-run 01_explore to write it again.")
    conn.execute("CREATE SCHEMA IF NOT EXISTS STARTER_KIT")
    print(view["sql"])
    conn.execute(view["sql"])
    features = _nonconstant(conn, view["name"], [item["name"] for item in handoff["input_schema"]])
    render = _renderer()
    options = {"schema": schema, "name": name, "features": features,
               "label": handoff["label"]["column"], "positive": handoff["label"]["positive"],
               "seed": seed, "C": C, "max_iter": max_iter}
    if model_dir is not None:
        options["model_dir"] = model_dir
    create = render.render_train(**options)
    select = render.train_sql(schema=schema, name=name, training_sql=handoff["training_sql"],
                              run_key=f"{ds.id}-v{ds.version}", label=handoff["label"]["column"], features=features)
    return TrainingPlan(view["name"], tuple(features), create, select,
                        {"C": C, "seed": seed, "max_iter": max_iter, "train_share": handoff["split"]["train_share"],
                         "features": len(features)}, handoff)


# --- the coefficients beside the handoff (design 7: "and into the handoff dir") -------------------------------------

def coefficients_path(handoff: dict[str, Any]) -> Path:
    """``$EXAKIT_HOME/handoffs/<id>-v<n>.coefficients.json`` for the handoff's descriptor: where 02_rust_score reads
    the exported model without MLflow."""
    record = handoff.get("descriptor") if isinstance(handoff.get("descriptor"), dict) else {}
    descriptor_id, version = record.get("id"), record.get("version")
    if not isinstance(descriptor_id, str) or not re.fullmatch(r"[a-z0-9]+([-_][a-z0-9]+)*", descriptor_id) or not version:
        raise ValueError("The handoff names no descriptor id and version; read it again: nb.read_handoff(<id>)")
    return handoffs_dir() / f"{descriptor_id}-v{int(version)}{COEFFICIENTS_SUFFIX}"


def _check_coefficients(coefficients: Any) -> dict[str, Any]:
    if not isinstance(coefficients, dict) or any(key not in coefficients for key in COEFFICIENT_KEYS):
        raise ValueError(f"coefficients must be the object the training UDF exports ({', '.join(COEFFICIENT_KEYS)}).")
    features, coef = coefficients["features"], coefficients["coef"]
    if not isinstance(features, list) or not features or not isinstance(coef, list) or not coef \
            or any(not isinstance(row, list) or len(row) != len(features) for row in coef):
        raise ValueError("coefficients.coef must hold one row per class with one weight per feature, in feature order.")
    return coefficients


def coefficients_of(run) -> dict[str, Any]:
    """The ``coefficients.json`` a finished exasol_mlflow run logged, read back from its artefact store: straight from
    the file when the store is a folder on this computer (the local store, the kit's server), else through mlflow's
    artefact download. ``run`` is the Run (or TrainingRun) with ``artifact_uri``."""
    uri = str(getattr(run, "artifact_uri", "") or "")
    if not uri:
        raise ValueError("The run has no artifact_uri yet: run.execute(plan.training_sql) first.")
    parsed = urlparse(uri)
    if parsed.scheme in ("", "file"):
        folder = Path(url2pathname(unquote(parsed.path))) if parsed.scheme else Path(uri)
        path = folder / COEFFICIENTS_FILE
        if not path.is_file():
            raise FileNotFoundError(f"{path} is missing: the run logged no coefficients (the UDF's extras had none).")
        return _check_coefficients(json.loads(path.read_text(encoding="utf-8")))
    from mlflow.artifacts import download_artifacts                       # the client package, present with exasol_mlflow

    local = download_artifacts(artifact_uri=uri.rstrip("/") + "/" + COEFFICIENTS_FILE)
    return _check_coefficients(json.loads(Path(local).read_text(encoding="utf-8")))


def write_coefficients(handoff: dict[str, Any], coefficients: dict[str, Any]) -> Path:
    """Write ``coefficients`` - the very content of the MLflow artefact - to coefficients_path(handoff): the folder
    0700, the file 0600, replaced whole. Returns the path."""
    path = coefficients_path(handoff)
    text = json.dumps(_check_coefficients(coefficients), indent=2, ensure_ascii=False) + "\n"
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=f".{path.name}-", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise
    return path


def export_coefficients(run, handoff: dict[str, Any]) -> Path:
    """After a successful run: the run's coefficients.json copied beside the handoff (write_coefficients of
    coefficients_of), so the Rust scoring notebook needs no MLflow. Returns the path."""
    return write_coefficients(handoff, coefficients_of(run))
