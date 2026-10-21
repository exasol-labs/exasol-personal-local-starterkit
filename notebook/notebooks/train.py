# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Train inside the database, log to MLflow
#
# SQL picks the training rows from the dataset's **descriptor** roles, a Python UDF trains a text classifier **inside
# Exasol**, and this notebook logs the run to **your** MLflow: the parameters, the metrics, the training SQL, the model
# file, and which database session and statement trained it. The UDF needs no MLflow credentials and no network.
#
# **Change one line to change the data**, as in `explore.ipynb`: a dataset the kit ships, your own CSV or Parquet file
# ("Your own file" below), or the path of a descriptor for a table you loaded (its label must be 0 or 1).

# %%
DATASET = "pharma_trials"   # or "banking_complaints", "~/my-data/descriptor.json", or "own-file" (the file below)

# %% [markdown]
# ## Your own file
#
# To run this notebook on your own CSV or Parquet file, say which column plays each role below and set
# `DATASET = "own-file"` above - that one change, and no SQL. `exakit_nb.load_own_file` loads the file into the table
# over the kit's connection (a second run loads nothing unless the file changed) and checks the roles by the same rules
# as a kit dataset. The label must be 0 or 1 (true/false works too). The example is a generic transactions file.

# %%
OWN_FILE = {
    "path": "~/my-data/transactions.csv",
    "table": "MY_DATA.TRANSACTIONS",
    "descriptor": {"entity": "CUSTOMER_ID", "category": "MERCHANT_CATEGORY", "date": "BOOKED_ON", "label": "DISPUTED",
                   "text": ["MEMO"]},
}

# %% [markdown]
# ## Where the run goes
#
# With `MLFLOW_TRACKING_URI` set before `exakit notebook`, the run goes to that MLflow server. Without it, it goes to
# a local MLflow store in the `mlflow` folder next to this notebook; open it with
# `mlflow ui --backend-store-uri sqlite:///mlflow/mlflow.db` (the full `mlflow` package has the UI).

# %%
EXPERIMENT = "exasol-starter-kit"
UDF_SCHEMA = "EXASOL_MLFLOW"        # where the training UDF is created; nothing else is written there

# %% [markdown]
# ## Connect, read the descriptor, create the training UDF

# %%
import json

import exakit_nb
import exasol_mlflow

conn = exakit_nb.connect()
ds = exakit_nb.load_own_file(**OWN_FILE, conn=conn) if DATASET == "own-file" else exakit_nb.dataset(conn, DATASET)
for role, column in ds.roles():
    print(f"  {role:<9} {column}")

conn.execute(f"CREATE SCHEMA IF NOT EXISTS {UDF_SCHEMA}")
conn.execute(exasol_mlflow.create_script(UDF_SCHEMA))
print(f"UDF {exasol_mlflow.call(UDF_SCHEMA)} is ready; it runs on the database's Python script language container")

# %% [markdown]
# ## The training query
#
# One row per observation: the label, the category and the text, built from the roles, plus the training parameters
# as one JSON value. The UDF sees every row and trains one model (it is a SET script called without GROUP BY).

# %%
PARAMS = dict(exasol_mlflow.DEFAULT_PARAMS)      # max_features, ngram_max, C, test_size, seed - change any of them
PARAMS["C"] = 1.0

training_sql = f"""SELECT {exasol_mlflow.call(UDF_SCHEMA)}(
         {ds.col("label")},
         CAST({ds.col("category")} AS VARCHAR(2000)),
         {ds.text_sql()},
         '{json.dumps(PARAMS)}')
FROM {ds.fact_table}
WHERE {ds.col("label")} IS NOT NULL"""
print(training_sql)

# %% [markdown]
# ## Train and log
#
# `start_run` opens one MLflow run around the training statement: `run.execute` runs it, checks the UDF's answer (one
# result, every model chunk present, the model's SHA-256 matching) and logs the parameters, the metrics, the training
# SQL, the model file and the lineage tags. A broken answer stops here with the reason, and MLflow gets nothing.

# %%
with exasol_mlflow.start_run(conn, params=PARAMS, experiment=EXPERIMENT, run_name=f"{ds.id}-text-classifier",
                             tags={"exasol.dataset": ds.id, "exasol.descriptor_sha256": ds.digest}) as run:
    run.execute(training_sql)
print(f"run {run.run_id} in {run.tracking_uri}")
print(f"model artefact: {run.artifact_uri}/model/model.pkl")
for name, value in sorted(run.metrics.items()):
    print(f"  {name:<14} {value:.4f}")
for name, value in sorted(run.tags.items()):
    print(f"  {name:<26} {value}")

# %% [markdown]
# ## Next
#
# - Change `PARAMS` and run the last two cells again: each run is one more row in the MLflow experiment, so runs compare
#   side by side.
# - The model file (`model/model.pkl`, a scikit-learn pipeline) was trained with the database container's Python and
#   scikit-learn - the run's tags say which - so load it where those match.
# - Packages beyond the container's own: the `udf-devkit` add-on (`exakit udf-setup`, `exakit udf-build`).
