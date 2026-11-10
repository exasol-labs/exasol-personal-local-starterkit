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
    # Prepare, explore, model, validate

    **Dataset:** the one you approved last (else `amazon_sales`). Change `DATASET` for `fraud_transactions` or your own file.

    ![Steps 3 Prepare, 4 Explore, 5 Model and 6 Validate of nine: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](data:image/svg+xml;base64,PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnIHdpZHRoPSc4ODAnIGhlaWdodD0nMjcwJyB2aWV3Qm94PScwIDAgODgwIDI3MCc+PGRlZnM+PG1hcmtlciBpZD0nYScgdmlld0JveD0nMCAwIDEwIDEwJyByZWZYPSc5JyByZWZZPSc1JyBtYXJrZXJXaWR0aD0nNycgbWFya2VySGVpZ2h0PSc3JyBvcmllbnQ9J2F1dG8nPjxwYXRoIGQ9J00wIDAgTDEwIDUgTDAgMTAgeicgZmlsbD0nIzk4QTJCMycvPjwvbWFya2VyPjwvZGVmcz48cmVjdCB4PScxLjAnIHk9JzEnIHdpZHRoPScyNjguNycgaGVpZ2h0PScyNDAnIHJ4PScxMicgZmlsbD0nI0Y4RkFGQycgc3Ryb2tlPScjRDBENUREJyBzdHJva2Utd2lkdGg9JzEnLz48dGV4dCB4PScxMzUuMycgeT0nMjInIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTIuNScgZm9udC13ZWlnaHQ9JzcwMCcgZmlsbD0nIzQ3NTQ2Nyc+R2V0IHRoZSBkYXRhPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nMScgZGF0YS1jdXJyZW50PScwJyB4PScxMy4wJyB5PSczNCcgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nMTM1LjMnIHk9JzU3JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+MTwvdHNwYW4+ICBBY2Nlc3M8L3RleHQ+PGxpbmUgeDE9JzEzNS4zJyB5MT0nNzEnIHgyPScxMzUuMycgeTI9Jzg0JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPScyJyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzEzLjAnIHk9Jzg2JyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PScxMzUuMycgeT0nMTA5JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+MjwvdHNwYW4+ICBVbmRlcnN0YW5kPC90ZXh0PjxsaW5lIHgxPScyNzIuNycgeTE9JzUyLjAnIHgyPSczMDIuNycgeTI9JzUyLjAnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCB4PSczMDUuNycgeT0nMScgd2lkdGg9JzI2OC43JyBoZWlnaHQ9JzI0MCcgcng9JzEyJyBmaWxsPScjRjhGQUZDJyBzdHJva2U9JyMxRjZGRUInIHN0cm9rZS13aWR0aD0nMS41Jy8+PHRleHQgeD0nNDQwLjAnIHk9JzIyJyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEyLjUnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyMxRjZGRUInPlByZXBhcmUgYW5kIG1vZGVsPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nMycgZGF0YS1jdXJyZW50PScxJyB4PSczMTcuNycgeT0nMzQnIHdpZHRoPScyNDQuNycgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyMxRjZGRUInIHN0cm9rZT0nIzFGNkZFQicvPjx0ZXh0IHg9JzQ0MC4wJyB5PSc1NycgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nI0ZGRkZGRic+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjM8L3RzcGFuPiAgUHJlcGFyZTwvdGV4dD48bGluZSB4MT0nNDQwLjAnIHkxPSc3MScgeDI9JzQ0MC4wJyB5Mj0nODQnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCBkYXRhLXN0ZXA9JzQnIGRhdGEtY3VycmVudD0nMScgeD0nMzE3LjcnIHk9Jzg2JyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjMUY2RkVCJyBzdHJva2U9JyMxRjZGRUInLz48dGV4dCB4PSc0NDAuMCcgeT0nMTA5JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjRkZGRkZGJz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+NDwvdHNwYW4+ICBFeHBsb3JlPC90ZXh0PjxsaW5lIHgxPSc0NDAuMCcgeTE9JzEyMycgeDI9JzQ0MC4wJyB5Mj0nMTM2JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc1JyBkYXRhLWN1cnJlbnQ9JzEnIHg9JzMxNy43JyB5PScxMzgnIHdpZHRoPScyNDQuNycgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyMxRjZGRUInIHN0cm9rZT0nIzFGNkZFQicvPjx0ZXh0IHg9JzQ0MC4wJyB5PScxNjEnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyNGRkZGRkYnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz41PC90c3Bhbj4gIE1vZGVsPC90ZXh0PjxsaW5lIHgxPSc0NDAuMCcgeTE9JzE3NScgeDI9JzQ0MC4wJyB5Mj0nMTg4JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc2JyBkYXRhLWN1cnJlbnQ9JzEnIHg9JzMxNy43JyB5PScxOTAnIHdpZHRoPScyNDQuNycgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyMxRjZGRUInIHN0cm9rZT0nIzFGNkZFQicvPjx0ZXh0IHg9JzQ0MC4wJyB5PScyMTMnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyNGRkZGRkYnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz42PC90c3Bhbj4gIFZhbGlkYXRlPC90ZXh0PjxsaW5lIHgxPSc1NzcuMycgeTE9JzUyLjAnIHgyPSc2MDcuMycgeTI9JzUyLjAnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCB4PSc2MTAuMycgeT0nMScgd2lkdGg9JzI2OC43JyBoZWlnaHQ9JzI0MCcgcng9JzEyJyBmaWxsPScjRjhGQUZDJyBzdHJva2U9JyNEMEQ1REQnIHN0cm9rZS13aWR0aD0nMScvPjx0ZXh0IHg9Jzc0NC43JyB5PScyMicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjNDc1NDY3Jz5Vc2UgYW5kIHNoYXJlPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nNycgZGF0YS1jdXJyZW50PScwJyB4PSc2MjIuMycgeT0nMzQnIHdpZHRoPScyNDQuNycgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyNGRkZGRkYnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9Jzc0NC43JyB5PSc1NycgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjc8L3RzcGFuPiAgQXNrIHdpdGggQUk8L3RleHQ+PGxpbmUgeDE9Jzc0NC43JyB5MT0nNzEnIHgyPSc3NDQuNycgeTI9Jzg0JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc4JyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzYyMi4zJyB5PSc4Nicgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNzQ0LjcnIHk9JzEwOScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjg8L3RzcGFuPiAgU2hhcmU8L3RleHQ+PGxpbmUgeDE9Jzc0NC43JyB5MT0nMTIzJyB4Mj0nNzQ0LjcnIHkyPScxMzYnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCBkYXRhLXN0ZXA9JzknIGRhdGEtY3VycmVudD0nMCcgeD0nNjIyLjMnIHk9JzEzOCcgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNzQ0LjcnIHk9JzE2MScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjk8L3RzcGFuPiAgSGFuZCBvZmY8L3RleHQ+PHJlY3QgeD0nMScgeT0nMjUxJyB3aWR0aD0nMTQnIGhlaWdodD0nMTQnIHJ4PSczJyBmaWxsPScjMUY2RkVCJy8+PHRleHQgeD0nMjInIHk9JzI2MicgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmaWxsPScjNDc1NDY3Jz5UaGlzIG5vdGVib29rPC90ZXh0Pjwvc3ZnPg==)

    Each query is built from the approved column map, so no cell names a column. If the data has no date or no text, the step that needs it skips and says why. All settings are in the first cell. The AI step at the end is optional and off.
    """)
    return


@app.cell
def _():
    DATASET = None   # None: the dataset approved last in a quickstart (else amazon_sales); or "fraud_transactions", or your own file ("~/my-data/transactions.csv", roles beside it)
    USE_AI_THEMES = False  # True: your model sorts the texts into themes (needs a text column and EXAKIT_MODEL_ID; see the AI step below)
    USE_JOINED = False     # True: approve the schema map and create the joined view proposed under Prepare (several tables), and explore that
    USE_PREPARED = False   # True: create the typed, cleaned view proposed under Prepare and explore that instead (nothing is created before)
    return DATASET, USE_AI_THEMES, USE_JOINED, USE_PREPARED


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Optional · Your AI model and Langfuse

    Only the AI step at the end needs this.

    - **In the cell:** `MODEL_ID`, `PROVIDER_BASE_URL` (any Chat Completions endpoint, listed in `MODEL-PROVIDERS.md`) and `LANGFUSE_BASE_URL` (where calls are traced).
    - **Not in the cell:** the API key and the two Langfuse keys. A hidden box asks for them. They stay in this kernel only.
    - **Not sure what to set?** Run `nb.model_setup()`. It asks for anything missing, with the keys in a hidden box, and prints the terminal lines that set them for every notebook.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    MODEL_ID = ""           # e.g. "claude-opus-5-5"; empty: no model (or the one set before `exakit notebook`)
    PROVIDER_BASE_URL = ""  # e.g. "https://api.anthropic.com/v1/" - any Chat Completions endpoint (MODEL-PROVIDERS.md lists more)
    LANGFUSE_BASE_URL = ""  # e.g. "https://cloud.langfuse.com"; empty: the model calls are not traced
    nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)
    return (nb,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 2, continued · Your column map

    Every query below is built from this map. A draft map is enough here.
    """)
    return


@app.cell
def _(DATASET, nb):
    import os
    workflow_id = nb.continue_workflow('explore')
    connection = nb.connect()
    dataset_id = nb.chosen_dataset(DATASET)  # the quickstart's workflow, or the last one: nothing to paste
    loaded_dataset = nb.review_roles(connection, dataset_id).dataset(draft_ok=True)
    nb.show_roles(loaded_dataset)  # the table as loaded; `dataset` below is what the steps read
    return connection, loaded_dataset


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 3 · Prepare the data

    Three checks: is the data clean, does it link to other tables, are the column types correct. They only propose. The table never changes. A view is created only when you set it in the first cell.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Is the data clean?

    Finds repeated IDs, empty cells, placeholders such as "Unknown" and a rare label, and says what each does to a result. It changes nothing. `fraud_transactions` has all of them.
    """)
    return


@app.cell
def _(connection, loaded_dataset, nb):
    findings = nb.data_checks(connection, loaded_dataset)
    findings
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Linked tables

    Shows the tables that link to this one, with the evidence for each link. A link adds the other table's columns without adding rows.

    To correct a link: `schema_map.unlink("TABLE.COLUMN")` or `schema_map.link("TABLE.COLUMN", "TABLE.KEY")`.
    """)
    return


@app.cell
def _(connection, loaded_dataset, nb):
    schema_map = nb.describe_schema(connection, loaded_dataset)
    schema_map
    return (schema_map,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    The joined view combines this table with every linked table. Read the joins and the SQL. To use it, set `USE_JOINED = True` in the first cell and run again. The view goes into `EXAKIT_PREPARED`, and the steps below read it.
    """)
    return


@app.cell
def _(USE_JOINED, connection, loaded_dataset, schema_map):
    joined_view_proposal = schema_map.joined_view(loaded_dataset)
    joined_dataset = joined_view_proposal.create(connection) if USE_JOINED and joined_view_proposal.needed else loaded_dataset
    joined_view_proposal
    return (joined_dataset,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### A typed, cleaned view

    Proposes a view with correct types (numbers, dates), blanks and placeholders as NULL, and exact copies removed. The table never changes.

    Read what changes. To use it, set `USE_PREPARED = True` in the first cell and run again. The view goes into `EXAKIT_PREPARED`, and the steps below read it.
    """)
    return


@app.cell
def _(USE_PREPARED, connection, joined_dataset, nb):
    typed_view_proposal = nb.typed_view(connection, joined_dataset)
    dataset = typed_view_proposal.create(connection) if USE_PREPARED and typed_view_proposal.needed else joined_dataset   # the dataset every step below reads
    typed_view_proposal
    return (dataset,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 4 · Explore

    Compares the groups and follows the outcome over time. Each query shows its SQL, then the result and a short note.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Columns for the steps below

    A role that the data does not have is `None`. A step that needs it skips and says why.
    """)
    return


@app.cell
def _(dataset):
    ENTITY_COLUMN = dataset.col("entity") if dataset.has("entity") else None
    CATEGORY_COLUMN = dataset.col("category") if dataset.has("category") else None
    TEXT_SQL = dataset.text_sql() if dataset.has("text") else None
    DATE_COLUMN = dataset.col("date") if dataset.has("date") else None      # a role no column fits is None here, never guessed
    LABEL_COLUMN = dataset.col("label") if dataset.has("label") else None
    missing_roles = {missing["role"]: missing["reason"] for missing in dataset.missing if not dataset.has(missing["role"])}
    missing_line = "; ".join(f"no {role} role: {reason}" for role, reason in missing_roles.items())
    for role in ("entity", "category", "date", "label", "text"):
        if role in missing_roles:
            print(f"No {role} role ({missing_roles[role]}): steps that need it explain why they skip below.")
    return (
        CATEGORY_COLUMN,
        DATE_COLUMN,
        ENTITY_COLUMN,
        LABEL_COLUMN,
        TEXT_SQL,
        missing_line,
    )


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Compare groups

    The 10 largest entities by category: the row count and the % where the label is 1.
    """)
    return


@app.cell
def _(
    CATEGORY_COLUMN,
    ENTITY_COLUMN,
    LABEL_COLUMN,
    connection,
    dataset,
    missing_line,
    nb,
):
    landscape = landscape_grid = None
    # Result columns are named after the data (SHIP_STATE, ORDER_LINES, CANCELLED_PCT); a note under each result says
    # what its numbers mean.
    COUNT_HEADER = nb.count_name(dataset)
    ENTITY_HEADER = nb.name(ENTITY_COLUMN) if ENTITY_COLUMN else None
    CATEGORY_HEADER = nb.name(CATEGORY_COLUMN) if CATEGORY_COLUMN else None
    LABEL_PCT_HEADER = nb.name(LABEL_COLUMN, "PCT") if LABEL_COLUMN else None
    if not all(dataset.has(role) for role in ("entity", "category", "label")):
        print(f"Skipped - the landscape needs entity, category and label roles ({missing_line}).")
    else:
        overall_rate = nb.sql(connection, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({LABEL_COLUMN}), 1) AS PCT FROM {dataset.fact_table}")
        landscape = nb.sql(connection, f"""
    WITH TOP_ENTITIES AS (
        SELECT {ENTITY_COLUMN} AS ENTITY, COUNT(*) AS N_ROWS
        FROM {dataset.fact_table}
        GROUP BY {ENTITY_COLUMN}
        ORDER BY N_ROWS DESC
        LIMIT 10)
    SELECT T.ENTITY AS {ENTITY_HEADER},
           F.{CATEGORY_COLUMN} AS {CATEGORY_HEADER},
           COUNT(*) AS {COUNT_HEADER},
           ROUND(100 * AVG(F.{LABEL_COLUMN}), 1) AS {LABEL_PCT_HEADER}
    FROM {dataset.fact_table} F
    JOIN TOP_ENTITIES T ON F.{ENTITY_COLUMN} = T.ENTITY
    GROUP BY T.ENTITY, F.{CATEGORY_COLUMN}
    ORDER BY T.ENTITY, {COUNT_HEADER} DESC""")
        nb.show_sql()
        nb.note_groups(landscape, dataset, (ENTITY_HEADER, CATEGORY_HEADER), COUNT_HEADER, LABEL_PCT_HEADER, overall=(overall_rate["N"][0], overall_rate["PCT"][0]))
        landscape_grid = landscape.pivot_table(index=ENTITY_HEADER, columns=CATEGORY_HEADER, values=COUNT_HEADER, fill_value=0, aggfunc="sum")
    landscape
    return COUNT_HEADER, LABEL_PCT_HEADER, landscape_grid


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    The same counts as a grid: one row per entity, one column per category.
    """)
    return


@app.cell
def _(landscape_grid):
    landscape_grid
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Over time

    Rows per day, month or year, and the % where the label is 1. Needs the date and label roles.
    """)
    return


@app.cell
def _(
    COUNT_HEADER,
    DATE_COLUMN,
    LABEL_COLUMN,
    LABEL_PCT_HEADER,
    connection,
    dataset,
    missing_line,
    nb,
):
    over_time = None
    if not (dataset.has("date") and dataset.has("label")):
        print(f"Skipped - rows and label rate per period need the date and label roles ({missing_line}).")
    else:
        date_span = nb.sql(connection, f"SELECT DAYS_BETWEEN(MAX({DATE_COLUMN}), MIN({DATE_COLUMN})) AS DAYS FROM {dataset.fact_table}")
        span_days = int(date_span["DAYS"][0] or 0)
        period = "DAY" if span_days <= 62 else "MONTH" if span_days <= 3 * 366 else "YEAR"

        over_time = nb.sql(connection, f"""
    SELECT CAST(DATE_TRUNC('{period}', {DATE_COLUMN}) AS DATE) AS {period}_START,
           COUNT(*) AS {COUNT_HEADER},
           ROUND(100 * AVG({LABEL_COLUMN}), 1) AS {LABEL_PCT_HEADER}
    FROM {dataset.fact_table}
    GROUP BY 1
    ORDER BY 1""")
        nb.show_sql()
        nb.note_trend(over_time, dataset, f"{period}_START", COUNT_HEADER, LABEL_PCT_HEADER)
    over_time
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 5 · Train a model

    Trains a small model on this computer to predict the label. First, it removes the columns that give the answer away.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Remove columns that give the answer away

    A column written after the outcome (an order's status after cancellation) predicts the label perfectly on old rows and fails on new rows. This cell flags those columns. The model does not use them.
    """)
    return


@app.cell
def _(connection, dataset, nb):
    LEAKING_COLUMNS = nb.leakage_check(connection, dataset)
    return (LEAKING_COLUMNS,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Train a baseline model

    The simplest useful model. It shows how much the data can predict. It trains on three quarters of the rows and keeps one quarter for step 6.

    Inputs: the category, the entity and the month (when there is a date). It reads the newest 20,000 rows, or the first 20,000 by key, so a rerun reads the same rows. Needs a label and a category or entity.

    Method: one-hot features, logistic regression with balanced class weights, stratified split with a fixed seed.
    """)
    return


@app.cell
def _(
    CATEGORY_COLUMN,
    DATE_COLUMN,
    ENTITY_COLUMN,
    LABEL_COLUMN,
    LEAKING_COLUMNS,
    connection,
    dataset,
    missing_line,
    nb,
):
    MODEL_ROW_LIMIT = 20000
    # The features the model reads, each only when its role exists and does not give the label away: the category and the
    # entity as text, then the month of the date.
    USE_CATEGORY = dataset.has("category") and CATEGORY_COLUMN.strip('"') not in LEAKING_COLUMNS
    USE_ENTITY = dataset.has("entity") and ENTITY_COLUMN.strip('"') not in LEAKING_COLUMNS
    CATEGORY_FEATURE = f"CAST({dataset.col('category')} AS VARCHAR(2000)) AS CATEGORY_,\n       " if USE_CATEGORY else ""
    ENTITY_FEATURE = f"CAST({dataset.col('entity')} AS VARCHAR(2000)) AS ENTITY_,\n       " if USE_ENTITY else ""
    MONTH_FEATURE = f"EXTRACT(MONTH FROM {dataset.col('date')}) AS MONTH_,\n       " if dataset.has("date") else ""
    # Which rows: the newest by date, else the first by the key - the same rows on every rerun either way.
    KEY_COLUMN = dataset.descriptor.slots.get("key")
    ROW_ORDER = f"{dataset.col('date')} DESC" if dataset.has("date") else (f'"{KEY_COLUMN}"' if KEY_COLUMN else "1")

    model = None
    if not (dataset.has("label") and (USE_CATEGORY or USE_ENTITY)):
        print(f"Skipped - the small model predicts the label from the category and entity, which needs a label and a "
              f"category or entity role that does not give the label away ({missing_line or 'see the cell above'}).")
    else:
        # What each feature is called on screen: the column it comes from, or "month".
        FEATURE_LABELS = {"MONTH_": "month", "CATEGORY_": (CATEGORY_COLUMN or "").strip('"'), "ENTITY_": (ENTITY_COLUMN or "").strip('"')}
        if not DATE_COLUMN:
            print("No date: the model reads the first rows by the key and leaves the month out.")
        model_rows = nb.sql(connection, f"""
    SELECT {CATEGORY_FEATURE}{ENTITY_FEATURE}{MONTH_FEATURE}{LABEL_COLUMN} AS LABEL_
    FROM {dataset.fact_table}
    WHERE {LABEL_COLUMN} IS NOT NULL
    ORDER BY {ROW_ORDER}
    LIMIT {MODEL_ROW_LIMIT}""")
        nb.show_sql()

        from sklearn.linear_model import LogisticRegression
        from sklearn.model_selection import train_test_split
        from sklearn.pipeline import Pipeline
        from sklearn.preprocessing import OneHotEncoder

        feature_columns = [name for name in ("CATEGORY_", "ENTITY_", "MONTH_") if name in model_rows.columns]
        feature_values, label_values = model_rows[feature_columns].fillna("(none)").astype(str), model_rows["LABEL_"].astype(int)
        train_features, test_features, train_labels, test_labels = train_test_split(feature_values, label_values, test_size=0.25, random_state=0, stratify=label_values)
        model = Pipeline([
            ("onehot", OneHotEncoder(handle_unknown="ignore")),
            ("classifier", LogisticRegression(max_iter=1000, class_weight="balanced")),
        ])
        model.fit(train_features, train_labels)
        print(f"Trained on {len(train_labels):,} rows; {len(test_labels):,} rows kept back for the test in step 6.")
    return (
        FEATURE_LABELS,
        feature_columns,
        label_values,
        model,
        model_rows,
        test_features,
        test_labels,
    )


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 6 · Validate

    Scores the model on the quarter of rows it did not see. Then lists the values it uses most.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Score on unseen rows

    ROC AUC: 0.5 is a guess, 1.0 is perfect. The note compares it with always predicting the most common answer.
    """)
    return


@app.cell
def _(
    dataset,
    label_values,
    model,
    model_rows,
    nb,
    test_features,
    test_labels,
):
    roc_auc = None
    if model is not None:
        from sklearn.metrics import roc_auc_score

        roc_auc = roc_auc_score(test_labels, model.predict_proba(test_features)[:, 1])
        print(f"ROC AUC on the held-out quarter: {roc_auc:.3f}")
        nb.note_model(roc_auc, dataset, len(model_rows), label_values.mean())
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### What it uses most

    The strongest values in each direction. Treat them as leads, not proof. A value with few rows can look strong by chance.
    """)
    return


@app.cell
def _(FEATURE_LABELS, LABEL_COLUMN, feature_columns, model):
    import numpy as np

    if model is not None:
        feature_names = model.named_steps["onehot"].get_feature_names_out(feature_columns)
        feature_weights = model.named_steps["classifier"].coef_[0]
        weight_order = np.argsort(feature_weights)

        def describe_feature(name):
            feature, value = name.split("_", 1)[0] + "_", name.split("__", 1)[1]
            return f"{FEATURE_LABELS[feature]} = {value}"

        CLUES_PER_SIDE = min(8, len(feature_names) // 2)        # each side its own values: few values are split, never shown twice
        print(f"Make {LABEL_COLUMN} = 1 more likely:", ", ".join(describe_feature(feature_name) for feature_name in feature_names[weight_order[-CLUES_PER_SIDE:]][::-1]))
        print(f"Make {LABEL_COLUMN} = 1 less likely:", ", ".join(describe_feature(feature_name) for feature_name in feature_names[weight_order[:CLUES_PER_SIDE]]))
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Optional · Themes in the label-1 texts (AI)

    Needs a text column. The practice datasets have none, so this step skips.

    Your model groups the newest texts on each side of the label into themes. A theme on one side only is a lead.

    To turn it on, fill in the model cell above and run it. Then set `USE_AI_THEMES = True` in the first cell. It makes two model calls. A live source asks before it sends anything. With `LANGFUSE_BASE_URL` set, both calls go into one trace, `explore-themes`.
    """)
    return


@app.cell
def _(
    LABEL_COLUMN,
    TEXT_SQL,
    USE_AI_THEMES,
    connection,
    dataset,
    missing_line,
    nb,
):
    SAMPLE_TEXTS = 20      # per side: the newest texts where the label is 1, and as many where it is 0
    text_sample = themes = None
    NEWEST_FIRST = f"{dataset.col('date')} DESC" if dataset.has("date") else dataset.col("entity") if dataset.has("entity") else "1"
    PER_LABEL = f"PARTITION BY {dataset.col('label')} " if dataset.has("label") else ""
    LABELLED_ONLY = f" AND {dataset.col('label')} IS NOT NULL" if dataset.has("label") else ""
    if not dataset.has("text"):
        print(f"Skipped - the themes need a text role ({missing_line}).")
    else:
        TEXT_SAMPLE_SQL = f"""
    SELECT {LABEL_COLUMN or 'NULL'} AS LABEL_, {TEXT_SQL} AS TEXT_
    FROM {dataset.fact_table}
    WHERE LENGTH(TRIM({TEXT_SQL})) > 0{LABELLED_ONLY}
    QUALIFY ROW_NUMBER() OVER ({PER_LABEL}ORDER BY {NEWEST_FIRST}) <= {SAMPLE_TEXTS}"""
        text_sample = nb.sql(connection, TEXT_SAMPLE_SQL)
        nb.show_sql()
        if not USE_AI_THEMES:
            print("The AI step is off: above is the sample it would read. To run it, switch USE_AI_THEMES on in the first "
                  "cell. Everything else in this notebook runs without a model.")
        else:
            model_endpoint = nb.model_client()
            if model_endpoint is not None and nb.confirm_send(dataset, len(text_sample)):
                themes = nb.themes(connection, dataset, text_sample, model_endpoint, sql=TEXT_SAMPLE_SQL)
    themes if themes is not None else text_sample
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next: step 7

    Note one finding to check. Then open `02_ask_your_data.ipynb` and ask a question in plain English. For other data, change `DATASET` and run again.
    """)
    return


if __name__ == "__main__":
    app.run()
