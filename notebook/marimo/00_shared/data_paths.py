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
    # Shared start: connect, load, describe

    **Dataset:** Amazon sales or fraud transactions.

    Both quickstarts include these cells.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: connect
    mo.md(r"""
    ### Connect

    Connects with the kit's saved connection and lists the schemas. The notebook holds no password.
    """)
    return


@app.cell
def _():
    # Cell tags: connect
    import exakit.nb as nb

    connection = nb.connect()
    nb.check_connection(connection)
    return connection, nb


@app.cell
def _(connection, nb):
    # Cell tags: connect
    nb.list_schemas(connection)
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
    SAMPLE = "amazon_sales"
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
    MY_DATA = ""
    MY_SCHEMA = ""
    MY_TABLE = ""
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


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    | Setting | What it does |
    |---|---|
    | `CONNECTOR` | the kind of source: `[c["id"] for c in connectors]`, such as `"postgresql"` or `"snowflake"` |
    | `SOURCE_NAME` | its name: the tables appear as `VS_<NAME>` |
    | `SOURCE_SETTINGS` | for a source with several kinds in one, such as `{"catalog": "unity", "files": "s3"}` |
    | `SOURCE_URL` | its connection string; a password in it is used, never shown |
    | `SOURCE_INPUTS` | what the string did not give, such as `{"user": "reader"}` |
    """)
    return


@app.cell
def _(nb):
    # Cell tags: load
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
    SOURCE = None
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
def _(ROLE_RULES, chosen_data, connection, nb):
    # Cell tags: review
    role_review = nb.review_roles(connection, chosen_data, rules=ROLE_RULES)
    return (role_review,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    `AI_CHECK = True`: your AI model completes the draft from names, types and the kit's evidence, never a row. `AI_APPROVE = True`: approve with its answer.
    """)
    return


@app.cell
def _(nb, role_review):
    # Cell tags: review
    AI_CHECK = False
    AI_APPROVE = False
    if AI_CHECK:
        ai_map = nb.fill_column_map(role_review)
        if AI_APPROVE:
            role_review.approve({r["column"]: r["role"] for r in ai_map["roles"]} or None, ai_map["slots"] or None, notes=ai_map["notes"])
    return (AI_CHECK,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    `ROLE_CHANGES`: `{"COLUMN": "role"}`. `SLOT_CHANGES`: `{"target": "COLUMN"}`. Empty: the picker above stands.
    """)
    return


@app.cell
def _(role_review):
    # Cell tags: review
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
    leaking = nb.leakage_check(connection, dataset)
    versions = nb.column_map_versions(dataset.id)
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
    dataset
    nb.data_map(connection)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ### Semantic views: one model over all your data

    Approving a column map published it in **Exasol Semantic Views**, the database's semantic layer, in two models: the schema's, and **`all_data`**, one model over every approved table of every source. The table is an entity whose description says what it is and where it lives (an external source names its connector and is read live). Its key, identifiers, time, category and flag columns are dimensions, and its measures are `total_` and `average_` metrics. Each field's comment says what the column holds and why it is used that way. Free-text columns are described to agents in an instruction, and a personal-data column is a rule never to use its values. The approved column map itself is kept on the entity, one per version. AI clients read all of it over MCP; a notebook asks it with `nb.semantic_sql`. The kit installs Semantic Views the first time it is needed.

    A model can also span sources: sample data, your own files and any number of external sources at once. List the tables (each with an approved column map) and the links between them (`SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY`). With `ai=True` your model proposes business names, synonyms and the metrics people ask for, from names, types and notes only (never a row). `preview=True` shows the result and writes nothing.

    **Do now:** put your tables into `SEMANTIC_TABLES`, run the cell, read the preview, then set `PUBLISH_SEMANTIC = True` and run it again.

    A model is built from what was approved at the time. Approving a column map refreshes every model its table is in. After a link or a new table, run `nb.refresh_semantic(connection, "<name>")`.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    | Setting | What it does |
    |---|---|
    | `SEMANTIC_NAME` | `all_data`: every approved table of every source |
    | `SEMANTIC_TABLES` | the tables, such as `"VS_LOGISTICS.COURIER_DAILY"` |
    | `SEMANTIC_LINKS` | links of your own: `"S.T.COL=S.T.KEY"`, or `{"from", "to", "note"}` |
    | `SEMANTIC_TABLE_NOTES` | what each table is, in a sentence |
    | `SEMANTIC_SCHEMAS` | whole schemas instead: every approved table of each |
    | `PUBLISH_SEMANTIC` | `True`: save it; `False`: a preview, which prints every statement saving runs |
    | `DATA_MAP_SQL` | your own version of those statements: the printed list, edited; it runs instead of the kit's |
    """)
    return


@app.cell
def _(AI_CHECK, LINK_RULES, connection, dataset, nb):
    # Cell tags: review
    SEMANTIC_NAME = "all_data"
    SEMANTIC_TABLES = [dataset.fact_table]
    SEMANTIC_LINKS = []
    SEMANTIC_TABLE_NOTES = {}
    PUBLISH_SEMANTIC = False
    SEMANTIC_SCHEMAS = []
    DATA_MAP_SQL = None
    found_links = nb.find_links(connection, tables=SEMANTIC_TABLES, ai=None, rules=LINK_RULES) if len(SEMANTIC_TABLES) > 1 else None
    model_links = SEMANTIC_LINKS + [link for link in (found_links or {}).get("links", []) if link["confidence"] == "high"]
    if AI_CHECK:
        model_notes = nb.model_notes(connection, SEMANTIC_TABLES, links=model_links)
        SEMANTIC_TABLE_NOTES = {**model_notes["tables"], **SEMANTIC_TABLE_NOTES}
    semantic = nb.semantic_model(connection, SEMANTIC_NAME, tables=SEMANTIC_TABLES, links=model_links, table_notes=SEMANTIC_TABLE_NOTES,
                                 schemas=SEMANTIC_SCHEMAS, find=bool(SEMANTIC_SCHEMAS), ai=None, preview=not PUBLISH_SEMANTIC,
                                 sql=DATA_MAP_SQL if PUBLISH_SEMANTIC else None)
    semantic
    return DATA_MAP_SQL, PUBLISH_SEMANTIC, SEMANTIC_NAME


@app.cell
def _(DATA_MAP_SQL, PUBLISH_SEMANTIC, SEMANTIC_NAME, connection, nb):
    # Cell tags: review
    semantic_models = nb.semantic_models(connection)
    if PUBLISH_SEMANTIC and not DATA_MAP_SQL:
        refreshed = nb.refresh_semantic(connection, SEMANTIC_NAME)
    semantic_models
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ### The same thing in two sources

    When another source holds the same rows as a table of the model - customers in the warehouse and in a CRM, orders here and in a lakehouse - declare them one thing with two sources (Exasol Semantic Views **fusion**). Requests are then answered from either, and for a value both hold the side you pick wins. `nb.fuse` checks it against the data first and changes nothing; `APPLY_FUSION = True` applies it, and the document is kept beside the model so a rebuild puts it back.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    `FUSE_TABLE`: a table of your data map. `FUSE_OTHER`: the same rows in another source. `FUSE_KEY`: its key there, when named differently. `FUSION_DOCUMENT`: your own version of the printed document, edited. `APPLY_FUSION = True` applies it after the check.
    """)
    return


@app.cell
def _(SEMANTIC_NAME, connection, nb):
    # Cell tags: review
    FUSE_TABLE = ""
    FUSE_OTHER = ""
    FUSE_KEY = None
    FUSION_DOCUMENT = None
    APPLY_FUSION = False
    if FUSION_DOCUMENT or (FUSE_TABLE and FUSE_OTHER):
        fusion_document = FUSION_DOCUMENT or nb.fusion_document(connection, SEMANTIC_NAME, FUSE_TABLE, FUSE_OTHER, key=FUSE_KEY, wins="model")
        print(fusion_document)
        fusion_check = nb.fuse(connection, SEMANTIC_NAME, fusion_document)
        if APPLY_FUSION and fusion_check["status"] != "error":
            fusion_applied = nb.fuse(connection, SEMANTIC_NAME, fusion_document, dry_run=False)
    return


if __name__ == "__main__":
    app.run()
