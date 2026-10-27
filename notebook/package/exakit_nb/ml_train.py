"""Prepare the ML Engineer's in-database training from an approved, fresh handoff."""

from __future__ import annotations

import importlib.util
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ._kit import setting
from .dataset import Dataset
from .handoff import feature_view, handoff_is_stale, training_sql

__all__ = ["TrainingPlan", "prepare_training"]


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
