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
    # Quickstart: connected, data in, a first query

    - **Dataset:** the Pharma sample (`pharma_trials`, ClinicalTrials.gov studies) unless you pick another below: the
      Banking sample (`banking_complaints`), your own CSV, Parquet or JSON file, or a table in a connected source.
    - **What must be loaded:** nothing beforehand. The sample-dataset cell loads it with `exakit data-load` the first
      time; your own file is loaded by its cell.
    - **How long:** about ten minutes, most of it loading the sample the first time (seconds after that).

    Run the cells top to bottom. The notebook is already connected: there is no host, user or password in it.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## One workflow id on everything

    The first cell starts a **workflow**: every step below - each query, the role proposal and its approval, a trace -
    appends one line carrying this id to `~/.exasol-starter-kit/workflows/<id>.jsonl`, so a result can be traced back
    through every step that made it (`exakit workflow show <id>`). Copy the printed `wf-...` id into `WORKFLOW_ID`
    in Explore, Ask and Share: Jupyter opens each notebook in a separate kernel. A kernel started with
    `EXAKIT_WORKFLOW_ID` already set also continues that workflow.
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

    Rows per category, built from the descriptor's roles - the same query on any dataset. `nb.show_sql()` prints the
    statement behind the result. A role no column fits (the descriptor's `missing`, with the profiler's reason) is
    not guessed: without a category the rows are counted per entity, without a label the label rate is left out, and
    the cell says so.
    """)
    return


@app.cell
def _(conn, ds_1, nb):
    skipped = {m['role']: m['reason'] for m in ds_1.missing}
    for role, instead in (('category', 'rows are counted per entity instead'), ('label', 'the label rate is left out')):
        if role in skipped:
            print(f'No {role} role ({skipped[role]}): {instead}; the steps that need it later say so.')
    BY = ds_1.col('category') if ds_1.has('category') else ds_1.col('entity')
    LABEL_PCT = f",\n       ROUND(100 * AVG({ds_1.col('label')}), 1) AS LABEL_1_PCT" if ds_1.has('label') else ''
    first_rows = nb.sql(conn, f'\nSELECT {BY} AS CATEGORY,\n       COUNT(*) AS N{LABEL_PCT}\nFROM {ds_1.fact_table}\nGROUP BY {BY}\nORDER BY N DESC\nLIMIT 10')
    nb.show_sql()
    first_rows
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next: `01_explore.ipynb`

    Open `01_explore.ipynb` in this folder: the landscape of this dataset with the SQL visible, a small model on this
    computer, and a text step with your own model, traced to your Langfuse. It runs on the dataset its first assignment
    names (`pharma_trials` as it ships); to run it on what you loaded here, set that one assignment to the dataset id, or
    to your file's path - its roles were saved beside it.
    """)
    return


if __name__ == "__main__":
    app.run()
