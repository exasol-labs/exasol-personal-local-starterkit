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
# **Dataset:** Amazon sales or fraud transactions.
#
# Both quickstarts include these cells.

# %% [markdown] tags=["connect"]
# ### Connect
#
# Connects with the kit's saved connection and lists the schemas. The notebook holds no password.

# %% tags=["connect"]
import exakit.nb as nb

connection = nb.connect()
nb.check_connection(connection)

# %% tags=["connect"]
nb.list_schemas(connection)

# %% [markdown] tags=["load"]
# ### Choose a dataset
#
# The kit has two practice datasets:
#
# - `amazon_sales`: online fashion orders, one row per order line.
# - `fraud_transactions`: card and bank payments with a fraud label. It has repeats, gaps and placeholders on purpose.
#
# Set `SAMPLE` to one of them. The first run downloads it (internet needed). Later runs reuse it. Keep `SOURCE = None` for this walkthrough.

# %% tags=["load"]
SAMPLE = "amazon_sales"   # or "fraud_transactions", or None
sample_data = nb.load_sample(connection, SAMPLE)

# %% [markdown] tags=["load"]
# **Your own file (optional):** set `OWN_FILE` (CSV, Parquet or JSON) and `OWN_TABLE`. A missing file is skipped.

# %% tags=["load"]
OWN_FILE = "~/my-data/transactions.csv"   # .csv, .parquet or .json
OWN_TABLE = "MY_DATA.TRANSACTIONS"
own_data = nb.load_own_file(OWN_FILE, OWN_TABLE, conn=connection, missing_ok=True)

# %% [markdown] tags=["load"]
# **A connected source (optional):** set `SOURCE = "SCHEMA.TABLE"` for a virtual-schema table. `None` skips it.

# %% tags=["load"]
SOURCE = None   # e.g. "VS_SALES.ORDERS"
source_data = nb.load_source(connection, SOURCE)

# %% [markdown] tags=["load"]
# The notebook uses the source first, then your file, then the sample.

# %% tags=["load"]
chosen_data = nb.first(source_data, own_data, sample_data)

# %% [markdown] tags=["review"]
# ### Approve the column map
#
# The column map (the descriptor) gives each column a role. Every later query is built from it, so no notebook types your column names.
#
# The kit proposes the map from the data. A proposal can be wrong. In `amazon_sales`, `STATUS` gives the answer away. Check the map before any query uses it.
#
# **Roles:** `key` (one per row), `time`, `measure` (a number to add up), `category` (a few repeated values), `flag` (yes/no), `text`, `identifier` (names or codes) and `other`.
#
# **Slots:** the one column each step uses for `key`, `time`, `text`, `target` (the outcome to predict), `category` (groups to compare) and `entity` (who or what a row is about).
#
# | Dataset | `key` | `time` | `text` | `target` | `category` | `entity` |
# |---|---|---|---|---|---|---|
# | Amazon sales | `ORDER_LINE_ID` | `ORDER_DATE` | — | `CANCELLED` | `CATEGORY` | `SHIP_STATE` |
# | Fraud transactions | `ROW_ID` | — | — | `FRAUDULENT` | `TRANSACTION_TYPE` | `LOCATION` |
#
# Neither dataset has a text column. The text steps skip and say why.
#
# The kit never guesses the **target**. You choose it. Leave a slot as **—** when no column fits.
#
# **Do now:**
#
# 1. Look at *Check these first*. These are the columns the kit was least sure about.
# 2. Correct what is wrong.
# 3. Click **Approve descriptor**. No click is needed if the map is already approved and you change nothing.
# 4. Run the next cell.
#
# Approval checks the data again and warns about a column that gives the target away.
#
# In plain Python: `review.approve({"COLUMN": "role"}, {"target": "COLUMN"})`.

# %% tags=["review"]
role_review = nb.review_roles(connection, chosen_data)

# %% tags=["review"]
dataset = role_review.dataset()
nb.show_roles(dataset)
