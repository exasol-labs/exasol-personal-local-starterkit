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
    - **How long:** about five minutes, most of it loading the sample the first time (seconds after that).

    Run the cells top to bottom. The notebook is already connected: there is no host, user or password in it.
    """)
    return


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
    **Your own file**: CSV, Parquet or JSON (an array of records, or one record per line). Name the table it goes into
    and the column that plays each role: the *entity* a row is about, the *category* to compare, the *date*, the
    *label* to predict (0 or 1; true/false works too) and one or more *text* columns. The roles are saved beside the file
    as `<name>.descriptor.yaml`, so the next notebook opens the file with one assignment.
    """)
    return


@app.cell
def _(conn, nb):
    # Cell tags: load
    OWN_FILE = "~/my-data/transactions.csv"   # .csv, .parquet or .json
    OWN_TABLE = "MY_DATA.TRANSACTIONS"
    OWN_ROLES = {"entity": "CUSTOMER_ID", "category": "MERCHANT_CATEGORY", "date": "BOOKED_ON", "label": "DISPUTED",
                 "text": ["MEMO"]}
    own = nb.load_own_file(OWN_FILE, OWN_TABLE, OWN_ROLES, conn=conn, missing_ok=True)
    return (own,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    **A connected source**: a table in a virtual schema, an external database Exasol reads live. Describe the table with
    a descriptor.yaml whose `fact_table` is that table and whose `source` names the source. With no source connected,
    the cell says so and skips.
    """)
    return


@app.cell
def _(conn, nb):
    # Cell tags: load
    SOURCE = None   # e.g. "~/my-data/orders.descriptor.yaml"
    source = nb.load_source(conn, SOURCE)
    return (source,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    The data used from here on, and the role each of its columns plays (the descriptor):
    """)
    return


@app.cell
def _(nb, own, sample, source):
    # Cell tags: load
    ds = nb.first(source, own, sample)
    nb.show_roles(ds)
    return (ds,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## A first query

    Rows per category, built from the descriptor's roles - the same query on any dataset. `nb.show_sql()` prints the
    statement behind the result.
    """)
    return


@app.cell
def _(conn, ds, nb):
    first_rows = nb.sql(conn, f"""
    SELECT {ds.col("category")} AS CATEGORY,
           COUNT(*) AS N,
           ROUND(100 * AVG({ds.col("label")}), 1) AS LABEL_1_PCT
    FROM {ds.fact_table}
    GROUP BY {ds.col("category")}
    ORDER BY N DESC
    LIMIT 10""")
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
