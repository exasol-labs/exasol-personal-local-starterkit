# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Start here: access and understand your data
#
# **Dataset:** `amazon_sales` (default), `walmart_sales`, `fraud_transactions` or your own file.
#
# **The journey:** 1 Access → 2 Understand → 3 Prepare → 4 Explore → 5 Model → 6 Validate → 7 Ask with AI → 8 Share → 9 Hand off. **This notebook: steps 1 and 2** (and a step 0: the kit itself, from here).
#
# You end with a connection, an approved column map and a first grouped result. No AI model needed. Everything the kit does - checking it, updating it, adding an add-on, loading data - runs from these cells, with its log shown here, so you never have to switch to a terminal.

# %% [markdown]
# ## Step 0 · The kit, from this notebook
#
# > **What is this?** The kit is the database on this computer, its add-ons and your notebooks. This cell asks it how it is doing and prints the answer: installed or not, the database, each add-on and where it runs, the datasets loaded.
# > It changes nothing. Any kit command can be run the same way: `nb.exakit("update")` brings the kit up to date, `nb.exakit("marketplace", "dash-server")` adds an add-on, `nb.exakit("logs")` shows the logs - each prints what the terminal would, as it happens.

# %%
import exakit.nb as nb

kit_state = nb.kit_check()

# %%
# Things you would otherwise do in a terminal - take the # off one line and run the cell; its log shows here.
# nb.exakit("update")                            # bring the kit and its add-ons up to date
# nb.exakit("marketplace", "dash-server")        # add an add-on (Share, step 8, needs this one)
# nb.exakit("data-load", "walmart_sales")        # load another of the kit's datasets
# nb.exakit("logs")                              # every log the kit keeps
# nb.exakit("mcp-setup", env={"EXAKIT_MCP_CLIENTS": "claude"})   # connect an AI client to the database

# %% [markdown]
# ## Step 1 · Access the data
#
# > **What happens here?** The notebook connects to the kit's database with the connection the kit saved (no password in this file), starts a *workflow* - one ID that every query and decision below is logged under - and loads a dataset: one of the kit's three, your own file, or a table from a source you connected.
# > After this step the data is in the database and this notebook can see it.

# %% [markdown]
# ### Start a workflow
#
# Logs your queries and decisions under one ID. Explore, Ask and Share continue it on their own: nothing to copy.

# %%
import os
import exakit.nb as nb

workflow_id = nb.workflow("data-scientist-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
print(f"Every step below is logged under it: exakit workflow show {workflow_id}")

# %% [include] ../00_shared/data_paths.py connect

# %% [include] ../00_shared/data_paths.py load

# %% [markdown]
# ## Step 2 · Understand the data
#
# > **What happens here?** Before any number is trusted, the notebook describes the table - what each column is, which one is the key, the date, the groups, the outcome - and you approve that description. The kit drafts it from the data and shows why; the columns it was least sure about come first.
# > Every later step reads this approved map, which is why the same notebooks run on any table.

# %% [include] ../00_shared/data_paths.py review

# %% [markdown]
# ### A first result
#
# How many rows per group and, when the column map names a label, the % where it is 1. A note under the result says what the numbers mean. Every query in these notebooks is printed before its result, so you always see the SQL.

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
# ## Next: steps 3 to 6
#
# Open `01_explore.ipynb`: prepare the data, explore it, train a small model and validate it. Then `02_ask_your_data.ipynb` (step 7) and `03_share.ipynb` (steps 8 and 9). Nothing to copy: each continues this workflow on its own.
