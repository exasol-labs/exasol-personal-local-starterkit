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
#   time. Training needs a Python container in the database: `exakit udf-setup` (the `udf-devkit` add-on).
# - **How long:** about five minutes, most of it loading the sample the first time.
#
# First the three things training depends on, one cell each: each prints `ok` with what it found, or `FAIL` with the
# reason and the fix. Then the same loader cells as the Data Scientist's quickstart.

# %% [include] ../00_shared/data_paths.py connect

# %% [markdown]
# ## The container answers the smoke UDF
#
# A small Python UDF runs on the database's Python container (`PYTHON3`) and reports Python and the packages the
# training UDF needs.

# %%
container_ok = nb.check_container(conn)

# %% [markdown]
# ## The MLflow server is reachable
#
# `MLFLOW_TRACKING_URI`, set before `exakit notebook`, names your MLflow server; without it the runs go to a local
# store in the `mlflow` folder beside the notebook, which needs no server.

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
# Rows and label rate per category, built from the descriptor's roles - the label is what `01_train` learns to predict.

# %%
first_rows = nb.sql(conn, f"""
SELECT {ds.col("category")} AS CATEGORY,
       COUNT(*) AS N,
       SUM({ds.col("label")}) AS LABEL_1
FROM {ds.fact_table}
GROUP BY {ds.col("category")}
ORDER BY N DESC
LIMIT 10""")
nb.show_sql()
first_rows

# %% [markdown]
# ## Next: `01_train.ipynb`
#
# Open `01_train.ipynb` in this folder: features in SQL from these roles, a scikit-learn classifier trained inside the
# database, and the run in your MLflow with its metrics, training SQL and model. It runs on the dataset its first
# assignment names (`pharma_trials` as it ships); set it to the dataset id, or to your file's path, to use what you
# loaded here.
