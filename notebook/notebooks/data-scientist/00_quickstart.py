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
# Logs your queries and decisions. Keep the printed `wf-...` ID: paste it into `WORKFLOW_ID` in Explore, Ask and Share.

# %%
import os
import exakit.nb as nb

wid = nb.workflow("data-scientist-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
print(f"Every step below is logged under it: exakit workflow show {wid}")

# %% [include] ../00_shared/data_paths.py connect

# %% [include] ../00_shared/data_paths.py load

# %% [include] ../00_shared/data_paths.py review

# %% [markdown]
# ## First result
#
# How many rows per group and, when the column map names a label, the % where it is 1. A note under the result says what the numbers mean.

# %%
skipped = {m["role"]: m["reason"] for m in ds.missing}
GROUPED_BY, BY = ds.group_by()   # the category, else the entity, else the target
if GROUPED_BY != "category":
    print(f"No category role ({skipped.get('category', 'none approved')}): rows are counted per {GROUPED_BY} instead.")
if "label" in skipped:
    print(f"No label role ({skipped['label']}): the label rate is left out; the steps that need it later say so.")
GROUP, COUNT = nb.name(BY), nb.count_name(ds)       # columns named after the data: CATEGORY, ORDER_LINES
PCT = nb.name(ds.col("label"), "PCT") if ds.has("label") and GROUPED_BY != "label" else None   # CANCELLED_PCT
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
# Open `01_explore.ipynb`, then `02_ask_your_data.ipynb` and `03_share.ipynb`. Bring your workflow ID.
