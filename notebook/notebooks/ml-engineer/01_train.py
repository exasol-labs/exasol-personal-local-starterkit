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
# **Dataset:** `esophageal_posts` by default; change `DATASET` for Banking or your own approved file. **How long:** about five minutes after setup.
#
# Trains a model inside Exasol from the Explore handoff and records it in MLflow. No LLM needed.
#
# **Run first:**
# - an approved descriptor and the Explore handoff
# - a Python ML runtime: `exakit udf-use default` (`PYTHON3_ML`) or `exakit udf-setup` (`PYTHON3`); `EXAKIT_UDF_CONTAINER` picks another alias
# - `exakit mlflow start` for the MLflow UI

# %%
import exakit.nb as nb
import exasol_mlflow
import os

DATASET = "esophageal_posts"  # or "banking_complaints", or "~/my-data/transactions.csv" with approved roles beside it
CONTAINER = nb.ml_train.udf_container()   # or "PYTHON3_ML", "PYTHON3", or the alias of a container you installed
if os.environ.get("EXAKIT_WORKFLOW_ID"):
    nb.workflow(resume=os.environ["EXAKIT_WORKFLOW_ID"])
elif not nb.current_workflow():
    nb.workflow("train-" + DATASET)

# %% [markdown]
# ## Load the handoff
#
# Check the printed ID and split. A stale handoff is refused; with no handoff file, one is built from the approved descriptor. No date role? Set `SPLIT = "random"`.

# %%
SPLIT = None  # None: the time split by the date role; "random": a hash split, only when there is no handoff file yet

conn = nb.connect()
ds = nb.dataset(conn, DATASET).require_approved("training")
handoff = nb.ml_train.training_handoff(conn, ds, split=SPLIT)
print(f"handoff: {ds.id} v{ds.version}; {handoff['rows']} rows; {handoff['split']['kind']} split"
      + (" (asked for)" if handoff['split'].get('explicit') else ""))
print(f"data digest: {handoff['data_digest']}")

# %% [markdown]
# ## Build features and the training UDF
#
# Creates a SQL feature view and a training UDF. Check the label is not among the printed features.

# %%
UDF_SCHEMA = "EXASOL_MLFLOW"
UDF_NAME = "TRAIN_FROM_HANDOFF"
SEED = 0
CLASS_WEIGHT = None  # "balanced" for the Banking reference recipe; None for Esophageal
REGULARIZATION_C = 1.0

plan = nb.prepare_training(conn, ds, handoff, schema=UDF_SCHEMA, name=UDF_NAME, container=CONTAINER,
                           seed=SEED, C=REGULARIZATION_C, class_weight=CLASS_WEIGHT)
conn.execute(f"CREATE SCHEMA IF NOT EXISTS {UDF_SCHEMA}")
nb.log_sql(conn, f"CREATE SCHEMA IF NOT EXISTS {UDF_SCHEMA}", None)
conn.execute(plan.create_script)
nb.log_sql(conn, plan.create_script, None)
print(f"UDF {UDF_SCHEMA}.{UDF_NAME} on {CONTAINER}; features ({len(plan.features)}): {', '.join(plan.features)}")
print(plan.training_sql)

# %% [markdown]
# ## Train and compare with the baseline
#
# Compare macro-F1 with `baseline_macro_f1` (always predicting the most common class). Use `CLASS_WEIGHT = None` for Esophageal, `"balanced"` for Banking.
#
# If MLflow fails after training, replay with `exakit mlflow replay`.

# %%
EXPERIMENT = "exasol-starter-kit"
with exasol_mlflow.start_run(conn, params=plan.params, experiment=EXPERIMENT,
                             run_name=f"{ds.id}-v{ds.version}-logistic", tags=ds.tags(),
                             handoff=handoff) as run:
    run.execute(plan.training_sql)
    nb.log_sql(conn, plan.training_sql, 1)

f1 = run.metrics["macro_f1"]
baseline = run.metrics["baseline_macro_f1"]
print(f"run {run.run_id} in {run.tracking_uri}")
print(f"accuracy: {run.metrics['accuracy']:.4f}")
print(f"macro-F1: {f1:.4f}; majority baseline: {baseline:.4f}")
print("beats baseline" if f1 > baseline else "does not beat baseline; inspect features or the split")

# %% [markdown]
# ## Model files
#
# `model/model.pkl` is the fitted pipeline. `coefficients.json` holds the weights, also saved beside the handoff for the Rust scorer.

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
# - To experiment, change one setting (e.g. `REGULARIZATION_C`) and compare runs in MLflow.
