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
    # Our shared starting point: a table we understand

    **Dataset:** Pharma or Banking. **Run time:** about ten minutes on a first load.
    These cells appear in both persona quickstarts. They connect to your kit, load the chosen data and help you agree what the columns mean. Open your persona's quickstart to follow its full story.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: connect
    mo.md(r"""
    ## Meet the data where it lives

    Before interpreting a number, check that the notebook can reach your local Exasol database. The next cell connects using the kit's saved connection and runs a small check. Then you can see the available schemas, which are folders of database tables.

    **Technical note:** `nb.connect()` reads the kit's connection store. You can reuse this cell in your own notebook without copying connection credentials into it.
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
    ## Choose a starting dataset

    Start with the bundled sample so you can learn the flow with known data. Pharma asks about trial outcomes; Banking asks about complaint outcomes. Later you can use the same pattern with a file of your own.

    Each loading cell has its own setting. Leave unused paths at their defaults. For this local walkthrough, keep `SOURCE = None`. The final selection cell tells the rest of the notebook which dataset to use.

    **Start here: use the bundled sample.** Keep `SAMPLE = "pharma_trials"` for trial data, or change it to `"banking_complaints"` for complaint data. The helper loads a missing sample and reuses one already loaded. Set it to `None` when you later want to work only with your own file.
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
    **Make this your own later.** Set `OWN_FILE` to a CSV, Parquet or JSON file and choose a new `OWN_TABLE`, such as `MY_DATA.TRANSACTIONS`. The loader brings its records into Exasol; the review step below suggests how to use its columns. A default path that does not exist is skipped, so you can finish the sample story first.
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
    ## Give the columns a meaning for this question

    A table stores values. A **role** tells these notebooks how you want to use a column. The kit suggests roles from the real column names, types and measured values, then shows its reasons. You decide whether those suggestions fit your goal.

    | Role | Meaning | Pharma example | Banking example |
    |---|---|---|---|
    | `entity` | Who or what to compare | `LEAD_SPONSOR` | `COMPANY` |
    | `category` | Groups to compare | `PHASE` | `PRODUCT` |
    | `date` | The event timeline | `START_DATE` | `DATE_RECEIVED` |
    | `label` | The outcome to predict | `TERMINATED` | `MONETARY_RELIEF` |
    | `text` | Written descriptions | `BRIEF_SUMMARY` | `ISSUE` |

    **Your most important choice is the label.** A model using `TERMINATED` learns about trial termination. A model using `HAS_RESULTS` answers whether results were published. Both can contain 0/1; the business question decides which is useful.

    **Do now:** read the reasons, keep or change the dropdowns, leave unrelated columns as **—**, then click **Approve descriptor**. A close alternative deserves a second look. A rule-match score measures how well a column fits the rules, not certainty about its meaning.

    **Technical note:** approval saves a versioned **descriptor**, the column map used by Explore, Ask, Train and Share. The next cell waits for approval; Marimo resumes it after the button is clicked. Plain Python can use `review.approve({"COLUMN": "role", ...})`. Automated `EXAKIT_NB_AUTO_APPROVE=1` reuses an unchanged approved map; `force` accepts a new proposal deliberately. Use the button for this walkthrough.
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
