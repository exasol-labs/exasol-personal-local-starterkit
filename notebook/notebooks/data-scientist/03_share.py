# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Share a result another person can inspect
#
# **Dataset:** Pharma, Banking or your own approved descriptor. **How long:** about five minutes after Dash Server is ready.
#
# You have checked a category comparison and want a colleague to see a live result. This notebook prepares a dashboard, gives you a preview, and publishes only after you confirm the figures.
#
# **By the end:** you will have a Dash Server URL linked to its SQL, descriptor version and workflow. No LLM endpoint is required. You can use this small dashboard as the base for a larger question after validating the first result.
#
# **Run first:** `exakit marketplace dash-server`, `exakit mcp-setup`, then `exakit start dash-server`. Paste the earlier workflow ID below. Choose a distinct `APP_NAME` for a separate investigation.

# %%
import exakit.nb as nb

DATASET = "pharma_trials"  # or banking_complaints or an approved descriptor of your own
TITLE = "Category overview"
APP_NAME = "category-overview"
WORKFLOW_ID = None  # paste the quickstart's wf-... id to continue its log

if WORKFLOW_ID:
    nb.workflow(resume=WORKFLOW_ID)
elif not nb.current_workflow():
    nb.workflow("share-" + APP_NAME)

conn = nb.connect()
ds = nb.dataset(conn, DATASET)
ds.require_approved("share")
category = ds.col("category")
QUERY = f"SELECT {category} AS CATEGORY, COUNT(*) AS N FROM {ds.fact_table} GROUP BY 1 ORDER BY N DESC"
draft = nb.share(ds, QUERY, TITLE, APP_NAME)
print("Query digest:", draft.query_digest)
print("Descriptor version:", ds.version)

# %% [markdown]
# ## See what a colleague would see before publishing
#
# Open the preview URL printed by the next cell. Compare its categories and counts with the SQL and the data you explored. Check that the dashboard title describes the result fairly.
#
# **Technical note:** the notebook drives Dash Server's MCP control plane, checks its read-only database profile and waits for a healthy preview. The draft carries the query digest and approved descriptor version for later tracing.

# %%
DASH_TOOL = nb.dash_tools()
preview_path = draft.preview(DASH_TOOL)
print("Preview:", DASH_TOOL.url + preview_path)

# %% [markdown]
# ## Publish after you have checked the figures
#
# Leave `FIGURES_CHECKED = False` while reviewing the preview. Set it to `True` only when the displayed result matches the query, then run the last cell. Open the live URL and keep it with your workflow ID.
#
# **Technical note:** promotion is a separate action from preview. The workflow log and dashboard revision metadata retain the same descriptor version and query digest. A healthy page proves it runs; your comparison establishes that it shows the intended figures.
#
# **Make it your own:** change the approved dataset and reviewed query, preview the new result, and validate it before publishing another revision.

# %%
FIGURES_CHECKED = False
if FIGURES_CHECKED:
    live_path = draft.confirm(DASH_TOOL, figures_checked=True)
    print("Live dashboard:", DASH_TOOL.url + live_path)
else:
    print("Open the healthy preview and check the figures before promoting.")
