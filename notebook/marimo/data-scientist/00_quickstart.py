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

    **Dataset:** `esophageal_posts` (default), `banking_complaints` or your own file. **How long:** about ten minutes on the first load.

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

    Start with the bundled sample: `SAMPLE = "esophageal_posts"` (social posts) or `"banking_complaints"` (complaints). It loads once and is reused. Keep `SOURCE = None` for this walkthrough.
    """)
    return


@app.cell
def _(conn, nb):
    # Cell tags: load
    SAMPLE = "esophageal_posts"   # or "banking_complaints", or None
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
    ## Approve the column roles

    A **role** tells the notebooks how to use a column. The kit suggests roles with its reasons.

    | Role | Meaning | Esophageal | Banking |
    |---|---|---|---|
    | `entity` | Who or what to compare | `SOURCE_DOMAIN` | `COMPANY` |
    | `category` | Groups to compare | `SOCIAL_NETWORK` | `PRODUCT` |
    | `date` | Event time | `START_DATE` | `DATE_RECEIVED` |
    | `label` | Outcome to predict | `IS_NEGATIVE` | `MONETARY_RELIEF` |
    | `text` | Free text | `MESSAGE` | none |

    The **label** matters most: it is what a model learns to predict.

    **Do now:** check the dropdowns, leave unrelated columns as **—**, click **Approve descriptor**. The next cell waits for it. Explore, Ask, Train and Share use this approved map.

    Plain Python: `review.approve({"COLUMN": "role", ...})`.
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

    Rows per category and, with an approved label, the share with label 1. Counts show size, not cause. `nb.show_sql()` shows the query.
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
    LABEL_PCT = f",\n       ROUND(100 * AVG({ds_1.col('label')}), 1) AS LABEL_1_PCT" if ds_1.has('label') and GROUPED_BY != 'label' else ''
    first_rows = nb.sql(conn, f'\nSELECT {BY} AS CATEGORY,\n       COUNT(*) AS N{LABEL_PCT}\nFROM {ds_1.fact_table}\nGROUP BY {BY}\nORDER BY N DESC\nLIMIT 10')
    nb.show_sql()
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
