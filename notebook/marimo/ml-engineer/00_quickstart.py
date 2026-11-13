import marimo

__generated_with = "0.25.2"
app = marimo.App()


@app.cell
def _():
    import marimo as mo

    return (mo,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    # ML Engineer quickstart

    **Dataset:** `amazon_sales` by default, `fraud_transactions` or your own file. **How long:** about five minutes after the runtimes are installed.

    Checks the database Python runtime, MLflow and the shared model directory. Then loads and describes the data.

    **Run first:** `exakit udf-use default`. It installs the ML runtime. A container install can restart the database.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Start a workflow

    One ID links the data, the checks and the model runs. The next notebooks continue it.
    """)
    return


@app.cell
def _():
    import os
    import exakit.nb as nb

    workflow_id = nb.workflow("ml-engineer-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
    print(f"Workflow {workflow_id}: every step below is recorded under it.")
    return (nb,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Pick the database Python runtime

    Training runs as a UDF: Python code that runs inside the database, next to the data. The runtime is the set of packages that code can use.

    - `PYTHON3_ML` (`exakit udf-use default`): preferred. It has the ML packages.
    - `PYTHON3` (`exakit udf-setup`): the official alternative.
    - `EXAKIT_UDF_CONTAINER` selects another installed alias.
    """)
    return


@app.cell
def _(nb):
    CONTAINER = nb.ml_train.udf_container()   # or "PYTHON3_ML", "PYTHON3", or the alias of a container you installed
    print(f"container alias: {CONTAINER}")
    return (CONTAINER,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: connect
    mo.md(r"""
    ### Connect

    Connects with the kit's saved connection and lists the schemas. The notebook holds no password.
    """)
    return


@app.cell
def _(nb):
    # Cell tags: connect
    connection = nb.connect()
    nb.check_connection(connection)
    return (connection,)


@app.cell
def _(connection, nb):
    # Cell tags: connect
    nb.list_schemas(connection)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Check the runtime packages

    Runs a small UDF that imports the training packages. If it fails, run the command it prints and try again.
    """)
    return


@app.cell
def _(CONTAINER, connection, nb):
    container_ok = nb.check_container(connection, alias=CONTAINER)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Check MLflow

    MLflow records the settings, scores and model file of each run. By default it is the kit's own MLflow on this computer. For the browser UI: `exakit mlflow start`, then `exakit mlflow url`.

    **Optional: your team's MLflow server.** Set `MLFLOW_TRACKING_URI`. `MLFLOW_SERVER_LOGIN = True` asks for the username and password in a hidden box. They stay in this kernel only.
    """)
    return


@app.cell
def _(nb):
    MLFLOW_TRACKING_URI = ""     # e.g. "https://mlflow.example.com"; empty: the kit's own MLflow (or the one set before `exakit notebook`)
    MLFLOW_SERVER_LOGIN = False  # True: asks for the server's username and password (hidden)
    nb.use_mlflow(MLFLOW_TRACKING_URI, MLFLOW_SERVER_LOGIN)
    mlflow_ok = nb.check_mlflow()
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Check the shared model directory

    Checks that a UDF can read the kit's model directory. Python model-file scoring needs it. `exakit model list --json` shows its paths.
    """)
    return


@app.cell
def _(connection, nb):
    bucket_ok = nb.check_bucket(connection)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Load and describe the data

    The same cells as the Data Scientist quickstart: choose a dataset, then approve its column map.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    ### Choose a dataset

    These notebooks use two practice datasets:

    - `amazon_sales`: online fashion orders, one row per order line.
    - `fraud_transactions`: card and bank payments with a fraud label. It has repeats, gaps and placeholders on purpose.

    Set `SAMPLE` to one of them. The first run downloads it (internet needed). Later runs reuse it. Keep `SOURCE = None` for this walkthrough.
    """)
    return


@app.cell
def _(connection, nb):
    # Cell tags: load
    SAMPLE = "amazon_sales"   # or "fraud_transactions", or None
    sample_data = nb.load_sample(connection, SAMPLE)
    return (sample_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    **Load your own data (optional):** set `MY_DATA` to a CSV, Parquet or JSON file, or to a folder of them. Empty skips it.

    Each file becomes one table named after the file, in a schema named after its folder (`MY_SCHEMA` names another). A folder loads like `exakit data-load`. Running the cell again skips what is already loaded.
    """)
    return


@app.cell
def _(connection, nb):
    # Cell tags: load
    MY_DATA = ""     # a file or a folder, e.g. "~/sales-data/orders.csv" or "~/sales-data" (Excel works too)
    MY_SCHEMA = ""   # the schema, e.g. "SALES" (empty: the folder's name, ~/sales-data -> SALES_DATA)
    MY_TABLE = ""    # or a table already in the database, e.g. "MY_DATA.ORDERS" (nb.data_map lists them)
    own_data = (nb.use_table(connection, MY_TABLE) if MY_TABLE
                else nb.load_own_file(MY_DATA, MY_SCHEMA, conn=connection, missing_ok=True))
    return (own_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    **An external source (optional):** a table in Postgres, MySQL, Snowflake and others, read live through a virtual schema. Nothing is copied.

    1. Not connected yet? Pick `CONNECTOR` and paste its connection string into `SOURCE_URL`: the kit reads it as `exakit connect --url` does, and `source_reading["missing"]` says what it did not give. Put those (and any other input you want to change, by the names in `connector_forms[CONNECTOR]["inputs"]`) in `SOURCE_INPUTS`. No connection string? Leave it empty and give every input in `SOURCE_INPUTS`. On a Mac, use `192.168.64.1` for a database on this computer.
    2. Test it: the kit checks the inputs and this computer tries the source's host and port. Nothing is changed and no password is needed.
    3. Connect it: the password is asked in a hidden box and goes to the kit only.
    4. Set `SOURCE` to its table, `"VS_<NAME>.<TABLE>"`. `"VS_<NAME>"` alone lists the tables. `None` skips it.
    """)
    return


@app.cell
def _(nb):
    # Cell tags: load
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
    return CONNECTOR, SOURCE_INPUTS, SOURCE_NAME


@app.cell
def _(CONNECTOR, SOURCE_INPUTS, SOURCE_NAME, nb):
    # Cell tags: load
    source_test = nb.test_source(CONNECTOR, SOURCE_NAME, **SOURCE_INPUTS) if CONNECTOR else None
    return


@app.cell
def _(CONNECTOR, SOURCE_INPUTS, SOURCE_NAME, nb):
    # Cell tags: load
    connected = nb.connect_source(CONNECTOR, SOURCE_NAME, **SOURCE_INPUTS) if CONNECTOR else None
    return (connected,)


@app.cell
def _(connected, connection, nb):
    # Cell tags: load
    SOURCE = None   # e.g. "VS_SALES.ORDERS" (None after a connect above: the new source's tables)
    source_data = nb.load_source(connection, SOURCE or connected)
    return (source_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    The notebook uses the source first, then your file, then the sample.
    """)
    return


@app.cell
def _(nb, own_data, sample_data, source_data):
    # Cell tags: load
    chosen_data = nb.first(source_data, own_data, sample_data)
    return (chosen_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    ### All your data in one map

    Every table by origin: external source, your data, sample data. Each shows its rows, its column map and the roles in it. *Links* lists columns that join tables, across origins too. A `possible` link only shares a name: check it before a join.
    """)
    return


@app.cell
def _(connection, nb):
    # Cell tags: load
    nb.data_map(connection)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ### Approve the column map

    The column map (the descriptor) gives each column a role. Every later query is built from it, so no notebook types your column names.

    The kit proposes the map from the data. A proposal can be wrong. In `amazon_sales`, `STATUS` gives the answer away. The kit warns about it when you approve, and the model leaves it out. Check the map before any query uses it.

    **Roles:** `key` (one per row), `time`, `measure` (a number to add up), `category` (a few repeated values), `flag` (yes/no), `text`, `identifier` (names or codes) and `other`.

    **Slots:** the one column each step uses for `key`, `time`, `text`, `target` (the outcome to predict), `category` (groups to compare) and `entity` (who or what a row is about).

    | Dataset | `key` | `time` | `text` | `target` | `category` | `entity` |
    |---|---|---|---|---|---|---|
    | Amazon sales | `ORDER_LINE_ID` | `ORDER_DATE` | — | `CANCELLED` | `CATEGORY` | `SHIP_STATE` |
    | Fraud transactions | `ROW_ID` | — | — | `FRAUDULENT` | `TRANSACTION_TYPE` | `LOCATION` |

    Neither dataset has a text column. The text steps skip and say why.

    The kit never guesses the **target**. You choose it. Leave a slot as "—" when no column fits.

    **Do now:**

    1. Look at *Check these first*. These are the columns the kit was least sure about.
    2. Correct what is wrong.
    3. Click **Approve column map**. No click is needed if the map is already approved and you change nothing.
    4. Run the next cell.

    Approval checks the data again and warns about a column that gives the target away.

    In plain Python: `role_review.approve({"COLUMN": "role"}, {"target": "COLUMN"})`.
    """)
    return


@app.cell
def _(chosen_data, connection, nb):
    # Cell tags: review
    role_review = nb.review_roles(connection, chosen_data)
    return (role_review,)


@app.cell
def _(nb, role_review):
    # Cell tags: review
    # Optional: let your AI model (set up on the Home card, or nb.model_setup) complete the draft. It is shown column
    # names, types and the kit's measured evidence - never a row, never a sensitive column - and answers with the roles it
    # would change and why, the column for each slot, and one sentence per column saying what it holds. It never picks
    # what to predict or what makes a row unique. Nothing changes until you approve: AI_APPROVE approves with its answer.
    AI_CHECK = False
    AI_APPROVE = False
    if AI_CHECK:
        ai_map = nb.fill_column_map(role_review)
        if AI_APPROVE:
            role_review.approve({r["column"]: r["role"] for r in ai_map["roles"]} or None, ai_map["slots"] or None, notes=ai_map["notes"])
    return


@app.cell
def _(role_review):
    # Cell tags: review
    # Or approve in code - what Approve in the column map card does: the roles you change, {"COLUMN": "role"}, and the
    # slots, {"target": "COLUMN"}. Empty: the picker above (or an approval already saved) stands.
    ROLE_CHANGES = {}
    SLOT_CHANGES = {}
    if ROLE_CHANGES or SLOT_CHANGES:
        role_review.approve(ROLE_CHANGES or None, SLOT_CHANGES or None)
    return


@app.cell
def _(nb, role_review):
    # Cell tags: review
    dataset = role_review.dataset()
    nb.show_roles(dataset)
    return (dataset,)


@app.cell
def _(connection, dataset, nb):
    # Cell tags: review
    leaking = nb.leakage_check(connection, dataset)            # columns that give the outcome away: left out of a model
    versions = nb.column_map_versions(dataset.id)              # every saved version; approving one's roles again restores it
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ### Check the map again

    The same map, read again after the approval. The table you approved now shows `approved vN, in semantic model <name>` and every slot by name. `not in a semantic model yet` means the roles are saved but agents cannot read them yet: approve again to publish.
    """)
    return


@app.cell
def _(connection, dataset, nb):
    # Cell tags: review
    dataset  # read after the approval above, so this map shows it
    nb.data_map(connection)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ### Semantic views: one model over all your data

    Approving a column map published it in **Exasol Semantic Views**, the database's semantic layer: the schema's model, with the table as an entity, its time, category and flag columns as dimensions and its measures as `total_` and `average_` metrics. AI clients read it over MCP; a notebook asks it with `nb.semantic_sql`. The kit installs Semantic Views the first time it is needed.

    A model can also span sources: sample data, your own files and any number of external sources at once. List the tables (each with an approved column map) and the links between them (`SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY`). With `ai=True` your model proposes business names, synonyms and the metrics people ask for, from names, types and notes only (never a row). `preview=True` shows the result and writes nothing.

    **Do now:** put your tables into `SEMANTIC_TABLES`, run the cell, read the preview, then set `PUBLISH_SEMANTIC = True` and run it again.

    A model is built from what was approved at the time. Approving a column map refreshes every model its table is in. After a link or a new table, run `nb.refresh_semantic(connection, "<name>")`.
    """)
    return


@app.cell
def _(connection, dataset, nb):
    # Cell tags: review
    SEMANTIC_NAME = "my_data"
    SEMANTIC_TABLES = [dataset.fact_table]        # add tables of this or other schemas: "VS_LOGISTICS.COURIER_DAILY", "MY_DATA.TARGETS"
    SEMANTIC_LINKS = []                           # your own: "MY_DATA.ORDERS.STATE=VS_LOGISTICS.STATE_LOGISTICS.STATE", or {"from": ..., "to": ..., "note": "why"}
    SEMANTIC_TABLE_NOTES = {}                     # what each table is, in a sentence: {"MY_DATA.TARGETS": "The monthly target per state."}
    PUBLISH_SEMANTIC = False
    SEMANTIC_SCHEMAS = []                         # or whole schemas: every approved table of each, e.g. ["MY_DATA", "VS_LOGISTICS"]
    # Links between the tables you listed, found from the values (two tables of one schema are compared too), each with its evidence.
    found_links = nb.find_links(connection, tables=SEMANTIC_TABLES, ai=None) if len(SEMANTIC_TABLES) > 1 else None
    # The links the model uses: yours, and the found ones the data backs. A found link carries its evidence into the model.
    model_links = SEMANTIC_LINKS + [link for link in (found_links or {}).get("links", []) if link["confidence"] == "high"]
    semantic = nb.semantic_model(connection, SEMANTIC_NAME, tables=SEMANTIC_TABLES, links=model_links, table_notes=SEMANTIC_TABLE_NOTES,
                                 schemas=SEMANTIC_SCHEMAS, find=bool(SEMANTIC_SCHEMAS), ai=None, preview=not PUBLISH_SEMANTIC)
    semantic
    return PUBLISH_SEMANTIC, SEMANTIC_NAME


@app.cell
def _(PUBLISH_SEMANTIC, SEMANTIC_NAME, connection, nb):
    # Cell tags: review
    semantic_models = nb.semantic_models(connection)       # every model in the database; "refreshable" ones the kit built
    if PUBLISH_SEMANTIC:
        refreshed = nb.refresh_semantic(connection, SEMANTIC_NAME)   # rebuild it after a link or a column map changed
    semantic_models
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Check the label

    Rows per group and the % where the label is 1. Label 1 means the outcome happened (`CANCELLED`: the order line was cancelled), not that it is good.
    """)
    return


@app.cell
def _(connection, dataset, nb):
    missing_roles = {missing["role"]: missing["reason"] for missing in dataset.missing}
    for role, instead in (("category", "rows are counted per entity instead"),
                          ("label", "the label count is left out, and 01_train has nothing to predict until a label role is approved")):
        if role in missing_roles:
            print(f"No {role} role ({missing_roles[role]}): {instead}; the steps that need it later say so.")
    GROUP_COLUMN = dataset.col("category") if dataset.has("category") else dataset.col("entity")
    GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)       # columns named after the data: CATEGORY, ORDER_LINES
    LABEL_PCT_HEADER = nb.name(dataset.col("label"), "PCT") if dataset.has("label") else None   # CANCELLED_PCT
    LABEL_RATE_SQL = f",\n       ROUND(100 * AVG({dataset.col('label')}), 1) AS {LABEL_PCT_HEADER}" if LABEL_PCT_HEADER else ""
    first_rows = nb.sql(connection, f"""
    SELECT {GROUP_COLUMN} AS {GROUP_HEADER},
           COUNT(*) AS {COUNT_HEADER}{LABEL_RATE_SQL}
    FROM {dataset.fact_table}
    GROUP BY {GROUP_COLUMN}
    ORDER BY {COUNT_HEADER} DESC
    LIMIT 10""")
    nb.show_sql()
    overall_rate = nb.sql(connection, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({dataset.col('label')}), 1) AS PCT FROM {dataset.fact_table}") if LABEL_PCT_HEADER else None
    nb.note_groups(first_rows, dataset, GROUP_HEADER, COUNT_HEADER, LABEL_PCT_HEADER, overall=(overall_rate["N"][0], overall_rate["PCT"][0]) if LABEL_PCT_HEADER else None)
    first_rows
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next

    Open `01_train.ipynb`. It trains from the approved column map and writes the training handoff.
    """)
    return


if __name__ == "__main__":
    app.run()
