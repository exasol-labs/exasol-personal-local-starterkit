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

    **Dataset:** Esophageal or Banking. **Run time:** about ten minutes on a first load.

    Both persona quickstarts include these cells.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: connect
    mo.md(r"""
    ## Connect

    Uses the kit's saved connection, then lists the schemas. No password in the notebook.
    """)
    return


@app.cell
def _():
    # Cell tags: connect
    import exakit.nb as nb

    conn = nb.connect()
    nb.check_connection(conn)
    return conn, nb


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
    return


if __name__ == "__main__":
    app.run()
