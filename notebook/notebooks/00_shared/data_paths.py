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
SAMPLE = "amazon_sales"
sample_data = nb.load_sample(connection, SAMPLE)

# %% [markdown] tags=["load"]
# **Load your own data (optional):** set `MY_DATA` to a CSV, Parquet or JSON file, or to a folder of them. Empty skips it.
#
# Each file becomes one table named after the file, in a schema named after its folder (`MY_SCHEMA` names another). A folder loads like `exakit data-load`. Running the cell again skips what is already loaded. `MY_TABLE` uses a table already in the database instead. `LOAD_RULES` changes how a file is loaded, such as `{"REPLACE": True, "DATE_SHARE": 0.8}`; `nb.load_rules()` lists every rule.

# %% tags=["load"]
MY_DATA = ""
MY_SCHEMA = ""
MY_TABLE = ""
LOAD_RULES = {}
own_data = (nb.use_table(connection, MY_TABLE) if MY_TABLE
            else nb.load_own_file(MY_DATA, MY_SCHEMA, conn=connection, missing_ok=True, rules=LOAD_RULES))

# %% [markdown] tags=["load"]
# **An external source (optional):** a table in Postgres, MySQL, Snowflake and others, read live through a virtual schema. Nothing is copied.
#
# 1. Not connected yet? Pick `CONNECTOR` and paste its connection string into `SOURCE_URL`: the kit reads it as `exakit connect --url` does, and `source_reading["missing"]` says what it did not give. Put those (and any other input you want to change, by the names in `connector_forms[CONNECTOR]["inputs"]`) in `SOURCE_INPUTS`. No connection string? Leave it empty and give every input in `SOURCE_INPUTS`. On a Mac, use `192.168.64.1` for a database on this computer.
# 2. Test it: the kit checks the inputs and this computer tries the source's host and port. Nothing is changed and no password is needed.
# 3. Connect it: the password is asked in a hidden box and goes to the kit only.
# 4. Set `SOURCE` to its table, `"VS_<NAME>.<TABLE>"`. `"VS_<NAME>"` alone lists the tables. `None` skips it.

# %% [markdown] tags=["load"]
# | Setting | What it does |
# |---|---|
# | `CONNECTOR` | the kind of source: `[c["id"] for c in connectors]`, such as `"postgresql"` or `"snowflake"` |
# | `SOURCE_NAME` | its name: the tables appear as `VS_<NAME>` |
# | `SOURCE_SETTINGS` | for a source with several kinds in one, such as `{"catalog": "unity", "files": "s3"}` |
# | `SOURCE_URL` | its connection string; a password in it is used, never shown |
# | `SOURCE_INPUTS` | what the string did not give, such as `{"user": "reader"}` |

# %% tags=["load"]
connectors = nb.connectors()
connector_forms = {c["id"]: nb.connector_inputs(c["id"]) for c in connectors}
source_tips = nb.source_engine("catalog", "--public-ip")["events"]
CONNECTOR = ""
SOURCE_NAME = ""
SOURCE_SETTINGS = {}
if CONNECTOR and SOURCE_SETTINGS:
    connector_forms[CONNECTOR] = nb.connector_inputs(CONNECTOR, **SOURCE_SETTINGS)
SOURCE_URL = ""
source_reading = nb.read_connection_string(CONNECTOR, SOURCE_URL, **SOURCE_SETTINGS) if CONNECTOR and SOURCE_URL else None
SOURCE_INPUTS = {}
SOURCE_INPUTS = {**SOURCE_SETTINGS, **({"url": SOURCE_URL} if SOURCE_URL else {}), **SOURCE_INPUTS}

# %% tags=["load"]
source_test = nb.test_source(CONNECTOR, SOURCE_NAME, **SOURCE_INPUTS) if CONNECTOR else None

# %% tags=["load"]
connected = nb.connect_source(CONNECTOR, SOURCE_NAME, **SOURCE_INPUTS) if CONNECTOR else None

# %% tags=["load"]
SOURCE = None
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
role_review = nb.review_roles(connection, chosen_data, rules=ROLE_RULES)

# %% [markdown] tags=["review"]
# `AI_CHECK = True`: your AI model completes the draft from names, types and the kit's evidence, never a row. `AI_APPROVE = True`: approve with its answer.

# %% tags=["review"]
AI_CHECK = False
AI_APPROVE = False
if AI_CHECK:
    ai_map = nb.fill_column_map(role_review)
    if AI_APPROVE:
        role_review.approve({r["column"]: r["role"] for r in ai_map["roles"]} or None, ai_map["slots"] or None, notes=ai_map["notes"])

# %% [markdown] tags=["review"]
# `ROLE_CHANGES`: `{"COLUMN": "role"}`. `SLOT_CHANGES`: `{"target": "COLUMN"}`. Empty: the picker above stands.

# %% tags=["review"]
ROLE_CHANGES = {}
SLOT_CHANGES = {}
if ROLE_CHANGES or SLOT_CHANGES:
    role_review.approve(ROLE_CHANGES or None, SLOT_CHANGES or None)

# %% tags=["review"]
dataset = role_review.dataset()
nb.show_roles(dataset)

# %% tags=["review"]
leaking = nb.leakage_check(connection, dataset)
versions = nb.column_map_versions(dataset.id)

# %% [markdown] tags=["review"]
# ### Check the map again
#
# The same map, read again after the approval. The table you approved now shows `approved vN, in semantic model <name>` and every slot by name. `not in a semantic model yet` means the roles are saved but agents cannot read them yet: approve again to publish.

# %% tags=["review"]
dataset
nb.data_map(connection)

# %% [markdown] tags=["review"]
# ### Your data map
#
# Approving a column map put the table into **your data map**: `all_data`, one **Exasol Semantic Views** model over every approved table of every source. Its key, time, category and flag columns are dimensions; its amounts get a total and an average; each field says what the column holds. AI clients read it over MCP, and Ask writes its SQL from it.
#
# Semantic Views needs a few things only you can say, and nothing here works them out for you:
#
# | What | Why Semantic Views needs it |
# |---|---|
# | What one row of each table is (its grain) | so an amount is never counted once per row of another table |
# | How the tables connect, and the type of each link | many-to-one (order lines to orders) or one-to-one; a join that would multiply an amount is refused |
# | Where questions start | each such table becomes a semantic view that reaches the linked tables |
# | Your metrics | "completed revenue" is a sum with a condition, defined once |
# | Rules for AI tools | what anyone asking must know, such as what an amount includes |
#
# `AI_CHECK = True` (above) has your AI model draft them from names, roles, notes and known values, never a row; what you set here wins. `CHECK_LINKS = True` runs one bounded count per link. Saving hands it all to Semantic Views, which checks it and says what is wrong. **Do now:** read the preview, then set `PUBLISH_SEMANTIC = True` and run it again.

# %% [markdown] tags=["review"]
# | Setting | What it does |
# |---|---|
# | `SEMANTIC_TABLES` | the tables, such as `"VS_LOGISTICS.COURIER_DAILY"` (each with an approved column map) |
# | `SEMANTIC_LINKS` | `[{"from": "S.T.COL", "to": "S.T.KEY", "type": "MANY_TO_ONE", "note": "why"}]`; optional `"join": "INNER"` (rows without a match left out) and `"fanout"`: `ALLOCATE`, `DEDUPLICATE` or `REFERENCE_ONLY` (when one row meets several) |
# | `SEMANTIC_GRAINS` | `{"S.T": "one row is one order line"}` |
# | `SEMANTIC_TABLE_NOTES` | `{"S.T": "what the table is"}` |
# | `SEMANTIC_STARTS` | the tables questions start from: `["S.T"]` |
# | `SEMANTIC_METRICS` | `[{"table": "S.T", "name": "completed_revenue", "how": "sum", "column": "AMOUNT", "where": {"column": "STATUS", "values": ["COMPLETED"]}}]`; `how` is `sum`, `count` or `average` |
# | `SEMANTIC_INSTRUCTIONS` | `["Revenue excludes tax"]`, or `{"table": "S.T", "text": "..."}` |
# | `SEMANTIC_SYNONYMS` | your words for a field: `{"total_amount": ["sales", "revenue"]}` |
# | `SEMANTIC_HIDDEN` | columns never shown in answers, still usable in filters: `{"S.T": ["CUSTOMER_NAME"]}` |
# | `SEMANTIC_ABOUT` | what your data is about, in a sentence |
# | `CHECK_LINKS` | `True`: count how many of each link's values its key holds |
# | `PUBLISH_SEMANTIC` | `True`: save it; `False`: a preview, which prints every statement saving runs |
# | `DATA_MAP_SQL` | your own version of those statements: the printed list, edited; it runs instead of the kit's |
#
# `None` keeps what you saved before.

# %% tags=["review"]
SEMANTIC_TABLES = [dataset.fact_table]
SEMANTIC_LINKS = None
SEMANTIC_GRAINS = None
SEMANTIC_TABLE_NOTES = None
SEMANTIC_STARTS = None
SEMANTIC_METRICS = None
SEMANTIC_INSTRUCTIONS = None
SEMANTIC_HIDDEN = None
SEMANTIC_SYNONYMS = None
SEMANTIC_ABOUT = None
CHECK_LINKS = False
PUBLISH_SEMANTIC = False
DATA_MAP_SQL = None
data_map_inputs = nb.data_map_inputs(SEMANTIC_TABLES, connection=connection)
your_map = {key: data_map_inputs[key] for key in ("links", "grains", "table_notes", "starts", "metrics", "instructions", "hidden", "synonyms", "description")}
if AI_CHECK:
    drafted_map = nb.draft_data_map(SEMANTIC_TABLES)
    your_map = {key: your_map[key] or drafted_map[key] for key in your_map}
your_map.update({key: value for key, value in (("links", SEMANTIC_LINKS), ("grains", SEMANTIC_GRAINS), ("table_notes", SEMANTIC_TABLE_NOTES),
                                               ("starts", SEMANTIC_STARTS), ("metrics", SEMANTIC_METRICS),
                                               ("instructions", SEMANTIC_INSTRUCTIONS), ("hidden", SEMANTIC_HIDDEN), ("synonyms", SEMANTIC_SYNONYMS),
                                               ("description", SEMANTIC_ABOUT)) if value is not None})
if CHECK_LINKS and your_map["links"]:
    link_check = nb.find_links(connection, tables=SEMANTIC_TABLES, check=[f"{link['from']}={link['to']}" for link in your_map["links"]],
                               ai=False, rules=LINK_RULES)
    print(link_check)
semantic = nb.semantic_model(connection, "all_data", tables=SEMANTIC_TABLES, links=your_map["links"], table_notes=your_map["table_notes"],
                             grains=your_map["grains"], starts=your_map["starts"] or None, metrics=your_map["metrics"],
                             instructions=your_map["instructions"], hidden=your_map["hidden"], synonyms=your_map["synonyms"],
                             description=your_map["description"] or None,
                             replace_links=True, ai=False, preview=not PUBLISH_SEMANTIC, sql=DATA_MAP_SQL if PUBLISH_SEMANTIC else None)
if PUBLISH_SEMANTIC:
    data_map_check = nb.validate_data_map(connection)
    print(data_map_check["issues"] or "Semantic Views finds nothing wrong with your data map.")
semantic

# %% [markdown] tags=["review"]
# Every save that changes your data map is a version, kept in the model itself: what you said, and the whole model as Semantic Views exports it. A new computer reads them back from the model. `DATA_MAP_VERSION = 3` saves version 3 again as the newest.

# %% tags=["review"]
DATA_MAP_VERSION = None
if DATA_MAP_VERSION:
    restored = nb.restore_data_map(connection, DATA_MAP_VERSION)
data_map_versions = nb.data_map_versions(connection)
semantic_models = nb.semantic_models(connection)
data_map_versions

# %% [markdown] tags=["review"]
# ### More from Semantic Views
#
# | Setting | What it does |
# |---|---|
# | `STORE_TOTALS` | `{"view": "ORDER_LINES", "metrics": ["total_amount"], "dimensions": ["ship_state"], "max_age": "1 DAYS"}`: pre-built totals for speed, stored in `EXAKIT_TOTALS`; Semantic Views answers from them while they are fresh |
# | `REFRESH_TOTALS` | the name of stored totals to fill again from the live tables |
# | `FREEZE_VIEWS` | `{"BI.REVENUE_BY_STATE": "SELECT ship_state, total_amount FROM SEM_ALL_DATA.ORDER_LINES GROUP BY ship_state"}`: views for BI tools, compiled once into plain SQL |
# | `GOVERNANCE_MODE` | `"OPEN"`: Semantic Views reports sources read without their own row and column policy; `"GOVERNED"`: it refuses them |
# | `QUERY_LOGGING` | `True` or `False`: Semantic Views' own log of Semantic SQL statements |
# | `REVIEW_SUGGESTIONS` | `{12: ("CERTIFIED", "why")}`: your decision on a suggested change (from feedback on answers, AI tools, colleagues) |
# | `IMPORT_DATABRICKS` | `{"model": "finance", "file": "metric_view.yaml", "apply": False}`: a Databricks metric view as a model of its own |

# %% tags=["review"]
STORE_TOTALS = None
REFRESH_TOTALS = None
FREEZE_VIEWS = {}
GOVERNANCE_MODE = None
QUERY_LOGGING = None
REVIEW_SUGGESTIONS = {}
IMPORT_DATABRICKS = None
if STORE_TOTALS:
    stored_totals = nb.store_totals(connection, STORE_TOTALS["view"], STORE_TOTALS["metrics"], STORE_TOTALS["dimensions"],
                                    max_age=STORE_TOTALS.get("max_age", "1 DAYS"))
if REFRESH_TOTALS:
    refreshed_totals = nb.refresh_totals(connection, REFRESH_TOTALS)
for frozen_name, frozen_sql in FREEZE_VIEWS.items():
    frozen = nb.freeze_view(connection, frozen_name, frozen_sql)
if GOVERNANCE_MODE:
    governance = nb.governance_mode(connection, GOVERNANCE_MODE)
if QUERY_LOGGING is not None:
    query_log_setting = nb.query_logging(connection, QUERY_LOGGING)
for suggestion_id, (decision, note) in REVIEW_SUGGESTIONS.items():
    reviewed = nb.review_change(connection, suggestion_id, decision, note)
if IMPORT_DATABRICKS:
    with open(IMPORT_DATABRICKS["file"], encoding="utf-8") as metric_view:
        imported = nb.import_databricks(connection, IMPORT_DATABRICKS["model"], metric_view.read(), apply=IMPORT_DATABRICKS.get("apply", False))
totals = nb.list_totals(connection)
frozen_views = nb.frozen_views(connection, sync=False)
data_map_suggestions = nb.suggestions(connection)
history = nb.query_history(connection)
data_map_suggestions

# %% [markdown] tags=["review"]
# ### The same thing in two sources
#
# When another source holds the same rows as a table of the model - customers in the warehouse and in a CRM, orders here and in a lakehouse - declare them one thing with two sources (Exasol Semantic Views **fusion**). Requests are then answered from either, and for a value both hold the side you pick wins. `nb.fuse` checks it against the data first and changes nothing; `APPLY_FUSION = True` applies it, and the document is kept beside the model so a rebuild puts it back.

# %% [markdown] tags=["review"]
# `FUSE_TABLE`: a table of your data map. `FUSE_OTHER`: the same rows in another source. `FUSE_KEY`: its key there, when named differently. `FUSE_MAPPING`: when the two use different ids, the table pairing them, `{"table": "CRM.CUSTOMER_XREF", "local": "ACCOUNT_ID", "key": "CUSTOMER_ID"}`. `FUSE_SPLIT`: when the other holds the older rows, `{"column": "ORDER_DATE", "at": "2026-01-01"}`. `FUSION_DOCUMENT`: your own version of the printed document, edited. `APPLY_FUSION = True` applies it after the check.

# %% tags=["review"]
FUSE_TABLE = ""
FUSE_OTHER = ""
FUSE_KEY = None
FUSE_MAPPING = None
FUSE_SPLIT = None
FUSION_DOCUMENT = None
APPLY_FUSION = False
if FUSION_DOCUMENT or (FUSE_TABLE and FUSE_OTHER):
    fusion_document = FUSION_DOCUMENT or nb.fusion_document(connection, "all_data", FUSE_TABLE, FUSE_OTHER, key=FUSE_KEY, wins="model",
                                                                mapping=FUSE_MAPPING, split=FUSE_SPLIT)
    print(fusion_document)
    fusion_check = nb.fuse(connection, "all_data", fusion_document)
    if APPLY_FUSION and fusion_check["status"] != "error":
        fusion_applied = nb.fuse(connection, "all_data", fusion_document, dry_run=False)
