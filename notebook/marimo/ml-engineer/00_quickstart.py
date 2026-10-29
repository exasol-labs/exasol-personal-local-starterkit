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
    # Prepare a trustworthy place to train

    **Dataset:** `pharma_trials` by default; Banking or your own described file can follow. **How long:** about five minutes once the required runtimes are installed.

    The Data Scientist has identified a question and a column map. Your job is to turn that work into a repeatable training and scoring flow. Start by checking the environment before interpreting any model metric.

    **By the end:** you will know whether the database can run Python, where training runs are recorded, whether shared model files are visible and which outcome the first query describes. The following chapters train in Exasol, verify a Rust scorer and try a trusted model file.

    **Optional AI:** this path uses SQL and scikit-learn as supplied; an LLM endpoint is optional. An assistant can help you inspect code or propose a later experiment, while the checks and measured results remain yours to validate.

    **Run first:** install the ML Engineer persona or UDF devkit. `exakit udf-use default` supplies the ML runtime; a container installation can restart the database.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Keep the investigation connected to the training run

    Use one workflow ID to follow the approved data, checks and model runs. If you continue the Data Scientist's investigation, start the kernel with its `EXAKIT_WORKFLOW_ID`; otherwise this cell creates a fresh workflow.

    **Technical note:** each logged step carries the same identifier, and MLflow runs can carry it as a tag. Keep the printed `exakit workflow show ...` command so you can inspect the trail later.
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
    ## Choose the Python that runs inside the database

    The notebook's Python prepares the work. A separate Python runtime inside Exasol executes the training UDF, which is a function you call from SQL. It needs its own copies of scikit-learn and the other training packages.

    **Read the result:** keep the default `CONTAINER` for the first run. The printed alias identifies the runtime the next check and training notebook will use.

    **Technical note:** `exakit udf-use default` installs `PYTHON3_ML` with the ML packages; `exakit udf-setup` installs the official `PYTHON3` alternative. `PYTHON3_ML` is preferred when installed. `EXAKIT_UDF_CONTAINER` can select another installed alias. If none is ready, the helper stops and names the installation command.
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
    mo.md(r"""
    ## Prove the database can import its training packages

    A package working in Jupyter does not establish that it works inside Exasol. The next cell runs a small UDF in the selected runtime and checks what it imports.

    **Read the result:** continue when the check reports success. If it prints a failure, use the command it names for that exact alias and repeat the check before training.

    **Technical note:** this is a smoke test of the database-side Python and required package versions. The useful lesson `01_udf_package_check` shows a fuller package report.
    """)
    return


@app.cell
def _(CONTAINER, conn, nb):
    container_ok = nb.check_container(conn, alias=CONTAINER)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Decide where the experiment record goes

    A useful experiment includes its inputs, settings, metrics and model files. MLflow is the experiment record you can inspect and compare after training; it is independent of any optional LLM endpoint.

    **Read the result:** the check reports the destination this notebook will actually use. For the local browser UI, run `exakit mlflow start` and open the address from `exakit mlflow url`.

    **Technical note:** `MLFLOW_TRACKING_URI` selects another configured server. Otherwise the helper uses the kit server or its local store under `~/.exasol-starter-kit/mlflow/`. The client records the UDF's result; database training does not need MLflow credentials.
    """)
    return


@app.cell
def _(nb):
    mlflow_ok = nb.check_mlflow()
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Check the path a scoring function will read

    A trained model can be a file on your computer, but a database function must see that file from inside its runtime. The next check tests the kit's shared model directory and its visibility in a UDF.

    **Read the result:** success makes the shared-file scoring route available. Record a failed check and its reason. Rust has a separate container-packaging fallback that asks before a needed restart; Python model-file scoring still needs a working shared directory.

    **Technical note:** `exakit model list --json` reports the host directory and the `/buckets/...` path a UDF uses. This check does not make a missing shared directory pass by assumption.
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
    ## Confirm the outcome before teaching a model

    Count the records and positive outcomes in each category. Pharma's label is trial termination; Banking's is monetary relief. Check that this matches the question handed to you.

    **Read the result:** a positive label means the chosen outcome occurred. It does not mean that the outcome is desirable. The query shows which groups and class balance the later training recipe will encounter.

    **Technical note:** the query uses the approved role map. Missing category or label roles produce the explained fallback rather than an invented column.
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
    ## Move from readiness to a repeatable experiment

    Run `data-scientist/01_explore.ipynb` through its handoff cell for the chosen dataset, then open `01_train.ipynb`. A **handoff** is the saved recipe tying the approved column map, data fingerprint, features and split together.

    Change one `DATASET` assignment in the training notebook to follow Banking or your own described file. Keep the default runtime until the first experiment is working.
    """)
    return


if __name__ == "__main__":
    app.run()
