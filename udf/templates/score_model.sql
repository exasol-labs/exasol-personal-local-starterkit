-- score_model.sql - a scoring UDF for a model file in the deployment's bucket directory.
--
-- Put the model there first (exakit model put churn.pkl prints the /buckets path), then fill the
-- placeholders with udf/templates/render.py, which checks every value and refuses any left unfilled:
--   python3 udf/templates/render.py --help
--
-- LANGUAGE       the container alias: PYTHON3 (the official container) or the one you installed
-- SCHEMA         the schema the UDF is created in (it must exist)
-- SCRIPT_NAME    the UDF's name
-- INPUT_COLUMNS  the UDF's parameters, "name TYPE" each, in the order the SQL passes them
-- OUTPUT_TYPE    what it returns: DOUBLE for a probability, the label's type for a class
-- MODEL_PATH     the /buckets path exakit model put printed
-- INPUTS         (parameter, model feature) pairs: the column names the model was trained on
-- METHOD         'predict', or 'predict_proba' for the probability of the model's last class
--
-- A scikit-learn pickle (.pkl, .pickle) or joblib file (.joblib) is loaded with the container's own Python and
-- scikit-learn, so train it with the same versions; an ONNX file (.onnx) needs onnxruntime in the container.
-- The file is read ONCE per UDF instance, on its first row, and kept for every row after it.
-- Loading a pickle runs code from the file: only put models you trust.
CREATE OR REPLACE {{LANGUAGE}} SCALAR SCRIPT {{SCHEMA}}.{{SCRIPT_NAME}}({{INPUT_COLUMNS}})
RETURNS {{OUTPUT_TYPE}} AS
import os

MODEL_PATH = {{MODEL_PATH}}
INPUTS = {{INPUTS}}
METHOD = {{METHOD}}

_model = None


def _load():
    global _model
    if _model is None:
        if not os.path.isfile(MODEL_PATH):
            raise RuntimeError(MODEL_PATH + " is not visible to this UDF: put the file with exakit model put "
                               "and use the path it printed (exakit model list shows what is there)")
        lowered = MODEL_PATH.lower()
        if lowered.endswith(".onnx"):
            import onnxruntime
            _model = onnxruntime.InferenceSession(MODEL_PATH, providers=["CPUExecutionProvider"])
        elif lowered.endswith(".joblib"):
            import joblib
            _model = joblib.load(MODEL_PATH)
        else:
            import pickle
            with open(MODEL_PATH, "rb") as handle:
                _model = pickle.load(handle)
    return _model


def _plain(value):
    return value.item() if hasattr(value, "item") else value


def _onnx(session, row):
    import numpy as np

    def tensor(values, kind):
        if "string" in kind:
            return np.array([values], dtype=object)
        if "int64" in kind:
            return np.array([values], dtype=np.int64)
        if "double" in kind:
            return np.array([values], dtype=np.float64)
        return np.array([values], dtype=np.float32)

    wanted = session.get_inputs()
    if len(wanted) == 1:
        feed = {wanted[0].name: tensor(row, wanted[0].type)}
    else:
        features = [feature for _, feature in INPUTS]
        missing = [given.name for given in wanted if given.name not in features]
        if missing:
            raise RuntimeError("the ONNX model wants inputs this UDF does not pass: " + ", ".join(missing))
        feed = {given.name: tensor([row[features.index(given.name)]], given.type) for given in wanted}
    outputs = session.run(None, feed)
    if METHOD == "predict_proba" and len(outputs) > 1:
        probabilities = outputs[1][0]
        if isinstance(probabilities, dict):
            return float(probabilities[sorted(probabilities)[-1]])
        return float(probabilities[-1])
    return _plain(outputs[0].ravel()[0] if hasattr(outputs[0], "ravel") else outputs[0][0])


def run(ctx):
    model = _load()
    row = [getattr(ctx, name) for name, _ in INPUTS]
    if hasattr(model, "get_inputs"):
        return _onnx(model, row)
    import pandas as pd
    frame = pd.DataFrame([row], columns=[feature for _, feature in INPUTS])
    if METHOD == "predict_proba":
        return float(model.predict_proba(frame)[0][-1])
    return _plain(model.predict(frame)[0])
