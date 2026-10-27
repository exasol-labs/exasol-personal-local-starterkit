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
    # Quickstart: container, MLflow, bucket directory, data in

    - **Dataset:** the Pharma sample (`pharma_trials`, ClinicalTrials.gov studies) unless you pick another below: the
      Banking sample (`banking_complaints`), your own CSV, Parquet or JSON file, or a table in a connected source.
    - **What must be loaded:** nothing beforehand. The sample-dataset cell loads it with `exakit data-load` the first
      time. Training needs a Python container in the database: `exakit udf-use default` (the `udf-devkit` add-on).
    - **How long:** about five minutes, most of it loading the sample the first time.

    First the three things training depends on, one cell each: each prints `ok` with what it found, or `FAIL` with the
    reason and the fix. Then the same loader cells as the Data Scientist's quickstart.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## One workflow id on everything

    The first cell starts a **workflow**: every step below - each check, each query, the role proposal and its approval -
    appends one line carrying this id to `~/.exasol-starter-kit/workflows/<id>.jsonl`, and `01_train` tags its MLflow run
    with it (`exakit workflow show <id>`). A kernel started with `EXAKIT_WORKFLOW_ID` set - the Data Scientist's, say -
    continues that workflow instead of starting one.
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
    ## Which container trains

    A training UDF runs on a Python container in the database, named by its **alias**. The `udf-devkit` add-on installs
    two: `exakit udf-use default` puts the kit's pre-built one (scikit-learn, pandas and numpy pinned) in as
    `PYTHON3_ML`; `exakit udf-setup` installs the official `PYTHON3`. This one assignment is the alias the container
    check below and `01_train` use. Its default reads what the kit recorded as installed, `PYTHON3_ML` before `PYTHON3`
    (`EXAKIT_UDF_CONTAINER` overrides it); with none installed it stops here and names the fix.
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
    ## Connected?

    The kernel **Exasol (Starter Kit)** opens the database from the kit's encrypted store: there is no host, user or
    password in this notebook. The second cell lists what the database holds; a virtual schema is a connected source.
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
    ## The container answers the smoke UDF

    A small Python UDF runs on the container behind `CONTAINER` and reports Python and the packages the training UDF
    needs. A `FAIL` line names the alias it probed and the command that installs that very container.
    """)
    return


@app.cell
def _(CONTAINER, conn, nb):
    container_ok = nb.check_container(conn, alias=CONTAINER)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## The MLflow server is reachable

    `exakit mlflow start` runs the kit's local server; `exakit mlflow url` shows its address. Set
    `MLFLOW_TRACKING_URI` before `exakit notebook` to use another server instead. If neither is running, runs still
    go to the kit's local store under `~/.exasol-starter-kit/mlflow/`.
    """)
    return


@app.cell
def _(nb):
    mlflow_ok = nb.check_mlflow()
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## The bucket directory is where the kit expects it

    On a local deployment the database's bucket is a folder on this computer, read by UDFs under `/buckets`. The kit
    names it (`exakit model list --json`); this checks the folder is there and that a UDF sees it.
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
    ## Bring data in: one cell for each way

    Set up the ones you want; a cell you leave as it is says so and skips. The data used from here on is the first
    that loaded, in this order: a connected source, your own file, the sample dataset.

    **A sample dataset** the kit ships: `pharma_trials` (ClinicalTrials.gov studies) or `banking_complaints` (CFPB
    consumer complaints). The cell loads it with `exakit data-load` the first time (a few minutes) and uses it as it is
    after that. `None` skips it.
    """)
    return


@app.cell
def _(conn, nb):
    # Cell tags: load
    SAMPLE = "pharma_trials"   # or "banking_complaints", or None
    sample = nb.load_sample(conn, SAMPLE)
    return (sample,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    **Your own file**: CSV, Parquet or JSON (an array of records, or one record per line). Name the table it goes into.
    The next cell profiles its columns and lets you choose their roles; you do not have to write a descriptor.
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
    **A connected source**: a table in a virtual schema, an external database Exasol reads live. Name it as
    SCHEMA.TABLE; the next cell profiles a sample and lets you review the roles. With no source connected, it skips.
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
    The data used from here on. A source wins over your file, which wins over the sample:
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
    ## Review and approve the roles

    The kit profiles the chosen table and shows the evidence behind each proposed role: one dropdown per column,
    labelled with its type, null share and distinct values or span, the runner-up for its role under it. Pick a role
    for each column, then click **Approve descriptor**. The next cell waits for your approval; it does not run on a
    draft (in Marimo it stops until the button is clicked, then runs on its own). In a plain Python session, call
    `review.approve({"COLUMN": "role", ...})` instead. A headless run (`EXAKIT_NB_AUTO_APPROVE=1`) approves only a
    proposal equal to the current approved version, writing nothing; any other proposal stays a draft and the run
    says why (`=force` approves it anyway).
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
    ## A first query

    Rows and positive labels per category, built from the descriptor's roles - the label is what `01_train` learns to
    predict. A role no column fits (the descriptor's `missing`, with the profiler's reason) is not guessed: without a
    category the rows are counted per entity, without a label the label count is left out, and the cell says so.
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
    ## Next: `01_train.ipynb`

    Open `01_train.ipynb` in this folder: features in SQL from these roles, a scikit-learn classifier trained inside the
    database, and the run in your MLflow with its metrics, training SQL and model. Run the Data Scientist's
    `01_explore.ipynb` first to write the handoff. Then set the one DATASET assignment in `01_train` to the dataset id
    or your file's path.
    """)
    return


if __name__ == "__main__":
    app.run()
