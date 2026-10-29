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
    # Start an investigation with data you can explain

    **Dataset:** `pharma_trials` by default; `banking_complaints` or your own file can follow the same path. **How long:** about ten minutes on the first load.

    Imagine a team asks you to understand outcomes: which trial phases and sponsors have more terminations, or which complaint products and companies receive monetary relief. Start by checking the data and agreeing what its columns mean.

    **By the end:** you will have a working connection, an approved column map and a first grouped result you can explain. Run top to bottom and use this as the starting notebook for your own investigation.

    **Optional AI:** an LLM endpoint is optional. The connection, table-based role suggestions and first SQL query work as supplied. Later, Explore can summarize text and Ask can draft SQL with your configured model.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Keep a trail of the investigation

    A colleague should be able to follow a result back to the data and decisions behind it. The next cell starts a **workflow**, a record of your queries, role review and later handoffs.

    **Do now:** keep the printed `wf-...` identifier. Paste it into `WORKFLOW_ID` in Explore, Ask and Share when those notebooks open in separate kernels.

    **Technical note:** the log lives in `~/.exasol-starter-kit/workflows/<id>.jsonl`. `exakit workflow show <id>` reads it; `EXAKIT_WORKFLOW_ID` can continue it from a new kernel.
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
    ## Meet the data where it lives

    Before interpreting a number, check that the notebook can reach your local Exasol database. The next cell connects using the kit's saved connection and runs a small check. Then you can see the available schemas, which are folders of database tables.

    **Technical note:** `nb.connect()` reads the kit's connection store. You can reuse this cell in your own notebook without copying connection credentials into it.
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
    return (ds_1,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Read the first answer before building a model

    Count the observations in each category. For Pharma these are trials by phase; for Banking they are complaints by product. The result also shows the share whose approved outcome is 1, when a label is available.

    **Read the result:** a large group has more records, while a high label percentage has more of the selected outcome. Those are different observations. Counts and associations alone do not explain why an outcome happened.

    **Technical note:** the SQL uses your role map rather than hard-coded dataset columns. Without a category it groups by entity; without a label it leaves out the outcome rate and explains the omission. `nb.show_sql()` reveals the query behind the result.
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
    ## Continue the story

    Open `01_explore.ipynb` to compare groups, follow outcomes over time and try a small local model. Keep the sample first; changing its `DATASET` assignment later lets you reuse the notebook with Banking or the path to your own described file.

    The next chapters are `02_ask_your_data.ipynb` for a reviewed question and `03_share.ipynb` for a checked dashboard on Dash Server. Bring your workflow ID along.
    """)
    return


if __name__ == "__main__":
    app.run()
