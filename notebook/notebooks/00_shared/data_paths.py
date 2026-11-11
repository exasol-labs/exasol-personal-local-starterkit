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
# These notebooks use two practice datasets:
#
# - `amazon_sales`: online fashion orders, one row per order line.
# - `fraud_transactions`: card and bank payments with a fraud label. It has repeats, gaps and placeholders on purpose.
#
# Set `SAMPLE` to one of them. The first run downloads it (internet needed). Later runs reuse it. Keep `SOURCE = None` for this walkthrough.

# %% tags=["load"]
SAMPLE = "amazon_sales"   # or "fraud_transactions", or None
sample_data = nb.load_sample(connection, SAMPLE)

# %% [markdown] tags=["load"]
# **Load your own data (optional):** set `MY_DATA` to a CSV, Parquet or JSON file, or to a folder of them. Empty skips it.
#
# Each file becomes one table named after the file, in a schema named after its folder (`MY_SCHEMA` names another). A folder loads like `exakit data-load`. Running the cell again skips what is already loaded.

# %% tags=["load"]
MY_DATA = ""     # a file or a folder, e.g. "~/sales-data/orders.csv" or "~/sales-data" (Excel works too)
MY_SCHEMA = ""   # the schema, e.g. "SALES" (empty: the folder's name, ~/sales-data -> SALES_DATA)
MY_TABLE = ""    # or a table already in the database, e.g. "MY_DATA.ORDERS" (nb.data_map lists them)
own_data = (nb.use_table(connection, MY_TABLE) if MY_TABLE
            else nb.load_own_file(MY_DATA, MY_SCHEMA, conn=connection, missing_ok=True))

# %% [markdown] tags=["load"]
# **An external source (optional):** a table in Postgres, MySQL, Snowflake and others, read live through a virtual schema. Nothing is copied.
#
# 1. Not connected yet? Pick `CONNECTOR`; `connector_forms[CONNECTOR]["inputs"]` lists what `exakit connect` asks for it (the same form as the card). Fill in `SOURCE_NAME` and `SOURCE_INPUTS` by those names, or `{"url": ...}` with its connection string. On a Mac, use `192.168.64.1` for a database on this computer.
# 2. Test it: the kit checks the inputs and this computer tries the source's host and port. Nothing is changed and no password is needed.
# 3. Connect it: the password is asked in a hidden box and goes to the kit only.
# 4. Set `SOURCE` to its table, `"VS_<NAME>.<TABLE>"`. `"VS_<NAME>"` alone lists the tables. `None` skips it.

# %% tags=["load"]
connectors = nb.connectors()   # every kind of source CONNECTOR takes: [c["id"] for c in connectors]
connector_forms = {c["id"]: nb.connector_inputs(c["id"]) for c in connectors}   # what each asks, required ones marked
CONNECTOR = ""     # e.g. "postgresql", "mysql", "snowflake" (empty: already connected, or no source)
SOURCE_NAME = ""   # e.g. "sales": the tables appear as VS_SALES
SOURCE_INPUTS = {}  # e.g. {"host": "192.168.64.1", "database": "shop", "user": "reader"}, or {"url": "postgres://reader@192.168.64.1:5432/shop"}

# %% tags=["load"]
source_test = nb.test_source(CONNECTOR, SOURCE_NAME, **SOURCE_INPUTS) if CONNECTOR else None

# %% tags=["load"]
connected = nb.connect_source(CONNECTOR, SOURCE_NAME, **SOURCE_INPUTS) if CONNECTOR else None

# %% tags=["load"]
SOURCE = None   # e.g. "VS_SALES.ORDERS" (None after a connect above: the new source's tables)
source_data = nb.load_source(connection, SOURCE or connected)

# %% [markdown] tags=["load"]
# The notebook uses the source first, then your file, then the sample.

# %% tags=["load"]
chosen_data = nb.first(source_data, own_data, sample_data)

# %% [markdown] tags=["load"]
# ### All your data in one map
#
# Every table by origin: external source, your data, sample data. Each shows its rows, its column map and the roles in it. *Links* lists columns that join tables, across origins too. A `possible` link only shares a name: check it before a join.

# %% tags=["load"]
nb.data_map(connection)

# %% [markdown] tags=["review"]
# ### Approve the column map
#
# The column map (the descriptor) gives each column a role. Every later query is built from it, so no notebook types your column names.
#
# The kit proposes the map from the data. A proposal can be wrong. In `amazon_sales`, `STATUS` gives the answer away. The kit warns about it when you approve, and the model leaves it out. Check the map before any query uses it.
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
# The kit never guesses the **target**. You choose it. Leave a slot as "—" when no column fits.
#
# **Do now:**
#
# 1. Look at *Check these first*. These are the columns the kit was least sure about.
# 2. Correct what is wrong.
# 3. Click **Approve column map**. No click is needed if the map is already approved and you change nothing.
# 4. Run the next cell.
#
# Approval checks the data again and warns about a column that gives the target away.
#
# In plain Python: `role_review.approve({"COLUMN": "role"}, {"target": "COLUMN"})`.

# %% tags=["review"]
role_review = nb.review_roles(connection, chosen_data)

# %% tags=["review"]
# Or approve in code - what Approve in the column map card does: the roles you change, {"COLUMN": "role"}, and the
# slots, {"target": "COLUMN"}. Empty: the picker above (or an approval already saved) stands.
ROLE_CHANGES = {}
SLOT_CHANGES = {}
if ROLE_CHANGES or SLOT_CHANGES:
    role_review.approve(ROLE_CHANGES or None, SLOT_CHANGES or None)

# %% tags=["review"]
dataset = role_review.dataset()
nb.show_roles(dataset)

# %% tags=["review"]
leaking = nb.leakage_check(connection, dataset)            # columns that give the outcome away: left out of a model
versions = nb.column_map_versions(dataset.id)              # every saved version; approving one's roles again restores it

# %% [markdown] tags=["review"]
# ### Check the map again
#
# The same map, read again after the approval. The table you approved now shows `approved vN, published` and every slot by name. `not published` means the roles are saved but agents cannot read them yet: approve again to publish.

# %% tags=["review"]
dataset  # read after the approval above, so this map shows it
nb.data_map(connection)
