# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Start an investigation with data you can explain
#
# **Dataset:** `pharma_trials` by default; `banking_complaints` or your own file can follow the same path. **How long:** about ten minutes on the first load.
#
# Imagine a team asks you to understand outcomes: which trial phases and sponsors have more terminations, or which complaint products and companies receive monetary relief. Start by checking the data and agreeing what its columns mean.
#
# **By the end:** you will have a working connection, an approved column map and a first grouped result you can explain. Run top to bottom and use this as the starting notebook for your own investigation.
#
# **Optional AI:** an LLM endpoint is optional. The connection, table-based role suggestions and first SQL query work as supplied. Later, Explore can summarize text and Ask can draft SQL with your configured model.

# %% [markdown]
# ## Keep a trail of the investigation
#
# A colleague should be able to follow a result back to the data and decisions behind it. The next cell starts a **workflow**, a record of your queries, role review and later handoffs.
#
# **Do now:** keep the printed `wf-...` identifier. Paste it into `WORKFLOW_ID` in Explore, Ask and Share when those notebooks open in separate kernels.
#
# **Technical note:** the log lives in `~/.exasol-starter-kit/workflows/<id>.jsonl`. `exakit workflow show <id>` reads it; `EXAKIT_WORKFLOW_ID` can continue it from a new kernel.

# %%
import os
import exakit.nb as nb

wid = nb.workflow("data-scientist-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
print(f"Every step below is logged under it: exakit workflow show {wid}")

# %% [include] ../00_shared/data_paths.py connect

# %% [include] ../00_shared/data_paths.py load

# %% [include] ../00_shared/data_paths.py review

# %% [markdown]
# ## Read the first answer before building a model
#
# Count the observations in each category. For Pharma these are trials by phase; for Banking they are complaints by product. The result also shows the share whose approved outcome is 1, when a label is available.
#
# **Read the result:** a large group has more records, while a high label percentage has more of the selected outcome. Those are different observations. Counts and associations alone do not explain why an outcome happened.
#
# **Technical note:** the SQL uses your role map rather than hard-coded dataset columns. Without a category it groups by entity; without a label it leaves out the outcome rate and explains the omission. `nb.show_sql()` reveals the query behind the result.

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
# ## Continue the story
#
# Open `01_explore.ipynb` to compare groups, follow outcomes over time and try a small local model. Keep the sample first; changing its `DATASET` assignment later lets you reuse the notebook with Banking or the path to your own described file.
#
# The next chapters are `02_ask_your_data.ipynb` for a reviewed question and `03_share.ipynb` for a checked dashboard on Dash Server. Bring your workflow ID along.
