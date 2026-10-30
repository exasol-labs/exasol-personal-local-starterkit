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
    # Ask a question and keep control of the answer

    **Dataset:** Pharma, Banking or your own approved descriptor. **How long:** about five minutes.

    A colleague asks how records are distributed across categories. You will inspect a proposed query, decide whether it answers the question and approve the exact SQL before it runs. In Pharma that means trial phases; in Banking it means complaint products.

    **By the end:** you will have a read-only answer and a record of the SQL you approved. Paste the quickstart's workflow ID into `WORKFLOW_ID` to connect it to the earlier investigation.

    **Optional AI:** the supplied query works with `DRAFT_WITH_MODEL = False`. A configured model can draft a different query when you opt in; you still inspect and approve it.
    Use the same `EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL` and `EXAKIT_PROVIDER_API_KEY` as Explore. The [provider guide](../MODEL-PROVIDERS.md) explains documented connection options and their limits. A compatible endpoint does not guarantee valid SQL or JSON; the helper validates the proposal before you approve it.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    DATASET = "pharma_trials"  # or "banking_complaints", or your own approved descriptor
    QUESTION = "How many rows are in each category?"
    DRAFT_WITH_MODEL = False  # set True after EXAKIT_MODEL_ID is configured; no rows are sent to draft SQL
    WORKFLOW_ID = None  # paste the quickstart's wf-... id to continue its log

    if WORKFLOW_ID:
        nb.workflow(resume=WORKFLOW_ID)
    elif not nb.current_workflow():
        nb.workflow("questions")

    conn = nb.connect()
    ds = nb.dataset(conn, DATASET)
    ds.require_approved("ask")
    nb.show_roles(ds)
    return DRAFT_WITH_MODEL, QUESTION, ds, nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Start from a question you can check

    The supplied question counts records per category. Read the SQL, assumptions and doubts before approving anything. Does it use the intended table and grouping? Would the result actually answer the question?

    **Technical note:** in the supplied mode, the SQL template determines the answer; changing `QUESTION` alone does not rewrite it. Edit the proposed SQL to ask a different manual question. With `DRAFT_WITH_MODEL = True`, your configured endpoint drafts from the question and approved table/role metadata, without receiving table rows. Treat its proposal as something to review.
    """)
    return


@app.cell
def _(DRAFT_WITH_MODEL, QUESTION, ds, nb):
    starter_sql = f"SELECT {ds.col('category')} AS CATEGORY, COUNT(*) AS N FROM {ds.fact_table} GROUP BY 1 ORDER BY N DESC"
    proposal = nb.ask(ds, QUESTION, proposed_sql=None if DRAFT_WITH_MODEL else starter_sql)
    print("Assumptions:", proposal.assumptions or "none")
    print("Doubts:", proposal.doubts or "none")
    return (proposal,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Make the execution an explicit decision

    First run the next cell with `APPROVE_SQL = False`: it should say that no query ran. After inspecting the proposal, set it to `True` and rerun the cell. Compare the returned counts with the exploration results.

    **Technical note:** approval belongs to the exact SQL text. `proposal.edit("SELECT ...")` removes an earlier approval. The execution uses the kit's read-only identity; write statements, unapproved SQL and draft descriptors are refused. The workflow records the query and row count.

    **Continue:** use `03_share.ipynb` when the result is worth showing to someone else.
    """)
    return


@app.cell
def _(proposal):
    APPROVE_SQL = False
    if APPROVE_SQL:
        proposal.approve()
        answer = proposal.run()
        print(f"{len(answer)} rows returned. Check the figures against the SQL printed above.")
        print(answer)
    else:
        print("SQL not approved; no query ran. Review it and set APPROVE_SQL=True to continue.")
    return


if __name__ == "__main__":
    app.run()
