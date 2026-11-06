# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Data Scientist quickstart
#
# **Dataset:** `amazon_sales` (default), `walmart_sales`, `fraud_transactions` or your own file. **How long:** about ten minutes on the first load.
#
# You end with a connection, an approved column map and a first grouped result. No LLM needed.

# %% [markdown]
# ## Start a workflow
#
# Logs your queries and decisions under one ID. Explore, Ask and Share continue it on their own: nothing to copy.

# %%
import os
import exakit.nb as nb

workflow_id = nb.workflow("data-scientist-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
print(f"Every step below is logged under it: exakit workflow show {workflow_id}")

# %% [include] ../00_shared/data_paths.py connect

# %% [include] ../00_shared/data_paths.py load

# %% [include] ../00_shared/data_paths.py review

# %% [markdown]
# ## First result
#
# How many rows per group and, when the column map names a label, the % where it is 1. A note under the result says what the numbers mean.

# %%
missing_roles = {missing["role"]: missing["reason"] for missing in dataset.missing}
GROUP_ROLE, GROUP_COLUMN = dataset.group_by()   # the category, else the entity, else the target
if GROUP_ROLE != "category":
    print(f"No category role ({missing_roles.get('category', 'none approved')}): rows are counted per {GROUP_ROLE} instead.")
if "label" in missing_roles:
    print(f"No label role ({missing_roles['label']}): the label rate is left out; the steps that need it later say so.")
GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)       # columns named after the data: CATEGORY, ORDER_LINES
LABEL_PCT_HEADER = nb.name(dataset.col("label"), "PCT") if dataset.has("label") and GROUP_ROLE != "label" else None   # CANCELLED_PCT
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
# Open `01_explore.ipynb`, then `02_ask_your_data.ipynb` and `03_share.ipynb`. Bring your workflow ID.
