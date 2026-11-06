# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown]
# # Shared start: connect, load, describe
#
# **Dataset:** Amazon sales or Walmart sales. **Run time:** about ten minutes on a first load.
#
# Both persona quickstarts include these cells.

# %% [markdown] tags=["connect"]
# ## Connect
#
# Uses the kit's saved connection, then lists the schemas. No password in the notebook.

# %% tags=["connect"]
import exakit.nb as nb

conn = nb.connect()
nb.check_connection(conn)

# %% tags=["connect"]
nb.list_schemas(conn)

# %% [markdown] tags=["load"]
# ## Choose a dataset
#
# > **What is a dataset?** One table of rows to learn from; each row is one thing that happened.
# > The kit offers three to practise on: `amazon_sales` (online fashion orders, one row per order line), `walmart_sales` (weekly sales, one row per store and week) and `fraud_transactions` (card and bank payments with a fraud label, messy on purpose: repeats, gaps and placeholders to find).
# > We start with one of these known samples so you can try every step before bringing your own data.
#
# Pick one: `SAMPLE = "amazon_sales"` (the default), `"walmart_sales"` or `"fraud_transactions"`. The first run downloads it from the kit's release (internet needed) and loads it once; after that it is reused, and the later notebooks carry on with the dataset you approve here (their `DATASET = None`). Keep `SOURCE = None` for this walkthrough.

# %% tags=["load"]
SAMPLE = "amazon_sales"   # or "walmart_sales", "fraud_transactions", or None
sample = nb.load_sample(conn, SAMPLE)

# %% [markdown] tags=["load"]
# **Your own file (optional):** set `OWN_FILE` (CSV, Parquet or JSON) and `OWN_TABLE`. A missing path is skipped.

# %% tags=["load"]
OWN_FILE = "~/my-data/transactions.csv"   # .csv, .parquet or .json
OWN_TABLE = "MY_DATA.TRANSACTIONS"
own = nb.load_own_file(OWN_FILE, OWN_TABLE, conn=conn, missing_ok=True)

# %% [markdown] tags=["load"]
# **A connected source (optional):** set `SOURCE = "SCHEMA.TABLE"` for a virtual-schema table. `None` skips it.

# %% tags=["load"]
SOURCE = None   # e.g. "VS_SALES.ORDERS"
source = nb.load_source(conn, SOURCE)

# %% [markdown] tags=["load"]
# The data used from here on: the source, else your file, else the sample.

# %% tags=["load"]
ds = nb.first(source, own, sample)

# %% [markdown] tags=["review"]
# ## Approve the column map
#
# > **What is the descriptor?** A short map of the table, also called the column map: which column plays which part - the key, the time, the groups to compare (category), the outcome to predict (target).
# > Every later query is written from this map, so no notebook has your column names typed in.
# > It is saved with a version number, so each result says which map it came from.
#
# > **Why approve it?** The kit proposes the map from the data, and a guess can be wrong: in `amazon_sales`, `STATUS` says `Cancelled` on exactly the cancelled lines, so it gives the answer away.
# > A person checks the map once and approves it before any query runs on it.
# > That way every number later rests on choices you have seen and agreed to.
#
# The kit suggests the map from the data and shows why. It has two parts.
#
# **1. A role for every column**, one of eight: `key` (one per row), `time`, `measure` (a number to add up), `category` (a few repeated values), `flag` (yes/no), `text`, `identifier` (names or codes, never grouped) and `other`.
#
# **2. The slots**: the one column the notebooks use for each job - `key` (one row), `time` (trends), `text` (words to explore), `target` (the outcome to predict), `category` (groups to compare) and `entity` (who or what a row is about). The datasets the kit ships with their map approved:
#
# | Dataset | `key` | `time` | `text` | `target` | `category` | `entity` |
# |---|---|---|---|---|---|---|
# | Amazon sales | `ORDER_LINE_ID` | `ORDER_DATE` | — | `CANCELLED` | `CATEGORY` | `SHIP_STATE` |
# | Walmart sales | `SALES_ID` | `WEEK_DATE` | — | `ABOVE_STORE_MEDIAN` | `STORE` | — |
#
# Neither has a text column, so the steps that read text skip and say why. Your own file: the picker below proposes its map from the data.
#
# The **target** matters most: the kit never guesses it, you choose it. Leave a slot as **—** when no column fits.
#
# **Do now:** check the dropdowns, click **Approve descriptor**, then run the next cell. If the map is already approved and you change nothing, no click is needed. The later notebooks use this approved map.
#
# Plain Python: `review.approve({"COLUMN": "role"}, {"target": "COLUMN"})`.

# %% tags=["review"]
review = nb.review_roles(conn, ds)

# %% tags=["review"]
ds = review.dataset()
nb.show_roles(ds)
