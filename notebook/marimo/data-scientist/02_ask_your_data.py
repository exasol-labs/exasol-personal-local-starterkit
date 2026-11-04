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

    **Dataset:** Esophageal, Banking or your own approved descriptor. **How long:** about five minutes.

    Review a proposed query, approve it, then run it read-only. Set `WORKFLOW_ID` to continue the quickstart's log.

    Optional: `DRAFT_WITH_MODEL = True` lets your model draft the SQL from the approved column map: every column with its role, evidence and note (same `EXAKIT_MODEL_ID` settings as Explore; no rows are sent). Setup: the README in the notebooks folder.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    DATASET = None  # None: the dataset approved last in a quickstart (else esophageal_posts); or "banking_complaints", or your own approved descriptor
    QUESTION = "How many rows are in each category?"
    DRAFT_WITH_MODEL = False  # set True after EXAKIT_MODEL_ID is configured; no rows are sent to draft SQL
    WORKFLOW_ID = None  # paste the quickstart's wf-... id to continue its log

    DATASET = nb.chosen_dataset(DATASET)
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
    ## Review the proposal

    Read the SQL, what the model assumed and what it says to check. With the starter SQL (`DRAFT_WITH_MODEL = False`), changing `QUESTION` alone changes nothing; edit the SQL instead: `proposal.edit("SELECT ...")`.
    """)
    return


@app.cell
def _(DRAFT_WITH_MODEL, QUESTION, ds, nb):
    GROUPED_BY, BY = ds.group_by()   # the category, else the entity, else the target
    GROUP, COUNT = nb.name(BY), nb.count_name(ds)       # columns named after the data: SOCIAL_NETWORK, POSTS
    starter_sql = f"SELECT {BY} AS {GROUP}, COUNT(*) AS {COUNT} FROM {ds.fact_table} GROUP BY 1 ORDER BY {COUNT} DESC"
    if GROUPED_BY != "category":
        print(f"{ds.id} has no category; the starter SQL counts rows per {GROUPED_BY} ({BY}).")
    proposal = nb.ask(ds, QUESTION, proposed_sql=None if DRAFT_WITH_MODEL else starter_sql)
    proposal
    return (proposal,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Approve and run

    Nothing runs while `APPROVE_SQL = False`. After review, set `APPROVE_SQL = True` and rerun.

    Only the exact approved SQL runs, as the read-only user. `proposal.edit(...)` clears the approval.

    Next: `03_share.ipynb`.
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


if __name__ == "__main__":
    app.run()
