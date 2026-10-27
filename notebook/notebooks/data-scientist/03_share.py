# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Share a checked result
#
# - **Dataset:** Pharma, Banking, or your own approved descriptor.
# - **How long:** about five minutes after the data and Dash Server are ready.
#
# This notebook prepares a live Exasol dashboard for Dash Server. Review the SQL and
# figures in the preview before promoting its revision. The dashboard uses the
# kit's read-only Exasol user; it contains no password or copied data.
#
# Start the dash-server add-on with `exakit marketplace dash-server`, then
# `exakit mcp-setup` and `exakit start`. The cells call its MCP control plane.

# %%
import exakit.nb as nb

DATASET = "pharma_trials"  # or banking_complaints or an approved descriptor of your own
TITLE = "Category overview"
APP_NAME = "category-overview"
WORKFLOW_ID = None  # Set an existing workflow id to continue it.

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
# ## Preview
#
# The notebook calls Dash Server's MCP tools. It validates the read-only profile
# and waits for a green preview health check before showing the preview URL.

# %%
DASH_TOOL = nb.dash_tools()
preview_path = draft.preview(DASH_TOOL)
print("Preview:", DASH_TOOL.url + preview_path)

# %% [markdown]
# ## Check the numbers, then publish
#
# Open the preview, compare its numbers with the SQL above and the data you
# explored. Promotion is refused until `figures_checked=True` is explicit.
# The workflow log records the same descriptor version and query digest as
# `REVISION.json` in the dashboard workspace.

# %%
FIGURES_CHECKED = False
if FIGURES_CHECKED:
    live_path = draft.confirm(DASH_TOOL, figures_checked=True)
    print("Live dashboard:", DASH_TOOL.url + live_path)
else:
    print("Open the healthy preview and check the figures before promoting.")
