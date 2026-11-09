# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # ML Engineer quickstart
#
# **Dataset:** `amazon_sales` by default; `fraud_transactions` or your own file also work. **How long:** about five minutes once runtimes are installed.
#
# Checks the database Python runtime, MLflow and the shared model directory, then loads and describes the data.
#
# **Run first:** `exakit udf-use default` (installs the ML runtime; a container install can restart the database).

# %% [markdown]
# ## Start a workflow
#
# One ID links data, checks and model runs. Train, Rust scoring and scoring continue it on their own: nothing to copy.

# %%
import os
import exakit.nb as nb

workflow_id = nb.workflow("ml-engineer-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
print(f"Every step below is logged under it: exakit workflow show {workflow_id}")

# %% [markdown]
# ## Pick the database Python runtime
#
# > **What is a UDF?** A user-defined function: a small program, here in Python, that runs inside the database, next to the data.
# > Training as a UDF means the rows are not copied out of the database into the notebook first.
# > The runtime (container) picked below is the set of Python packages that program can use.
#
# Training runs as a UDF inside Exasol, with its own packages.
#
# - `PYTHON3_ML` (`exakit udf-use default`): preferred, has the ML packages.
# - `PYTHON3` (`exakit udf-setup`): the official alternative.
# - `EXAKIT_UDF_CONTAINER` picks another installed alias.

# %%
CONTAINER = nb.ml_train.udf_container()   # or "PYTHON3_ML", "PYTHON3", or the alias of a container you installed
print(f"container alias: {CONTAINER}")

# %% [include] ../00_shared/data_paths.py connect

# %% [markdown]
# ## Check the runtime packages
#
# Runs a small UDF that imports the training packages. On failure, run the command it prints and repeat.

# %%
container_ok = nb.check_container(connection, alias=CONTAINER)

# %% [markdown]
# ## Check MLflow
#
# > **What is MLflow tracking?** A logbook for model training: every run's settings, scores and model file.
# > With it you can compare two runs side by side and find the exact model a result came from.
# > By default the runs are kept on this computer, in the kit's own MLflow.
#
# Shows where runs are recorded. Browser UI: `exakit mlflow start`, then `exakit mlflow url`.
#
# **Optional: another MLflow server.** Fill in `MLFLOW_TRACKING_URI` to record to your team's server instead; `MLFLOW_SERVER_LOGIN = True` asks for its username and password in a hidden box. They stay in this notebook's kernel only - never in this file. Left empty, runs go to the kit's own MLflow.

# %%
MLFLOW_TRACKING_URI = ""     # e.g. "https://mlflow.example.com"; empty: the kit's own MLflow (or the one set before `exakit notebook`)
MLFLOW_SERVER_LOGIN = False  # True: asks for the server's username and password (hidden)
nb.use_mlflow(MLFLOW_TRACKING_URI, MLFLOW_SERVER_LOGIN)
mlflow_ok = nb.check_mlflow()

# %% [markdown]
# ## Check the shared model directory
#
# Tests that a UDF can read the kit's model directory (needed for Python model-file scoring). `exakit model list --json` shows its paths.

# %%
bucket_ok = nb.check_bucket(connection)

# %% [markdown]
# ## Load and describe the data
#
# The same cells as the Data Scientist quickstart: pick a dataset, then approve its column map.

# %% [include] ../00_shared/data_paths.py load

# %% [include] ../00_shared/data_paths.py review

# %% [markdown]
# ## Check the label
#
# How many rows per group and the % where the label is 1. Label 1 means the outcome happened (`CANCELLED`: the order line was cancelled; `ABOVE_STORE_MEDIAN`: the store sold more that week than in its median week), not that it is good. A note under the result says what the numbers mean.

# %%
missing_roles = {missing["role"]: missing["reason"] for missing in dataset.missing}
for role, instead in (("category", "rows are counted per entity instead"),
                      ("label", "the label count is left out, and 01_train has nothing to predict until a label role is approved")):
    if role in missing_roles:
        print(f"No {role} role ({missing_roles[role]}): {instead}; the steps that need it later say so.")
GROUP_COLUMN = dataset.col("category") if dataset.has("category") else dataset.col("entity")
GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)       # columns named after the data: CATEGORY, ORDER_LINES
LABEL_PCT_HEADER = nb.name(dataset.col("label"), "PCT") if dataset.has("label") else None   # CANCELLED_PCT
LABEL_RATE_SQL = f",\n       ROUND(100 * AVG({dataset.col('label')}), 1) AS {LABEL_PCT_HEADER}" if LABEL_PCT_HEADER else ""
first_rows = nb.sql(connection, f"""
SELECT {GROUP_COLUMN} AS {GROUP_HEADER},
       COUNT(*) AS {COUNT_HEADER}{LABEL_RATE_SQL}
FROM {dataset.fact_table}
GROUP BY {GROUP_COLUMN}
ORDER BY {COUNT_HEADER} DESC
LIMIT 10""")
nb.show_sql()
overall_rate = nb.sql(connection, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({dataset.col('label')}), 1) AS PCT FROM {dataset.fact_table}") if LABEL_PCT_HEADER else None
nb.note_groups(first_rows, dataset, GROUP_HEADER, COUNT_HEADER, LABEL_PCT_HEADER, overall=(overall_rate["N"][0], overall_rate["PCT"][0]) if LABEL_PCT_HEADER else None)
first_rows

# %% [markdown]
# ## Next
#
# Open `01_train.ipynb`: it trains from the approved column map above and writes the training handoff the next notebooks use.
