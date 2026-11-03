-- train_model.sql - a training UDF that follows the exasol-mlflow run contract (packages/exasol-mlflow).
--
-- A SET script: every row of one group (one RUN_KEY) reaches one instance, which trains one scikit-learn
-- LogisticRegression on the rows whose split column says 'train', evaluates on 'test' and emits ONE row per group - one
-- per part of the model when it is over 1 MB - in the contract exasol_mlflow.start_run() validates and logs:
--
--   RUN_KEY VARCHAR(64)             the group's key (what the caller put in the RUN_KEY column)
--   PARAMS VARCHAR(2000000)         JSON: what was trained (model, solver, C, max_iter, seed, label, n_features)
--   METRICS VARCHAR(2000000)        JSON: accuracy, macro_f1, baseline_macro_f1 (majority class of the train labels),
--                                   beats_baseline (1/0), roc_auc (binary), rows_train, rows_test, ... - numbers; plus
--                                   "error": "<text>" when the model could not be trained or stored
--   MODEL_B64 VARCHAR(2000000)      the pickled model, base64 - one part of it, up to 1 MB, when it is bigger
--   MODEL_PATH VARCHAR(2000)        NULL: nothing is written anywhere (the contract still reads it from older UDFs)
--   MODEL_SHA256 VARCHAR(64)        SHA-256 of the WHOLE pickle (NULL when there is no model: see METRICS.error)
--   LANGUAGE VARCHAR(16)            "python"
--   CONTAINER_DIGEST VARCHAR(80)    the container's release hash from /build_info/image_info, else the alias
--   VERSIONS VARCHAR(2000000)       JSON: python, scikit-learn, numpy, pandas (+ flavor, commit when known)
--   EXTRAS VARCHAR(2000000)         JSON: coefficients {features, coef, intercept, classes} over the RAW feature
--                                   values (the scaler is folded in: p = sigmoid(intercept + coef . x)), positive_class
--   MODEL_PART DECIMAL(9,0)         which part of the model this row carries, from 1
--   MODEL_PARTS DECIMAL(9,0)        how many parts there are (1 for a model of 1 MB or less)
--
-- A model over 1 MB comes back through the query in parts, not as a file: on a local deployment no bucket may be
-- writable from a UDF, and the client puts the parts together and checks them against MODEL_SHA256.
--
-- Fill the placeholders with udf/templates/render.py (render_train() and train_sql()), which checks every value
-- and refuses any left unfilled:
--
-- LANGUAGE       the container alias: PYTHON3 (the official container) or the one you installed
-- SCHEMA         the schema the UDF is created in (it must exist)
-- SCRIPT_NAME    the UDF's name
-- INPUT_COLUMNS  run_key VARCHAR(64), split_ VARCHAR(8), label VARCHAR(2000), f0 DOUBLE, f1 DOUBLE, ... - positional,
--                so a feature's name never has to be a valid parameter name; train_sql() casts the columns to match
-- FEATURES       the feature names, in the order of f0, f1, ... (the coefficient vector follows it)
-- LABEL          the label column's name (recorded, not read: the label arrives as the third parameter)
-- POSITIVE       the positive class as text (roc_auc and positive_class refer to it), or None for the last class
-- SEED, C, MAX_ITER  LogisticRegression(random_state=SEED, C=C, max_iter=MAX_ITER, solver="lbfgs")
-- ALIAS          the container alias again, as text, for CONTAINER_DIGEST when /build_info is missing
--
-- The UDF needs no network, no MLflow and no credentials: the client logs the row.
CREATE OR REPLACE {{LANGUAGE}} SET SCRIPT {{SCHEMA}}.{{SCRIPT_NAME}}({{INPUT_COLUMNS}})
EMITS (RUN_KEY VARCHAR(64), PARAMS VARCHAR(2000000), METRICS VARCHAR(2000000), MODEL_B64 VARCHAR(2000000),
       MODEL_PATH VARCHAR(2000), MODEL_SHA256 VARCHAR(64), LANGUAGE VARCHAR(16), CONTAINER_DIGEST VARCHAR(80),
       VERSIONS VARCHAR(2000000), EXTRAS VARCHAR(2000000), MODEL_PART DECIMAL(9,0), MODEL_PARTS DECIMAL(9,0)) AS
import base64
import hashlib
import json
import os
import pickle
import platform

FEATURES = {{FEATURES}}
LABEL = {{LABEL}}
POSITIVE = {{POSITIVE}}
SEED = {{SEED}}
C = {{C}}
MAX_ITER = {{MAX_ITER}}
CLASS_WEIGHT = {{CLASS_WEIGHT}}
ALIAS = {{ALIAS}}
LANGUAGE = "python"
INLINE_LIMIT = 1048576            # bytes: a pickle travels base64 in MODEL_B64, in parts of up to 1 MB


def _container():
    """(digest, info): the release hash of the script-languages container from /build_info/image_info and its flavor
    and commit; the alias alone when the container does not say."""
    try:
        folder = "/build_info/image_info"
        for name in sorted(os.listdir(folder)):
            if name.endswith("-release"):
                with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as handle:
                    doc = json.load(handle)
                digest = str(doc.get("hash") or "").strip()
                if digest:
                    return digest[:80], {"flavor": name[:-len("-release")], "commit": str(doc.get("commit", ""))[:40]}
    except Exception:
        pass
    return ALIAS[:80], {}


def _versions():
    from importlib import metadata
    found = {"python": platform.python_version()}
    for name in ("scikit-learn", "numpy", "pandas"):
        try:
            found[name] = metadata.version(name)
        except Exception:
            found[name] = None
    return found


def _parts(blob):
    """(model_sha256, [base64 parts of up to INLINE_LIMIT bytes]) for the pickle; (None, [None]) without one."""
    if blob is None:
        return None, [None]
    chunks = [blob[at:at + INLINE_LIMIT] for at in range(0, len(blob), INLINE_LIMIT)] or [b""]
    return hashlib.sha256(blob).hexdigest(), [base64.b64encode(chunk).decode("ascii") for chunk in chunks]


def _train(x_train, y_train, x_test, y_test, metrics, extras):
    """Fit, evaluate, and fill metrics and extras; returns the pickled pipeline."""
    import numpy as np
    from sklearn.linear_model import LogisticRegression
    from sklearn.metrics import accuracy_score, f1_score, roc_auc_score
    from sklearn.pipeline import Pipeline
    from sklearn.preprocessing import StandardScaler

    model = Pipeline([("scale", StandardScaler()),
                      ("model", LogisticRegression(C=C, max_iter=MAX_ITER, random_state=SEED,
                                                    solver="lbfgs", class_weight=CLASS_WEIGHT))])
    model.fit(np.asarray(x_train, dtype=float), y_train)
    classifier, scaler = model.named_steps["model"], model.named_steps["scale"]
    classes = [str(c) for c in classifier.classes_]
    predicted = [str(p) for p in model.predict(np.asarray(x_test, dtype=float))]
    majority = max(sorted(set(y_train)), key=y_train.count)
    baseline = f1_score(y_test, [majority] * len(y_test), average="macro", labels=classes, zero_division=0)
    macro_f1 = f1_score(y_test, predicted, average="macro", labels=classes, zero_division=0)
    metrics.update({"accuracy": float(accuracy_score(y_test, predicted)), "macro_f1": float(macro_f1),
                    "baseline_macro_f1": float(baseline), "beats_baseline": 1.0 if macro_f1 > baseline else 0.0,
                    "n_classes": float(len(classes)), "iterations": float(np.max(classifier.n_iter_))})
    positive = POSITIVE if POSITIVE in classes else classes[-1]
    if len(classes) == 2 and len(set(y_test)) == 2:
        scores = model.predict_proba(np.asarray(x_test, dtype=float))[:, classes.index(positive)]
        metrics["roc_auc"] = float(roc_auc_score([1 if y == positive else 0 for y in y_test], scores))
    # The scaler folded into the linear model, so a scorer that has only the raw feature values (Rust, SQL) computes
    # the same logit: coef_raw = coef / scale, intercept_raw = intercept - sum(coef * mean / scale).
    scale = np.where(scaler.scale_ == 0, 1.0, scaler.scale_)
    coef = classifier.coef_ / scale
    intercept = classifier.intercept_ - (classifier.coef_ * scaler.mean_ / scale).sum(axis=1)
    extras["coefficients"] = {"features": list(FEATURES), "coef": coef.tolist(), "intercept": intercept.tolist(),
                              "classes": classes, "positive_class": positive, "formula": "sigmoid(intercept + coef . x)"}
    extras["positive_class"] = positive
    extras["majority_class"] = majority
    return pickle.dumps(model)


def run(ctx):
    run_key = str(ctx.run_key or "run")[:64]
    params = {"model": "LogisticRegression", "solver": "lbfgs", "C": C, "max_iter": MAX_ITER, "class_weight": CLASS_WEIGHT, "seed": SEED,
              "label": LABEL, "n_features": len(FEATURES), "scaler": "standard"}
    metrics, extras = {}, {"features": list(FEATURES), "label": LABEL}
    rows, nulls = [], 0
    while True:
        values = []
        for index in range(len(FEATURES)):
            value = getattr(ctx, "f%d" % index)
            if value is None:
                nulls += 1
                value = 0.0
            values.append(float(value))
        if ctx.label is not None:
            rows.append((str(ctx.split_ or ""), str(ctx.label), tuple(values)))
        if not ctx.next():
            break
    rows.sort()                                      # the same rows in any order give the same model
    train = [(y, x) for s, y, x in rows if s == "train"]
    test = [(y, x) for s, y, x in rows if s == "test"]
    metrics.update({"rows_train": float(len(train)), "rows_test": float(len(test)), "nulls_filled": float(nulls)})
    blob = None
    if len(train) < 2 or len({y for y, _ in train}) < 2:
        metrics["error"] = "the train split has %d row(s) with %d class(es); training needs 2 of each" % (
            len(train), len({y for y, _ in train}))
    elif not test:
        metrics["error"] = "the test split is empty; nothing to evaluate on"
    else:
        try:
            blob = _train([x for _, x in train], [y for y, _ in train], [x for _, x in test], [y for y, _ in test],
                          metrics, extras)
        except Exception as err:
            metrics["error"] = ("%s: %s" % (type(err).__name__, err))[:2000]
            blob = None
    if blob is not None:
        metrics["model_bytes"] = float(len(blob))
    sha, parts = _parts(blob)
    digest, info = _container()
    versions = _versions()
    versions.update(info)
    for number, part in enumerate(parts, 1):
        ctx.emit(run_key, json.dumps(params), json.dumps(metrics), part, None, sha, LANGUAGE, digest,
                 json.dumps(versions), json.dumps(extras), number, len(parts))
