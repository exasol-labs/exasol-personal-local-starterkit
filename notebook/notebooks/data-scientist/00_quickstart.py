# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Quickstart: connected, data in, a first query
#
# - **Dataset:** the Pharma sample (`pharma_trials`, ClinicalTrials.gov studies) unless you pick another below: the
#   Banking sample (`banking_complaints`), your own CSV, Parquet or JSON file, or a table in a connected source.
# - **What must be loaded:** nothing beforehand. The sample-dataset cell loads it with `exakit data-load` the first
#   time; your own file is loaded by its cell.
# - **How long:** about five minutes, most of it loading the sample the first time (seconds after that).
#
# Run the cells top to bottom. The notebook is already connected: there is no host, user or password in it.

# %% [include] ../00_shared/data_paths.py connect

# %% [include] ../00_shared/data_paths.py load

# %% [markdown]
# ## A first query
#
# Rows per category, built from the descriptor's roles - the same query on any dataset. `nb.show_sql()` prints the
# statement behind the result.

# %%
first_rows = nb.sql(conn, f"""
SELECT {ds.col("category")} AS CATEGORY,
       COUNT(*) AS N,
       ROUND(100 * AVG({ds.col("label")}), 1) AS LABEL_1_PCT
FROM {ds.fact_table}
GROUP BY {ds.col("category")}
ORDER BY N DESC
LIMIT 10""")
nb.show_sql()
first_rows

# %% [markdown]
# ## Next: `01_explore.ipynb`
#
# Open `01_explore.ipynb` in this folder: the landscape of this dataset with the SQL visible, a small model on this
# computer, and a text step with your own model, traced to your Langfuse. It runs on the dataset its first assignment
# names (`pharma_trials` as it ships); to run it on what you loaded here, set that one assignment to the dataset id, or
# to your file's path - its roles were saved beside it.
