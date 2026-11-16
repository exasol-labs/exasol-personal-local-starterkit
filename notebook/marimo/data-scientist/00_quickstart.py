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

    **Start here · Your kit and your data.** Click into the cell below and press **Shift + Enter** to open it: the kit's state, then your data: datasets, your own files and tables, and external sources. Its **Guided / Code** switch, top right, shows the code behind this page.

    </div>
    """)
    return


@app.cell
def _():
    # Cell tags: exakit-guide, skip-ci
    import exakit.guide as guide

    guide.start()
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
    ## Start here: your kit and your data

    **Dataset:** `amazon_sales` (default), `fraud_transactions` or your own file.

    ![Steps 0 Check the kit and 1 Access. All steps: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](data:image/svg+xml;base64,PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnIHdpZHRoPSc4ODAnIGhlaWdodD0nMjcwJyB2aWV3Qm94PScwIDAgODgwIDI3MCc+PGRlZnM+PG1hcmtlciBpZD0nYScgdmlld0JveD0nMCAwIDEwIDEwJyByZWZYPSc5JyByZWZZPSc1JyBtYXJrZXJXaWR0aD0nNycgbWFya2VySGVpZ2h0PSc3JyBvcmllbnQ9J2F1dG8nPjxwYXRoIGQ9J00wIDAgTDEwIDUgTDAgMTAgeicgZmlsbD0nIzk4QTJCMycvPjwvbWFya2VyPjwvZGVmcz48cmVjdCB4PScxLjAnIHk9JzEnIHdpZHRoPScxMjguMCcgaGVpZ2h0PScyNDAnIHJ4PScxMicgZmlsbD0nI0Y4RkFGQycgc3Ryb2tlPScjMUY2RkVCJyBzdHJva2Utd2lkdGg9JzEuNScvPjx0ZXh0IHg9JzY1LjAnIHk9JzIyJyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEyLjUnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyMxRjZGRUInPlN0YXJ0PC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nMCcgZGF0YS1jdXJyZW50PScxJyB4PScxMy4wJyB5PSczNCcgd2lkdGg9JzEwNC4wJyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nIzFGNkZFQicgc3Ryb2tlPScjMUY2RkVCJy8+PHRleHQgeD0nNjUuMCcgeT0nNTcnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyNGRkZGRkYnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz4wPC90c3Bhbj4gIENoZWNrIHRoZSBraXQ8L3RleHQ+PGxpbmUgeDE9JzEzMi4wJyB5MT0nNTIuMCcgeDI9JzE2Mi4wJyB5Mj0nNTIuMCcgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IHg9JzE2NS4wJyB5PScxJyB3aWR0aD0nMjE0LjAnIGhlaWdodD0nMjQwJyByeD0nMTInIGZpbGw9JyNGOEZBRkMnIHN0cm9rZT0nIzFGNkZFQicgc3Ryb2tlLXdpZHRoPScxLjUnLz48dGV4dCB4PScyNzIuMCcgeT0nMjInIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTIuNScgZm9udC13ZWlnaHQ9JzcwMCcgZmlsbD0nIzFGNkZFQic+R2V0IHRoZSBkYXRhPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nMScgZGF0YS1jdXJyZW50PScxJyB4PScxNzcuMCcgeT0nMzQnIHdpZHRoPScxOTAuMCcgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyMxRjZGRUInIHN0cm9rZT0nIzFGNkZFQicvPjx0ZXh0IHg9JzI3Mi4wJyB5PSc1NycgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nI0ZGRkZGRic+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjE8L3RzcGFuPiAgQWNjZXNzPC90ZXh0PjxsaW5lIHgxPScyNzIuMCcgeTE9JzcxJyB4Mj0nMjcyLjAnIHkyPSc4NCcgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IGRhdGEtc3RlcD0nMicgZGF0YS1jdXJyZW50PScwJyB4PScxNzcuMCcgeT0nODYnIHdpZHRoPScxOTAuMCcgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyNGRkZGRkYnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9JzI3Mi4wJyB5PScxMDknIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyMzNDQwNTQnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz4yPC90c3Bhbj4gIFVuZGVyc3RhbmQ8L3RleHQ+PGxpbmUgeDE9JzM4Mi4wJyB5MT0nNTIuMCcgeDI9JzQxMi4wJyB5Mj0nNTIuMCcgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IHg9JzQxNS4wJyB5PScxJyB3aWR0aD0nMjE0LjAnIGhlaWdodD0nMjQwJyByeD0nMTInIGZpbGw9JyNGOEZBRkMnIHN0cm9rZT0nI0QwRDVERCcgc3Ryb2tlLXdpZHRoPScxJy8+PHRleHQgeD0nNTIyLjAnIHk9JzIyJyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEyLjUnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyM0NzU0NjcnPlByZXBhcmUgYW5kIG1vZGVsPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nMycgZGF0YS1jdXJyZW50PScwJyB4PSc0MjcuMCcgeT0nMzQnIHdpZHRoPScxOTAuMCcgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyNGRkZGRkYnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9JzUyMi4wJyB5PSc1NycgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjM8L3RzcGFuPiAgUHJlcGFyZTwvdGV4dD48bGluZSB4MT0nNTIyLjAnIHkxPSc3MScgeDI9JzUyMi4wJyB5Mj0nODQnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCBkYXRhLXN0ZXA9JzQnIGRhdGEtY3VycmVudD0nMCcgeD0nNDI3LjAnIHk9Jzg2JyB3aWR0aD0nMTkwLjAnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSc1MjIuMCcgeT0nMTA5JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+NDwvdHNwYW4+ICBFeHBsb3JlPC90ZXh0PjxsaW5lIHgxPSc1MjIuMCcgeTE9JzEyMycgeDI9JzUyMi4wJyB5Mj0nMTM2JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc1JyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzQyNy4wJyB5PScxMzgnIHdpZHRoPScxOTAuMCcgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyNGRkZGRkYnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9JzUyMi4wJyB5PScxNjEnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyMzNDQwNTQnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz41PC90c3Bhbj4gIE1vZGVsPC90ZXh0PjxsaW5lIHgxPSc1MjIuMCcgeTE9JzE3NScgeDI9JzUyMi4wJyB5Mj0nMTg4JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc2JyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzQyNy4wJyB5PScxOTAnIHdpZHRoPScxOTAuMCcgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyNGRkZGRkYnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9JzUyMi4wJyB5PScyMTMnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyMzNDQwNTQnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz42PC90c3Bhbj4gIFZhbGlkYXRlPC90ZXh0PjxsaW5lIHgxPSc2MzIuMCcgeTE9JzUyLjAnIHgyPSc2NjIuMCcgeTI9JzUyLjAnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCB4PSc2NjUuMCcgeT0nMScgd2lkdGg9JzIxNC4wJyBoZWlnaHQ9JzI0MCcgcng9JzEyJyBmaWxsPScjRjhGQUZDJyBzdHJva2U9JyNEMEQ1REQnIHN0cm9rZS13aWR0aD0nMScvPjx0ZXh0IHg9Jzc3Mi4wJyB5PScyMicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjNDc1NDY3Jz5Vc2UgYW5kIHNoYXJlPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nNycgZGF0YS1jdXJyZW50PScwJyB4PSc2NzcuMCcgeT0nMzQnIHdpZHRoPScxOTAuMCcgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyNGRkZGRkYnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9Jzc3Mi4wJyB5PSc1NycgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjc8L3RzcGFuPiAgQXNrIHdpdGggQUk8L3RleHQ+PGxpbmUgeDE9Jzc3Mi4wJyB5MT0nNzEnIHgyPSc3NzIuMCcgeTI9Jzg0JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc4JyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzY3Ny4wJyB5PSc4Nicgd2lkdGg9JzE5MC4wJyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNzcyLjAnIHk9JzEwOScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjg8L3RzcGFuPiAgU2hhcmU8L3RleHQ+PGxpbmUgeDE9Jzc3Mi4wJyB5MT0nMTIzJyB4Mj0nNzcyLjAnIHkyPScxMzYnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCBkYXRhLXN0ZXA9JzknIGRhdGEtY3VycmVudD0nMCcgeD0nNjc3LjAnIHk9JzEzOCcgd2lkdGg9JzE5MC4wJyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNzcyLjAnIHk9JzE2MScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjk8L3RzcGFuPiAgSGFuZCBvZmY8L3RleHQ+PHJlY3QgeD0nMScgeT0nMjUxJyB3aWR0aD0nMTQnIGhlaWdodD0nMTQnIHJ4PSczJyBmaWxsPScjMUY2RkVCJy8+PHRleHQgeD0nMjInIHk9JzI2MicgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmaWxsPScjNDc1NDY3Jz5UaGlzIG5vdGVib29rPC90ZXh0Pjwvc3ZnPg==)

    At the end you have a connection and your data, from as many sources as you like. `01_explore` opens it to understand it: the column map and the semantic views. No AI model is needed. Kit commands run from these cells, so you do not need a terminal.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 0 · Check the kit

    Shows what is installed and running: the database, each add-on and the loaded datasets. It changes nothing.

    The next cells read the rest of the kit live, change it from here (each with its log in the cell), and set up your AI model and Langfuse tracing. They are the calls the Home card's rows and buttons make.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    kit_state = nb.kit_check()
    return (nb,)


@app.cell
def _(nb):
    components = nb.components()
    addons = nb.addons()
    ai_clients = nb.ai_clients()
    sample_datasets = nb.sample_datasets()
    loaded_files = nb.loaded_files()
    sources = nb.sources()
    notebooks = nb.notebooks("data-scientist")
    persona_plan = nb.persona_plan()
    approved = nb.approved_datasets()
    workflows = nb.list_workflows()
    workflow_events = nb.workflow_log(workflows[-1]["id"]) if workflows else []
    model, tracing = nb.model_settings(), nb.tracing()
    [(c["id"], c["installed"], c["status"]) for c in components]
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    | Setting | What it does |
    |---|---|
    | `START_DATABASE` | start the database after a restart of this computer |
    | `ADD_ON` | an add-on to install and start: one of `[a["id"] for a in addons]` |
    | `LOAD`, `LOAD_SCHEMA` | a kit dataset, a file or a folder to load, and the schema it lands in |
    | `SERVICE` | a service to start, then its log |
    | `CHECK_AI` | check the AI clients' connection to the database |
    | `UPDATE_KIT` | bring the kit and its add-ons up to date |
    """)
    return


@app.cell
def _(nb):
    START_DATABASE = False
    ADD_ON = ""
    LOAD = ""
    LOAD_SCHEMA = ""
    SERVICE = ""
    CHECK_AI = False
    UPDATE_KIT = False
    if START_DATABASE:
        nb.exakit("start")
    if ADD_ON:
        nb.addon_ready(ADD_ON)
    if LOAD:
        nb.exakit("data-load", LOAD, env={"EXAKIT_SCHEMA": LOAD_SCHEMA.upper()} if LOAD_SCHEMA else None)
    if SERVICE:
        nb.exakit("start", SERVICE)
        nb.exakit("logs", SERVICE)
    if CHECK_AI:
        nb.exakit("mcp-doctor")
    if UPDATE_KIT:
        nb.kit_update()
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    | Setting | What it does |
    |---|---|
    | `PROVIDER` | one of `providers`: `"anthropic"`, `"openai"`, `"gemini"`, `"ollama"` |
    | `SHOW_MODELS` | list the models your key may use; the key is asked in a hidden box |
    | `MODEL_ID`, `EFFORT` | the model, and its effort where it takes one |
    | `PROVIDER_BASE_URL` | empty: the provider's own address |
    | `LANGFUSE_BASE_URL` | where model calls are traced, such as `https://cloud.langfuse.com` |
    | `FORGET` | delete what was remembered |
    """)
    return


@app.cell
def _(nb):
    providers = {p["id"]: p for p in nb.model_providers()}
    PROVIDER = ""
    SHOW_MODELS = False
    MODEL_ID = ""
    EFFORT = ""
    PROVIDER_BASE_URL = ""
    LANGFUSE_BASE_URL = ""
    FORGET = False
    if PROVIDER and not PROVIDER_BASE_URL:
        PROVIDER_BASE_URL = providers[PROVIDER]["base_url"]
    if PROVIDER and SHOW_MODELS:
        print(nb.provider_models(PROVIDER, base_url=PROVIDER_BASE_URL))
    if MODEL_ID:
        nb.use_model(MODEL_ID, PROVIDER_BASE_URL, effort=EFFORT, remember=True)
    if LANGFUSE_BASE_URL:
        nb.use_model(langfuse_base_url=LANGFUSE_BASE_URL, remember=True)
    if FORGET:
        nb.forget_model(model=True, langfuse=True)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 1 · Access the data

    Starts a workflow, connects to the database and loads a dataset: a practice dataset, your own file or a connected source.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Start a workflow

    The workflow gives one ID to every query and decision below. The next notebooks continue it. You do not copy anything.
    """)
    return


@app.cell
def _(nb):
    import os
    workflow_id = nb.workflow('data-scientist-quickstart', resume=os.environ.get('EXAKIT_WORKFLOW_ID'))
    print(f'Workflow {workflow_id}: every step below is recorded under it.')
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: connect
    mo.md(r"""
    ### Connect

    Connects with the kit's saved connection and lists the schemas. The notebook holds no password.
    """)
    return


@app.cell
def _(nb):
    # Cell tags: connect
    connection = nb.connect()
    nb.check_connection(connection)
    return (connection,)


@app.cell
def _(connection, nb):
    # Cell tags: connect
    nb.list_schemas(connection)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    ### Choose a dataset

    These notebooks use two practice datasets:

    - `amazon_sales`: online fashion orders, one row per order line.
    - `fraud_transactions`: card and bank payments with a fraud label. It has repeats, gaps and placeholders on purpose.

    Set `SAMPLE` to one of them. The first run downloads it (internet needed). Later runs reuse it. Keep `SOURCE = None` for this walkthrough.
    """)
    return


@app.cell
def _(connection, nb):
    # Cell tags: load
    SAMPLE = "amazon_sales"
    sample_data = nb.load_sample(connection, SAMPLE)
    return (sample_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    **Load your own data (optional):** set `MY_DATA` to a CSV, Parquet or JSON file, or to a folder of them. Empty skips it.

    Each file becomes one table named after the file, in a schema named after its folder (`MY_SCHEMA` names another). A folder loads like `exakit data-load`. Running the cell again skips what is already loaded. `MY_TABLE` uses a table already in the database instead. `LOAD_RULES` changes how a file is loaded, such as `{"REPLACE": True, "DATE_SHARE": 0.8}`; `nb.load_rules()` lists every rule.
    """)
    return


@app.cell
def _(connection, nb):
    # Cell tags: load
    MY_DATA = ""
    MY_SCHEMA = ""
    MY_TABLE = ""
    LOAD_RULES = {}
    own_data = (nb.use_table(connection, MY_TABLE) if MY_TABLE
                else nb.load_own_file(MY_DATA, MY_SCHEMA, conn=connection, missing_ok=True, rules=LOAD_RULES))
    return (own_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    **An external source (optional):** a table in Postgres, MySQL, Snowflake and others, read live through a virtual schema. Nothing is copied.

    1. Not connected yet? Pick `CONNECTOR` and paste its connection string into `SOURCE_URL`: the kit reads it as `exakit connect --url` does, and `source_reading["missing"]` says what it did not give. Put those (and any other input you want to change, by the names in `connector_forms[CONNECTOR]["inputs"]`) in `SOURCE_INPUTS`. No connection string? Leave it empty and give every input in `SOURCE_INPUTS`. On a Mac, use `192.168.64.1` for a database on this computer.
    2. Test it: the kit checks the inputs and this computer tries the source's host and port. Nothing is changed and no password is needed.
    3. Connect it: the password is asked in a hidden box and goes to the kit only.
    4. Set `SOURCE` to its table, `"VS_<NAME>.<TABLE>"`. `"VS_<NAME>"` alone lists the tables. `None` skips it.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    | Setting | What it does |
    |---|---|
    | `CONNECTOR` | the kind of source: `[c["id"] for c in connectors]`, such as `"postgresql"` or `"snowflake"` |
    | `SOURCE_NAME` | its name: the tables appear as `VS_<NAME>` |
    | `SOURCE_SETTINGS` | for a source with several kinds in one, such as `{"catalog": "unity", "files": "s3"}` |
    | `SOURCE_URL` | its connection string; a password in it is used, never shown |
    | `SOURCE_INPUTS` | what the string did not give, such as `{"user": "reader"}` |
    """)
    return


@app.cell
def _(nb):
    # Cell tags: load
    connectors = nb.connectors()
    connector_forms = {c["id"]: nb.connector_inputs(c["id"]) for c in connectors}
    source_tips = nb.source_engine("catalog", "--public-ip")["events"]
    CONNECTOR = ""
    SOURCE_NAME = ""
    SOURCE_SETTINGS = {}
    if CONNECTOR and SOURCE_SETTINGS:
        connector_forms[CONNECTOR] = nb.connector_inputs(CONNECTOR, **SOURCE_SETTINGS)
    SOURCE_URL = ""
    source_reading = nb.read_connection_string(CONNECTOR, SOURCE_URL, **SOURCE_SETTINGS) if CONNECTOR and SOURCE_URL else None
    SOURCE_INPUTS = {}
    SOURCE_INPUTS = {**SOURCE_SETTINGS, **({"url": SOURCE_URL} if SOURCE_URL else {}), **SOURCE_INPUTS}
    return CONNECTOR, SOURCE_INPUTS, SOURCE_NAME


@app.cell
def _(CONNECTOR, SOURCE_INPUTS, SOURCE_NAME, nb):
    # Cell tags: load
    source_test = nb.test_source(CONNECTOR, SOURCE_NAME, **SOURCE_INPUTS) if CONNECTOR else None
    return


@app.cell
def _(CONNECTOR, SOURCE_INPUTS, SOURCE_NAME, nb):
    # Cell tags: load
    connected = nb.connect_source(CONNECTOR, SOURCE_NAME, **SOURCE_INPUTS) if CONNECTOR else None
    return (connected,)


@app.cell
def _(connected, connection, nb):
    # Cell tags: load
    SOURCE = None
    source_data = nb.load_source(connection, SOURCE or connected)
    return (source_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    The notebook uses the source first, then your file, then the sample.
    """)
    return


@app.cell
def _(nb, own_data, sample_data, source_data):
    # Cell tags: load
    _chosen_data = nb.first(source_data, own_data, sample_data)
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    ### All your data in one map

    Every table by origin: external source, your data, sample data. Each shows its rows, its column map and the roles in it. *Links* lists columns that join tables, across origins too. A `possible` link only shares a name: check it before a join.
    """)
    return


@app.cell
def _(connection, nb):
    # Cell tags: load
    nb.data_map(connection)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Carry the choice to the next notebook

    `01_explore` opens the tables chosen here: their column maps and semantic views are its first step. Several tables? Put them all in: `nb.remember_chosen(chosen_tables)`.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    `OPEN_APPROVED`: a dataset approved before, by its id (`nb.approved_datasets()` lists them).
    """)
    return


@app.cell
def _(connection, nb):
    OPEN_APPROVED = ''
    if OPEN_APPROVED:
        _chosen_data = nb.dataset(connection, OPEN_APPROVED)
    remembered = nb.remember_chosen(_chosen_data)
    print('01_explore opens: ' + ', '.join(remembered))
    return (remembered,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    Several tables? Their column roles are drawn up in the background, every source at once, so `01_explore` shows them without reading each table again.
    """)
    return


@app.cell
def _(nb, remembered):
    if len(remembered) > 1:
        drafting = nb.prepare_drafts(remembered)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next

    Open `01_explore` to understand your data - the column map and the semantic views - then prepare, explore, model and validate (steps 2 to 6). Then open `02_ask_your_data` (step 7) and `03_share` (steps 8 and 9). Each one continues this workflow.
    """)
    return


if __name__ == "__main__":
    app.run()
