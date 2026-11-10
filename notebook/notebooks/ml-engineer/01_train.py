# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Train in Exasol
#
# **Dataset:** the one you approved last (else `amazon_sales`). Set `DATASET` for `fraud_transactions` or your own approved file. **How long:** about five minutes after setup.
#
# Trains a model inside Exasol from the approved column map and records it in MLflow. No LLM is needed.
#
# **Run first:**
# - an approved column map with a label (the quickstart's review, or `exakit describe <id> --approve`)
# - a Python ML runtime: `exakit udf-use default` (`PYTHON3_ML`) or `exakit udf-setup` (`PYTHON3`). `EXAKIT_UDF_CONTAINER` selects another alias.
# - `exakit mlflow start` for the MLflow UI

# %%
import exakit.nb as nb
import exasol_mlflow
import os

DATASET = None  # None: the dataset approved last in a quickstart (else amazon_sales); or "fraud_transactions", or "~/my-data/transactions.csv" with approved roles beside it
CONTAINER = nb.ml_train.udf_container()   # or "PYTHON3_ML", "PYTHON3", or the alias of a container you installed
dataset_id = nb.chosen_dataset(DATASET)
nb.continue_workflow("train-" + dataset_id)   # the quickstart's workflow, or the last one: nothing to paste

# %% [markdown]
# ## Optional: your team's MLflow server
#
# By default the run goes to the kit's own MLflow. Set `MLFLOW_TRACKING_URI` to use your team's server. `MLFLOW_SERVER_LOGIN = True` asks for the username and password in a hidden box. They stay in this kernel only. Left empty, this cell changes nothing.

# %%
MLFLOW_TRACKING_URI = ""     # e.g. "https://mlflow.example.com"; empty: the kit's own MLflow (or the one set before `exakit notebook`)
MLFLOW_SERVER_LOGIN = False  # True: asks for the server's username and password (hidden)
nb.use_mlflow(MLFLOW_TRACKING_URI, MLFLOW_SERVER_LOGIN)

# %% [markdown]
# ## Load the handoff
#
# The handoff fixes what the model trains on: the map version, a data fingerprint, the features, the label and the split. The same handoff gives the same model. If there is none, this cell writes it from the approved map. A stale handoff is refused.
#
# Check the printed ID and split. No date role? Set `SPLIT = "random"`.

# %%
SPLIT = None  # None: the time split by the date role; "random": a hash split, only when there is no handoff file yet

connection = nb.connect()
dataset = nb.dataset(connection, dataset_id).require_approved("training")
handoff = nb.ml_train.training_handoff(connection, dataset, split=SPLIT)
print(f"handoff: {dataset.id} v{dataset.version}; {handoff['rows']} rows; {handoff['split']['kind']} split"
      + (" (asked for)" if handoff['split'].get('explicit') else ""))
print(f"data digest: {handoff['data_digest']}")

# %% [markdown]
# ## Build features and the training UDF
#
# Creates a SQL feature view and a training UDF. The view turns each row into numbers: year, month and weekday, one 0/1 column per common category, and the entity's frequency. The Rust scorer reads the same view. A column that gives the answer away (`STATUS` in `amazon_sales`) never becomes a feature.
#
# Make sure the label is not in the printed features.

# %%
UDF_SCHEMA = "EXASOL_MLFLOW"
UDF_NAME = "TRAIN_FROM_HANDOFF"
SEED = 0
CLASS_WEIGHT = "balanced"  # "balanced": the rarer outcome counts more (amazon_sales: 14.2% cancelled); None: every row counts the same
REGULARIZATION_C = 1.0

plan = nb.prepare_training(connection, dataset, handoff, schema=UDF_SCHEMA, name=UDF_NAME, container=CONTAINER,
                           seed=SEED, C=REGULARIZATION_C, class_weight=CLASS_WEIGHT)
connection.execute(f"CREATE SCHEMA IF NOT EXISTS {UDF_SCHEMA}")
nb.log_sql(connection, f"CREATE SCHEMA IF NOT EXISTS {UDF_SCHEMA}", None)
connection.execute(plan.create_script)
nb.log_sql(connection, plan.create_script, None)
print(f"UDF {UDF_SCHEMA}.{UDF_NAME} on {CONTAINER}; features ({len(plan.features)}): {', '.join(plan.features)}")
print(plan.training_sql)

# %% [markdown]
# ## Train and compare with the baseline
#
# The baseline always predicts the most common outcome. The model must beat it. The score is macro-F1, which weighs both outcomes equally.
#
# Compare macro-F1 with `baseline_macro_f1`. Use `CLASS_WEIGHT = "balanced"` when the label is rare (`amazon_sales`: 14.2% cancelled). For an even label, `None` is fine.
#
# MLflow records the run with the map version and the handoff. If MLflow fails after training, run `exakit mlflow replay`.

# %%
EXPERIMENT = "exasol-starter-kit"
with exasol_mlflow.start_run(connection, params=plan.params, experiment=EXPERIMENT,
                             run_name=f"{dataset.id}-v{dataset.version}-logistic", tags=dataset.tags(),
                             handoff=handoff) as run:
    run.execute(plan.training_sql)
    nb.log_sql(connection, plan.training_sql, 1)

f1 = run.metrics["macro_f1"]
baseline = run.metrics["baseline_macro_f1"]
print(f"run {run.run_id} in {run.tracking_uri}")
print(f"accuracy: {run.metrics['accuracy']:.4f}")
print(f"macro-F1: {f1:.4f}; majority baseline: {baseline:.4f}")
print("beats baseline" if f1 > baseline else "does not beat baseline; inspect features or the split")

# %% [markdown]
# ## Model files
#
# `model/model.pkl` is the fitted pipeline. `coefficients.json` holds the weights. A copy goes beside the handoff for the Rust scorer.

# %%
from urllib.parse import unquote, urlparse

print(f"model: {run.artifact_uri}/model/model.pkl")
print(f"coefficients: {run.artifact_uri}/coefficients.json")
if urlparse(run.artifact_uri).scheme == "file":
    print(f"on this computer: {unquote(urlparse(run.artifact_uri).path)}")
coefficients_path = nb.ml_train.export_coefficients(run, handoff)
print(f"coefficients beside the handoff: {coefficients_path}")

# %% [markdown]
# ## Next
#
# - `02_rust_score.ipynb`: check a Rust scorer against this model.
# - `03_score_external_model.ipynb`: score a model file in SQL.
# - To experiment, change one setting (for example `REGULARIZATION_C`) and compare the runs in MLflow.

