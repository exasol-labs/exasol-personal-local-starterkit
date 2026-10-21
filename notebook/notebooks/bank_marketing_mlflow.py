# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Train, track and compare models with MLflow
#
# A bank phoned 45,211 clients to sell a term deposit; 11.7% said yes. Which clients should it call next time? The
# client data is read from Exasol, several classifiers train on this computer, and **every run is logged to MLflow** -
# its parameters, its metrics, the SQL it read, the model file and which database session read the data. Then the runs
# are compared side by side and the best one is named: the loop an ML engineer runs every day.
#
# Load the data first: `exakit data-load bank_marketing`.

# %%
EXPERIMENT = "bank-marketing"

# %% [markdown]
# ## Where the runs go
#
# With `MLFLOW_TRACKING_URI` set before `exakit notebook`, to that MLflow server. Without it, to a local MLflow store in
# the `mlflow` folder next to this notebook - open it with `mlflow ui --backend-store-uri sqlite:///mlflow/mlflow.db`
# (the full `mlflow` package has the UI).

# %%
import os
from pathlib import Path

import mlflow

if os.environ.get("MLFLOW_TRACKING_URI"):
    mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
else:
    store = Path("mlflow").resolve()
    store.mkdir(exist_ok=True)
    mlflow.set_tracking_uri(f"sqlite:///{store / 'mlflow.db'}")
    if mlflow.get_experiment_by_name(EXPERIMENT) is None:
        mlflow.create_experiment(EXPERIMENT, artifact_location=(store / "artifacts").as_uri())
mlflow.set_experiment(EXPERIMENT)
print(f"runs go to {mlflow.get_tracking_uri()}, experiment {EXPERIMENT}")

# %% [markdown]
# ## The data, from Exasol
#
# One row per client. `CALL_DURATION` is left out on purpose: a long call almost always means a yes, but its length is
# known only once the call is over - a model that uses it cannot help decide whom to call. Leaving out what the model
# would not know at prediction time is the first job of an ML engineer. The query is printed, and logged with every run.

# %%
import exakit_nb

conn = exakit_nb.connect()
NUMERIC = ["AGE", "BALANCE", "CREDIT_IN_DEFAULT", "HOUSING_LOAN", "PERSONAL_LOAN", "CAMPAIGN_CONTACTS",
           "DAYS_SINCE_PREVIOUS", "PREVIOUS_CONTACTS"]
CATEGORICAL = ["JOB", "MARITAL", "EDUCATION", "CONTACT_TYPE", "LAST_CONTACT_MONTH", "PREVIOUS_OUTCOME"]
DATA_SQL = f"""
SELECT CLIENT_ID, {", ".join(NUMERIC + CATEGORICAL)}, SUBSCRIBED
FROM BANKMKT.BANK_CLIENTS
ORDER BY CLIENT_ID"""
clients = exakit_nb.sql(conn, DATA_SQL)
exakit_nb.show_sql()
print(f"{len(clients)} clients, {int(clients['SUBSCRIBED'].sum())} subscribed")

# %% [markdown]
# Who says yes, straight from the database: the subscription rate by what happened in the previous campaign.

# %%
exakit_nb.sql(conn, """
SELECT PREVIOUS_OUTCOME, COUNT(*) AS CLIENTS, ROUND(100 * AVG(SUBSCRIBED), 1) AS SUBSCRIBED_PCT
FROM BANKMKT.BANK_CLIENTS
GROUP BY PREVIOUS_OUTCOME
ORDER BY SUBSCRIBED_PCT DESC""")

# %% [markdown]
# ## Train and log
#
# Each candidate is one MLflow run: a logistic regression with two strengths, a random forest, and gradient boosting.
# A quarter of the clients is kept back to test on. The metrics are the ones that matter when yes is rare: ROC AUC
# (how well it ranks yes above no), and precision and recall on the yes class (of those it would call, how many say
# yes; of those who would say yes, how many it calls).

# %%
import pickle
import tempfile

from sklearn.compose import ColumnTransformer
from sklearn.ensemble import HistGradientBoostingClassifier, RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import f1_score, precision_score, recall_score, roc_auc_score
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

X, y = clients[NUMERIC + CATEGORICAL].copy(), clients["SUBSCRIBED"].astype(int)
X[NUMERIC] = X[NUMERIC].astype(float)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.25, random_state=42, stratify=y)

CANDIDATES = [
    ("logistic_regression", {"C": 1.0}),
    ("logistic_regression", {"C": 0.1}),
    ("random_forest", {"n_estimators": 200, "max_depth": 10}),
    ("gradient_boosting", {"learning_rate": 0.1, "max_iter": 200}),
]


def build(kind, params):
    prepare = ColumnTransformer([("numbers", StandardScaler(), NUMERIC),
                                 ("categories", OneHotEncoder(handle_unknown="ignore"), CATEGORICAL)])
    if kind == "logistic_regression":
        model = LogisticRegression(max_iter=2000, class_weight="balanced", **params)
    elif kind == "random_forest":
        model = RandomForestClassifier(class_weight="balanced", random_state=42, n_jobs=-1, **params)
    else:
        model = HistGradientBoostingClassifier(class_weight="balanced", random_state=42, **params)
    return Pipeline([("prepare", prepare), ("model", model)])


for kind, params in CANDIDATES:
    with mlflow.start_run(run_name=f"{kind} {params}"):
        model = build(kind, params).fit(X_train, y_train)
        scores = model.predict_proba(X_test)[:, 1]
        said_yes = (scores >= 0.5).astype(int)
        mlflow.log_params({"model": kind, **params, "features": ",".join(NUMERIC + CATEGORICAL), "left_out": "CALL_DURATION"})
        mlflow.log_metrics({"roc_auc": roc_auc_score(y_test, scores), "precision": precision_score(y_test, said_yes),
                            "recall": recall_score(y_test, said_yes), "f1": f1_score(y_test, said_yes)})
        mlflow.set_tags({"exasol.session_id": str(conn.session_id()), "exasol.table": "BANKMKT.BANK_CLIENTS",
                         "exasol.rows": str(len(clients))})
        mlflow.log_text(DATA_SQL.strip(), "data.sql")
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "model.pkl"
            path.write_bytes(pickle.dumps(model))
            mlflow.log_artifact(str(path), "model")
print(f"{len(CANDIDATES)} runs logged")

# %% [markdown]
# ## Compare the runs
#
# Every run of the experiment so far - this notebook's and earlier ones - best ROC AUC first.

# %%
runs = mlflow.search_runs(experiment_names=[EXPERIMENT], order_by=["metrics.roc_auc DESC"])
columns = ["tags.mlflow.runName", "metrics.roc_auc", "metrics.precision", "metrics.recall", "metrics.f1", "run_id"]
runs[[c for c in columns if c in runs.columns]].head(10)

# %%
best = runs.iloc[0]
print(f"best run: {best['tags.mlflow.runName']} - ROC AUC {best['metrics.roc_auc']:.3f}, "
      f"recall {best['metrics.recall']:.3f}, precision {best['metrics.precision']:.3f}")
print(f"its model: {best['artifact_uri']}/model/model.pkl")

# %% [markdown]
# ## Next
#
# - Change `CANDIDATES` and run the last three cells again: each run is one more row to compare.
# - Train inside the database instead, with the rows never leaving it: `train.ipynb`, beside this notebook.
