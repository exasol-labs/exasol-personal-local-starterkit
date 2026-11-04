# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Share a dashboard
#
# **Dataset:** Esophageal, Banking or your own approved descriptor. **How long:** about five minutes once Dash Server is ready.
#
# Builds a dashboard on Dash Server, previews it and publishes only after you check the figures. No LLM needed.
#
# **Run first:** `exakit marketplace dash-server`, `exakit mcp-setup`, `exakit start dash-server`. Paste your workflow ID below.

# %%
import exakit.nb as nb

DATASET = "esophageal_posts"  # or banking_complaints or an approved descriptor of your own
TITLE = "Category overview"
APP_NAME = None  # or a name of your own; the default includes the approved dataset ID
WORKFLOW_ID = None  # paste the quickstart's wf-... id to continue its log

if WORKFLOW_ID:
    nb.workflow(resume=WORKFLOW_ID)
elif not nb.current_workflow():
    nb.workflow("share")

conn = nb.connect()
ds = nb.dataset(conn, DATASET)
ds.require_approved("share")
APP_NAME = APP_NAME or ds.id.replace("_", "-")[:40] + "-category-overview"
GROUPED_BY, category = ds.group_by()   # the category, else the entity, else the target
if GROUPED_BY != "category":
    print(f"{ds.id} has no category; the dashboard counts rows per {GROUPED_BY} ({category}).")
QUERY = f"SELECT {category} AS CATEGORY, COUNT(*) AS N FROM {ds.fact_table} GROUP BY 1 ORDER BY N DESC"
draft = nb.share(ds, QUERY, TITLE, APP_NAME, measure="count")
print("Query digest:", draft.query_digest)
print("Descriptor version:", ds.version)

# %% [markdown]
# ## Preview
#
# Open the printed URL. Check the categories and counts match your SQL, and that the filters update both charts and the table.

# %%
DASH_TOOL = nb.dash_tools()
preview_path = draft.preview(DASH_TOOL)
print("Preview:", DASH_TOOL.url + preview_path)

# %% [markdown]
# ## Publish
#
# Set `FIGURES_CHECKED = True` only when the preview matches the query, then run the cell. Keep the live URL with your workflow ID.

# %%
FIGURES_CHECKED = False
if FIGURES_CHECKED:
    live_path = draft.confirm(DASH_TOOL, figures_checked=True)
    print("Live dashboard:", DASH_TOOL.url + live_path)
else:
    print("Open the healthy preview and check the figures before promoting.")
