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
# **Dataset:** `amazon_sales` (default), `fraud_transactions` or your own file.
#
# ![Steps 0 Check the kit, 1 Access and 2 Understand. All steps: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](journey:0,1,2)
#
# At the end you have a connection, an approved column map and a first result. No AI model is needed. Kit commands run from these cells, so you do not need a terminal.

# %% [markdown]
# ## Step 0 · Check the kit
#
# Shows what is installed and running: the database, each add-on and the loaded datasets. It changes nothing.
#
# The next cell lists other kit commands. Each runs here, with its log in the cell.

# %%
import exakit.nb as nb

kit_state = nb.kit_check()

# %%
# Things you would otherwise do in a terminal - take the # off one line and run the cell; its log shows here.
# nb.exakit("update")                            # bring the kit and its add-ons up to date
# nb.exakit("marketplace", "dash-server")        # add an add-on (Share, step 8, needs this one)
# nb.exakit("data-load", "fraud_transactions")   # load another of the kit's datasets
# nb.exakit("logs")                              # every log the kit keeps
# nb.exakit("mcp-setup", env={"EXAKIT_MCP_CLIENTS": "claude"})   # connect an AI client to the database

# %% [markdown]
# ## Step 1 · Access the data
#
# Starts a workflow, connects to the database and loads a dataset: a practice dataset, your own file or a connected source.

# %% [markdown]
# ### Start a workflow
#
# The workflow gives one ID to every query and decision below. The next notebooks continue it. You do not copy anything.

# %%
import os
import exakit.nb as nb

workflow_id = nb.workflow("data-scientist-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
print(f"Workflow {workflow_id}: every step below is recorded under it.")

# %% [include] ../00_shared/data_paths.py connect

# %% [include] ../00_shared/data_paths.py load

# %% [markdown]
# ## Step 2 · Understand the data
#
# You approve the column map: the key, the date, the groups and the outcome. The kit proposes it and shows the least certain columns first. Every later step reads this map, so the same notebooks run on any table.

# %% [include] ../00_shared/data_paths.py review

# %% [markdown]
# ### A first result
#
# Rows per group, and the % where the target is 1 when the map has a target. Each query shows its SQL before the result.

# %%
missing_roles = {missing["role"]: missing["reason"] for missing in dataset.missing}
GROUP_ROLE, GROUP_COLUMN = dataset.group_by()   # the category, else the entity, else the target
if GROUP_ROLE != "category":
    print(f"No category ({missing_roles.get('category', 'none approved')}): rows are counted per {GROUP_ROLE} instead.")
if "label" in missing_roles:
    print(f"No target ({missing_roles['label']}): the target rate is left out. Later steps that need it say so.")
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
# Open `01_explore` to prepare, explore, model and validate (steps 3 to 6). Then open `02_ask_your_data` (step 7) and `03_share` (steps 8 and 9). Each one continues this workflow.

