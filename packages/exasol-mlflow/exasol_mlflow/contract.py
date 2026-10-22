"""The result contract between a training UDF and the client: what the UDF emits, checked before anything is logged.

A training UDF emits one row per model chunk: ``PART`` (0, 1, ...), ``CHUNK`` (base64 of the serialised model, in
order) and, on part 0 only, ``TRAINING_RESULT`` - a JSON document::

    {"contract": 1,
     "metrics": {"roc_auc": 0.81, ...},             # numbers
     "params":  {"max_features": 5000, ...},        # what the UDF trained with
     "model":   {"format": "sklearn-pickle", "sha256": "...", "bytes": 12345, "parts": 1,
                 "python": "3.12.3", "sklearn": "1.7.2"}}

The model always travels inline: chunking lifts the size limit of one VARCHAR, and the other route - a file under the
host folder a local deployment maps for BucketFS, read by the client - is closed, because a UDF sees BucketFS read-only
and a local deployment serves no BucketFS endpoint to upload to.

The client adds ``EXASOL_STATEMENT_ID`` (the statement that trained) when it runs the query. Anything else - a missing
column, two TRAINING_RESULT rows, a gap in the parts, a digest that does not match - is a ResultContractError naming it, and
nothing is logged.
"""

from __future__ import annotations

import base64
import hashlib
import json
import math
from dataclasses import dataclass
from typing import Any

CONTRACT = 1
COLUMNS = ("EXASOL_STATEMENT_ID", "PART", "CHUNK", "TRAINING_RESULT")


class ResultContractError(ValueError):
    """The training query's rows do not follow the contract; nothing was logged."""


@dataclass(frozen=True)
class TrainingResult:
    """A checked training result: the numbers to log, the model's bytes, and the statement that trained it."""

    metrics: dict[str, float]
    params: dict[str, Any]
    model: dict[str, Any]
    model_bytes: bytes
    statement_id: str


def _result_doc(text: Any) -> dict[str, Any]:
    try:
        doc = json.loads(text)
    except (TypeError, ValueError) as err:
        raise ResultContractError("TRAINING_RESULT on part 0 is not JSON") from err
    if not isinstance(doc, dict) or doc.get("contract") != CONTRACT:
        raise ResultContractError(f"TRAINING_RESULT must be a JSON object with contract {CONTRACT}")
    for key in ("metrics", "params", "model"):
        if not isinstance(doc.get(key), dict):
            raise ResultContractError(f"TRAINING_RESULT has no '{key}' object")
    bad = [k for k, v in doc["metrics"].items() if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v)]
    if bad:
        raise ResultContractError(f"metrics must be finite numbers: {', '.join(sorted(bad))}")
    for key in ("format", "sha256", "parts"):
        if key not in doc["model"]:
            raise ResultContractError(f"TRAINING_RESULT.model has no '{key}'")
    return doc


def check(columns: list[str], rows: list[tuple]) -> TrainingResult:
    """The rows of a training query, checked against the contract; ResultContractError says what is wrong."""
    names = [str(c).upper() for c in columns]
    missing = [c for c in COLUMNS if c not in names]
    if missing:
        raise ResultContractError(f"the training query returned no {', '.join(missing)} column")
    at = {c: names.index(c) for c in COLUMNS}
    if not rows:
        raise ResultContractError("the training query returned no rows (did the UDF see any data?)")
    results = [r[at["TRAINING_RESULT"]] for r in rows if r[at["TRAINING_RESULT"]] not in (None, "")]
    if len(results) != 1:
        raise ResultContractError(f"exactly one row must carry TRAINING_RESULT, found {len(results)} (one UDF instance must train)")
    doc = _result_doc(results[0])
    parts = sorted((int(r[at["PART"]]), r[at["CHUNK"]] or "") for r in rows)
    if [p for p, _ in parts] != list(range(int(doc["model"]["parts"]))):
        raise ResultContractError(f"model parts must be 0..{int(doc['model']['parts']) - 1}, found {[p for p, _ in parts]}")
    try:
        blob = base64.b64decode("".join(chunk for _, chunk in parts), validate=True)
    except ValueError as err:
        raise ResultContractError("CHUNK is not base64") from err
    if hashlib.sha256(blob).hexdigest() != doc["model"]["sha256"]:
        raise ResultContractError("the model's bytes do not match TRAINING_RESULT.model.sha256")
    statements = {str(r[at["EXASOL_STATEMENT_ID"]]) for r in rows}
    if len(statements) != 1:
        raise ResultContractError("the rows come from more than one statement")
    return TrainingResult({k: float(v) for k, v in doc["metrics"].items()}, doc["params"], doc["model"], blob, statements.pop())
