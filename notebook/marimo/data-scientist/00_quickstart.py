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
    # Data Scientist quickstart

    **Dataset:** `amazon_sales` (default), `walmart_sales`, `fraud_transactions` or your own file. **How long:** about ten minutes on the first load.

    You end with a connection, an approved column map and a first grouped result. No LLM needed.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Start a workflow

    Logs your queries and decisions. Keep the printed `wf-...` ID: paste it into `WORKFLOW_ID` in Explore, Ask and Share.
    """)
    return


@app.cell
def _():
    import os
    import exakit.nb as nb

    wid = nb.workflow("data-scientist-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
    print(f"Every step below is logged under it: exakit workflow show {wid}")
    return (nb,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: connect
    mo.md(r"""
    ## Connect

    Uses the kit's saved connection, then lists the schemas. No password in the notebook.
    """)
    return


@app.cell
def _(nb):
    # Cell tags: connect
    conn = nb.connect()
    nb.check_connection(conn)
    return (conn,)


@app.cell
def _(conn, nb):
    # Cell tags: connect
    nb.list_schemas(conn)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    ## Choose a dataset

    > **What is a dataset?** One table of rows to learn from; each row is one thing that happened.
    > The kit offers three to practise on: `amazon_sales` (online fashion orders, one row per order line), `walmart_sales` (weekly sales, one row per store and week) and `fraud_transactions` (card and bank payments with a fraud label, messy on purpose: repeats, gaps and placeholders to find).
    > We start with one of these known samples so you can try every step before bringing your own data.

    Pick one: `SAMPLE = "amazon_sales"` (the default), `"walmart_sales"` or `"fraud_transactions"`. The first run downloads it from the kit's release (internet needed) and loads it once; after that it is reused, and the later notebooks carry on with the dataset you approve here (their `DATASET = None`). Keep `SOURCE = None` for this walkthrough.
    """)
    return


@app.cell
def _(conn, nb):
    # Cell tags: load
    SAMPLE = "amazon_sales"   # or "walmart_sales", "fraud_transactions", or None
    sample = nb.load_sample(conn, SAMPLE)
    return (sample,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    **Your own file (optional):** set `OWN_FILE` (CSV, Parquet or JSON) and `OWN_TABLE`. A missing path is skipped.
    """)
    return


@app.cell
def _(conn, nb):
    # Cell tags: load
    OWN_FILE = "~/my-data/transactions.csv"   # .csv, .parquet or .json
    OWN_TABLE = "MY_DATA.TRANSACTIONS"
    own = nb.load_own_file(OWN_FILE, OWN_TABLE, conn=conn, missing_ok=True)
    return (own,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    **A connected source (optional):** set `SOURCE = "SCHEMA.TABLE"` for a virtual-schema table. `None` skips it.
    """)
    return


@app.cell
def _(conn, nb):
    # Cell tags: load
    SOURCE = None   # e.g. "VS_SALES.ORDERS"
    source = nb.load_source(conn, SOURCE)
    return (source,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    The data used from here on: the source, else your file, else the sample.
    """)
    return


@app.cell
def _(nb, own, sample, source):
    # Cell tags: load
    ds = nb.first(source, own, sample)
    return (ds,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ## Approve the column map

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
    | Walmart sales | `SALES_ID` | `WEEK_DATE` | — | `ABOVE_STORE_MEDIAN` | `STORE` | — |

    Neither has a text column, so the steps that read text skip and say why. Your own file: the picker below proposes its map from the data.

    The **target** matters most: the kit never guesses it, you choose it. Leave a slot as **—** when no column fits.

    **Do now:** check the dropdowns, click **Approve descriptor**, then run the next cell. If the map is already approved and you change nothing, no click is needed. The later notebooks use this approved map.

    Plain Python: `review.approve({"COLUMN": "role"}, {"target": "COLUMN"})`.
    """)
    return


@app.cell
def _(conn, ds, nb):
    # Cell tags: review
    review = nb.review_roles(conn, ds)
    return (review,)


@app.cell
def _(nb, review):
    # Cell tags: review
    ds_1 = review.dataset()
    nb.show_roles(ds_1)
    return (ds_1,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## First result

    How many rows per group and, when the column map names a label, the % where it is 1. A note under the result says what the numbers mean.
    """)
    return


@app.cell
def _(conn, ds_1, nb):
    skipped = {m['role']: m['reason'] for m in ds_1.missing}
    GROUPED_BY, BY = ds_1.group_by()  # the category, else the entity, else the target
    if GROUPED_BY != 'category':
        print(f"No category role ({skipped.get('category', 'none approved')}): rows are counted per {GROUPED_BY} instead.")
    if 'label' in skipped:
        print(f"No label role ({skipped['label']}): the label rate is left out; the steps that need it later say so.")
    GROUP, COUNT = (nb.name(BY), nb.count_name(ds_1))  # columns named after the data: CATEGORY, ORDER_LINES
    PCT = nb.name(ds_1.col('label'), 'PCT') if ds_1.has('label') and GROUPED_BY != 'label' else None  # CANCELLED_PCT
    RATE = f",\n       ROUND(100 * AVG({ds_1.col('label')}), 1) AS {PCT}" if PCT else ''
    first_rows = nb.sql(conn, f'\nSELECT {BY} AS {GROUP},\n       COUNT(*) AS {COUNT}{RATE}\nFROM {ds_1.fact_table}\nGROUP BY {BY}\nORDER BY {COUNT} DESC\nLIMIT 10')
    nb.show_sql()
    overall = nb.sql(conn, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({ds_1.col('label')}), 1) AS PCT FROM {ds_1.fact_table}") if PCT else None
    nb.note_groups(first_rows, ds_1, GROUP, COUNT, PCT, overall=(overall['N'][0], overall['PCT'][0]) if PCT else None)
    first_rows
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next

    Open `01_explore.ipynb`, then `02_ask_your_data.ipynb` and `03_share.ipynb`. Bring your workflow ID.
    """)
    return


if __name__ == "__main__":
    app.run()
