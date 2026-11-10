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

    **Dataset:** the one you approved last (else `amazon_sales`), `fraud_transactions` or your own approved descriptor.

    ![Step 7 Ask with AI of nine: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](data:image/svg+xml;base64,PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnIHdpZHRoPSc4ODAnIGhlaWdodD0nOTQnIHZpZXdCb3g9JzAgMCA4ODAgOTQnPjxyZWN0IHg9JzEuMCcgeT0nMScgd2lkdGg9Jzg1LjEnIGhlaWdodD0nNTgnIHJ4PScxMCcgZmlsbD0nI0YyRjRGNycgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNDMuNicgeT0nMjYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTgnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyMzNDQwNTQnPjE8L3RleHQ+PHRleHQgeD0nNDMuNicgeT0nNDYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTEuNScgZmlsbD0nIzQ3NTQ2Nyc+QWNjZXNzPC90ZXh0PjxwYXRoIGQ9J005MC4xIDI0IEw5Ni4xIDMwIEw5MC4xIDM2JyBmaWxsPSdub25lJyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMicgc3Ryb2tlLWxpbmVjYXA9J3JvdW5kJyBzdHJva2UtbGluZWpvaW49J3JvdW5kJy8+PHJlY3QgeD0nMTAwLjEnIHk9JzEnIHdpZHRoPSc4NS4xJyBoZWlnaHQ9JzU4JyByeD0nMTAnIGZpbGw9JyNGMkY0RjcnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9JzE0Mi43JyB5PScyNicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxOCcgZm9udC13ZWlnaHQ9JzcwMCcgZmlsbD0nIzM0NDA1NCc+MjwvdGV4dD48dGV4dCB4PScxNDIuNycgeT0nNDYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTEuNScgZmlsbD0nIzQ3NTQ2Nyc+VW5kZXJzdGFuZDwvdGV4dD48cGF0aCBkPSdNMTg5LjIgMjQgTDE5NS4yIDMwIEwxODkuMiAzNicgZmlsbD0nbm9uZScgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzInIHN0cm9rZS1saW5lY2FwPSdyb3VuZCcgc3Ryb2tlLWxpbmVqb2luPSdyb3VuZCcvPjxyZWN0IHg9JzE5OS4yJyB5PScxJyB3aWR0aD0nODUuMScgaGVpZ2h0PSc1OCcgcng9JzEwJyBmaWxsPScjRjJGNEY3JyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PScyNDEuOCcgeT0nMjYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTgnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyMzNDQwNTQnPjM8L3RleHQ+PHRleHQgeD0nMjQxLjgnIHk9JzQ2JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzExLjUnIGZpbGw9JyM0NzU0NjcnPlByZXBhcmU8L3RleHQ+PHBhdGggZD0nTTI4OC4zIDI0IEwyOTQuMyAzMCBMMjg4LjMgMzYnIGZpbGw9J25vbmUnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScyJyBzdHJva2UtbGluZWNhcD0ncm91bmQnIHN0cm9rZS1saW5lam9pbj0ncm91bmQnLz48cmVjdCB4PScyOTguMycgeT0nMScgd2lkdGg9Jzg1LjEnIGhlaWdodD0nNTgnIHJ4PScxMCcgZmlsbD0nI0YyRjRGNycgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nMzQwLjknIHk9JzI2JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzE4JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjMzQ0MDU0Jz40PC90ZXh0Pjx0ZXh0IHg9JzM0MC45JyB5PSc0NicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMS41JyBmaWxsPScjNDc1NDY3Jz5FeHBsb3JlPC90ZXh0PjxwYXRoIGQ9J00zODcuNCAyNCBMMzkzLjQgMzAgTDM4Ny40IDM2JyBmaWxsPSdub25lJyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMicgc3Ryb2tlLWxpbmVjYXA9J3JvdW5kJyBzdHJva2UtbGluZWpvaW49J3JvdW5kJy8+PHJlY3QgeD0nMzk3LjQnIHk9JzEnIHdpZHRoPSc4NS4xJyBoZWlnaHQ9JzU4JyByeD0nMTAnIGZpbGw9JyNGMkY0RjcnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9JzQ0MC4wJyB5PScyNicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxOCcgZm9udC13ZWlnaHQ9JzcwMCcgZmlsbD0nIzM0NDA1NCc+NTwvdGV4dD48dGV4dCB4PSc0NDAuMCcgeT0nNDYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTEuNScgZmlsbD0nIzQ3NTQ2Nyc+TW9kZWw8L3RleHQ+PHBhdGggZD0nTTQ4Ni42IDI0IEw0OTIuNiAzMCBMNDg2LjYgMzYnIGZpbGw9J25vbmUnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScyJyBzdHJva2UtbGluZWNhcD0ncm91bmQnIHN0cm9rZS1saW5lam9pbj0ncm91bmQnLz48cmVjdCB4PSc0OTYuNicgeT0nMScgd2lkdGg9Jzg1LjEnIGhlaWdodD0nNTgnIHJ4PScxMCcgZmlsbD0nI0YyRjRGNycgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNTM5LjEnIHk9JzI2JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzE4JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjMzQ0MDU0Jz42PC90ZXh0Pjx0ZXh0IHg9JzUzOS4xJyB5PSc0NicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMS41JyBmaWxsPScjNDc1NDY3Jz5WYWxpZGF0ZTwvdGV4dD48cGF0aCBkPSdNNTg1LjcgMjQgTDU5MS43IDMwIEw1ODUuNyAzNicgZmlsbD0nbm9uZScgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzInIHN0cm9rZS1saW5lY2FwPSdyb3VuZCcgc3Ryb2tlLWxpbmVqb2luPSdyb3VuZCcvPjxyZWN0IHg9JzU5NS43JyB5PScxJyB3aWR0aD0nODUuMScgaGVpZ2h0PSc1OCcgcng9JzEwJyBmaWxsPScjMUY2RkVCJyBzdHJva2U9JyMxRjZGRUInLz48dGV4dCB4PSc2MzguMicgeT0nMjYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTgnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyNGRkZGRkYnPjc8L3RleHQ+PHRleHQgeD0nNjM4LjInIHk9JzQ2JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzExLjUnIGZpbGw9JyNGRkZGRkYnPkFzayB3aXRoIEFJPC90ZXh0PjxwYXRoIGQ9J002ODQuOCAyNCBMNjkwLjggMzAgTDY4NC44IDM2JyBmaWxsPSdub25lJyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMicgc3Ryb2tlLWxpbmVjYXA9J3JvdW5kJyBzdHJva2UtbGluZWpvaW49J3JvdW5kJy8+PHJlY3QgeD0nNjk0LjgnIHk9JzEnIHdpZHRoPSc4NS4xJyBoZWlnaHQ9JzU4JyByeD0nMTAnIGZpbGw9JyNGMkY0RjcnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9JzczNy4zJyB5PScyNicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxOCcgZm9udC13ZWlnaHQ9JzcwMCcgZmlsbD0nIzM0NDA1NCc+ODwvdGV4dD48dGV4dCB4PSc3MzcuMycgeT0nNDYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTEuNScgZmlsbD0nIzQ3NTQ2Nyc+U2hhcmU8L3RleHQ+PHBhdGggZD0nTTc4My45IDI0IEw3ODkuOSAzMCBMNzgzLjkgMzYnIGZpbGw9J25vbmUnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScyJyBzdHJva2UtbGluZWNhcD0ncm91bmQnIHN0cm9rZS1saW5lam9pbj0ncm91bmQnLz48cmVjdCB4PSc3OTMuOScgeT0nMScgd2lkdGg9Jzg1LjEnIGhlaWdodD0nNTgnIHJ4PScxMCcgZmlsbD0nI0YyRjRGNycgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nODM2LjQnIHk9JzI2JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzE4JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjMzQ0MDU0Jz45PC90ZXh0Pjx0ZXh0IHg9JzgzNi40JyB5PSc0NicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMS41JyBmaWxsPScjNDc1NDY3Jz5IYW5kIG9mZjwvdGV4dD48cmVjdCB4PSc1OTUuNycgeT0nNjYnIHdpZHRoPSc4NS4xJyBoZWlnaHQ9JzQnIHJ4PScyJyBmaWxsPScjMUY2RkVCJy8+PHRleHQgeD0nNjM4LjInIHk9Jzg4JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEyLjUnIGZvbnQtd2VpZ2h0PSc2MDAnIGZpbGw9JyMxRjZGRUInPlRoaXMgbm90ZWJvb2s8L3RleHQ+PC9zdmc+)

    Ask a question in plain English. Read the proposed SQL, approve it, then run it read-only.

    Optional: set `DRAFT_WITH_MODEL = True` to let your model write the SQL. The model gets the column map only, never rows.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    DATASET = None  # None: the dataset approved last in a quickstart (else amazon_sales); or "fraud_transactions", or your own approved descriptor
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
    ## Step 7 · Ask your data

    1. You ask a question.
    2. The starter SQL or your model writes the query from the column map.
    3. You read and approve the query.
    4. The query runs with read-only rights.

    With Langfuse set up, each model call is traced: what was sent, the answer and the cost.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Your AI model and Langfuse (optional)

    Only `DRAFT_WITH_MODEL = True` needs this.

    - **In the cell:** `MODEL_ID`, `PROVIDER_BASE_URL` (any Chat Completions endpoint, listed in `MODEL-PROVIDERS.md`) and `LANGFUSE_BASE_URL` (where calls are traced).
    - **Not in the cell:** the API key and the two Langfuse keys. A hidden box asks for them. They stay in this kernel only.
    - **For every notebook:** run `nb.model_setup()`. It prints the terminal lines for this machine.
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

    Read the SQL, the model's assumptions and its checks. With the starter SQL (`DRAFT_WITH_MODEL = False`), a new `QUESTION` does not change the SQL. Edit the SQL instead: `proposal.edit("SELECT ...")`.
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

    A proposed query can be wrong: a wrong column, a missing filter. Read it before you approve it.

    1. Set `APPROVE_SQL = True`.
    2. Run the cell again.

    Only the exact approved SQL runs, as the read-only user. `proposal.edit(...)` removes the approval.
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

    Open `03_share.ipynb` to publish a dashboard and hand off the work.
    """)
    return


if __name__ == "__main__":
    app.run()
