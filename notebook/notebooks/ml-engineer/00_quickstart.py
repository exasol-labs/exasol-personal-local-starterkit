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
# **Dataset:** `amazon_sales` by default; `walmart_sales` or your own file also work. **How long:** about five minutes once runtimes are installed.
#
# Checks the database Python runtime, MLflow and the shared model directory, then loads and describes the data.
#
# **Run first:** `exakit udf-use default` (installs the ML runtime; a container install can restart the database).

# %% [markdown]
# ## Start a workflow
#
# One ID links data, checks and model runs. To continue an earlier log, start the kernel with `EXAKIT_WORKFLOW_ID`.

# %%
import os
import exakit.nb as nb

wid = nb.workflow("ml-engineer-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
print(f"Every step below is logged under it: exakit workflow show {wid}")

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
container_ok = nb.check_container(conn, alias=CONTAINER)

# %% [markdown]
# ## Check MLflow
#
# > **What is MLflow tracking?** A logbook for model training: every run's settings, scores and model file.
# > With it you can compare two runs side by side and find the exact model a result came from.
# > By default the runs are kept on this computer, in the kit's own MLflow.
#
# Shows where runs are recorded. Browser UI: `exakit mlflow start`, then `exakit mlflow url`. `MLFLOW_TRACKING_URI` overrides.

# %%
mlflow_ok = nb.check_mlflow()

# %% [markdown]
# ## Check the shared model directory
#
# Tests that a UDF can read the kit's model directory (needed for Python model-file scoring). `exakit model list --json` shows its paths.

# %%
bucket_ok = nb.check_bucket(conn)

# %% [include] ../00_shared/data_paths.py load

# %% [include] ../00_shared/data_paths.py review

# %% [markdown]
# ## Check the label
#
# How many rows per group and the % where the label is 1. Label 1 means the outcome happened (`CANCELLED`: the order line was cancelled; `ABOVE_STORE_MEDIAN`: the store sold more that week than in its median week), not that it is good. A note under the result says what the numbers mean.

# %%
skipped = {m["role"]: m["reason"] for m in ds.missing}
for role, instead in (("category", "rows are counted per entity instead"),
                      ("label", "the label count is left out, and 01_train has nothing to predict until a label role is approved")):
    if role in skipped:
        print(f"No {role} role ({skipped[role]}): {instead}; the steps that need it later say so.")
BY = ds.col("category") if ds.has("category") else ds.col("entity")
GROUP, COUNT = nb.name(BY), nb.count_name(ds)       # columns named after the data: CATEGORY, ORDER_LINES
PCT = nb.name(ds.col("label"), "PCT") if ds.has("label") else None   # CANCELLED_PCT
RATE = f",\n       ROUND(100 * AVG({ds.col('label')}), 1) AS {PCT}" if PCT else ""
first_rows = nb.sql(conn, f"""
SELECT {BY} AS {GROUP},
       COUNT(*) AS {COUNT}{RATE}
FROM {ds.fact_table}
GROUP BY {BY}
ORDER BY {COUNT} DESC
LIMIT 10""")
nb.show_sql()
overall = nb.sql(conn, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({ds.col('label')}), 1) AS PCT FROM {ds.fact_table}") if PCT else None
nb.note_groups(first_rows, ds, GROUP, COUNT, PCT, overall=(overall["N"][0], overall["PCT"][0]) if PCT else None)
first_rows

# %% [markdown]
# ## Next
#
# Open `01_train.ipynb`: it trains from the approved column map above and writes the training handoff the next notebooks use.
