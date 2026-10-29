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
    # Take a database result into Python and check it

    **Dataset:** Pharma or Banking. **How long:** five minutes.

    A colleague wants category shares in a Python table. Begin with counts computed in Exasol, then calculate shares in pandas and verify the total independently. Pharma groups by phase; Banking groups by product.

    **By the end:** you will have a small result, the SQL behind it and a simple validation check you can reuse in your own notebook. **Optional AI:** no LLM endpoint is required; an assistant can help propose a different aggregate after you understand this one.

    Adapted from Notebook Connector / AI Lab's `pyexasol/roundtrip_import_and_export.ipynb`. Sources and MIT notices are in `EXAMPLE-GUIDE.md`.
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
    ## Ask the database for the useful summary

    You need a category comparison, so bring back category counts rather than every source row. Inspect the printed SQL and the category names in the result.

    **Technical note:** the approved category role selects `PHASE` or `PRODUCT`. `nb.sql` executes the aggregate and returns a pandas DataFrame. This keeps the same code useful when the dataset changes.
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
    ## Check the number before using it in a story

    The next cell calculates each category's share in Python and checks that the category counts add up to an independent database count. A failing assertion means you should investigate the grouping or data before sharing the result.

    **Technical note:** pandas calculates shares from the returned counts, while a separate `COUNT(*)` checks the total. Matching totals support this aggregate; they do not establish every possible data-quality claim. Use `data-scientist/03_share` for a reviewed dashboard on Dash Server.
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
