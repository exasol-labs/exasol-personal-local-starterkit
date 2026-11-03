"""The run contract between a training UDF and the client: what one SET-UDF group emits, checked before anything is
logged (design §6; udf/templates/train_model.sql is the template that emits it).

One row per run key - or, for a model over 1 MB, one row per part of it - ten columns, every one a VARCHAR, and two
optional numbers::

    RUN_KEY VARCHAR(64)             the group's key: letters, digits, . _ - (it names the spool file)
    PARAMS VARCHAR(2000000)         JSON object: what the UDF trained with
    METRICS VARCHAR(2000000)        JSON object: finite numbers; "error": "<text>" is the one non-number allowed
    MODEL_B64 VARCHAR(2000000)      the model, base64 - or one part of it, up to 1 MB, when it is bigger
    MODEL_PATH VARCHAR(2000)        a /buckets/<bucket>/... file instead: what an earlier UDF wrote a big model to
    MODEL_SHA256 VARCHAR(64)        SHA-256 of the model bytes; NULL only when there is no model
    LANGUAGE VARCHAR(16)            python | rust | ...
    CONTAINER_DIGEST VARCHAR(80)    the script-language container's release hash (else its alias)
    VERSIONS VARCHAR(2000000)       JSON object: package or crate versions (python, scikit-learn, numpy, pandas ...)
    EXTRAS VARCHAR(2000000)         JSON object or NULL: coefficients {features, coef, intercept, classes}, anything else
    MODEL_PART, MODEL_PARTS         optional: this row's part of the model, and how many there are (1 and 1 when absent)

A MODEL OVER 1 MB COMES BACK IN PARTS, through the query itself: one row per part, in any order, every one with the
same run key, fields and MODEL_SHA256 - the digest of the WHOLE model - and its own piece in MODEL_B64. The parts are
put back together here and checked against that digest, so the UDF writes nothing anywhere: no bucket has to be
writable from it (on a local deployment it may well not be). MODEL_PATH is still read from an earlier UDF.

Exactly one of MODEL_B64 and MODEL_PATH is set - unless both are NULL together with MODEL_SHA256 and METRICS.error
names why (the UDF could not train or store the model); the helper then raises instead of logging a run without a
model. The client adds EXASOL_STATEMENT_ID (the statement that trained) when it runs the query. Anything else - a
missing column, a field of the wrong shape, two rows for one key - is a ContractError naming the row and the field
(``row 1: metrics is not JSON: ...``), and nothing is logged.
"""

from __future__ import annotations

import base64
import hashlib
import json
import math
import re
from dataclasses import dataclass, field
from typing import Any

COLUMNS = ("RUN_KEY", "PARAMS", "METRICS", "MODEL_B64", "MODEL_PATH", "MODEL_SHA256", "LANGUAGE", "CONTAINER_DIGEST",
           "VERSIONS", "EXTRAS")
PART_COLUMNS = ("MODEL_PART", "MODEL_PARTS")      # optional: a model over INLINE_LIMIT comes back in parts
STATEMENT_COLUMN = "EXASOL_STATEMENT_ID"
INLINE_LIMIT = 1048576                      # bytes: a model up to 1 MB travels inline (base64), a bigger one as a file
ERROR_KEY = "error"
_RUN_KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_LANGUAGE = re.compile(r"^[a-z][a-z0-9_+-]{0,15}$")
_BUCKET_PATH = re.compile(r"^/buckets/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$")


class ContractError(ValueError):
    """The training query's rows do not follow the contract; nothing was logged. The message names the row and the field."""


ResultContractError = ContractError         # the name the first release used


@dataclass(frozen=True)
class TrainingResult:
    """One checked contract row: the numbers to log, the model (inline bytes, or a /buckets path with its digest),
    where it was trained, and the statement that trained it."""

    run_key: str
    params: dict[str, Any]
    metrics: dict[str, float]
    error: str | None
    model_bytes: bytes | None
    model_path: str | None
    model_sha256: str | None
    language: str
    container_digest: str
    versions: dict[str, Any]
    extras: dict[str, Any] = field(default_factory=dict)
    statement_id: str = ""

    @property
    def has_model(self) -> bool:
        return self.model_bytes is not None or self.model_path is not None


def _text(value: Any, where: str, limit: int, *, required: bool = True) -> str | None:
    if value is None or (isinstance(value, str) and not value.strip()):
        if required:
            raise ContractError(f"{where} is NULL")
        return None
    if not isinstance(value, str):
        raise ContractError(f"{where} is not text but {type(value).__name__}")
    if len(value) > limit:
        raise ContractError(f"{where} is {len(value)} characters, over VARCHAR({limit})")
    return value


def _json_object(value: Any, where: str, *, required: bool = True) -> dict[str, Any] | None:
    text = _text(value, where, 2000000, required=required)
    if text is None:
        return None
    try:
        doc = json.loads(text)
    except ValueError as err:
        raise ContractError(f"{where} is not JSON: {str(err)[:200]}") from err
    if not isinstance(doc, dict):
        raise ContractError(f"{where} is JSON but not an object ({type(doc).__name__})")
    return doc


def _metrics(value: Any, where: str) -> tuple[dict[str, float], str | None]:
    doc = _json_object(value, where)
    assert doc is not None
    error = doc.pop(ERROR_KEY, None)
    if error is not None and not isinstance(error, str):
        raise ContractError(f"{where}.{ERROR_KEY} must be text, not {type(error).__name__}")
    bad = sorted(k for k, v in doc.items() if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v))
    if bad:
        raise ContractError(f"{where} must hold finite numbers; not: {', '.join(bad)}")
    return {str(k): float(v) for k, v in doc.items()}, (error.strip() or None) if error else None


def parse_row(values: dict[str, Any], row: int, assembled: bytes | None = None) -> TrainingResult:
    """One contract row (column name -> value, upper-case names) checked field by field. ``assembled`` is the model
    put back together from its parts (parse() does that), which this row then carries instead of its own piece."""
    where = f"row {row}"
    run_key = _text(values.get("RUN_KEY"), f"{where}: run_key", 64)
    assert run_key is not None
    if not _RUN_KEY.match(run_key):
        raise ContractError(f"{where}: run_key {run_key!r} is not letters, digits, . _ - (up to 64 characters)")
    params = _json_object(values.get("PARAMS"), f"{where}: params")
    metrics, error = _metrics(values.get("METRICS"), f"{where}: metrics")
    b64 = _text(values.get("MODEL_B64"), f"{where}: model_b64", 2000000, required=False)
    path = _text(values.get("MODEL_PATH"), f"{where}: model_path", 2000, required=False)
    sha = _text(values.get("MODEL_SHA256"), f"{where}: model_sha256", 64, required=False)
    language = _text(values.get("LANGUAGE"), f"{where}: language", 16)
    assert language is not None
    if not _LANGUAGE.match(language):
        raise ContractError(f"{where}: language {language!r} is not a lower-case name such as python or rust")
    digest = _text(values.get("CONTAINER_DIGEST"), f"{where}: container_digest", 80)
    versions = _json_object(values.get("VERSIONS"), f"{where}: versions")
    extras = _json_object(values.get("EXTRAS"), f"{where}: extras", required=False) or {}
    model_bytes = None
    if b64 is not None and path is not None:
        raise ContractError(f"{where}: model_b64 and model_path are both set; exactly one carries the model")
    if b64 is None and path is None and assembled is None:
        if sha is not None:
            raise ContractError(f"{where}: model_sha256 is set but model_b64 and model_path are both NULL")
        if error is None:
            raise ContractError(f"{where}: model_b64 and model_path are both NULL and metrics.{ERROR_KEY} does not say why")
    else:
        if sha is None:
            raise ContractError(f"{where}: model_sha256 is NULL but there is a model")
        if not _SHA256.match(sha):
            raise ContractError(f"{where}: model_sha256 {sha[:70]!r} is not 64 hex characters")
        if assembled is not None:
            if path is not None:
                raise ContractError(f"{where}: a model in parts has no model_path")
            if hashlib.sha256(assembled).hexdigest() != sha:
                raise ContractError(f"{where}: model_sha256 does not match the model its parts put together")
            model_bytes = assembled
        elif b64 is not None:
            try:
                model_bytes = base64.b64decode(b64, validate=True)
            except (ValueError, TypeError) as err:
                raise ContractError(f"{where}: model_b64 is not base64") from err
            if len(model_bytes) > INLINE_LIMIT:
                raise ContractError(f"{where}: model_b64 decodes to {len(model_bytes)} bytes, over the {INLINE_LIMIT} inline limit"
                                    " (a bigger model goes to model_path)")
            if hashlib.sha256(model_bytes).hexdigest() != sha:
                raise ContractError(f"{where}: model_sha256 does not match the bytes in model_b64")
        elif not _BUCKET_PATH.match(path or "") or "/../" in (path or "") + "/":
            raise ContractError(f"{where}: model_path {path!r} is not a /buckets/<bucket>/... path")
    assert params is not None and digest is not None and versions is not None
    return TrainingResult(run_key, params, metrics, error, model_bytes, path, sha, language, digest, versions, extras)


def _part(value: Any, where: str) -> int:
    if value is None or (isinstance(value, str) and not value.strip()):
        return 1
    try:
        number = int(str(value).strip())
    except ValueError as err:
        raise ContractError(f"{where} is not a whole number: {str(value)[:40]!r}") from err
    if number < 1:
        raise ContractError(f"{where} must be 1 or more, not {number}")
    return number


def _assemble(run_key: str, parts: list[tuple[int, int, int, dict[str, Any]]]) -> bytes:
    """The model of one run key from its part rows ((part, parts, row number, values)): every part from 1 to the count,
    once, each at most INLINE_LIMIT bytes and base64, the other fields the same on every row; the bytes in part order."""
    count = parts[0][1]
    if any(total != count for _, total, _, _ in parts):
        raise ContractError(f"run_key {run_key!r}: its rows disagree on model_parts")
    numbers = sorted(part for part, _, _, _ in parts)
    if numbers != list(range(1, count + 1)):
        missing = sorted(set(range(1, count + 1)) - set(numbers))
        raise ContractError(f"run_key {run_key!r}: the model has {count} parts but "
                            + (f"part {', '.join(map(str, missing))} is missing" if missing else "a part appears twice"))
    same = [c for c in COLUMNS if c != "MODEL_B64"]
    first = parts[0][3]
    for _, _, number, values in parts[1:]:
        differ = [c.lower() for c in same if values.get(c) != first.get(c)]
        if differ:
            raise ContractError(f"row {number}: run_key {run_key!r}: a part's {', '.join(differ)} differs from the first part's")
    chunks = []
    for part, _, number, values in sorted(parts, key=lambda item: item[0]):
        b64 = _text(values.get("MODEL_B64"), f"row {number}: model_b64 (part {part})", 2000000)
        try:
            chunk = base64.b64decode(b64 or "", validate=True)
        except (ValueError, TypeError) as err:
            raise ContractError(f"row {number}: model_b64 (part {part}) is not base64") from err
        if len(chunk) > INLINE_LIMIT:
            raise ContractError(f"row {number}: part {part} decodes to {len(chunk)} bytes, over the {INLINE_LIMIT} part limit")
        chunks.append(chunk)
    return b"".join(chunks)


def parse(columns: list[str], rows: list[tuple]) -> list[TrainingResult]:
    """The rows of a training query, checked against the contract: one TrainingResult per run key, in the order they
    came - a model in parts put back together and checked against its digest. ContractError names the row and the
    field that is wrong; a missing column names the column."""
    names = [str(c).upper() for c in columns]
    missing = [c for c in (*COLUMNS, STATEMENT_COLUMN) if c not in names]
    if missing:
        raise ContractError(f"the training query returned no {', '.join(missing)} column"
                            + (" (run it through exasol_mlflow, which adds EXASOL_STATEMENT_ID)" if STATEMENT_COLUMN in missing else ""))
    if not rows:
        raise ContractError("the training query returned no rows (did the UDF see any data?)")
    at = {c: names.index(c) for c in (*COLUMNS, STATEMENT_COLUMN, *PART_COLUMNS) if c in names}
    groups: dict[str, list[tuple[int, int, int, dict[str, Any]]]] = {}
    statements: dict[str, Any] = {}
    for number, row in enumerate(rows, start=1):
        if len(row) != len(names):
            raise ContractError(f"row {number} has {len(row)} values for {len(names)} columns")
        values = {c: row[at[c]] for c in COLUMNS}
        part = _part(row[at["MODEL_PART"]] if "MODEL_PART" in at else None, f"row {number}: model_part")
        count = _part(row[at["MODEL_PARTS"]] if "MODEL_PARTS" in at else None, f"row {number}: model_parts")
        if part > count:
            raise ContractError(f"row {number}: model_part {part} is over model_parts {count}")
        key = values.get("RUN_KEY")
        key = key if isinstance(key, str) else str(key)
        if key in groups and (count == 1 or groups[key][0][1] == 1):
            raise ContractError(f"row {number}: run_key {key!r} appears twice; one row per run key")
        groups.setdefault(key, []).append((part, count, number, values))
        statements.setdefault(key, row[at[STATEMENT_COLUMN]])
    results: list[TrainingResult] = []
    for key, parts in groups.items():
        _, count, number, values = parts[0]
        if count == 1:
            result = parse_row(values, number)
        else:
            result = parse_row({**values, "MODEL_B64": None}, number, assembled=_assemble(key, parts))
        statement = statements[key]
        results.append(TrainingResult(**{**result.__dict__, "statement_id": "" if statement is None else str(statement)}))
    if len({r.statement_id for r in results}) != 1:
        raise ContractError("the rows come from more than one statement")
    return results
