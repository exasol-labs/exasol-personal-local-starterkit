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

    **Dataset:** `esophageal_posts` by default; Banking or your own file also work. **How long:** about five minutes once runtimes are installed.

    Checks the database Python runtime, MLflow and the shared model directory, then loads and describes the data.

    **Run first:** `exakit udf-use default` (installs the ML runtime; a container install can restart the database).
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Start a workflow

    One ID links data, checks and model runs. To continue the Data Scientist's log, start the kernel with `EXAKIT_WORKFLOW_ID`.
    """)
    return


@app.cell
def _():
    import os
    import exakit.nb as nb

    wid = nb.workflow("ml-engineer-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
    print(f"Every step below is logged under it: exakit workflow show {wid}")
    return (nb,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Pick the database Python runtime

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
    mo.md(r"""
    ## Check the runtime packages

    Runs a small UDF that imports the training packages. On failure, run the command it prints and repeat.
    """)
    return


@app.cell
def _(CONTAINER, conn, nb):
    container_ok = nb.check_container(conn, alias=CONTAINER)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Check MLflow

    Shows where runs are recorded. Browser UI: `exakit mlflow start`, then `exakit mlflow url`. `MLFLOW_TRACKING_URI` overrides.
    """)
    return


@app.cell
def _(nb):
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
def _(conn, nb):
    bucket_ok = nb.check_bucket(conn)
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
    ## Check the label

    Rows and positive labels per category. Label 1 means the outcome happened (negative post, monetary relief), not that it is good.
    """)
    return


@app.cell
def _(conn, ds_1, nb):
    skipped = {m['role']: m['reason'] for m in ds_1.missing}
    for role, instead in (('category', 'rows are counted per entity instead'), ('label', 'the label count is left out, and 01_train has nothing to predict until a label role is approved')):
        if role in skipped:
            print(f'No {role} role ({skipped[role]}): {instead}; the steps that need it later say so.')
    BY = ds_1.col('category') if ds_1.has('category') else ds_1.col('entity')
    LABEL_1 = f",\n       SUM({ds_1.col('label')}) AS LABEL_1" if ds_1.has('label') else ''
    first_rows = nb.sql(conn, f'\nSELECT {BY} AS CATEGORY,\n       COUNT(*) AS N{LABEL_1}\nFROM {ds_1.fact_table}\nGROUP BY {BY}\nORDER BY N DESC\nLIMIT 10')
    nb.show_sql()
    first_rows
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next

    Run `data-scientist/01_explore.ipynb` up to its handoff cell, then open `01_train.ipynb`.
    """)
    return


if __name__ == "__main__":
    app.run()
