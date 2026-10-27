"""A training UDF that follows the run contract (contract.py): a text classifier trained inside the database.

``create_script(schema)`` is the CREATE statement; the UDF is a SET script, so called without GROUP BY every row reaches
one instance and one model is trained (one run, not one per worker). It reads ``(label, category, doc_text, params)`` -
``params`` a JSON object, the same on every row, with an optional ``run_key`` - and needs only the Python and
scikit-learn of the database's script language container: no network, no MLflow, no credentials. It emits exactly one
contract row: the model inline (base64) when it is 1 MB or smaller, else written under /buckets when that is writable
from the UDF, else no model and ``metrics.error`` saying so.
"""

from __future__ import annotations

import re

NAME = "EXASOL_MLFLOW_TRAIN_TEXT_CLASSIFIER"
DEFAULT_PARAMS = {"max_features": 5000, "ngram_max": 2, "C": 1.0, "test_size": 0.25, "seed": 0}
MODEL_DIR = "/buckets/bfsdefault/default/models"
_SQL_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")

_BODY = r'''
import base64, hashlib, json, os, pickle, platform

INLINE_LIMIT = 1048576                            # bytes: a pickle up to 1 MB travels base64 in MODEL_B64
MODEL_DIR = "%(model_dir)s"


def _container():
    try:
        folder = "/build_info/image_info"
        for name in sorted(os.listdir(folder)):
            if name.endswith("-release"):
                with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as handle:
                    doc = json.load(handle)
                if doc.get("hash"):
                    return str(doc["hash"])[:80], {"flavor": name[:-len("-release")], "commit": str(doc.get("commit", ""))[:40]}
    except Exception:
        pass
    return "PYTHON3", {}


def _versions():
    from importlib import metadata
    found = {"python": platform.python_version()}
    for name in ("scikit-learn", "numpy", "pandas"):
        try:
            found[name] = metadata.version(name)
        except Exception:
            found[name] = None
    return found


def run(ctx):
    labels, categories, texts, params = [], [], [], None
    while True:
        if ctx.label is not None:
            labels.append(int(ctx.label))
            categories.append(ctx.category or "")
            texts.append(ctx.doc_text or "")
            params = params or json.loads(ctx.params or "{}")
        if not ctx.next():
            break
    p = dict(params or {})
    run_key = str(p.pop("run_key", "") or "text-classifier")[:64]
    metrics, extras, blob = {"rows": float(len(labels))}, {}, None
    try:
        import sklearn
        from sklearn.compose import ColumnTransformer
        from sklearn.feature_extraction.text import TfidfVectorizer
        from sklearn.linear_model import LogisticRegression
        from sklearn.metrics import accuracy_score, f1_score, roc_auc_score
        from sklearn.model_selection import train_test_split
        from sklearn.pipeline import Pipeline
        from sklearn.preprocessing import OneHotEncoder
        import pandas as pd
        frame = pd.DataFrame({"text": texts, "category": categories})
        x_train, x_test, y_train, y_test = train_test_split(frame, labels, test_size=float(p["test_size"]),
                                                            random_state=int(p["seed"]), stratify=labels)
        model = Pipeline([
            ("features", ColumnTransformer([
                ("text", TfidfVectorizer(max_features=int(p["max_features"]), ngram_range=(1, int(p["ngram_max"])), min_df=2), "text"),
                ("category", OneHotEncoder(handle_unknown="ignore"), ["category"])])),
            ("classifier", LogisticRegression(C=float(p["C"]), max_iter=1000, class_weight="balanced"))])
        model.fit(x_train, y_train)
        scores = model.predict_proba(x_test)[:, 1]
        predicted = [1 if s >= 0.5 else 0 for s in scores]
        majority = max(sorted(set(y_train)), key=y_train.count)
        baseline = f1_score(y_test, [majority] * len(y_test), average="macro", labels=[0, 1], zero_division=0)
        macro_f1 = f1_score(y_test, predicted, average="macro", labels=[0, 1], zero_division=0)
        metrics.update({"roc_auc": float(roc_auc_score(y_test, scores)), "accuracy": float(accuracy_score(y_test, predicted)),
                        "macro_f1": float(macro_f1), "baseline_macro_f1": float(baseline),
                        "beats_baseline": 1.0 if macro_f1 > baseline else 0.0,
                        "rows_train": float(len(y_train)), "rows_test": float(len(y_test)),
                        "label_1_share": float(sum(labels)) / len(labels)})
        extras = {"classes": [0, 1], "positive_class": 1, "majority_class": majority}
        blob = pickle.dumps(model)
        metrics["model_bytes"] = float(len(blob))
    except Exception as err:
        metrics["error"] = ("%%s: %%s" %% (type(err).__name__, err))[:2000]
    model_b64 = model_path = sha = None
    if blob is not None:
        sha = hashlib.sha256(blob).hexdigest()
        if len(blob) <= INLINE_LIMIT:
            model_b64 = base64.b64encode(blob).decode("ascii")
        else:
            target = MODEL_DIR + "/" + run_key + ".pkl"
            try:
                os.makedirs(MODEL_DIR, exist_ok=True)
                with open(target, "wb") as handle:
                    handle.write(blob)
                model_path = target
            except OSError as err:
                sha = None
                metrics["error"] = ("the model is %%d bytes (over the 1 MB inline limit) and %%s is not writable from the UDF: %%s"
                                    %% (len(blob), MODEL_DIR, err))
    digest, info = _container()
    versions = _versions()
    versions.update(info)
    ctx.emit(run_key, json.dumps({"model": "tfidf+LogisticRegression", **p}), json.dumps(metrics), model_b64, model_path, sha,
             "python", digest, json.dumps(versions), json.dumps(extras))
'''

EMITS = ("EMITS (RUN_KEY VARCHAR(64), PARAMS VARCHAR(2000000), METRICS VARCHAR(2000000), MODEL_B64 VARCHAR(2000000), "
         "MODEL_PATH VARCHAR(2000), MODEL_SHA256 VARCHAR(64), LANGUAGE VARCHAR(16), CONTAINER_DIGEST VARCHAR(80), "
         "VERSIONS VARCHAR(2000000), EXTRAS VARCHAR(2000000))")


def create_script(schema: str, model_dir: str = MODEL_DIR) -> str:
    """The CREATE OR REPLACE statement for the training UDF in ``schema`` (a plain SQL name), as a driver sends it
    (a SQL client such as exapump also wants a line holding only ``/`` after it)."""
    if not _SQL_NAME.match(schema):
        raise ValueError(f"'{schema}' is not a plain SQL name")
    if not re.match(r"^/buckets/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$", model_dir):
        raise ValueError(f"'{model_dir}' is not a /buckets folder")
    return (f"CREATE OR REPLACE PYTHON3 SET SCRIPT {schema.upper()}.{NAME}"
            "(label DECIMAL(1,0), category VARCHAR(2000), doc_text VARCHAR(2000000), params VARCHAR(2000))\n"
            f"{EMITS} AS" + _BODY % {"model_dir": model_dir})


def call(schema: str) -> str:
    """The UDF's qualified name, for the training query: ``SELECT <call>(label, category, doc_text, params) FROM ...``."""
    return f"{schema.upper()}.{NAME}"
