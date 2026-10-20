"""A training UDF that follows the result contract (contract.py): a text classifier trained inside the database.

``create_script(schema)`` is the CREATE statement; the UDF is a SET script, so called without GROUP BY every row reaches
one instance and one model is trained (one run, not one per worker). It reads ``(label, category, doc_text, params)`` -
``params`` a JSON object, the same on every row - and needs only the Python and scikit-learn of the database's script
language container: no network, no MLflow, no credentials.
"""

from __future__ import annotations

import re

NAME = "EXASOL_MLFLOW_TRAIN_TEXT_CLASSIFIER"
DEFAULT_PARAMS = {"max_features": 5000, "ngram_max": 2, "C": 1.0, "test_size": 0.25, "seed": 0}
_SQL_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")

_BODY = r'''
import base64, hashlib, json, pickle, platform

CHUNK = 1900000                                   # characters of base64 per row, under VARCHAR(2000000)

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
    import sklearn
    from sklearn.compose import ColumnTransformer
    from sklearn.feature_extraction.text import TfidfVectorizer
    from sklearn.linear_model import LogisticRegression
    from sklearn.metrics import accuracy_score, roc_auc_score
    from sklearn.model_selection import train_test_split
    from sklearn.pipeline import Pipeline
    from sklearn.preprocessing import OneHotEncoder
    import pandas as pd
    p = dict(params or {})
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
    metrics = {"roc_auc": float(roc_auc_score(y_test, scores)),
               "accuracy": float(accuracy_score(y_test, (scores >= 0.5).astype(int))),
               "rows_train": float(len(y_train)), "rows_test": float(len(y_test)),
               "label_1_share": float(sum(labels)) / len(labels)}
    blob = pickle.dumps(model)
    text = base64.b64encode(blob).decode("ascii")
    parts = [text[i:i + CHUNK] for i in range(0, len(text), CHUNK)] or [""]
    result = json.dumps({"contract": 1, "metrics": metrics, "params": p,
                         "model": {"format": "sklearn-pickle", "sha256": hashlib.sha256(blob).hexdigest(), "bytes": len(blob),
                                   "parts": len(parts), "python": platform.python_version(), "sklearn": sklearn.__version__}})
    for index, part in enumerate(parts):
        ctx.emit(index, part, result if index == 0 else None)
'''


def create_script(schema: str) -> str:
    """The CREATE OR REPLACE statement for the training UDF in ``schema`` (a plain SQL name), as a driver sends it
    (a SQL client such as exapump also wants a line holding only ``/`` after it)."""
    if not _SQL_NAME.match(schema):
        raise ValueError(f"'{schema}' is not a plain SQL name")
    return (f"CREATE OR REPLACE PYTHON3 SET SCRIPT {schema.upper()}.{NAME}"
            "(label DECIMAL(1,0), category VARCHAR(2000), doc_text VARCHAR(2000000), params VARCHAR(2000))\n"
            "EMITS (PART DECIMAL(9,0), CHUNK VARCHAR(2000000), TRAINING_RESULT VARCHAR(2000000)) AS" + _BODY)


def call(schema: str) -> str:
    """The UDF's qualified name, for the training query: ``SELECT <call>(label, category, doc_text, params) FROM ...``."""
    return f"{schema.upper()}.{NAME}"
