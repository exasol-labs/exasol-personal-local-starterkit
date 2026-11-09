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

    **Dataset:** `amazon_sales` by default; `fraud_transactions` or your own file also work. **How long:** about five minutes once runtimes are installed.

    Checks the database Python runtime, MLflow and the shared model directory, then loads and describes the data.

    **Run first:** `exakit udf-use default` (installs the ML runtime; a container install can restart the database).
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Start a workflow

    One ID links data, checks and model runs. Train, Rust scoring and scoring continue it on their own: nothing to copy.
    """)
    return


@app.cell
def _():
    import os
    import exakit.nb as nb

    workflow_id = nb.workflow("ml-engineer-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
    print(f"Every step below is logged under it: exakit workflow show {workflow_id}")
    return (nb,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Pick the database Python runtime

    > **What is a UDF?** A user-defined function: a small program, here in Python, that runs inside the database, next to the data.
    > Training as a UDF means the rows are not copied out of the database into the notebook first.
    > The runtime (container) picked below is the set of Python packages that program can use.

    Training runs as a UDF inside Exasol, with its own packages.

    - `PYTHON3_ML` (`exakit udf-use default`): preferred, has the ML packages.
    - `PYTHON3` (`exakit udf-setup`): the official alternative.
    - `EXAKIT_UDF_CONTAINER` picks another installed alias.
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

    Uses the kit's saved connection, then lists the schemas. No password in the notebook.
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

    Runs a small UDF that imports the training packages. On failure, run the command it prints and repeat.
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

    > **What is MLflow tracking?** A logbook for model training: every run's settings, scores and model file.
    > With it you can compare two runs side by side and find the exact model a result came from.
    > By default the runs are kept on this computer, in the kit's own MLflow.

    Shows where runs are recorded. Browser UI: `exakit mlflow start`, then `exakit mlflow url`.

    **Optional: another MLflow server.** Fill in `MLFLOW_TRACKING_URI` to record to your team's server instead; `MLFLOW_SERVER_LOGIN = True` asks for its username and password in a hidden box. They stay in this notebook's kernel only - never in this file. Left empty, runs go to the kit's own MLflow.
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

    Tests that a UDF can read the kit's model directory (needed for Python model-file scoring). `exakit model list --json` shows its paths.
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

    The same cells as the Data Scientist quickstart: pick a dataset, then approve its column map.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    ### Choose a dataset

    > **What is a dataset?** One table of rows to learn from; each row is one thing that happened.
    > The kit offers two to practise on: `amazon_sales` (online fashion orders, one row per order line) and `fraud_transactions` (card and bank payments with a fraud label, messy on purpose: repeats, gaps and placeholders to find).
    > We start with one of these known samples so you can try every step before bringing your own data.

    Pick one: `SAMPLE = "amazon_sales"` (the default) or `"fraud_transactions"`. The first run downloads it from the kit's release (internet needed) and loads it once; after that it is reused, and the later notebooks carry on with the dataset you approve here (their `DATASET = None`). Keep `SOURCE = None` for this walkthrough.
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
    **Your own file (optional):** set `OWN_FILE` (CSV, Parquet or JSON) and `OWN_TABLE`. A missing path is skipped.
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
    The data used from here on: the source, else your file, else the sample.
    """)
    return


@app.cell
def _(nb, own_data, sample_data, source_data):
    # Cell tags: load
    chosen_data = nb.first(source_data, own_data, sample_data)
    return (chosen_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ### Approve the column map

    > **What is the descriptor?** A short map of the table, also called the column map: which column plays which part - the key, the time, the groups to compare (category), the outcome to predict (target).
    > Every later query is written from this map, so no notebook has your column names typed in.
    > It is saved with a version number, so each result says which map it came from.

    > **Why approve it?** The kit proposes the map from the data, and a guess can be wrong: in `amazon_sales`, `STATUS` says `Cancelled` on exactly the cancelled lines, so it gives the answer away.
    > A person checks the map once and approves it before any query runs on it.
    > That way every number later rests on choices you have seen and agreed to.

    The kit suggests the map from the data and shows why. It has two parts.

    **1. A role for every column**, one of eight: `key` (one per row), `time`, `measure` (a number to add up), `category` (a few repeated values), `flag` (yes/no), `text`, `identifier` (names or codes, never grouped) and `other`.

    **2. The slots**: the one column the notebooks use for each job - `key` (one row), `time` (trends), `text` (words to explore), `target` (the outcome to predict), `category` (groups to compare) and `entity` (who or what a row is about). The datasets the kit ships with their map approved:

    | Dataset | `key` | `time` | `text` | `target` | `category` | `entity` |
    |---|---|---|---|---|---|---|
    | Amazon sales | `ORDER_LINE_ID` | `ORDER_DATE` | — | `CANCELLED` | `CATEGORY` | `SHIP_STATE` |
    | Fraud transactions | `ROW_ID` | — | — | `FRAUDULENT` | `TRANSACTION_TYPE` | `LOCATION` |

    Neither has a text column, so the steps that read text skip and say why. Your own file: the picker below proposes its map from the data.

    The **target** matters most: the kit never guesses it, you choose it. Leave a slot as **—** when no column fits.

    **Do now:** the columns the kit was least sure about come first, under *Check these first* - look at those, change what is wrong, click **Approve descriptor**, then run the next cell. If the map is already approved and you change nothing, no click is needed. Approving also checks the data once more (a key that repeats, a target that is not yes/no) and warns about a column that gives the target away.

    Plain Python: `review.approve({"COLUMN": "role"}, {"target": "COLUMN"})`.
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
    ## Check the label

    How many rows per group and the % where the label is 1. Label 1 means the outcome happened (`CANCELLED`: the order line was cancelled; `ABOVE_STORE_MEDIAN`: the store sold more that week than in its median week), not that it is good. A note under the result says what the numbers mean.
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

    Open `01_train.ipynb`: it trains from the approved column map above and writes the training handoff the next notebooks use.
    """)
    return


if __name__ == "__main__":
    app.run()
