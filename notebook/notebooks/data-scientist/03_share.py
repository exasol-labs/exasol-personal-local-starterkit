# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown] tags=["exakit-guide-hint"]
# <div class="guide-start-hint">
#
# **Step 4 · Share and hand off.** Click into the cell below and press **Shift + Enter** to open it: a dashboard preview, its publication and the hand-off bundle. Its **Guided / Code** switch, top right, shows the code behind this page.
#
# </div>

# %% tags=["exakit-guide", "skip-ci"]
import exakit.guide as guide

guide.share()

# %% [markdown] tags=["exakit-code-start"]
# # The code behind this page
#
# <div class="guide-code-start"></div>
#
# The same steps as the cards above, as cells you can read, change and run one by one. **Code**, at the top right of a card, opens this section; **Guided** closes it again.

# %% [markdown]
# ## Share the insight and hand it off
#
# **Dataset:** the one you approved last (else `amazon_sales`), `fraud_transactions` or your own approved descriptor.
#
# ![Steps 8 Share and 9 Hand off of nine: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](journey:8,9)
#
# Builds a dashboard on Dash Server, then packs the work into one folder. No AI model is needed. This notebook installs and starts Dash Server.

# %% [markdown]
# `DATASET`: `None` is the dataset approved last. `TITLE` and `APP_NAME`: `None` names them after the data. `DASHBOARD_QUERY`: your own query for this dashboard. `APP_FILE`: your own version of the dashboard's source, saved from `nb.share_app()` and changed (keep `create_dash_app`).

# %%
import exakit.nb as nb

DATASET = None
TITLE = None
APP_NAME = None
DASHBOARD_QUERY = None
APP_FILE = None

dataset_id = nb.chosen_dataset(DATASET)
nb.continue_workflow("share")

connection = nb.connect()
dataset = nb.dataset(connection, dataset_id)
dataset.require_approved("share")
GROUP_ROLE, GROUP_COLUMN = dataset.group_by()
if GROUP_ROLE != "category":
    print(f"{dataset.id} has no category; the dashboard counts rows per {GROUP_ROLE} ({GROUP_COLUMN}).")
GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)
dashboard_title = TITLE or f"{dataset.id} by {GROUP_HEADER.lower()}"
app_name = APP_NAME or (dataset.id.replace("_", "-")[:30] + "-by-" + GROUP_HEADER.lower().replace("_", "-"))[:60]
dashboard_query = DASHBOARD_QUERY or f"SELECT {GROUP_COLUMN} AS {GROUP_HEADER}, COUNT(*) AS {COUNT_HEADER} FROM {dataset.fact_table} GROUP BY 1 ORDER BY {COUNT_HEADER} DESC"
dashboard_app = open(APP_FILE, encoding="utf-8").read() if APP_FILE else None
dashboard_draft = nb.share(dataset, dashboard_query, dashboard_title, app_name, measure="count", app=dashboard_app)
print("Query digest:", dashboard_draft.query_digest)
print("Descriptor version:", dataset.version)

# %% [markdown]
# ## Step 8 · Share the insight
#
# One checked result becomes a dashboard that others open in a browser. It goes up as a preview first. You publish it after you check the figures.

# %% [markdown]
# ### Dash Server
#
# Installs Dash Server if it is missing and starts it if it is stopped. Then prints its address. This is the same as `exakit marketplace dash-server` and `exakit start dash-server`.

# %%
dash_server_state = nb.addon_ready("dash-server")

# %% [markdown]
# ### Preview
#
# Dash Server is installed and started first when this cell runs on its own. Open the printed URL. Make sure that:
#
# - the categories and counts match your SQL;
# - the filters update both charts and the table.

# %%
dash_server = nb.dash_tools()
preview_path = dashboard_draft.preview(dash_server)
print("Preview:", dash_server.url + preview_path)

# %% [markdown]
# ### Publish
#
# Set `FIGURES_CHECKED = True` only when the preview matches the query. Then run the cell. Keep the live URL with your workflow ID.

# %%
FIGURES_CHECKED = False
if FIGURES_CHECKED:
    live_path = dashboard_draft.confirm(dash_server, figures_checked=True)
    print("Live dashboard:", dash_server.url + live_path)
else:
    print("Open the healthy preview and check the figures before promoting.")

# %% [markdown]
# ### A dashboard of several pages
#
# The answers you pinned in `02_ask_your_data` (**Pin to dashboard**, or `nb.pin`) make one dashboard: a tab per page, a tile per answer, its SQL exactly as approved. The filters on a page are the columns all its tiles return. Only the open tab is queried, its tiles in parallel, and each result is kept for five minutes, so moving between tabs and filtering does not query again. `board.move(tile, page)` and `board.remove(tile)` change it before it is shared; a preview comes first, and it goes live only after you check the figures.

# %% [markdown]
# | Setting | What it does |
# |---|---|
# | `STARTER_BOARD` | `True`: make `overview` from your approved column maps, a page per table |
# | `STARTER_RULES` | changes to how its tiles are made, such as `{"GROUPS": 5, "TOP": 10, "PERIOD": "WEEK", "MEASURE_SUM": "AVG"}`; `nb.starter_rules()` lists every rule |
# | `BOARD_NAME` | `None`: the dashboard changed last; or its name |
# | `BOARD_FIGURES_CHECKED` | `True` only after you checked the preview's figures: it goes live |
# | `MOVE_TILE`, `REMOVE_TILE` | `("a1b2c3d4", "Delivery")` moves a tile to a page; `"a1b2c3d4"` takes it off |
# | `EDIT_TILE` | `("a1b2c3d4", "SELECT ...")`: your own SQL for a tile, the one printed below, edited |
# | `UPDATE_TILES` | `True`: tiles whose SQL your data map now writes differently (listed below) take the new SQL |
# | `DASHBOARD_RULES` | changes to how the dashboard behaves, such as `{"CACHE_SECONDS": 60, "PARALLEL": 8, "FILTERS": 5}`; `nb.dashboard_rules()` lists every rule |
# | `PAGE_FILTERS` | the filters of a page, chosen by you: `{"Revenue": ["STATE", "CATEGORY"]}` |
# | `BOARD_APP_FILE` | your own version of the dashboard's source, saved from `nb.board_app()` and changed (keep `create_dash_app`) |

# %%
STARTER_BOARD = False
STARTER_RULES = {}
if STARTER_BOARD:
    board = nb.starter_board(connection, name="overview", rules=STARTER_RULES)
BOARD_NAME = None
BOARD_FIGURES_CHECKED = False
MOVE_TILE = None
REMOVE_TILE = None
EDIT_TILE = None
UPDATE_TILES = False
DASHBOARD_RULES = {}
PAGE_FILTERS = {}
BOARD_APP_FILE = None
boards = nb.boards()
if boards:
    board = nb.board(BOARD_NAME or boards[0]["name"])
    if MOVE_TILE:
        board.move(MOVE_TILE[0], MOVE_TILE[1]).save()
    if REMOVE_TILE:
        board.remove(REMOVE_TILE).save()
    if EDIT_TILE:
        board.edit(EDIT_TILE[0], EDIT_TILE[1]).save()
    if DASHBOARD_RULES:
        board.rules = {**board.rules, **DASHBOARD_RULES}
        board.save()
    for page_title, columns in PAGE_FILTERS.items():
        board.set_filters(page_title, columns).save()
    for tile in board.recheck(connection, update=UPDATE_TILES):
        if tile["state"] != "same":
            print(f"[{tile['id']}] {tile['page']} / {tile['title']}: your data map now writes it differently ({tile['state']})"
                  + (f"\n{tile['sql']}" if tile["sql"] else f": {tile['reason']}") + "\n")
    for page in board.pages:
        for tile in page["tiles"]:
            print(f"[{tile['id']}] {page['title']} / {tile['title']}\n{tile['sql']}\n")
    print(board)
    board_app = open(BOARD_APP_FILE, encoding="utf-8").read() if BOARD_APP_FILE else None
    board_draft = nb.board(board.name).share(app=board_app)
    dash_server = nb.dash_tools()
    board_preview = board_draft.preview(dash_server)
    print("Preview:", dash_server.url + board_preview)
    if BOARD_FIGURES_CHECKED:
        board_live = board_draft.confirm(dash_server, figures_checked=True)
        print("Live dashboard:", dash_server.url + board_live)
else:
    print("No answer is pinned yet: pin one in 02_ask_your_data (Pin to dashboard).")

# %% [markdown]
# ## Step 9 · Hand off
#
# Packs the work into one folder and a zip: the approved column map, the schema map if there is one, every query with its digest and row count, the dashboards, the workflow log and a README. It contains no passwords. It does not need Dash Server.

# %%
handoff = nb.handoff_bundle(connection, dataset)
handoff
