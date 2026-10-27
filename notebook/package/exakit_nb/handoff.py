"""The handoff from the Data Scientist to the ML Engineer (DS-3 -> ML-3, design 4): one JSON file that holds everything
``01_train`` needs to train without opening the descriptor - which descriptor version and digest it came from, a digest
of the data, the feature view built from the roles (as ``CREATE OR REPLACE VIEW`` SQL), the label and its positive
class, the training SELECT with a reproducible time split, and the input and output schemas. A descriptor without a date
role has no time split: the handoff is refused with the fix (``split="random"`` for a reproducible hash split, or a
date role) - a random split is never silent, and ``01_train`` refuses one the file does not mark as asked for.

    path = nb.write_handoff(conn, ds)          # explore's last cell: ~/.exasol-starter-kit/handoffs/<id>-v<n>.json
    handoff = nb.read_handoff("pharma_trials")  # the latest one for that descriptor (or a path, or "<id>-v2")
    handoff = nb.handoff_from(conn, ds)         # the same record, built from an approved descriptor, not written
    nb.handoff_is_stale(conn, handoff, ds)      # None, or the line that says what changed and what to do

The feature view is SQL only - category one-hot over the top-20 values plus OTHER, date -> year / month / ISO day of
week / days since the first date, text -> LENGTH, entity -> frequency - so a model that is linear over these columns can
be scored by Rust on the very same view (ML-5): TF-IDF stays out of it (the client-side model in explore keeps it);
top-k token flags computed in SQL are the deferred next step and are recorded as such in the file. The view is not
created here: the ML quickstart and 01_train create it, with the admin profile.

The file names a table, columns, SQL and digests, never a host, a user or a password; the kit's secret-grep test
covers the folder. A workflow that is active gets one ``handoff`` line in its log (X-1).
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .dataset import Dataset
from .descriptor_store import kit_home
from .workflow import HANDOFF, current_workflow, log_event

__all__ = ["FOLDER", "OUTPUT_SCHEMA", "TOP_CATEGORIES", "VIEW_SCHEMA", "WRITTEN_BY", "feature_view", "handoff_from",
           "handoff_is_stale", "handoff_path", "handoffs_dir", "no_time_split", "read_handoff", "training_sql",
           "write_handoff"]

FOLDER = "handoffs"
WRITTEN_BY = "01_explore"
VIEW_SCHEMA = "STARTER_KIT"
TOP_CATEGORIES = 20                       # one-hot columns per category role; every other value is OTHER
SPLIT_COLUMN = "SPLIT_"                   # 'train' | 'test' in the training SELECT
SPLITS = ("time", "random")
INTEGER = "DECIMAL(18,0)"                 # every feature the view computes is a whole number
OUTPUT_SCHEMA = ({"name": "label", "type": "BOOLEAN"}, {"name": "p", "type": "DOUBLE"})
DEFERRED = ("top-k token flags computed in SQL (the text features are LENGTH only; TF-IDF never enters the view)",)
_FILE = re.compile(r"^(?P<id>[a-z0-9]+([-_][a-z0-9]+)*)-v(?P<version>[1-9][0-9]*)\.json$")
_ID = re.compile(r"^[a-z0-9]+([-_][a-z0-9]+)*$")
_HANDOFF_NAME = re.compile(r"^(?P<id>[a-z0-9]+([-_][a-z0-9]+)*)-v(?P<version>[1-9][0-9]*)$")


# --- where the files live ---------------------------------------------------------------------------------------------

def handoffs_dir() -> Path:
    """``$EXAKIT_HOME/handoffs`` (EXAKIT_HOME default ~/.exasol-starter-kit), whether or not it exists yet."""
    return kit_home() / FOLDER


def handoff_path(descriptor_id: str, version: int) -> Path:
    """Where the handoff for one descriptor version lives: ``<id>-v<n>.json`` in handoffs_dir()."""
    if not isinstance(descriptor_id, str) or not _ID.match(descriptor_id):
        raise ValueError(f"'{descriptor_id}' is not a dataset id (lower-case letters and digits, joined by - or _).")
    return handoffs_dir() / f"{descriptor_id}-v{int(version)}.json"


# --- SQL building blocks ---------------------------------------------------------------------------------------------

def _q(name: str) -> str:
    """An identifier, always double-quoted (a name with a space, a reserved word, lower case: all safe)."""
    return '"' + str(name).replace('"', '""') + '"'


def _qualified(table: str) -> str:
    """``SCHEMA.TABLE`` -> ``"SCHEMA"."TABLE"``."""
    return ".".join(_q(part) for part in table.split(".", 1))


def _literal(value: Any) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def _slug(text: str, limit: int = 40) -> str:
    """A value or a name as part of a column name: upper case, runs of anything but letters and digits as one ``_``."""
    slug = re.sub(r"[^A-Z0-9]+", "_", str(text).upper()).strip("_")
    return (slug or "BLANK")[:limit].rstrip("_") or "BLANK"


def _view_name(ds: Dataset) -> str:
    """``STARTER_KIT.<ID>_FEATURES_V<n>``, the id upper-cased with ``-`` as ``_``."""
    return f"{VIEW_SCHEMA}.{_slug(ds.id, 80)}_FEATURES_V{ds.version}"


def _category_values_sql(ds: Dataset) -> str:
    column = _q(ds.col("category"))
    return (f"SELECT CAST({column} AS VARCHAR(2000)) AS VALUE_, COUNT(*) AS N FROM {_qualified(ds.fact_table)} "
            f"WHERE {column} IS NOT NULL GROUP BY 1 ORDER BY N DESC, 1 LIMIT {TOP_CATEGORIES}")


def _category_values(conn, ds: Dataset) -> list[str]:
    """The top-20 values of the category role by row count (ties by value), as strings: what the one-hot columns are."""
    return [str(row[0]) for row in conn.execute(_category_values_sql(ds)).fetchall()]


def _summary_sql(ds: Dataset) -> str:
    """COUNT(*) and, with a date role, MIN and MAX of the date: the cheap data digest and the first date of the span."""
    if ds.has("date"):
        date = _q(ds.col("date"))
        return f"SELECT COUNT(*), MIN({date}), MAX({date}) FROM {_qualified(ds.fact_table)}"
    return f"SELECT COUNT(*), NULL, NULL FROM {_qualified(ds.fact_table)}"


def _summary(conn, ds: Dataset) -> tuple[int, str | None, str | None]:
    row = conn.execute(_summary_sql(ds)).fetchall()[0]
    return int(row[0] or 0), (str(row[1]) if row[1] is not None else None), (str(row[2]) if row[2] is not None else None)


def _features(ds: Dataset, categories: list[str], date_min: str | None) -> list[dict[str, str]]:
    """Every feature column the view computes: ``{name, sql, type, role}`` in a fixed order - date, category, entity,
    text - so the view, the input schema and a model's coefficient vector line up."""
    features: list[dict[str, str]] = []

    def add(name: str, sql: str, role: str) -> None:
        features.append({"name": name, "sql": sql, "type": INTEGER, "role": role})

    if ds.has("date"):
        date = _q(ds.col("date"))
        add("DATE_YEAR", f"EXTRACT(YEAR FROM {date})", "date")
        add("DATE_MONTH", f"EXTRACT(MONTH FROM {date})", "date")
        add("DATE_DOW", f"TO_NUMBER(TO_CHAR({date}, 'ID'))", "date")                    # ISO: Monday 1 .. Sunday 7
        if date_min is not None:
            add("DATE_DAYS_SINCE_MIN", f"DAYS_BETWEEN({date}, DATE {_literal(date_min)})", "date")
    if ds.has("category"):
        category = f"CAST({_q(ds.col('category'))} AS VARCHAR(2000))"
        taken: set[str] = set()
        for value in categories:
            name, n = f"CAT_{_slug(value)}", 2
            while name in taken:
                name, n = f"CAT_{_slug(value)}_{n}", n + 1
            taken.add(name)
            add(name, f"CASE WHEN {category} = {_literal(value)} THEN 1 ELSE 0 END", "category")
        known = ", ".join(_literal(value) for value in categories) or "''"
        add("CAT_OTHER", f"CASE WHEN {category} IS NULL OR {category} NOT IN ({known}) THEN 1 ELSE 0 END", "category")
    if ds.has("entity"):
        add("ENTITY_FREQ", f"COUNT(*) OVER (PARTITION BY {_q(ds.col('entity'))})", "entity")
    for column in ds.text_cols():
        add(f"TEXT_LEN_{_slug(column, 60)}", f"LENGTH(COALESCE({_q(column)}, ''))", "text")
    return features


def feature_view(conn, ds: Dataset) -> dict[str, Any]:
    """The feature view from the roles: its name, the ``CREATE OR REPLACE VIEW`` SQL (not run here), the features it
    computes, the category values the one-hot columns stand for (from a top-20 query run now) and the first date.

    The view keeps the date and the label columns under their own names (the split orders by the date, the label is
    what is learnt) and adds one column per feature; everything else of the table stays out of it."""
    categories = _category_values(conn, ds) if ds.has("category") else []
    _rows, date_min, _date_max = _summary(conn, ds)
    features = _features(ds, categories, date_min)
    name = _view_name(ds)
    kept = [ds.col(role) for role in ("date", "label") if ds.has(role)]
    lines = [f"CREATE OR REPLACE VIEW {_qualified(name)} AS", "SELECT"]
    columns = [f"    {_q(column)}" for column in kept] + [f"    {f['sql']} AS {_q(f['name'])}" for f in features]
    lines.append(",\n".join(columns))
    lines.append(f"FROM {_qualified(ds.fact_table)}")
    return {"name": name, "sql": "\n".join(lines), "features": features,
            "categories": [{"value": value, "column": f["name"]} for value, f in zip(categories, [f for f in features if f["role"] == "category"])],
            "category_values_sql": _category_values_sql(ds) if ds.has("category") else None,
            "date_min": date_min, "deferred": list(DEFERRED)}


def no_time_split(ds: Dataset) -> str:
    """The line a handoff without a date role is refused with: the reason and the two fixes (design 2.4 / 7)."""
    reason = ds.descriptor.missing_reason("date") or "the descriptor has no date role"
    return (f"{ds.id} has no date role ({reason}), so there is no time split for the handoff: ask for a reproducible "
            f"hash split instead, nb.write_handoff(conn, ds, split=\"random\"), or add a date role to the descriptor and "
            f"approve it (exakit describe {ds.id}).")


def _split(ds: Dataset, split: str | None, train_share: float) -> dict[str, Any]:
    """``{kind, explicit, date_column, train_share, order_by, note[, reason]}``: a time split over the date role
    (``split`` None or "time"), or a random one by a hash of the row's role columns when the caller asked for it
    (``split="random"``; reproducible: the same rows give the same split). ``explicit`` records whether the caller
    named the kind. Without a date role a time split is refused with no_time_split(): the fallback is never silent, and
    ``reason`` keeps why there was no time split when a random one was asked for instead."""
    explicit = split is not None
    kind = "time" if split is None else split
    if kind not in SPLITS:
        raise ValueError(f"split must be one of {', '.join(SPLITS)}, not {split!r}")
    if not 0 < float(train_share) < 1:
        raise ValueError(f"train_share must be between 0 and 1, not {train_share!r}")
    record: dict[str, Any] = {"kind": kind, "explicit": explicit, "date_column": None, "train_share": float(train_share)}
    if not ds.has("date"):
        if kind == "time":
            raise ValueError(no_time_split(ds))
        reason = ds.descriptor.missing_reason("date") or "the descriptor has no date role"
        record["reason"] = f"no time split: {reason}; split=\"random\" was asked for, so the split is a hash of the row's role columns"
    if record["kind"] == "time":
        record["date_column"] = ds.col("date")
        record["order_by"] = _q(ds.col("date"))
        record["note"] = ("PERCENT_RANK over the date: every row of one date lands on the same side, so the boundary is a "
                          "date and the split is the same on every run")
    else:
        parts = " || '|' || ".join(f"COALESCE(CAST({_q(ref.column)} AS VARCHAR(2000)), '')" for _r, ref in ds.descriptor.references())
        record["order_by"] = f"HASH_MD5({parts})"
        record.setdefault("note", "PERCENT_RANK over a hash of the row's role columns: the same rows give the same split")
    return record


def training_sql(view_name: str, ds: Dataset, split: dict[str, Any]) -> str:
    """The training SELECT: every column of the view for the rows that have a label, ``SPLIT_`` 'train' for the
    earliest ``train_share`` by the split's order (a window, so train and test are the same on every run), ordered the
    same way."""
    label = _q(ds.col("label"))
    order = split["order_by"]
    return (f"SELECT F.*,\n       CASE WHEN PERCENT_RANK() OVER (ORDER BY {order}) < {split['train_share']} "
            f"THEN 'train' ELSE 'test' END AS {_q(SPLIT_COLUMN)}\n"
            f"FROM {_qualified(view_name)} F\nWHERE {label} IS NOT NULL\nORDER BY {order}")


# --- digests and the label --------------------------------------------------------------------------------------------

def _descriptor_digest(ds: Dataset) -> tuple[str, str]:
    """(digest, kind): the table digest the descriptor was approved on (``table``) when it has one, else the
    descriptor file's own SHA-256 (``file``) - a schema_version 1 or shipped descriptor carries no table digest."""
    if ds.table_digest:
        return str(ds.table_digest), "table"
    return f"sha256:{ds.digest}", "file"


def _current_table_digest(conn, ds: Dataset) -> str | None:
    """The table's digest as it is now, the way approve computes it (``Dataset.current_table_digest``, design 2.3),
    or None when this package has no such method yet, the kit's describe service is not beside this Python, or the
    connection cannot answer it - then the approval-time digest stands."""
    compute = getattr(ds, "current_table_digest", None)
    if compute is None or conn is None:
        return None
    try:
        return str(compute(conn))
    except Exception:          # noqa: BLE001 - the digest is best effort here; the cheap digest and the version remain
        return None


def _data_digest(conn, ds: Dataset, summary: tuple[int, str | None, str | None] | None = None) -> tuple[str, str]:
    """(digest, kind): when the descriptor carries a table digest, the table's digest as it is now (``table``; the
    approval-time one when it cannot be recomputed), else a cheap one over the fact table's name, its row count and
    the span of its date role (``rowcount+date_span``; ``rowcount`` without a date) - one COUNT, no column hashing,
    so writing the handoff costs one statement. The train side recomputes the same."""
    if ds.table_digest:
        return _current_table_digest(conn, ds) or str(ds.table_digest), "table"
    rows, date_min, date_max = summary if summary is not None else _summary(conn, ds)
    text = f"{ds.fact_table}|rows={rows}|min={date_min}|max={date_max}"
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest(), ("rowcount+date_span" if ds.has("date") else "rowcount")


def _label_positive(conn, ds: Dataset, given: str | None) -> tuple[str, str]:
    """(positive value, where it came from): the value given; else the minority class the profiler's evidence recorded
    (``top`` shares); else the minority class one GROUP BY on the label finds; else "true"."""
    if given is not None:
        return str(given), "given"
    top = (ds.evidence.get("label") or {}).get("top") if isinstance(ds.evidence, dict) else None
    if isinstance(top, list) and top:
        try:
            least = min(top, key=lambda item: float(item["share"]))
            return str(least["value"]), "evidence"
        except (KeyError, TypeError, ValueError):
            pass
    try:
        label = _q(ds.col("label"))
        rows = conn.execute(f"SELECT CAST({label} AS VARCHAR(100)), COUNT(*) FROM {_qualified(ds.fact_table)} "
                            f"WHERE {label} IS NOT NULL GROUP BY 1 ORDER BY 2, 1").fetchall()
    except Exception:          # noqa: BLE001 - no connection that answers: the default stands
        rows = []
    if rows:
        return str(rows[0][0]).strip(), "query"
    return "true", "default"


# --- the record -------------------------------------------------------------------------------------------------------

def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def handoff_from(conn, ds: Dataset, label: str | None = None, split: str | None = None, train_share: float = 0.8,
                 workflow_id: str | None = None, written_by: str = WRITTEN_BY) -> dict[str, Any]:
    """The handoff record for ``ds`` as design 4 shapes it, built now and returned, nothing written: the descriptor's
    id, version, digest (``digest_kind`` says whether it is the table digest or the file's) and source; the data
    digest (``data_digest_kind``); the feature view; the label and its positive class (``label`` overrides it);
    the split (``time`` over the date role by default; ``split="random"`` for a hash split, the only way to get one -
    without a date role and without that, a ValueError names the fix; ``split.explicit`` records the choice) and
    ``train_share``; the training SQL; input and output schemas. ``workflow_id`` defaults to the active workflow's."""
    if not ds.has("label"):
        raise ValueError(f"The handoff needs a label role: {ds.descriptor.missing_reason('label') or 'the descriptor has none'}.")
    view = feature_view(conn, ds)
    digest, digest_kind = _descriptor_digest(ds)
    rows, date_min, date_max = _summary(conn, ds)
    data_digest, data_kind = _data_digest(conn, ds, (rows, date_min, date_max))
    positive, positive_from = _label_positive(conn, ds, label)
    split_record = _split(ds, split, train_share)
    return {
        "schema_version": 1,
        "workflow_id": workflow_id if workflow_id is not None else current_workflow(),
        "descriptor": {"id": ds.id, "version": ds.version, "digest": digest, "digest_kind": digest_kind,
                       "source": ds.source_ref, "status": ds.status, "fact_table": ds.fact_table},
        "data_digest": data_digest, "data_digest_kind": data_kind, "rows": rows,
        "written_at": _now(), "written_by": written_by,
        "feature_view": view,
        "label": {"column": ds.col("label"), "positive": positive, "positive_from": positive_from},
        "split": split_record,
        "training_sql": training_sql(view["name"], ds, split_record),
        "input_schema": [{"name": f["name"], "type": f["type"]} for f in view["features"]],
        "output_schema": [dict(item) for item in OUTPUT_SCHEMA],
    }


def write_handoff(conn, ds: Dataset, label: str | None = None, split: str | None = None, train_share: float = 0.8,
                  workflow_id: str | None = None, written_by: str = WRITTEN_BY) -> Path:
    """Build the handoff (handoff_from) and write it to ``$EXAKIT_HOME/handoffs/<id>-v<n>.json`` - the folder 0700,
    the file 0600, replaced whole (a temporary file renamed over it) so a reader never sees half of one. The active
    workflow's log gets a ``handoff`` line with the path and the descriptor's id and version. Returns the path."""
    record = handoff_from(conn, ds, label=label, split=split, train_share=train_share, workflow_id=workflow_id,
                          written_by=written_by)
    path = handoff_path(ds.id, ds.version)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    text = json.dumps(record, indent=2, ensure_ascii=False) + "\n"
    fd, temp = tempfile.mkstemp(prefix=f".{path.stem}-", suffix=".json", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise
    log_event(HANDOFF, path=str(path), descriptor_id=ds.id, descriptor_version=ds.version,
              feature_view=record["feature_view"]["name"], data_digest=record["data_digest"])
    return path


def read_handoff(id_or_path: str | Path) -> dict[str, Any]:
    """The handoff as a dict: from a path to the file, from ``<id>-v<n>`` (that version's file), or from a descriptor
    id (the file with the highest version in the handoffs folder). None there is a FileNotFoundError saying how to
    make one."""
    name = str(id_or_path)
    given = Path(name).expanduser()
    if given.is_file():
        path = given
    elif (match := _HANDOFF_NAME.match(name)):
        path = handoff_path(match.group("id"), int(match.group("version")))
    elif _ID.match(name):
        found = [(int(m.group("version")), p) for p in handoffs_dir().glob(f"{name}-v*.json")
                 if (m := _FILE.match(p.name)) and m.group("id") == name]
        if not found:
            raise FileNotFoundError(f"No handoff for descriptor {name} in {handoffs_dir()}: run 01_explore on it, or "
                                    "build one: handoff = exakit.nb.handoff_from(conn, ds)")
        path = max(found)[1]
    else:
        raise FileNotFoundError(f"No handoff at {name}: give a descriptor id, <id>-v<n>, or the path of a handoff file.")
    if not path.is_file():
        raise FileNotFoundError(f"No handoff at {path}: run 01_explore on the descriptor, or build one: "
                                "handoff = exakit.nb.handoff_from(conn, ds)")
    record = json.loads(path.read_text(encoding="utf-8"))
    for key in ("descriptor", "feature_view", "label", "split", "training_sql", "input_schema", "output_schema"):
        if key not in record:
            raise ValueError(f"{path} is not a handoff: it has no '{key}'.")
    return record


def handoff_is_stale(conn, handoff: dict[str, Any], ds: Dataset) -> str | None:
    """None when ``handoff`` still describes ``ds`` and its data; else the line 01_train prints before it refuses:
    the descriptor's version or digest changed (recomputed from ``ds``: the same kind the handoff recorded), or - with
    a connection - the data digest no longer matches. The fix is in the line."""
    fix = "re-run 01_explore or build the handoff: handoff = exakit.nb.handoff_from(ds)"
    record = handoff.get("descriptor") or {}
    if record.get("id") != ds.id:
        return f"the handoff is for descriptor {record.get('id')}, not {ds.id}: {fix}"
    was = int(record.get("version") or 0)
    if was != ds.version:
        return f"descriptor {ds.id} changed since the handoff (v{was} → v{ds.version}): {fix}"
    kind = record.get("digest_kind") or ("table" if ds.table_digest else "file")
    digest = str(ds.table_digest) if kind == "table" and ds.table_digest else f"sha256:{ds.digest}"
    if record.get("digest") != digest:
        return f"descriptor {ds.id} changed since the handoff (v{ds.version}, its {kind} digest differs): {fix}"
    if conn is not None and handoff.get("data_digest"):
        data_digest, _kind = _data_digest(conn, ds)
        if data_digest != handoff["data_digest"]:
            return f"the data of {ds.fact_table} changed since the handoff (its rows or dates differ): {fix}"
    return None
