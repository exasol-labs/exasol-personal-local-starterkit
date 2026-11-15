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

    **Step 2 · Understand, explore and predict.** Click into the cell below and press **Shift + Enter** to open it: what each column means and the semantic views over your data, then checks, a cleaned view, groups and trends, and a first model. Its **Guided / Code** switch, top right, shows the code behind this page.

    </div>
    """)
    return


@app.cell
def _():
    # Cell tags: exakit-guide, skip-ci
    import exakit.guide as guide

    guide.explore()
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
    ## Understand, prepare, explore, model, validate

    **Dataset:** the tables chosen in the quickstart (else the one approved last, else `amazon_sales`). Set `DATASET` for `fraud_transactions` or your own file.

    ![Steps 2 Understand, 3 Prepare, 4 Explore, 5 Model and 6 Validate . All steps: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](data:image/svg+xml;base64,PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnIHdpZHRoPSc4ODAnIGhlaWdodD0nMjcwJyB2aWV3Qm94PScwIDAgODgwIDI3MCc+PGRlZnM+PG1hcmtlciBpZD0nYScgdmlld0JveD0nMCAwIDEwIDEwJyByZWZYPSc5JyByZWZZPSc1JyBtYXJrZXJXaWR0aD0nNycgbWFya2VySGVpZ2h0PSc3JyBvcmllbnQ9J2F1dG8nPjxwYXRoIGQ9J00wIDAgTDEwIDUgTDAgMTAgeicgZmlsbD0nIzk4QTJCMycvPjwvbWFya2VyPjwvZGVmcz48cmVjdCB4PScxLjAnIHk9JzEnIHdpZHRoPScyNjguNycgaGVpZ2h0PScyNDAnIHJ4PScxMicgZmlsbD0nI0Y4RkFGQycgc3Ryb2tlPScjMUY2RkVCJyBzdHJva2Utd2lkdGg9JzEuNScvPjx0ZXh0IHg9JzEzNS4zJyB5PScyMicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjMUY2RkVCJz5HZXQgdGhlIGRhdGE8L3RleHQ+PHJlY3QgZGF0YS1zdGVwPScxJyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzEzLjAnIHk9JzM0JyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PScxMzUuMycgeT0nNTcnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyMzNDQwNTQnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz4xPC90c3Bhbj4gIEFjY2VzczwvdGV4dD48bGluZSB4MT0nMTM1LjMnIHkxPSc3MScgeDI9JzEzNS4zJyB5Mj0nODQnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCBkYXRhLXN0ZXA9JzInIGRhdGEtY3VycmVudD0nMScgeD0nMTMuMCcgeT0nODYnIHdpZHRoPScyNDQuNycgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyMxRjZGRUInIHN0cm9rZT0nIzFGNkZFQicvPjx0ZXh0IHg9JzEzNS4zJyB5PScxMDknIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyNGRkZGRkYnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz4yPC90c3Bhbj4gIFVuZGVyc3RhbmQ8L3RleHQ+PGxpbmUgeDE9JzI3Mi43JyB5MT0nNTIuMCcgeDI9JzMwMi43JyB5Mj0nNTIuMCcgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IHg9JzMwNS43JyB5PScxJyB3aWR0aD0nMjY4LjcnIGhlaWdodD0nMjQwJyByeD0nMTInIGZpbGw9JyNGOEZBRkMnIHN0cm9rZT0nIzFGNkZFQicgc3Ryb2tlLXdpZHRoPScxLjUnLz48dGV4dCB4PSc0NDAuMCcgeT0nMjInIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTIuNScgZm9udC13ZWlnaHQ9JzcwMCcgZmlsbD0nIzFGNkZFQic+UHJlcGFyZSBhbmQgbW9kZWw8L3RleHQ+PHJlY3QgZGF0YS1zdGVwPSczJyBkYXRhLWN1cnJlbnQ9JzEnIHg9JzMxNy43JyB5PSczNCcgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nIzFGNkZFQicgc3Ryb2tlPScjMUY2RkVCJy8+PHRleHQgeD0nNDQwLjAnIHk9JzU3JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjRkZGRkZGJz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+MzwvdHNwYW4+ICBQcmVwYXJlPC90ZXh0PjxsaW5lIHgxPSc0NDAuMCcgeTE9JzcxJyB4Mj0nNDQwLjAnIHkyPSc4NCcgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IGRhdGEtc3RlcD0nNCcgZGF0YS1jdXJyZW50PScxJyB4PSczMTcuNycgeT0nODYnIHdpZHRoPScyNDQuNycgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyMxRjZGRUInIHN0cm9rZT0nIzFGNkZFQicvPjx0ZXh0IHg9JzQ0MC4wJyB5PScxMDknIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyNGRkZGRkYnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz40PC90c3Bhbj4gIEV4cGxvcmU8L3RleHQ+PGxpbmUgeDE9JzQ0MC4wJyB5MT0nMTIzJyB4Mj0nNDQwLjAnIHkyPScxMzYnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCBkYXRhLXN0ZXA9JzUnIGRhdGEtY3VycmVudD0nMScgeD0nMzE3LjcnIHk9JzEzOCcgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nIzFGNkZFQicgc3Ryb2tlPScjMUY2RkVCJy8+PHRleHQgeD0nNDQwLjAnIHk9JzE2MScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nI0ZGRkZGRic+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjU8L3RzcGFuPiAgTW9kZWw8L3RleHQ+PGxpbmUgeDE9JzQ0MC4wJyB5MT0nMTc1JyB4Mj0nNDQwLjAnIHkyPScxODgnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCBkYXRhLXN0ZXA9JzYnIGRhdGEtY3VycmVudD0nMScgeD0nMzE3LjcnIHk9JzE5MCcgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nIzFGNkZFQicgc3Ryb2tlPScjMUY2RkVCJy8+PHRleHQgeD0nNDQwLjAnIHk9JzIxMycgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nI0ZGRkZGRic+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjY8L3RzcGFuPiAgVmFsaWRhdGU8L3RleHQ+PGxpbmUgeDE9JzU3Ny4zJyB5MT0nNTIuMCcgeDI9JzYwNy4zJyB5Mj0nNTIuMCcgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IHg9JzYxMC4zJyB5PScxJyB3aWR0aD0nMjY4LjcnIGhlaWdodD0nMjQwJyByeD0nMTInIGZpbGw9JyNGOEZBRkMnIHN0cm9rZT0nI0QwRDVERCcgc3Ryb2tlLXdpZHRoPScxJy8+PHRleHQgeD0nNzQ0LjcnIHk9JzIyJyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEyLjUnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyM0NzU0NjcnPlVzZSBhbmQgc2hhcmU8L3RleHQ+PHJlY3QgZGF0YS1zdGVwPSc3JyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzYyMi4zJyB5PSczNCcgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNzQ0LjcnIHk9JzU3JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+NzwvdHNwYW4+ICBBc2sgd2l0aCBBSTwvdGV4dD48bGluZSB4MT0nNzQ0LjcnIHkxPSc3MScgeDI9Jzc0NC43JyB5Mj0nODQnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCBkYXRhLXN0ZXA9JzgnIGRhdGEtY3VycmVudD0nMCcgeD0nNjIyLjMnIHk9Jzg2JyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSc3NDQuNycgeT0nMTA5JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+ODwvdHNwYW4+ICBTaGFyZTwvdGV4dD48bGluZSB4MT0nNzQ0LjcnIHkxPScxMjMnIHgyPSc3NDQuNycgeTI9JzEzNicgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IGRhdGEtc3RlcD0nOScgZGF0YS1jdXJyZW50PScwJyB4PSc2MjIuMycgeT0nMTM4JyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSc3NDQuNycgeT0nMTYxJyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+OTwvdHNwYW4+ICBIYW5kIG9mZjwvdGV4dD48cmVjdCB4PScxJyB5PScyNTEnIHdpZHRoPScxNCcgaGVpZ2h0PScxNCcgcng9JzMnIGZpbGw9JyMxRjZGRUInLz48dGV4dCB4PScyMicgeT0nMjYyJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEyLjUnIGZpbGw9JyM0NzU0NjcnPlRoaXMgbm90ZWJvb2s8L3RleHQ+PC9zdmc+)

    Each query is built from the approved column map, so no cell names a column. If the data has no date or no text, the step that needs it skips and says why. Settings are in the first cell. The AI model has its own cell. The AI step at the end is optional and off.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    | Setting | What it does |
    |---|---|
    | `DATASET` | `None`: the tables chosen in the quickstart; or `"fraud_transactions"`, or a file of your own |
    | `USE_AI_THEMES` | `True`: your AI model sorts the texts into themes |
    | `USE_JOINED`, `USE_PREPARED` | `True`: create the joined or the cleaned view proposed under Prepare, and explore that |
    | `JOINED_SQL`, `CLEANING_SQL` | your own version of that view: the CREATE VIEW printed under Prepare, edited |
    | `PLACEHOLDER_VALUES` | values that mean "not known"; `word*` matches anything starting with the word |
    | `RARE_TARGET` | a target in fewer rows than this share is rare: judge a model by ROC AUC |
    | `DATE_FORMATS`, `TIMESTAMP_FORMATS` | how a date written as text is read |
    | `DROP_COPIES`, `CAST_TYPES` | the cleaned view drops copied rows, and gives text columns of numbers or dates their type |
    | `GIVES_IT_AWAY` | a value whose target rate is this or more (or one minus this or less) decides the target |
    | `ROLE_RULES` | changes to how a column map is drafted and how the table is read for it, such as `{"CATEGORY_DISTINCT": 100, "MEASURE_HINTS": ["revenue", "amount"], "VIRTUAL_ROWS": 50000}`; `nb.role_rules()` lists every rule with its value |
    | `LINK_RULES` | changes to how links are found, such as `{"MIN_SHARE": 0.8}`; `nb.link_rules()` lists every rule |
    """)
    return


@app.cell
def _():
    DATASET = None
    USE_AI_THEMES = False
    USE_JOINED = False
    USE_PREPARED = False
    JOINED_SQL = None
    CLEANING_SQL = None
    PLACEHOLDER_VALUES = ["unknown*", "invalid*", "n/a", "na", "none", "null", "nil", "missing", "not available",
                          "not known", "not set", "undefined", "-", "?", "tbd", "#n/a"]
    RARE_TARGET = 0.10
    DATE_FORMATS = ["YYYY-MM-DD", "DD-MM-YYYY", "DD.MM.YYYY", "MM/DD/YYYY", "DD/MM/YYYY"]
    TIMESTAMP_FORMATS = ["YYYY-MM-DD HH24:MI:SS", "YYYY-MM-DD HH24:MI"]
    DROP_COPIES = True
    CAST_TYPES = True
    GIVES_IT_AWAY = 0.99
    ROLE_RULES = {}
    LINK_RULES = {}
    return (
        CAST_TYPES,
        CLEANING_SQL,
        DATASET,
        DATE_FORMATS,
        DROP_COPIES,
        GIVES_IT_AWAY,
        JOINED_SQL,
        LINK_RULES,
        PLACEHOLDER_VALUES,
        RARE_TARGET,
        ROLE_RULES,
        TIMESTAMP_FORMATS,
        USE_AI_THEMES,
        USE_JOINED,
        USE_PREPARED,
    )


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


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    `MODEL_ID`, for example `"claude-opus-5-5"`; `PROVIDER_BASE_URL`, any Chat Completions address; `LANGFUSE_BASE_URL`, where the calls are traced. Empty: no model.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    MODEL_ID = ""
    PROVIDER_BASE_URL = ""
    LANGFUSE_BASE_URL = ""
    nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)
    return (nb,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 2 · Understand the data

    The tables chosen in the quickstart, opened again here. For each you approve the column map: the key, the date, the groups and the outcome. The kit proposes it and shows the least certain columns first. Approving it publishes the table in **Exasol Semantic Views**, the database's semantic layer, and the model over all your tables is built from the same choices. Every later step reads this map, so the same notebooks run on any table.
    """)
    return


@app.cell
def _(DATASET, nb):
    import os
    workflow_id = nb.continue_workflow('explore')
    connection = nb.connect()
    chosen_tables = nb.open_chosen(connection)
    if DATASET or not chosen_tables:
        chosen_data = nb.chosen_dataset(DATASET)
    else:
        chosen_data = next(iter(chosen_tables.values()))
    return chosen_data, chosen_tables, connection


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ### Approve the column map

    The column map (the descriptor) gives each column a role. Every later query is built from it, so no notebook types your column names.

    The kit proposes the map from the data. A proposal can be wrong. In `amazon_sales`, `STATUS` gives the answer away. The kit warns about it when you approve, and the model leaves it out. Check the map before any query uses it.

    **Roles:** `key` (one per row), `time`, `measure` (a number to add up), `category` (a few repeated values), `flag` (yes/no), `text`, `identifier` (names or codes) and `other`.

    **Slots:** the one column each step uses for `key`, `time`, `text`, `target` (the outcome to predict), `category` (groups to compare) and `entity` (who or what a row is about).

    | Dataset | `key` | `time` | `text` | `target` | `category` | `entity` |
    |---|---|---|---|---|---|---|
    | Amazon sales | `ORDER_LINE_ID` | `ORDER_DATE` | — | `CANCELLED` | `CATEGORY` | `SHIP_STATE` |
    | Fraud transactions | `ROW_ID` | — | — | `FRAUDULENT` | `TRANSACTION_TYPE` | `LOCATION` |

    Neither dataset has a text column. The text steps skip and say why.

    The kit never guesses the **target**. You choose it. Leave a slot as "—" when no column fits.

    **Do now:**

    1. Look at *Check these first*. These are the columns the kit was least sure about.
    2. Correct what is wrong.
    3. Click **Approve column map**. No click is needed if the map is already approved and you change nothing.
    4. Run the next cell.

    Approval checks the data again and warns about a column that gives the target away.

    In plain Python: `role_review.approve({"COLUMN": "role"}, {"target": "COLUMN"})`.
    """)
    return


@app.cell
def _(ROLE_RULES, chosen_data, connection, nb):
    # Cell tags: review
    role_review = nb.review_roles(connection, chosen_data, rules=ROLE_RULES)
    return (role_review,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    `AI_CHECK = True`: your AI model completes the draft from names, types and the kit's evidence, never a row. `AI_APPROVE = True`: approve with its answer.
    """)
    return


@app.cell
def _(nb, role_review):
    # Cell tags: review
    AI_CHECK = False
    AI_APPROVE = False
    if AI_CHECK:
        ai_map = nb.fill_column_map(role_review)
        if AI_APPROVE:
            role_review.approve({r["column"]: r["role"] for r in ai_map["roles"]} or None, ai_map["slots"] or None, notes=ai_map["notes"])
    return (AI_CHECK,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    `ROLE_CHANGES`: `{"COLUMN": "role"}`. `SLOT_CHANGES`: `{"target": "COLUMN"}`. Empty: the picker above stands.
    """)
    return


@app.cell
def _(role_review):
    # Cell tags: review
    ROLE_CHANGES = {}
    SLOT_CHANGES = {}
    if ROLE_CHANGES or SLOT_CHANGES:
        role_review.approve(ROLE_CHANGES or None, SLOT_CHANGES or None)
    return


@app.cell
def _(nb, role_review):
    # Cell tags: review
    dataset = role_review.dataset()
    nb.show_roles(dataset)
    return (dataset,)


@app.cell
def _(connection, dataset, nb):
    # Cell tags: review
    leaking = nb.leakage_check(connection, dataset)
    versions = nb.column_map_versions(dataset.id)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ### Check the map again

    The same map, read again after the approval. The table you approved now shows `approved vN, in semantic model <name>` and every slot by name. `not in a semantic model yet` means the roles are saved but agents cannot read them yet: approve again to publish.
    """)
    return


@app.cell
def _(connection, dataset, nb):
    # Cell tags: review
    dataset
    nb.data_map(connection)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ### Your data map

    Approving a column map put the table into **your data map**: `all_data`, one **Exasol Semantic Views** model over every approved table of every source. Its key, time, category and flag columns are dimensions; its amounts get a total and an average; each field says what the column holds. AI clients read it over MCP, and Ask writes its SQL from it.

    Semantic Views needs a few things only you can say, and nothing here works them out for you:

    | What | Why Semantic Views needs it |
    |---|---|
    | What one row of each table is (its grain) | so an amount is never counted once per row of another table |
    | How the tables connect, and the type of each link | many-to-one (order lines to orders) or one-to-one; a join that would multiply an amount is refused |
    | Where questions start | each such table becomes a semantic view that reaches the linked tables |
    | Your metrics | "completed revenue" is a sum with a condition, defined once |
    | Rules for AI tools | what anyone asking must know, such as what an amount includes |

    `AI_CHECK = True` (above) has your AI model draft them from names, roles, notes and known values, never a row; what you set here wins. `CHECK_LINKS = True` runs one bounded count per link. Saving hands it all to Semantic Views, which checks it and says what is wrong. **Do now:** read the preview, then set `PUBLISH_SEMANTIC = True` and run it again.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    | Setting | What it does |
    |---|---|
    | `SEMANTIC_TABLES` | the tables, such as `"VS_LOGISTICS.COURIER_DAILY"` (each with an approved column map) |
    | `SEMANTIC_LINKS` | `[{"from": "S.T.COL", "to": "S.T.KEY", "type": "MANY_TO_ONE", "note": "why"}]` |
    | `SEMANTIC_GRAINS` | `{"S.T": "one row is one order line"}` |
    | `SEMANTIC_TABLE_NOTES` | `{"S.T": "what the table is"}` |
    | `SEMANTIC_STARTS` | the tables questions start from: `["S.T"]` |
    | `SEMANTIC_METRICS` | `[{"table": "S.T", "name": "completed_revenue", "how": "sum", "column": "AMOUNT", "where": {"column": "STATUS", "values": ["COMPLETED"]}}]`; `how` is `sum`, `count` or `average` |
    | `SEMANTIC_INSTRUCTIONS` | `["Revenue excludes tax"]`, or `{"table": "S.T", "text": "..."}` |
    | `SEMANTIC_HIDDEN` | columns never shown in answers, still usable in filters: `{"S.T": ["CUSTOMER_NAME"]}` |
    | `SEMANTIC_ABOUT` | what your data is about, in a sentence |
    | `CHECK_LINKS` | `True`: count how many of each link's values its key holds |
    | `PUBLISH_SEMANTIC` | `True`: save it; `False`: a preview, which prints every statement saving runs |
    | `DATA_MAP_SQL` | your own version of those statements: the printed list, edited; it runs instead of the kit's |

    `None` keeps what you saved before.
    """)
    return


@app.cell
def _(AI_CHECK, LINK_RULES, connection, dataset, nb):
    # Cell tags: review
    SEMANTIC_TABLES = [dataset.fact_table]
    SEMANTIC_LINKS = None
    SEMANTIC_GRAINS = None
    SEMANTIC_TABLE_NOTES = None
    SEMANTIC_STARTS = None
    SEMANTIC_METRICS = None
    SEMANTIC_INSTRUCTIONS = None
    SEMANTIC_HIDDEN = None
    SEMANTIC_ABOUT = None
    CHECK_LINKS = False
    PUBLISH_SEMANTIC = False
    DATA_MAP_SQL = None
    data_map_inputs = nb.data_map_inputs(SEMANTIC_TABLES)
    your_map = {key: data_map_inputs[key] for key in ("links", "grains", "table_notes", "starts", "metrics", "instructions", "hidden", "description")}
    if AI_CHECK:
        drafted_map = nb.draft_data_map(SEMANTIC_TABLES)
        your_map = {key: your_map[key] or drafted_map[key] for key in your_map}
    your_map.update({key: value for key, value in (("links", SEMANTIC_LINKS), ("grains", SEMANTIC_GRAINS), ("table_notes", SEMANTIC_TABLE_NOTES),
                                                   ("starts", SEMANTIC_STARTS), ("metrics", SEMANTIC_METRICS),
                                                   ("instructions", SEMANTIC_INSTRUCTIONS), ("hidden", SEMANTIC_HIDDEN),
                                                   ("description", SEMANTIC_ABOUT)) if value is not None})
    if CHECK_LINKS and your_map["links"]:
        link_check = nb.find_links(connection, tables=SEMANTIC_TABLES, check=[f"{link['from']}={link['to']}" for link in your_map["links"]],
                                   ai=False, rules=LINK_RULES)
        print(link_check)
    semantic = nb.semantic_model(connection, "all_data", tables=SEMANTIC_TABLES, links=your_map["links"], table_notes=your_map["table_notes"],
                                 grains=your_map["grains"], starts=your_map["starts"] or None, metrics=your_map["metrics"],
                                 instructions=your_map["instructions"], hidden=your_map["hidden"], description=your_map["description"] or None,
                                 replace_links=True, ai=False, preview=not PUBLISH_SEMANTIC, sql=DATA_MAP_SQL if PUBLISH_SEMANTIC else None)
    if PUBLISH_SEMANTIC:
        data_map_check = nb.validate_data_map(connection)
        print(data_map_check["issues"] or "Semantic Views finds nothing wrong with your data map.")
    semantic
    return


@app.cell
def _(connection, nb):
    # Cell tags: review
    semantic_models = nb.semantic_models(connection)
    semantic_models
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ### The same thing in two sources

    When another source holds the same rows as a table of the model - customers in the warehouse and in a CRM, orders here and in a lakehouse - declare them one thing with two sources (Exasol Semantic Views **fusion**). Requests are then answered from either, and for a value both hold the side you pick wins. `nb.fuse` checks it against the data first and changes nothing; `APPLY_FUSION = True` applies it, and the document is kept beside the model so a rebuild puts it back.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    `FUSE_TABLE`: a table of your data map. `FUSE_OTHER`: the same rows in another source. `FUSE_KEY`: its key there, when named differently. `FUSION_DOCUMENT`: your own version of the printed document, edited. `APPLY_FUSION = True` applies it after the check.
    """)
    return


@app.cell
def _(connection, nb):
    # Cell tags: review
    FUSE_TABLE = ""
    FUSE_OTHER = ""
    FUSE_KEY = None
    FUSION_DOCUMENT = None
    APPLY_FUSION = False
    if FUSION_DOCUMENT or (FUSE_TABLE and FUSE_OTHER):
        fusion_document = FUSION_DOCUMENT or nb.fusion_document(connection, "all_data", FUSE_TABLE, FUSE_OTHER, key=FUSE_KEY, wins="model")
        print(fusion_document)
        fusion_check = nb.fuse(connection, "all_data", fusion_document)
        if APPLY_FUSION and fusion_check["status"] != "error":
            fusion_applied = nb.fuse(connection, "all_data", fusion_document, dry_run=False)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Approve every table at once

    With several tables chosen - six tables of one source, say - you do not have to approve them one by one. `nb.schema_review` says what to look at across all of them: the columns the kit guessed at, and the ones it marked personal data. `nb.approve_all` then approves every table as drafted, with the columns you change in `ALL_CHOICES`, and updates the semantic model once per source instead of once per table. What to predict is not set here: it stays each table's own choice.
    """)
    return


@app.cell
def _(chosen_data, chosen_tables, connection, nb):
    APPROVE_ALL = False
    ALL_CHOICES = None
    if APPROVE_ALL and chosen_tables:
        role_reviews = {table: nb.review_roles(connection, data) for table, data in chosen_tables.items()}
        schema_summary = nb.schema_review(role_reviews)
        print(f"{len(schema_summary['check'])} columns to look at, {len(schema_summary['sensitive'])} marked personal data, {schema_summary['fine']} look fine.")
        approved_all = nb.approve_all(role_reviews, ALL_CHOICES)
        dataset_1 = approved_all[str(chosen_data.fact_table)]
    return (dataset_1,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Add another source

    Fusion: data from several places in one model. Every source connected with `exakit connect` (S3, Snowflake, MongoDB, PostgreSQL and the rest) is listed here, read live where it lives. Name a table of one in `ADD_SOURCE` to add it to the tables above; the card's **Add a source or table** does the same and connects a new source too.
    """)
    return


@app.cell
def _(chosen_tables, connection, nb):
    sources = nb.sources()
    ADD_SOURCE = ""
    if ADD_SOURCE:
        source_data = nb.load_source(connection, ADD_SOURCE)
        chosen_tables[str(source_data.fact_table)] = source_data
        remembered = nb.remember_chosen(chosen_tables)
    print("Sources: " + (", ".join(f"{s['schema']} ({s.get('connector_name') or s.get('connector')})" for s in sources) or "none connected yet"))
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### A first result

    Rows per group, and the % where the target is 1 when the map has a target. Each query shows its SQL before the result.
    """)
    return


@app.cell
def _(connection, dataset_1, nb):
    _missing_roles = {missing['role']: missing['reason'] for missing in dataset_1.missing}
    GROUP_ROLE, GROUP_COLUMN = dataset_1.group_by()
    if GROUP_ROLE != 'category':
        print(f"No category ({_missing_roles.get('category', 'none approved')}): rows are counted per {GROUP_ROLE} instead.")
    if 'label' in _missing_roles:
        print(f"No target ({_missing_roles['label']}): the target rate is left out. Later steps that need it say so.")
    _GROUP_HEADER, COUNT_HEADER = (nb.name(GROUP_COLUMN), nb.count_name(dataset_1))
    LABEL_PCT_HEADER = nb.name(dataset_1.col('label'), 'PCT') if dataset_1.has('label') and GROUP_ROLE != 'label' else None
    LABEL_RATE_SQL = f",\n       ROUND(100 * AVG({dataset_1.col('label')}), 1) AS {LABEL_PCT_HEADER}" if LABEL_PCT_HEADER else ''
    first_rows = nb.sql(connection, f'\nSELECT {GROUP_COLUMN} AS {_GROUP_HEADER},\n       COUNT(*) AS {COUNT_HEADER}{LABEL_RATE_SQL}\nFROM {dataset_1.fact_table}\nGROUP BY {GROUP_COLUMN}\nORDER BY {COUNT_HEADER} DESC\nLIMIT 10')
    nb.show_sql()
    _overall_rate = nb.sql(connection, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({dataset_1.col('label')}), 1) AS PCT FROM {dataset_1.fact_table}") if LABEL_PCT_HEADER else None
    nb.note_groups(first_rows, dataset_1, _GROUP_HEADER, COUNT_HEADER, LABEL_PCT_HEADER, overall=(_overall_rate['N'][0], _overall_rate['PCT'][0]) if LABEL_PCT_HEADER else None)
    first_rows
    return


@app.cell
def _(role_review):
    loaded_dataset = role_review.dataset(draft_ok=True)
    return (loaded_dataset,)


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

    Finds repeated IDs, empty cells, placeholders such as "Unknown" and a rare target, and says what each does to a result. It changes nothing. What counts as a placeholder and when a target is rare are `PLACEHOLDER_VALUES` and `RARE_TARGET` in the first cell. `fraud_transactions` has all of them.
    """)
    return


@app.cell
def _(PLACEHOLDER_VALUES, RARE_TARGET, connection, loaded_dataset, nb):
    findings = nb.data_checks(connection, loaded_dataset, placeholder_values=PLACEHOLDER_VALUES, rare=RARE_TARGET)
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
    The joined view combines this table with every linked table. Read the joins and the SQL. To change the SQL, copy it into `JOINED_SQL` in the first cell and edit it there. To use it, set `USE_JOINED = True` in the first cell and run the cells below again (Marimo reruns them for you). The view goes into `EXAKIT_PREPARED`, and the steps below read it.
    """)
    return


@app.cell
def _(JOINED_SQL, USE_JOINED, connection, loaded_dataset, schema_map):
    joined_view_proposal = schema_map.joined_view(loaded_dataset)
    joined_dataset = (joined_view_proposal.create(connection, sql=JOINED_SQL) if USE_JOINED and joined_view_proposal.needed
                      else loaded_dataset)
    joined_view_proposal
    return (joined_dataset,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### A typed, cleaned view

    Proposes a view with correct types (numbers, dates), blanks and placeholders as NULL, and exact copies removed. The table never changes.

    Read what changes. The rules are in the first cell (`PLACEHOLDER_VALUES`, `DATE_FORMATS`, `DROP_COPIES`, `CAST_TYPES`): change one and run this cell again. To change the SQL itself, copy it into `CLEANING_SQL` in the first cell and edit it there. To use it, set `USE_PREPARED = True` in the first cell and run the cells below again (Marimo reruns them for you). The view goes into `EXAKIT_PREPARED`, and the steps below read it.
    """)
    return


@app.cell
def _(
    CAST_TYPES,
    CLEANING_SQL,
    DATE_FORMATS,
    DROP_COPIES,
    PLACEHOLDER_VALUES,
    TIMESTAMP_FORMATS,
    USE_PREPARED,
    connection,
    joined_dataset,
    nb,
):
    typed_view_proposal = nb.typed_view(connection, joined_dataset, placeholder_values=PLACEHOLDER_VALUES, date_formats=DATE_FORMATS, timestamp_formats=TIMESTAMP_FORMATS, drop_copies=DROP_COPIES, cast_types=CAST_TYPES)
    dataset_2 = typed_view_proposal.create(connection, sql=CLEANING_SQL) if USE_PREPARED and (typed_view_proposal.needed or CLEANING_SQL) else joined_dataset
    typed_view_proposal
    return (dataset_2,)


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
def _(dataset_2):
    ENTITY_COLUMN = dataset_2.col('entity') if dataset_2.has('entity') else None
    CATEGORY_COLUMN = dataset_2.col('category') if dataset_2.has('category') else None
    TEXT_SQL = dataset_2.text_sql() if dataset_2.has('text') else None
    DATE_COLUMN = dataset_2.col('date') if dataset_2.has('date') else None
    LABEL_COLUMN = dataset_2.col('label') if dataset_2.has('label') else None
    _missing_roles = {missing['role']: missing['reason'] for missing in dataset_2.missing if not dataset_2.has(missing['role'])}
    SHOWN = {'date': 'time', 'label': 'target'}
    missing_line = '; '.join((f'no {SHOWN.get(role, role)}: {reason}' for role, reason in _missing_roles.items()))
    for role in ('entity', 'category', 'date', 'label', 'text'):
        if role in _missing_roles:
            print(f'No {SHOWN.get(role, role)} ({_missing_roles[role]}): steps that need it explain why they skip below.')
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

    The 10 largest entities by category: the row count and the % where the target is 1.
    """)
    return


@app.cell
def _(
    CATEGORY_COLUMN,
    ENTITY_COLUMN,
    LABEL_COLUMN,
    connection,
    dataset_2,
    missing_line,
    nb,
):
    landscape = landscape_grid = None
    COUNT_HEADER_1 = nb.count_name(dataset_2)
    ENTITY_HEADER = nb.name(ENTITY_COLUMN) if ENTITY_COLUMN else None
    CATEGORY_HEADER = nb.name(CATEGORY_COLUMN) if CATEGORY_COLUMN else None
    LABEL_PCT_HEADER_1 = nb.name(LABEL_COLUMN, 'PCT') if LABEL_COLUMN else None
    if not all((dataset_2.has(role) for role in ('entity', 'category', 'label'))):
        print(f'Skipped - the landscape needs an entity, a category and a target ({missing_line}).')
    else:
        _overall_rate = nb.sql(connection, f'SELECT COUNT(*) AS N, ROUND(100 * AVG({LABEL_COLUMN}), 1) AS PCT FROM {dataset_2.fact_table}')
        landscape = nb.sql(connection, f'\nWITH TOP_ENTITIES AS (\n    SELECT {ENTITY_COLUMN} AS ENTITY, COUNT(*) AS N_ROWS\n    FROM {dataset_2.fact_table}\n    GROUP BY {ENTITY_COLUMN}\n    ORDER BY N_ROWS DESC\n    LIMIT 10)\nSELECT T.ENTITY AS {ENTITY_HEADER},\n       F.{CATEGORY_COLUMN} AS {CATEGORY_HEADER},\n       COUNT(*) AS {COUNT_HEADER_1},\n       ROUND(100 * AVG(F.{LABEL_COLUMN}), 1) AS {LABEL_PCT_HEADER_1}\nFROM {dataset_2.fact_table} F\nJOIN TOP_ENTITIES T ON F.{ENTITY_COLUMN} = T.ENTITY\nGROUP BY T.ENTITY, F.{CATEGORY_COLUMN}\nORDER BY T.ENTITY, {COUNT_HEADER_1} DESC')
        nb.show_sql()
        nb.note_groups(landscape, dataset_2, (ENTITY_HEADER, CATEGORY_HEADER), COUNT_HEADER_1, LABEL_PCT_HEADER_1, overall=(_overall_rate['N'][0], _overall_rate['PCT'][0]))
        landscape_grid = landscape.pivot_table(index=ENTITY_HEADER, columns=CATEGORY_HEADER, values=COUNT_HEADER_1, fill_value=0, aggfunc='sum')
    landscape
    return COUNT_HEADER_1, LABEL_PCT_HEADER_1, landscape_grid


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
    ### Compare by a group of a linked table

    When this table links to another table (the links you saved in step 2), its rows can be compared by a group kept there, such as orders by the customer's segment. `nb.linked_groups` lists those groups, each with the table and system it comes from. With no saved link the list is empty and this cell does nothing.
    """)
    return


@app.cell
def _(COUNT_HEADER_1, connection, dataset_2, nb):
    linked = nb.linked_groups(dataset_2)
    LINKED_GROUP = linked[0] if linked else None
    groups = None
    if LINKED_GROUP:
        _GROUP_HEADER = nb.name(LINKED_GROUP['column'])
        groups = nb.sql(connection, f'''\nSELECT b."{LINKED_GROUP['column']}" AS {_GROUP_HEADER},\n       COUNT(*) AS {COUNT_HEADER_1}\nFROM {dataset_2.fact_table} a\nJOIN {LINKED_GROUP['table']} b ON a."{LINKED_GROUP['link_column']}" = b."{LINKED_GROUP['key']}"\nGROUP BY 1\nORDER BY 2 DESC\nLIMIT 15''')
        nb.show_sql()
    print('\n'.join((g['label'] for g in linked)) or 'No linked table with a group.')
    groups
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Over time

    Rows per day, month or year, and the % where the target is 1. Needs a time and a target.
    """)
    return


@app.cell
def _(
    COUNT_HEADER_1,
    DATE_COLUMN,
    LABEL_COLUMN,
    LABEL_PCT_HEADER_1,
    connection,
    dataset_2,
    missing_line,
    nb,
):
    over_time = None
    if not (dataset_2.has('date') and dataset_2.has('label')):
        print(f'Skipped - rows and target rate per period need a time and a target ({missing_line}).')
    else:
        date_span = nb.sql(connection, f'SELECT DAYS_BETWEEN(MAX({DATE_COLUMN}), MIN({DATE_COLUMN})) AS DAYS FROM {dataset_2.fact_table}')
        span_days = int(date_span['DAYS'][0] or 0)
        period = 'DAY' if span_days <= 62 else 'MONTH' if span_days <= 3 * 366 else 'YEAR'
        over_time = nb.sql(connection, f"\nSELECT CAST(DATE_TRUNC('{period}', {DATE_COLUMN}) AS DATE) AS {period}_START,\n       COUNT(*) AS {COUNT_HEADER_1},\n       ROUND(100 * AVG({LABEL_COLUMN}), 1) AS {LABEL_PCT_HEADER_1}\nFROM {dataset_2.fact_table}\nGROUP BY 1\nORDER BY 1")
        nb.show_sql()
        nb.note_trend(over_time, dataset_2, f'{period}_START', COUNT_HEADER_1, LABEL_PCT_HEADER_1)
    over_time
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 5 · Train a model

    Trains a small model on this computer to predict the target. First, it removes the columns that give the answer away.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Remove columns that give the answer away

    A column written after the outcome (an order's status after cancellation) predicts the target perfectly on old rows and fails on new rows. This cell flags those columns. The model does not use them.
    """)
    return


@app.cell
def _(GIVES_IT_AWAY, connection, dataset_2, nb):
    LEAKING_COLUMNS = nb.leakage_check(connection, dataset_2, pure=GIVES_IT_AWAY)
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
    dataset_2,
    missing_line,
    nb,
):
    MODEL_ROW_LIMIT = 20000
    USE_CATEGORY = dataset_2.has('category') and CATEGORY_COLUMN.strip('"') not in LEAKING_COLUMNS
    USE_ENTITY = dataset_2.has('entity') and ENTITY_COLUMN.strip('"') not in LEAKING_COLUMNS
    CATEGORY_FEATURE = f"CAST({dataset_2.col('category')} AS VARCHAR(2000)) AS CATEGORY_,\n       " if USE_CATEGORY else ''
    ENTITY_FEATURE = f"CAST({dataset_2.col('entity')} AS VARCHAR(2000)) AS ENTITY_,\n       " if USE_ENTITY else ''
    MONTH_FEATURE = f"EXTRACT(MONTH FROM {dataset_2.col('date')}) AS MONTH_,\n       " if dataset_2.has('date') else ''
    KEY_COLUMN = dataset_2.descriptor.slots.get('key')
    ROW_ORDER = f"{dataset_2.col('date')} DESC" if dataset_2.has('date') else f'"{KEY_COLUMN}"' if KEY_COLUMN else '1'
    model = None
    if not (dataset_2.has('label') and (USE_CATEGORY or USE_ENTITY)):
        print(f"Skipped - the small model predicts the target from the category and entity, so it needs a target and a category or entity that does not give the target away ({missing_line or 'see the cell above'}).")
    else:
        FEATURE_LABELS = {'MONTH_': 'month', 'CATEGORY_': (CATEGORY_COLUMN or '').strip('"'), 'ENTITY_': (ENTITY_COLUMN or '').strip('"')}
        if not DATE_COLUMN:
            print('No date: the model reads the first rows by the key and leaves the month out.')
        model_rows = nb.sql(connection, f'\nSELECT {CATEGORY_FEATURE}{ENTITY_FEATURE}{MONTH_FEATURE}{LABEL_COLUMN} AS LABEL_\nFROM {dataset_2.fact_table}\nWHERE {LABEL_COLUMN} IS NOT NULL\nORDER BY {ROW_ORDER}\nLIMIT {MODEL_ROW_LIMIT}')
        nb.show_sql()
        from sklearn.linear_model import LogisticRegression
        from sklearn.model_selection import train_test_split
        from sklearn.pipeline import Pipeline
        from sklearn.preprocessing import OneHotEncoder
        feature_columns = [name for name in ('CATEGORY_', 'ENTITY_', 'MONTH_') if name in model_rows.columns]
        feature_values, label_values = (model_rows[feature_columns].fillna('(none)').astype(str), model_rows['LABEL_'].astype(int))
        train_features, test_features, train_labels, test_labels = train_test_split(feature_values, label_values, test_size=0.25, random_state=0, stratify=label_values)
        model = Pipeline([('onehot', OneHotEncoder(handle_unknown='ignore')), ('classifier', LogisticRegression(max_iter=1000, class_weight='balanced'))])
        model.fit(train_features, train_labels)
        print(f'Trained on {len(train_labels):,} rows; {len(test_labels):,} rows kept back for the test in step 6.')
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
    dataset_2,
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
        print(f'ROC AUC on the held-out quarter: {roc_auc:.3f}')
        nb.note_model(roc_auc, dataset_2, len(model_rows), label_values.mean())
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

        CLUES_PER_SIDE = min(8, len(feature_names) // 2)
        print(f"Make {LABEL_COLUMN} = 1 more likely:", ", ".join(describe_feature(feature_name) for feature_name in feature_names[weight_order[-CLUES_PER_SIDE:]][::-1]))
        print(f"Make {LABEL_COLUMN} = 1 less likely:", ", ".join(describe_feature(feature_name) for feature_name in feature_names[weight_order[:CLUES_PER_SIDE]]))
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### The model lab (optional)

    What the **Build a model** card runs: one task - predict yes or no, predict a number, find natural groups or find unusual rows - with every model of that task trained on the same split ("all"), or one model you name. Columns that give the answer away and personal data are left out. Then feature ideas, each tried on the same split before it is kept.
    """)
    return


@app.cell
def _(connection, dataset_2, nb):
    # Cell tags: skip-ci
    LAB_TASK = 'predict_yes_no'
    lab_data = nb.lab_data(connection, dataset_2)
    kept_features = {}
    lab = nb.model_lab(connection, dataset_2, LAB_TASK, model='all', target_number=None, data=lab_data, features=kept_features)
    print(lab.note or lab)
    lab.board if LAB_TASK in ('predict_yes_no', 'predict_number') else lab.result
    return LAB_TASK, kept_features, lab


@app.cell
def _(LAB_TASK, connection, kept_features, lab, nb):
    # Cell tags: skip-ci
    ideas = nb.feature_ideas(lab, ai=False, conn=connection)
    for index, idea in enumerate(ideas[:3] if LAB_TASK in ("predict_yes_no", "predict_number") else []):
        tried = nb.try_feature(lab, ideas[index])
        print(f"{idea.title}: {tried['text']}")
        if tried["verdict"] == "helps":
            kept_features[ideas[index].id] = tried["series"]
        else:
            kept_features.pop(ideas[index].id, None)
    kept_features
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Optional · Themes in the texts where the target is 1 (AI)

    Needs a text column. The practice datasets have none, so this step skips.

    Your model groups the newest texts where the target is 1 and where it is 0 into themes. A theme on one side only is a lead.

    To turn it on, fill in the model cell above and run it. Then set `USE_AI_THEMES = True` in the first cell. It makes two model calls. A live source asks before it sends anything. With `LANGFUSE_BASE_URL` set, both calls go into one trace, `explore-themes`.
    """)
    return


@app.cell
def _(
    LABEL_COLUMN,
    TEXT_SQL,
    USE_AI_THEMES,
    connection,
    dataset_2,
    missing_line,
    nb,
):
    SAMPLE_TEXTS = 20
    text_sample = themes = None
    NEWEST_FIRST = f"{dataset_2.col('date')} DESC" if dataset_2.has('date') else dataset_2.col('entity') if dataset_2.has('entity') else '1'
    PER_LABEL = f"PARTITION BY {dataset_2.col('label')} " if dataset_2.has('label') else ''
    LABELLED_ONLY = f" AND {dataset_2.col('label')} IS NOT NULL" if dataset_2.has('label') else ''
    if not dataset_2.has('text'):
        print(f'Skipped - the themes need a text role ({missing_line}).')
    else:
        TEXT_SAMPLE_SQL = f"\nSELECT {LABEL_COLUMN or 'NULL'} AS LABEL_, {TEXT_SQL} AS TEXT_\nFROM {dataset_2.fact_table}\nWHERE LENGTH(TRIM({TEXT_SQL})) > 0{LABELLED_ONLY}\nQUALIFY ROW_NUMBER() OVER ({PER_LABEL}ORDER BY {NEWEST_FIRST}) <= {SAMPLE_TEXTS}"
        text_sample = nb.sql(connection, TEXT_SAMPLE_SQL)
        nb.show_sql()
        if not USE_AI_THEMES:
            print('The AI step is off: above is the sample it would read. To run it, switch USE_AI_THEMES on in the first cell. Everything else in this notebook runs without a model.')
        else:
            model_endpoint = nb.model_client()
            if model_endpoint is not None and nb.confirm_send(dataset_2, len(text_sample)):
                themes = nb.themes(connection, dataset_2, text_sample, model_endpoint, sql=TEXT_SAMPLE_SQL)
    themes if themes is not None else text_sample
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next: step 7

    Note one finding to check. Then open `02_ask_your_data` and ask a question in plain English. For other data, change `DATASET` and run again.
    """)
    return


if __name__ == "__main__":
    app.run()
