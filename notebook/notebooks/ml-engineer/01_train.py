# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Train inside Exasol from the Data Scientist's handoff
#
# - **Dataset:** `pharma_trials` as it ships; change one assignment for `banking_complaints` or a file you loaded.
# - **What must be loaded:** an approved descriptor, the handoff written by `data-scientist/01_explore`, and the Python
#   UDF container (`exakit udf-setup`). Run `exakit mlflow start` to see the run in the local MLflow UI.
# - **How long:** about five minutes, depending on the dataset and container.
#
# The handoff records the exact descriptor version, data digest, feature view, label and time split. This notebook
# refuses a stale handoff before creating a view or running training SQL. With no handoff file at all (a fresh
# machine), it builds one from the approved descriptor and says so.

# %%
DATASET = "pharma_trials"  # or "banking_complaints", or "~/my-data/transactions.csv" with approved roles beside it

# %% [markdown]
# ## Load and check the handoff
#
# `01_explore` wrote it with `nb.write_handoff(conn, ds)`. A changed descriptor or table stops here and says to rerun
# explore. When no file exists, `training_handoff` builds the same record from the approved descriptor
# (`nb.handoff_from`) and prints that it did. The earliest 80% by the date role train the classifier; the latest 20%
# test it. Without a date role there is no time split: the handoff is refused with the fix - ask explore (or this
# cell, `SPLIT = "random"`) for a reproducible hash split, or add a date role - and a random split that nobody asked
# for is refused here too.

# %%
import exakit.nb as nb
import exasol_mlflow

SPLIT = None  # None: the time split by the date role; "random": a hash split, only when there is no handoff file yet

conn = nb.connect()
ds = nb.dataset(conn, DATASET).require_approved("training")
handoff = nb.ml_train.training_handoff(conn, ds, split=SPLIT)
print(f"handoff: {ds.id} v{ds.version}; {handoff['rows']} rows; {handoff['split']['kind']} split"
      + (" (asked for)" if handoff['split'].get('explicit') else ""))
print(f"data digest: {handoff['data_digest']}")

# %% [markdown]
# ## Build the feature view and training UDF
#
# Every feature is made in SQL from an approved role. The view and its training SELECT are checked against the
# current descriptor. Constant features are dropped before fitting. The UDF trains a logistic regression with a
# fixed seed, and sends its model, metrics and coefficients back to this notebook; it has no network or credentials.

# %%
UDF_SCHEMA = "EXASOL_MLFLOW"
UDF_NAME = "TRAIN_FROM_HANDOFF"
SEED = 0
REGULARIZATION_C = 1.0

plan = nb.prepare_training(conn, ds, handoff, schema=UDF_SCHEMA, name=UDF_NAME,
                           seed=SEED, C=REGULARIZATION_C)
conn.execute(f"CREATE SCHEMA IF NOT EXISTS {UDF_SCHEMA}")
conn.execute(plan.create_script)
print(f"features ({len(plan.features)}): {', '.join(plan.features)}")
print(plan.training_sql)

# %% [markdown]
# ## Train and compare with the majority baseline
#
# `start_run` checks the tracking server before the training SELECT. If MLflow goes away after training, it keeps a
# spool record; `exakit mlflow replay` logs it when the server returns. A database restart marks the run FAILED.
#
# Accuracy and macro-F1 come from the later 20%, beside a majority-class baseline on the same rows. The MLflow run
# stores `training.sql`, the model, coefficients, descriptor version and data digest.

# %%
EXPERIMENT = "exasol-starter-kit"
with exasol_mlflow.start_run(conn, params=plan.params, experiment=EXPERIMENT,
                             run_name=f"{ds.id}-v{ds.version}-logistic", tags=ds.tags(),
                             handoff=handoff) as run:
    run.execute(plan.training_sql)

f1 = run.metrics["macro_f1"]
baseline = run.metrics["baseline_macro_f1"]
print(f"run {run.run_id} in {run.tracking_uri}")
print(f"accuracy: {run.metrics['accuracy']:.4f}")
print(f"macro-F1: {f1:.4f}; majority baseline: {baseline:.4f}")
print("beats baseline" if f1 > baseline else "does not beat baseline; inspect features or the split")

# %% [markdown]
# ## Model and coefficient artifacts
#
# `model/model.pkl` is the fitted scikit-learn pipeline; `coefficients.json` holds weights for the raw feature
# columns (the scaler has been folded in), ready for the Rust scoring notebook. The run records the container and
# package versions so a model moved to another container can be checked before use. The same coefficients are copied
# beside the handoff, `~/.exasol-starter-kit/handoffs/<id>-v<n>.coefficients.json`, so `02_rust_score` reads them
# without MLflow. Rerun the training cell with the same seed: the metrics and these coefficients come out identical.

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
# Change `REGULARIZATION_C` and rerun the last cells to compare a new MLflow run. `02_rust_score.ipynb` scores from
# the exported coefficients when a Rust container is installed. For a model trained elsewhere, open
# `03_score_external_model.ipynb`.
