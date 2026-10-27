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
    # Ask your data

    - **Dataset:** Pharma, Banking, or your own approved descriptor.
    - **How long:** about five minutes to draft, inspect, approve and validate one question.

    Draft a question from an **approved** descriptor. Read the SQL and assumptions first. Edit the SQL if needed;
    approval applies to the exact text you reviewed. Only then does it run, using the kit's dedicated read-only identity.
    The SQL, row count and any model doubts are recorded under the active workflow id.
    Copy the workflow id printed by the quickstart into WORKFLOW_ID to keep the
    same log when this notebook runs in a separate kernel.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    DATASET = "pharma_trials"  # or "banking_complaints", or your own approved descriptor
    QUESTION = "How many rows are in each category?"
    DRAFT_WITH_MODEL = False  # set True after EXAKIT_NB_MODEL is configured; no rows are sent to draft SQL
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
    ## Draft and inspect

    The starter query uses the descriptor's category role. With DRAFT_WITH_MODEL=True, the opted-in model proposes SQL
    from the question, table and roles. It receives no table rows. The model may be wrong; check every table and number.
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
    ## Approve this SQL, then run

    Edit `proposal.edit("SELECT …")` if needed. Set APPROVE_SQL=True only after reading the printed query. Editing it
    afterwards removes approval. A Draft descriptor, write statement, or unapproved query is refused.
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
