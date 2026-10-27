# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Quickstart: container, MLflow, bucket directory, data in
#
# - **Dataset:** the Pharma sample (`pharma_trials`, ClinicalTrials.gov studies) unless you pick another below: the
#   Banking sample (`banking_complaints`), your own CSV, Parquet or JSON file, or a table in a connected source.
# - **What must be loaded:** nothing beforehand. The sample-dataset cell loads it with `exakit data-load` the first
#   time. Training needs a Python container in the database: `exakit udf-use default` (the `udf-devkit` add-on).
# - **How long:** about five minutes, most of it loading the sample the first time.
#
# First the three things training depends on, one cell each: each prints `ok` with what it found, or `FAIL` with the
# reason and the fix. Then the same loader cells as the Data Scientist's quickstart.

# %% [markdown]
# ## One workflow id on everything
#
# The first cell starts a **workflow**: every step below - each check, each query, the role proposal and its approval -
# appends one line carrying this id to `~/.exasol-starter-kit/workflows/<id>.jsonl`, and `01_train` tags its MLflow run
# with it (`exakit workflow show <id>`). A kernel started with `EXAKIT_WORKFLOW_ID` set - the Data Scientist's, say -
# continues that workflow instead of starting one.

# %%
import os
import exakit.nb as nb

wid = nb.workflow("ml-engineer-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
print(f"Every step below is logged under it: exakit workflow show {wid}")

# %% [markdown]
# ## Which container trains
#
# A training UDF runs on a Python container in the database, named by its **alias**. The `udf-devkit` add-on installs
# two: `exakit udf-use default` puts the kit's pre-built one (scikit-learn, pandas and numpy pinned) in as
# `PYTHON3_ML`; `exakit udf-setup` installs the official `PYTHON3`. This one assignment is the alias the container
# check below and `01_train` use. Its default reads what the kit recorded as installed, `PYTHON3_ML` before `PYTHON3`
# (`EXAKIT_UDF_CONTAINER` overrides it); with none installed it stops here and names the fix.

# %%
CONTAINER = nb.ml_train.udf_container()   # or "PYTHON3_ML", "PYTHON3", or the alias of a container you installed
print(f"container alias: {CONTAINER}")

# %% [include] ../00_shared/data_paths.py connect

# %% [markdown]
# ## The container answers the smoke UDF
#
# A small Python UDF runs on the container behind `CONTAINER` and reports Python and the packages the training UDF
# needs. A `FAIL` line names the alias it probed and the command that installs that very container.

# %%
container_ok = nb.check_container(conn, alias=CONTAINER)

# %% [markdown]
# ## The MLflow server is reachable
#
# `exakit mlflow start` runs the kit's local server; `exakit mlflow url` shows its address. Set
# `MLFLOW_TRACKING_URI` before `exakit notebook` to use another server instead. If neither is running, runs still
# go to the kit's local store under `~/.exasol-starter-kit/mlflow/`.

# %%
mlflow_ok = nb.check_mlflow()

# %% [markdown]
# ## The bucket directory is where the kit expects it
#
# On a local deployment the database's bucket is a folder on this computer, read by UDFs under `/buckets`. The kit
# names it (`exakit model list --json`); this checks the folder is there and that a UDF sees it.

# %%
bucket_ok = nb.check_bucket(conn)

# %% [include] ../00_shared/data_paths.py load

# %% [include] ../00_shared/data_paths.py review

# %% [markdown]
# ## A first query
#
# Rows and positive labels per category, built from the descriptor's roles - the label is what `01_train` learns to
# predict. A role no column fits (the descriptor's `missing`, with the profiler's reason) is not guessed: without a
# category the rows are counted per entity, without a label the label count is left out, and the cell says so.

# %%
skipped = {m["role"]: m["reason"] for m in ds.missing}
for role, instead in (("category", "rows are counted per entity instead"),
                      ("label", "the label count is left out, and 01_train has nothing to predict until a label role is approved")):
    if role in skipped:
        print(f"No {role} role ({skipped[role]}): {instead}; the steps that need it later say so.")
BY = ds.col("category") if ds.has("category") else ds.col("entity")
LABEL_1 = f",\n       SUM({ds.col('label')}) AS LABEL_1" if ds.has("label") else ""
first_rows = nb.sql(conn, f"""
SELECT {BY} AS CATEGORY,
       COUNT(*) AS N{LABEL_1}
FROM {ds.fact_table}
GROUP BY {BY}
ORDER BY N DESC
LIMIT 10""")
nb.show_sql()
first_rows

# %% [markdown]
# ## Next: `01_train.ipynb`
#
# Open `01_train.ipynb` in this folder: features in SQL from these roles, a scikit-learn classifier trained inside the
# database, and the run in your MLflow with its metrics, training SQL and model. Run the Data Scientist's
# `01_explore.ipynb` first to write the handoff. Then set the one DATASET assignment in `01_train` to the dataset id
# or your file's path.
