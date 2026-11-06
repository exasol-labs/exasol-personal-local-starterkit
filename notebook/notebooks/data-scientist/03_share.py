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
# **Dataset:** the one you approved last (else `amazon_sales`), `walmart_sales`, `fraud_transactions` or your own approved descriptor. **How long:** about five minutes once Dash Server is ready.
#
# Builds a dashboard on Dash Server, previews it and publishes only after you check the figures. No LLM needed.
#
# **Run first:** `exakit marketplace dash-server`, `exakit mcp-setup`, `exakit start dash-server`. Paste your workflow ID below.

# %%
import exakit.nb as nb

DATASET = None  # None: the dataset approved last in a quickstart (else amazon_sales); or "walmart_sales", "fraud_transactions", or an approved descriptor of your own
TITLE = None     # None: named after the data ("<dataset> by <column>"); or a title of your own
APP_NAME = None  # or a name of your own; the default includes the approved dataset ID and the column

DATASET = nb.chosen_dataset(DATASET)
nb.continue_workflow("share")   # the quickstart's workflow, or the last one: nothing to paste

conn = nb.connect()
ds = nb.dataset(conn, DATASET)
ds.require_approved("share")
GROUPED_BY, category = ds.group_by()   # the category, else the entity, else the target
if GROUPED_BY != "category":
    print(f"{ds.id} has no category; the dashboard counts rows per {GROUPED_BY} ({category}).")
# Everything below is named after the data: the column it counts by, and what one row is.
GROUP, COUNT = nb.name(category), nb.count_name(ds)
TITLE = TITLE or f"{ds.id} by {GROUP.lower()}"
APP_NAME = APP_NAME or (ds.id.replace("_", "-")[:30] + "-by-" + GROUP.lower().replace("_", "-"))[:60]
QUERY = f"SELECT {category} AS {GROUP}, COUNT(*) AS {COUNT} FROM {ds.fact_table} GROUP BY 1 ORDER BY {COUNT} DESC"
draft = nb.share(ds, QUERY, TITLE, APP_NAME, measure="count")
print("Query digest:", draft.query_digest)
print("Descriptor version:", ds.version)

# %% [markdown]
# ## Preview
#
# > **Why a preview first?** A dashboard is what other people will read and trust.
# > It goes up as a preview first, and you check its figures against the SQL.
# > Only after that do you publish it at its live address.
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
