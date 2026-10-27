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
# `exakit mcp-setup` and `exakit start`. In your AI client, run the MCP requests
# prepared below. The tool adapter must call the registered `dash-server` tools.

# %%
import exakit.nb as nb

DATASET = "pharma_trials"  # or banking_complaints or an approved descriptor of your own
TITLE = "Category overview"
APP_NAME = "category-overview"

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
# Ask your AI client to run `draft.requests()` through its registered Dash Server
# MCP control plane, or pass its tool-call adapter below. The adapter accepts
# `(tool_name, arguments)` and returns the MCP result. Read-only profile
# validation and a green preview health check are required.

# %%
DASH_TOOL = None  # Set to your client's registered Dash Server MCP tool adapter.
if DASH_TOOL is not None:
    preview_path = draft.preview(DASH_TOOL)
    print("Preview:", preview_path)
else:
    print("Run these requests with the dash-server MCP tools in your AI client:")
    for tool_name, arguments in draft.requests():
        print(tool_name, arguments if tool_name != "app_put_files" else "(app.py, SQL and revision metadata from draft.files)")

# %% [markdown]
# ## Check the numbers, then publish
#
# Open the preview, compare its numbers with the SQL above and the data you
# explored. Promotion is refused until `figures_checked=True` is explicit.
# The workflow log records the same descriptor version and query digest as
# `REVISION.json` in the dashboard workspace.

# %%
FIGURES_CHECKED = False
if DASH_TOOL is not None and FIGURES_CHECKED:
    live_path = draft.confirm(DASH_TOOL, figures_checked=True)
    print("Live dashboard:", live_path)
else:
    print("Open the healthy preview and check the figures before promoting.")
