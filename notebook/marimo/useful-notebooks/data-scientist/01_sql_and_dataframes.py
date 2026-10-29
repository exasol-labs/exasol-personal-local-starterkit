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
    # SQL results as pandas DataFrames

    **Dataset:** Pharma or Banking; **How long:** five minutes. Learn the SQL-to-DataFrame
    pattern from Exasol's Notebook Connector / AI Lab examples, using the kit's
    bundled data and encrypted connection. No download or external source is needed.
    Adapted from `pyexasol/roundtrip_import_and_export.ipynb`; upstream versions,
    links and the MIT license are recorded in `EXAMPLE-GUIDE.md`.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    DATASET = "pharma_trials"  # or "banking_complaints"
    conn = nb.connect()
    ds = nb.dataset(conn, DATASET).require_approved("SQL and DataFrames")
    nb.workflow("sql-and-dataframes")
    return conn, ds, nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Read a small result with the SQL visible

    Query an aggregate in Exasol before bringing the result into memory. The
    category role chooses the correct column for either reference dataset.
    """)
    return


@app.cell
def _(conn, ds, nb):
    if not ds.has("category"):
        raise ValueError("This lesson needs a category role; review and approve that role in 00_quickstart.")
    counts_sql = f"SELECT {ds.col('category')} AS CATEGORY, COUNT(*) AS N FROM {ds.fact_table} GROUP BY 1 ORDER BY N DESC"
    print(counts_sql)
    counts = nb.sql(conn, counts_sql)
    print(counts.to_string(index=False))
    return (counts,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Validate the aggregate in Python

    pandas computes shares from the returned counts. Compare their sum with an
    independent COUNT in Exasol before sharing a result. Use 03_share for a chart.
    """)
    return


@app.cell
def _(conn, counts, ds, nb):
    shares = counts.assign(SHARE=counts["N"].astype(float) / counts["N"].astype(float).sum())
    total_sql = f"SELECT COUNT(*) AS N FROM {ds.fact_table}"
    print(total_sql)
    total = nb.sql(conn, total_sql)
    assert int(counts["N"].sum()) == int(total.iloc[0]["N"])
    print(shares.to_string(index=False))
    print("Validated: category counts equal the table row count.")
    return


if __name__ == "__main__":
    app.run()
