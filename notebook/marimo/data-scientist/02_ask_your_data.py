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
    # Ask your data with AI

    **Dataset:** the one you approved last (else `amazon_sales`), `walmart_sales`, `fraud_transactions` or your own approved descriptor. **How long:** about five minutes.

    **The journey:** 1 Access → 2 Understand → 3 Prepare → 4 Explore → 5 Model → 6 Validate → **7 Ask with AI** → 8 Share → 9 Hand off. **This notebook: step 7.**

    Ask a question in plain English, review the SQL proposed for it, approve it, then run it read-only. It continues the quickstart's workflow log on its own.

    Optional: `DRAFT_WITH_MODEL = True` lets your model draft the SQL from the approved column map: every column with its role, evidence and note (no rows are sent). Set the model up in the cell *Your AI model and Langfuse* below - an external one (Claude, OpenAI, ...) or one running on your own machine (Ollama) both work.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    DATASET = None  # None: the dataset approved last in a quickstart (else amazon_sales); or "walmart_sales", "fraud_transactions", or your own approved descriptor
    QUESTION = "How many rows are in each category?"
    DRAFT_WITH_MODEL = False  # True: your model drafts the SQL (set it up in the model cell below); no rows are sent

    dataset_id = nb.chosen_dataset(DATASET)
    nb.continue_workflow("questions")   # the quickstart's workflow, or the last one: nothing to paste

    connection = nb.connect()
    dataset = nb.dataset(connection, dataset_id)
    dataset.require_approved("ask")
    nb.show_roles(dataset)
    return DRAFT_WITH_MODEL, QUESTION, dataset, nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 7 · Ask your data with AI

    > **What happens here?** You ask in words; the notebook (or your AI model) turns the question into SQL from the approved column map; you read that SQL and approve it; only then does it run, with read-only rights. The model never sees your rows - only the column map - and every call can be recorded in Langfuse so you can see what was sent, what came back and what it cost.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Your AI model and Langfuse (optional)

    > **What is this?** Where you tell the notebook which AI model drafts the SQL, and where to record its calls (Langfuse: what was sent, the answer, the cost).
    > We set it here so you need no terminal: fill in the plain values and run the cell; the keys are asked for in a hidden box.
    > The keys stay in this notebook's kernel only - never in this file - and are gone when it stops. Left empty, the cell changes nothing and the starter SQL is used.

    Rather set them for every notebook? Export `EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL`, `EXAKIT_PROVIDER_API_KEY` and the `LANGFUSE_*` keys in the terminal before `exakit notebook` (the README in the notebooks folder shows how).
    """)
    return


@app.cell
def _(nb):
    MODEL_ID = ""           # e.g. "claude-opus-5-5"; empty: no model (or the one set before `exakit notebook`)
    PROVIDER_BASE_URL = ""  # e.g. "https://api.anthropic.com/v1/" - any Chat Completions endpoint (MODEL-PROVIDERS.md lists more)
    LANGFUSE_BASE_URL = ""  # e.g. "https://cloud.langfuse.com"; empty: the model calls are not traced
    nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Review the proposal

    Read the SQL, what the model assumed and what it says to check. With the starter SQL (`DRAFT_WITH_MODEL = False`), changing `QUESTION` alone changes nothing; edit the SQL instead: `proposal.edit("SELECT ...")`.
    """)
    return


@app.cell
def _(DRAFT_WITH_MODEL, QUESTION, dataset, nb):
    GROUP_ROLE, GROUP_COLUMN = dataset.group_by()   # the category, else the entity, else the target
    GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)       # columns named after the data: CATEGORY, ORDER_LINES
    starter_sql = f"SELECT {GROUP_COLUMN} AS {GROUP_HEADER}, COUNT(*) AS {COUNT_HEADER} FROM {dataset.fact_table} GROUP BY 1 ORDER BY {COUNT_HEADER} DESC"
    if GROUP_ROLE != "category":
        print(f"{dataset.id} has no category; the starter SQL counts rows per {GROUP_ROLE} ({GROUP_COLUMN}).")
    proposal = nb.ask(dataset, QUESTION, proposed_sql=None if DRAFT_WITH_MODEL else starter_sql)
    proposal
    return (proposal,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Approve and run

    > **Why approve a query?** A query written for you, by the starter SQL or by a model, can be subtly wrong: the wrong column, a missing filter.
    > You read it and say yes first; only that exact text then runs.
    > It runs with read-only rights, so it can never change your data.

    Nothing runs while `APPROVE_SQL = False`. After review, set `APPROVE_SQL = True` and rerun.

    Only the exact approved SQL runs, as the read-only user. `proposal.edit(...)` clears the approval.
    """)
    return


@app.cell
def _(proposal):
    APPROVE_SQL = False
    if APPROVE_SQL:
        proposal.approve()
        answer = proposal.run()
        print(f"{len(answer)} rows. Check the figures against the SQL above.")
    else:
        answer = None
        print("Not approved: no query ran. Review the proposal above, then set APPROVE_SQL = True and run this cell again.")
    answer
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next: steps 8 and 9

    Open `03_share.ipynb`: publish a dashboard others can open, then hand the whole piece of work off in one bundle.
    """)
    return


if __name__ == "__main__":
    app.run()
