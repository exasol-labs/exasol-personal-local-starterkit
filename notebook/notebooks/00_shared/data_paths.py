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
# 1. Not connected yet? Pick `CONNECTOR` and paste its connection string into `SOURCE_URL`: the kit reads it as `exakit connect --url` does, and `source_reading["missing"]` says what it did not give. Put those (and any other input you want to change, by the names in `connector_forms[CONNECTOR]["inputs"]`) in `SOURCE_INPUTS`. No connection string? Leave it empty and give every input in `SOURCE_INPUTS`. On a Mac, use `192.168.64.1` for a database on this computer.
# 2. Test it: the kit checks the inputs and this computer tries the source's host and port. Nothing is changed and no password is needed.
# 3. Connect it: the password is asked in a hidden box and goes to the kit only.
# 4. Set `SOURCE` to its table, `"VS_<NAME>.<TABLE>"`. `"VS_<NAME>"` alone lists the tables. `None` skips it.

# %% tags=["load"]
connectors = nb.connectors()   # every kind of source CONNECTOR takes: [c["id"] for c in connectors]
connector_forms = {c["id"]: nb.connector_inputs(c["id"]) for c in connectors}   # what each asks, required ones marked
source_tips = nb.source_engine("catalog", "--public-ip")["events"]   # this computer's public IP, to allow at a cloud source
CONNECTOR = ""     # e.g. "postgresql", "mysql", "snowflake" (empty: already connected, or no source)
SOURCE_NAME = ""   # e.g. "sales": the tables appear as VS_SALES
SOURCE_SETTINGS = {}   # a source with several kinds in one: {"catalog": "unity", "files": "s3"} for a Lakehouse (connector_forms["lakehouse"]["tree"] lists the picks)
if CONNECTOR and SOURCE_SETTINGS:
    connector_forms[CONNECTOR] = nb.connector_inputs(CONNECTOR, **SOURCE_SETTINGS)   # what that combination asks
SOURCE_URL = ""    # its connection string, e.g. "postgres://reader@192.168.64.1:5432/shop" (a password in it is used, never shown)
source_reading = nb.read_connection_string(CONNECTOR, SOURCE_URL, **SOURCE_SETTINGS) if CONNECTOR and SOURCE_URL else None
SOURCE_INPUTS = {}  # what the string did not give (source_reading["missing"]), e.g. {"user": "reader"}; no string: every input
SOURCE_INPUTS = {**SOURCE_SETTINGS, **({"url": SOURCE_URL} if SOURCE_URL else {}), **SOURCE_INPUTS}

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
# The same map, read again after the approval. The table you approved now shows `approved vN, in semantic model <name>` and every slot by name. `not in a semantic model yet` means the roles are saved but agents cannot read them yet: approve again to publish.

# %% tags=["review"]
dataset  # read after the approval above, so this map shows it
nb.data_map(connection)

# %% [markdown] tags=["review"]
# ### Semantic views: one model over all your data
#
# Approving a column map published it in **Exasol Semantic Views**, the database's semantic layer: the schema's model, with the table as an entity, its time, category and flag columns as dimensions and its measures as `total_` and `average_` metrics. AI clients read it over MCP; a notebook asks it with `nb.semantic_sql`. The kit installs Semantic Views the first time it is needed.
#
# A model can also span sources: sample data, your own files and any number of external sources at once. List the tables (each with an approved column map) and the links between them (`SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY`). With `ai=True` your model proposes business names, synonyms and the metrics people ask for, from names, types and notes only (never a row). `preview=True` shows the result and writes nothing.
#
# **Do now:** put your tables into `SEMANTIC_TABLES`, run the cell, read the preview, then set `PUBLISH_SEMANTIC = True` and run it again.
#
# A model is built from what was approved at the time. Approving a column map refreshes every model its table is in. After a link or a new table, run `nb.refresh_semantic(connection, "<name>")`.

# %% tags=["review"]
SEMANTIC_NAME = "my_data"
SEMANTIC_TABLES = [dataset.fact_table]        # add tables of other schemas: "VS_LOGISTICS.COURIER_DAILY", "MY_DATA.TARGETS"
SEMANTIC_LINKS = []                           # e.g. "MY_DATA.ORDERS.STATE=VS_LOGISTICS.STATE_LOGISTICS.STATE"
PUBLISH_SEMANTIC = False
SEMANTIC_SCHEMAS = []                         # or whole schemas: every approved table of each, e.g. ["MY_DATA", "VS_LOGISTICS"]
found_links = nb.find_links(connection, SEMANTIC_SCHEMAS, ai=None) if len(SEMANTIC_SCHEMAS) > 1 else None   # links across them, from the values
semantic = nb.semantic_model(connection, SEMANTIC_NAME, tables=SEMANTIC_TABLES, links=SEMANTIC_LINKS,
                             schemas=SEMANTIC_SCHEMAS, find=bool(SEMANTIC_SCHEMAS), ai=None, preview=not PUBLISH_SEMANTIC)
semantic

# %% tags=["review"]
semantic_models = nb.semantic_models(connection)       # every model in the database; "refreshable" ones the kit built
if PUBLISH_SEMANTIC:
    refreshed = nb.refresh_semantic(connection, SEMANTIC_NAME)   # rebuild it after a link or a column map changed
semantic_models
