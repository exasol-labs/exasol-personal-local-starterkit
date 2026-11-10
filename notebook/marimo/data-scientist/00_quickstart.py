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
    # Start here: access and understand your data

    **Dataset:** `amazon_sales` (default), `fraud_transactions` or your own file.

    **Steps:** 1 Access, 2 Understand, 3 Prepare, 4 Explore, 5 Model, 6 Validate, 7 Ask with AI, 8 Share, 9 Hand off. **This notebook: steps 0, 1 and 2.**

    At the end you have a connection, an approved column map and a first result. No AI model is needed. Kit commands run from these cells, so you do not need a terminal.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 0 · Check the kit

    Shows what is installed and running: the database, each add-on and the loaded datasets. It changes nothing.

    Other kit commands run the same way, with the log in the cell:

    - `nb.exakit("update")` updates the kit.
    - `nb.exakit("marketplace", "dash-server")` adds an add-on.
    - `nb.exakit("logs")` shows the logs.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    kit_state = nb.kit_check()
    return (nb,)


@app.cell
def _():
    # Things you would otherwise do in a terminal - take the # off one line and run the cell; its log shows here.
    # nb.exakit("update")                            # bring the kit and its add-ons up to date
    # nb.exakit("marketplace", "dash-server")        # add an add-on (Share, step 8, needs this one)
    # nb.exakit("data-load", "fraud_transactions")        # load another of the kit's datasets
    # nb.exakit("logs")                              # every log the kit keeps
    # nb.exakit("mcp-setup", env={"EXAKIT_MCP_CLIENTS": "claude"})   # connect an AI client to the database
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 1 · Access the data

    Connects to the database, starts a workflow and loads a dataset: a practice dataset, your own file or a connected source.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Start a workflow

    The workflow gives one ID to every query and decision below. The next notebooks continue it. You do not copy anything.
    """)
    return


@app.cell
def _(nb):
    import os
    workflow_id = nb.workflow('data-scientist-quickstart', resume=os.environ.get('EXAKIT_WORKFLOW_ID'))
    print(f'Every step below is logged under it: exakit workflow show {workflow_id}')
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
    # Cell tags: load
    mo.md(r"""
    ### Choose a dataset

    The kit has two practice datasets:

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
    **Your own file (optional):** set `OWN_FILE` (CSV, Parquet or JSON) and `OWN_TABLE`. A missing file is skipped.
    """)
    return


@app.cell
def _(connection, nb):
    # Cell tags: load
    OWN_FILE = "~/my-data/transactions.csv"   # .csv, .parquet or .json
    OWN_TABLE = "MY_DATA.TRANSACTIONS"
    own_data = nb.load_own_file(OWN_FILE, OWN_TABLE, conn=connection, missing_ok=True)
    return (own_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    **A connected source (optional):** set `SOURCE = "SCHEMA.TABLE"` for a virtual-schema table. `None` skips it.
    """)
    return


@app.cell
def _(connection, nb):
    # Cell tags: load
    SOURCE = None   # e.g. "VS_SALES.ORDERS"
    source_data = nb.load_source(connection, SOURCE)
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
    mo.md(r"""
    ## Step 2 · Understand the data

    You approve the column map: the key, the date, the groups and the outcome. The kit proposes it and shows the least certain columns first. Every later step reads this map, so the same notebooks run on any table.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ### Approve the column map

    The column map (the descriptor) gives each column a role. Every later query is built from it, so no notebook types your column names.

    The kit proposes the map from the data. A proposal can be wrong. In `amazon_sales`, `STATUS` gives the answer away. Check the map before any query uses it.

    **Roles:** `key` (one per row), `time`, `measure` (a number to add up), `category` (a few repeated values), `flag` (yes/no), `text`, `identifier` (names or codes) and `other`.

    **Slots:** the one column each step uses for `key`, `time`, `text`, `target` (the outcome to predict), `category` (groups to compare) and `entity` (who or what a row is about).

    | Dataset | `key` | `time` | `text` | `target` | `category` | `entity` |
    |---|---|---|---|---|---|---|
    | Amazon sales | `ORDER_LINE_ID` | `ORDER_DATE` | — | `CANCELLED` | `CATEGORY` | `SHIP_STATE` |
    | Fraud transactions | `ROW_ID` | — | — | `FRAUDULENT` | `TRANSACTION_TYPE` | `LOCATION` |

    Neither dataset has a text column. The text steps skip and say why.

    The kit never guesses the **target**. You choose it. Leave a slot as **—** when no column fits.

    **Do now:**

    1. Look at *Check these first*. These are the columns the kit was least sure about.
    2. Correct what is wrong.
    3. Click **Approve descriptor**. No click is needed if the map is already approved and you change nothing.
    4. Run the next cell.

    Approval checks the data again and warns about a column that gives the target away.

    In plain Python: `review.approve({"COLUMN": "role"}, {"target": "COLUMN"})`.
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
    dataset = role_review.dataset()
    nb.show_roles(dataset)
    return (dataset,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### A first result

    Rows per group, and the % where the label is 1 when the map has a label. Each query shows its SQL before the result.
    """)
    return


@app.cell
def _(connection, dataset, nb):
    missing_roles = {missing["role"]: missing["reason"] for missing in dataset.missing}
    GROUP_ROLE, GROUP_COLUMN = dataset.group_by()   # the category, else the entity, else the target
    if GROUP_ROLE != "category":
        print(f"No category role ({missing_roles.get('category', 'none approved')}): rows are counted per {GROUP_ROLE} instead.")
    if "label" in missing_roles:
        print(f"No label role ({missing_roles['label']}): the label rate is left out; the steps that need it later say so.")
    GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)       # columns named after the data: CATEGORY, ORDER_LINES
    LABEL_PCT_HEADER = nb.name(dataset.col("label"), "PCT") if dataset.has("label") and GROUP_ROLE != "label" else None   # CANCELLED_PCT
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
    ## Next: steps 3 to 6

    Open `01_explore.ipynb` to prepare, explore, model and validate. Then open `02_ask_your_data.ipynb` (step 7) and `03_share.ipynb` (steps 8 and 9). Each one continues this workflow.
    """)
    return


if __name__ == "__main__":
    app.run()
