import marimo

__generated_with = "0.25.2"
app = marimo.App()


@app.cell
def _():
    import marimo as mo

    return (mo,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: exakit-guide-hint
    mo.md(r"""
    <div class="guide-start-hint">

    **Step 3 · Ask in plain words.** Click into the cell below and press **Shift + Enter** to open it: a question drafted into SQL, run only after you approve it. Its **Guided / Code** switch, top right, shows the code behind this page.

    </div>
    """)
    return


@app.cell
def _():
    # Cell tags: exakit-guide, skip-ci
    import exakit.guide as guide

    guide.ask()
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: exakit-code-start
    mo.md(r"""
    # The code behind this page

    <div class="guide-code-start"></div>

    The same steps as the cards above, as cells you can read, change and run one by one. **Code**, at the top right of a card, opens this section; **Guided** closes it again.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Ask your data with AI

    **Dataset:** the one you approved last (else `amazon_sales`), `fraud_transactions` or your own approved descriptor.

    ![Step 7 Ask with AI of nine: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](data:image/svg+xml;base64,PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnIHdpZHRoPSc4ODAnIGhlaWdodD0nMjcwJyB2aWV3Qm94PScwIDAgODgwIDI3MCc+PGRlZnM+PG1hcmtlciBpZD0nYScgdmlld0JveD0nMCAwIDEwIDEwJyByZWZYPSc5JyByZWZZPSc1JyBtYXJrZXJXaWR0aD0nNycgbWFya2VySGVpZ2h0PSc3JyBvcmllbnQ9J2F1dG8nPjxwYXRoIGQ9J00wIDAgTDEwIDUgTDAgMTAgeicgZmlsbD0nIzk4QTJCMycvPjwvbWFya2VyPjwvZGVmcz48cmVjdCB4PScxLjAnIHk9JzEnIHdpZHRoPScyNjguNycgaGVpZ2h0PScyNDAnIHJ4PScxMicgZmlsbD0nI0Y4RkFGQycgc3Ryb2tlPScjRDBENUREJyBzdHJva2Utd2lkdGg9JzEnLz48dGV4dCB4PScxMzUuMycgeT0nMjInIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTIuNScgZm9udC13ZWlnaHQ9JzcwMCcgZmlsbD0nIzQ3NTQ2Nyc+R2V0IHRoZSBkYXRhPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nMScgZGF0YS1jdXJyZW50PScwJyB4PScxMy4wJyB5PSczNCcgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nMTM1LjMnIHk9JzU3JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+MTwvdHNwYW4+ICBBY2Nlc3M8L3RleHQ+PGxpbmUgeDE9JzEzNS4zJyB5MT0nNzEnIHgyPScxMzUuMycgeTI9Jzg0JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPScyJyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzEzLjAnIHk9Jzg2JyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PScxMzUuMycgeT0nMTA5JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+MjwvdHNwYW4+ICBVbmRlcnN0YW5kPC90ZXh0PjxsaW5lIHgxPScyNzIuNycgeTE9JzUyLjAnIHgyPSczMDIuNycgeTI9JzUyLjAnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCB4PSczMDUuNycgeT0nMScgd2lkdGg9JzI2OC43JyBoZWlnaHQ9JzI0MCcgcng9JzEyJyBmaWxsPScjRjhGQUZDJyBzdHJva2U9JyNEMEQ1REQnIHN0cm9rZS13aWR0aD0nMScvPjx0ZXh0IHg9JzQ0MC4wJyB5PScyMicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjNDc1NDY3Jz5QcmVwYXJlIGFuZCBtb2RlbDwvdGV4dD48cmVjdCBkYXRhLXN0ZXA9JzMnIGRhdGEtY3VycmVudD0nMCcgeD0nMzE3LjcnIHk9JzM0JyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSc0NDAuMCcgeT0nNTcnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyMzNDQwNTQnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz4zPC90c3Bhbj4gIFByZXBhcmU8L3RleHQ+PGxpbmUgeDE9JzQ0MC4wJyB5MT0nNzEnIHgyPSc0NDAuMCcgeTI9Jzg0JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc0JyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzMxNy43JyB5PSc4Nicgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNDQwLjAnIHk9JzEwOScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjQ8L3RzcGFuPiAgRXhwbG9yZTwvdGV4dD48bGluZSB4MT0nNDQwLjAnIHkxPScxMjMnIHgyPSc0NDAuMCcgeTI9JzEzNicgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IGRhdGEtc3RlcD0nNScgZGF0YS1jdXJyZW50PScwJyB4PSczMTcuNycgeT0nMTM4JyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSc0NDAuMCcgeT0nMTYxJyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+NTwvdHNwYW4+ICBNb2RlbDwvdGV4dD48bGluZSB4MT0nNDQwLjAnIHkxPScxNzUnIHgyPSc0NDAuMCcgeTI9JzE4OCcgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IGRhdGEtc3RlcD0nNicgZGF0YS1jdXJyZW50PScwJyB4PSczMTcuNycgeT0nMTkwJyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSc0NDAuMCcgeT0nMjEzJyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+NjwvdHNwYW4+ICBWYWxpZGF0ZTwvdGV4dD48bGluZSB4MT0nNTc3LjMnIHkxPSc1Mi4wJyB4Mj0nNjA3LjMnIHkyPSc1Mi4wJyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgeD0nNjEwLjMnIHk9JzEnIHdpZHRoPScyNjguNycgaGVpZ2h0PScyNDAnIHJ4PScxMicgZmlsbD0nI0Y4RkFGQycgc3Ryb2tlPScjMUY2RkVCJyBzdHJva2Utd2lkdGg9JzEuNScvPjx0ZXh0IHg9Jzc0NC43JyB5PScyMicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjMUY2RkVCJz5Vc2UgYW5kIHNoYXJlPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nNycgZGF0YS1jdXJyZW50PScxJyB4PSc2MjIuMycgeT0nMzQnIHdpZHRoPScyNDQuNycgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyMxRjZGRUInIHN0cm9rZT0nIzFGNkZFQicvPjx0ZXh0IHg9Jzc0NC43JyB5PSc1NycgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nI0ZGRkZGRic+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjc8L3RzcGFuPiAgQXNrIHdpdGggQUk8L3RleHQ+PGxpbmUgeDE9Jzc0NC43JyB5MT0nNzEnIHgyPSc3NDQuNycgeTI9Jzg0JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc4JyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzYyMi4zJyB5PSc4Nicgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNzQ0LjcnIHk9JzEwOScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjg8L3RzcGFuPiAgU2hhcmU8L3RleHQ+PGxpbmUgeDE9Jzc0NC43JyB5MT0nMTIzJyB4Mj0nNzQ0LjcnIHkyPScxMzYnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCBkYXRhLXN0ZXA9JzknIGRhdGEtY3VycmVudD0nMCcgeD0nNjIyLjMnIHk9JzEzOCcgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNzQ0LjcnIHk9JzE2MScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjk8L3RzcGFuPiAgSGFuZCBvZmY8L3RleHQ+PHJlY3QgeD0nMScgeT0nMjUxJyB3aWR0aD0nMTQnIGhlaWdodD0nMTQnIHJ4PSczJyBmaWxsPScjMUY2RkVCJy8+PHRleHQgeD0nMjInIHk9JzI2MicgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmaWxsPScjNDc1NDY3Jz5UaGlzIG5vdGVib29rPC90ZXh0Pjwvc3ZnPg==)

    Ask a question in plain English. Read the proposed SQL, approve it, then run it read-only.

    Optional: set `DRAFT_WITH_MODEL = True` to let your model write the SQL. The model gets the column map only, never rows.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    | Setting | What it does |
    |---|---|
    | `DATASET` | `None`: the dataset approved last |
    | `QUESTION` | your question in words |
    | `DRAFT_WITH_MODEL` | `True`: your AI model drafts the SQL; no rows are sent |
    | `ASK_RULES` | changes to how the AI drafts: the order of the ways it tries and every word of its instructions; `nb.ask_rules()` lists them |
    | `DRAFT_RULES` | changes to the no-AI drafter, such as `{"MIN_GROUP_ROWS": 10, "SYNONYMS": {"amount": ["revenue", "turnover"]}}`; `nb.draft_rules()` lists them |
    | `INSIGHT_RULES` | changes to the insights, such as `{"TOP": 5, "OUTLIER_IQR": 3}`; `nb.insight_rules()` lists them |
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    DATASET = None
    QUESTION = "How many rows are in each category?"
    DRAFT_WITH_MODEL = False
    ASK_RULES = {}
    DRAFT_RULES = {}
    INSIGHT_RULES = {}

    dataset_id = nb.chosen_dataset(DATASET)
    nb.continue_workflow("questions")

    connection = nb.connect()
    dataset = nb.dataset(connection, dataset_id)
    dataset.require_approved("ask")
    nb.show_roles(dataset)
    return (
        ASK_RULES,
        DRAFT_RULES,
        DRAFT_WITH_MODEL,
        INSIGHT_RULES,
        QUESTION,
        connection,
        dataset,
        nb,
    )


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
    - **Not sure what to set?** Run `nb.model_setup()`. It asks for anything missing, with the keys in a hidden box, and prints the terminal lines that set them for every notebook.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    `MODEL_ID`, for example `"claude-opus-5-5"`; `PROVIDER_BASE_URL`, any Chat Completions address; `LANGFUSE_BASE_URL`, where the calls are traced. Empty: no model.
    """)
    return


@app.cell
def _(nb):
    MODEL_ID = ""
    PROVIDER_BASE_URL = ""
    LANGFUSE_BASE_URL = ""
    nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Review the proposal

    Read the SQL, the model's assumptions and its checks. With the starter SQL (`DRAFT_WITH_MODEL = False`), a new `QUESTION` does not change the SQL. Edit the SQL instead: `proposal.edit("SELECT ...")`.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    `DRAFT_WITH_RULES = True`: the kit's rules draft the question, no AI model needed. `EDITED_SQL`: your own SQL for it, which you then approve.
    """)
    return


@app.cell
def _(
    ASK_RULES,
    DRAFT_RULES,
    DRAFT_WITH_MODEL,
    QUESTION,
    connection,
    dataset,
    nb,
):
    GROUP_ROLE, GROUP_COLUMN = dataset.group_by()
    GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)
    starter_sql = f"SELECT {GROUP_COLUMN} AS {GROUP_HEADER}, COUNT(*) AS {COUNT_HEADER} FROM {dataset.fact_table} GROUP BY 1 ORDER BY {COUNT_HEADER} DESC"
    if GROUP_ROLE != "category":
        print(f"{dataset.id} has no category; the starter SQL counts rows per {GROUP_ROLE} ({GROUP_COLUMN}).")
    DRAFT_WITH_RULES = False
    if DRAFT_WITH_RULES:
        proposal = nb.draft_question(connection, dataset, QUESTION, rules=DRAFT_RULES)
    else:
        proposal = nb.ask(dataset, QUESTION, proposed_sql=None if DRAFT_WITH_MODEL else starter_sql, conn=connection, rules=ASK_RULES)
    EDITED_SQL = ""
    if EDITED_SQL:
        proposal.edit(EDITED_SQL)
    proposal
    return (proposal,)


@app.cell
def _(dataset, nb):
    examples = nb.example_questions(dataset)
    examples
    return


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
def _(connection, dataset, nb, proposal):
    APPROVE_SQL = False
    if APPROVE_SQL:
        proposal.approve()
        answer = proposal.run()
        print(f"{len(answer)} rows. Check the figures against the SQL above.")
    else:
        answer = None
        print("Not approved: no query ran. Review the proposal above, then set APPROVE_SQL = True and run this cell again.")
    currency = nb.currency_of(connection, dataset)
    nb.formatted(answer, dataset, currency) if answer is not None else None
    return (answer,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### What the answer says, and keeping it

    `nb.insights` writes the answer out in sentences by fixed rules (the largest and smallest, shares, the change over time, values far from the rest): no model and no new query. Pin the answer to a page of a dashboard (`nb.pin`): `03_share` publishes the pages as one dashboard with tabs and filters. When it was answered from the semantic model, `proposal.verify(connection)` keeps it in the model as a verified question: asked again, here or in an AI client, it is answered with this reviewed request.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    `PIN_TO`: a dashboard and a page, such as `("sales-overview", "Revenue")`. `TILE_TITLE`: the tile's title on the dashboard (None: the question; set it when you rewrote the SQL to answer something else). `KEEP_AS_VERIFIED = True` keeps the question as a trusted question.
    """)
    return


@app.cell
def _(INSIGHT_RULES, answer, connection, nb, proposal):
    PIN_TO = None
    TILE_TITLE = None
    KEEP_AS_VERIFIED = False
    if answer is not None:
        insights = nb.insights(answer, rules=INSIGHT_RULES)
        print("\n".join(insights))
        if PIN_TO:
            pinned = nb.pin(proposal, answer, board=PIN_TO[0], page=PIN_TO[1], title=TILE_TITLE)
            preparing = nb.prepare_preview(PIN_TO[0])   # its preview is built in the background: 03_share shows it at once
        if KEEP_AS_VERIFIED:
            verified = proposal.verify(connection)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next: steps 8 and 9

    Open `03_share` to publish a dashboard and hand off the work.
    """)
    return


if __name__ == "__main__":
    app.run()
