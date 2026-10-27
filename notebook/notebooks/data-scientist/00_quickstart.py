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
# - **How long:** about ten minutes, most of it loading the sample the first time (seconds after that).
#
# Run the cells top to bottom. The notebook is already connected: there is no host, user or password in it.

# %% [markdown]
# ## One workflow id on everything
#
# The first cell starts a **workflow**: every step below - each query, the role proposal and its approval, a trace -
# appends one line carrying this id to `~/.exasol-starter-kit/workflows/<id>.jsonl`, so a result can be traced back
# through every step that made it (`exakit workflow show <id>`). Copy the printed `wf-...` id into `WORKFLOW_ID`
# in Explore, Ask and Share: Jupyter opens each notebook in a separate kernel. A kernel started with
# `EXAKIT_WORKFLOW_ID` already set also continues that workflow.

# %%
import os
import exakit.nb as nb

wid = nb.workflow("data-scientist-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
print(f"Every step below is logged under it: exakit workflow show {wid}")

# %% [include] ../00_shared/data_paths.py connect

# %% [include] ../00_shared/data_paths.py load

# %% [include] ../00_shared/data_paths.py review

# %% [markdown]
# ## A first query
#
# Rows per category, built from the descriptor's roles - the same query on any dataset. `nb.show_sql()` prints the
# statement behind the result. A role no column fits (the descriptor's `missing`, with the profiler's reason) is
# not guessed: without a category the rows are counted per entity, without a label the label rate is left out, and
# the cell says so.

# %%
skipped = {m["role"]: m["reason"] for m in ds.missing}
for role, instead in (("category", "rows are counted per entity instead"), ("label", "the label rate is left out")):
    if role in skipped:
        print(f"No {role} role ({skipped[role]}): {instead}; the steps that need it later say so.")
BY = ds.col("category") if ds.has("category") else ds.col("entity")
LABEL_PCT = f",\n       ROUND(100 * AVG({ds.col('label')}), 1) AS LABEL_1_PCT" if ds.has("label") else ""
first_rows = nb.sql(conn, f"""
SELECT {BY} AS CATEGORY,
       COUNT(*) AS N{LABEL_PCT}
FROM {ds.fact_table}
GROUP BY {BY}
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
