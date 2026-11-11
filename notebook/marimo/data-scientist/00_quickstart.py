import marimo

__generated_with = "0.25.2"
app = marimo.App()


@app.cell(hide_code=True)
def _():
    import marimo as mo

    return (mo,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: exakit-guide-hint
    mo.md(r"""
    <div class="guide-start-hint">

    **Start here · Your kit and your data.** Click into the cell below and press **Shift + Enter** to open it: the kit's state, then your data and its column map. Its **Guided / Code** switch, top right, shows the code behind this page.

    </div>
    """)
    return


@app.cell(hide_code=True)
def _():
    # Cell tags: exakit-guide, skip-ci
    # Your kit and your data: the guided view of this page. Guided / Code, top right, switches to the code cells below.
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
    ## Start here: access and understand your data

    **Dataset:** `amazon_sales` (default), `fraud_transactions` or your own file.

    ![Steps 0 Check the kit, 1 Access and 2 Understand. All steps: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](data:image/svg+xml;base64,PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnIHdpZHRoPSc4ODAnIGhlaWdodD0nMjcwJyB2aWV3Qm94PScwIDAgODgwIDI3MCc+PGRlZnM+PG1hcmtlciBpZD0nYScgdmlld0JveD0nMCAwIDEwIDEwJyByZWZYPSc5JyByZWZZPSc1JyBtYXJrZXJXaWR0aD0nNycgbWFya2VySGVpZ2h0PSc3JyBvcmllbnQ9J2F1dG8nPjxwYXRoIGQ9J00wIDAgTDEwIDUgTDAgMTAgeicgZmlsbD0nIzk4QTJCMycvPjwvbWFya2VyPjwvZGVmcz48cmVjdCB4PScxLjAnIHk9JzEnIHdpZHRoPScxMjguMCcgaGVpZ2h0PScyNDAnIHJ4PScxMicgZmlsbD0nI0Y4RkFGQycgc3Ryb2tlPScjMUY2RkVCJyBzdHJva2Utd2lkdGg9JzEuNScvPjx0ZXh0IHg9JzY1LjAnIHk9JzIyJyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEyLjUnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyMxRjZGRUInPlN0YXJ0PC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nMCcgZGF0YS1jdXJyZW50PScxJyB4PScxMy4wJyB5PSczNCcgd2lkdGg9JzEwNC4wJyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nIzFGNkZFQicgc3Ryb2tlPScjMUY2RkVCJy8+PHRleHQgeD0nNjUuMCcgeT0nNTcnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyNGRkZGRkYnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz4wPC90c3Bhbj4gIENoZWNrIHRoZSBraXQ8L3RleHQ+PGxpbmUgeDE9JzEzMi4wJyB5MT0nNTIuMCcgeDI9JzE2Mi4wJyB5Mj0nNTIuMCcgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IHg9JzE2NS4wJyB5PScxJyB3aWR0aD0nMjE0LjAnIGhlaWdodD0nMjQwJyByeD0nMTInIGZpbGw9JyNGOEZBRkMnIHN0cm9rZT0nIzFGNkZFQicgc3Ryb2tlLXdpZHRoPScxLjUnLz48dGV4dCB4PScyNzIuMCcgeT0nMjInIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTIuNScgZm9udC13ZWlnaHQ9JzcwMCcgZmlsbD0nIzFGNkZFQic+R2V0IHRoZSBkYXRhPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nMScgZGF0YS1jdXJyZW50PScxJyB4PScxNzcuMCcgeT0nMzQnIHdpZHRoPScxOTAuMCcgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyMxRjZGRUInIHN0cm9rZT0nIzFGNkZFQicvPjx0ZXh0IHg9JzI3Mi4wJyB5PSc1NycgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nI0ZGRkZGRic+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjE8L3RzcGFuPiAgQWNjZXNzPC90ZXh0PjxsaW5lIHgxPScyNzIuMCcgeTE9JzcxJyB4Mj0nMjcyLjAnIHkyPSc4NCcgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IGRhdGEtc3RlcD0nMicgZGF0YS1jdXJyZW50PScxJyB4PScxNzcuMCcgeT0nODYnIHdpZHRoPScxOTAuMCcgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyMxRjZGRUInIHN0cm9rZT0nIzFGNkZFQicvPjx0ZXh0IHg9JzI3Mi4wJyB5PScxMDknIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyNGRkZGRkYnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz4yPC90c3Bhbj4gIFVuZGVyc3RhbmQ8L3RleHQ+PGxpbmUgeDE9JzM4Mi4wJyB5MT0nNTIuMCcgeDI9JzQxMi4wJyB5Mj0nNTIuMCcgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IHg9JzQxNS4wJyB5PScxJyB3aWR0aD0nMjE0LjAnIGhlaWdodD0nMjQwJyByeD0nMTInIGZpbGw9JyNGOEZBRkMnIHN0cm9rZT0nI0QwRDVERCcgc3Ryb2tlLXdpZHRoPScxJy8+PHRleHQgeD0nNTIyLjAnIHk9JzIyJyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEyLjUnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyM0NzU0NjcnPlByZXBhcmUgYW5kIG1vZGVsPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nMycgZGF0YS1jdXJyZW50PScwJyB4PSc0MjcuMCcgeT0nMzQnIHdpZHRoPScxOTAuMCcgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyNGRkZGRkYnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9JzUyMi4wJyB5PSc1NycgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjM8L3RzcGFuPiAgUHJlcGFyZTwvdGV4dD48bGluZSB4MT0nNTIyLjAnIHkxPSc3MScgeDI9JzUyMi4wJyB5Mj0nODQnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCBkYXRhLXN0ZXA9JzQnIGRhdGEtY3VycmVudD0nMCcgeD0nNDI3LjAnIHk9Jzg2JyB3aWR0aD0nMTkwLjAnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSc1MjIuMCcgeT0nMTA5JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+NDwvdHNwYW4+ICBFeHBsb3JlPC90ZXh0PjxsaW5lIHgxPSc1MjIuMCcgeTE9JzEyMycgeDI9JzUyMi4wJyB5Mj0nMTM2JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc1JyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzQyNy4wJyB5PScxMzgnIHdpZHRoPScxOTAuMCcgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyNGRkZGRkYnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9JzUyMi4wJyB5PScxNjEnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyMzNDQwNTQnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz41PC90c3Bhbj4gIE1vZGVsPC90ZXh0PjxsaW5lIHgxPSc1MjIuMCcgeTE9JzE3NScgeDI9JzUyMi4wJyB5Mj0nMTg4JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc2JyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzQyNy4wJyB5PScxOTAnIHdpZHRoPScxOTAuMCcgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyNGRkZGRkYnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9JzUyMi4wJyB5PScyMTMnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyMzNDQwNTQnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz42PC90c3Bhbj4gIFZhbGlkYXRlPC90ZXh0PjxsaW5lIHgxPSc2MzIuMCcgeTE9JzUyLjAnIHgyPSc2NjIuMCcgeTI9JzUyLjAnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCB4PSc2NjUuMCcgeT0nMScgd2lkdGg9JzIxNC4wJyBoZWlnaHQ9JzI0MCcgcng9JzEyJyBmaWxsPScjRjhGQUZDJyBzdHJva2U9JyNEMEQ1REQnIHN0cm9rZS13aWR0aD0nMScvPjx0ZXh0IHg9Jzc3Mi4wJyB5PScyMicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjNDc1NDY3Jz5Vc2UgYW5kIHNoYXJlPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nNycgZGF0YS1jdXJyZW50PScwJyB4PSc2NzcuMCcgeT0nMzQnIHdpZHRoPScxOTAuMCcgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyNGRkZGRkYnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9Jzc3Mi4wJyB5PSc1NycgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjc8L3RzcGFuPiAgQXNrIHdpdGggQUk8L3RleHQ+PGxpbmUgeDE9Jzc3Mi4wJyB5MT0nNzEnIHgyPSc3NzIuMCcgeTI9Jzg0JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc4JyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzY3Ny4wJyB5PSc4Nicgd2lkdGg9JzE5MC4wJyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNzcyLjAnIHk9JzEwOScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjg8L3RzcGFuPiAgU2hhcmU8L3RleHQ+PGxpbmUgeDE9Jzc3Mi4wJyB5MT0nMTIzJyB4Mj0nNzcyLjAnIHkyPScxMzYnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCBkYXRhLXN0ZXA9JzknIGRhdGEtY3VycmVudD0nMCcgeD0nNjc3LjAnIHk9JzEzOCcgd2lkdGg9JzE5MC4wJyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNzcyLjAnIHk9JzE2MScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjk8L3RzcGFuPiAgSGFuZCBvZmY8L3RleHQ+PHJlY3QgeD0nMScgeT0nMjUxJyB3aWR0aD0nMTQnIGhlaWdodD0nMTQnIHJ4PSczJyBmaWxsPScjMUY2RkVCJy8+PHRleHQgeD0nMjInIHk9JzI2MicgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmaWxsPScjNDc1NDY3Jz5UaGlzIG5vdGVib29rPC90ZXh0Pjwvc3ZnPg==)

    At the end you have a connection, an approved column map and a first result. No AI model is needed. Kit commands run from these cells, so you do not need a terminal.
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


@app.cell(hide_code=True)
def _():
    import exakit.nb as nb

    kit_state = nb.kit_check()
    return (nb,)


@app.cell(hide_code=True)
def _(nb):
    # What the kit has, read live: the same calls the Home card shows.
    components = nb.components()            # the kit's parts, their versions and pending updates
    addons = nb.addons()                    # the marketplace's add-ons and their state
    ai_clients = nb.ai_clients()            # the AI clients the kit can connect, and which are connected
    sample_datasets = nb.sample_datasets()  # the kit's sample datasets, and which are loaded
    loaded_files = nb.loaded_files()        # the files you loaded with exakit data-load: table, rows, file
    notebooks = nb.notebooks("data-scientist")   # this persona's notebooks, in order
    persona_plan = nb.persona_plan()        # what this kit's personas bring that is still missing
    approved = nb.approved_datasets()       # the column maps approved so far
    workflows = nb.list_workflows()         # every workflow log; the last one's events:
    workflow_events = nb.workflow_log(workflows[-1]["id"]) if workflows else []
    model, tracing = nb.model_settings(), nb.tracing()
    [(c["id"], c["installed"], c["status"]) for c in components]
    return


@app.cell(hide_code=True)
def _(nb):
    # Change the kit from here: set what you want, run the cell; each runs as `exakit` would, its log in the cell.
    START_DATABASE = False   # start the database after a restart of this computer
    ADD_ON = ""              # an add-on to install and start, e.g. one of [a["id"] for a in addons]
    LOAD = ""                # a kit dataset (sample_datasets), a file or a folder, loaded with exakit data-load
    LOAD_SCHEMA = ""         # where a file or folder lands (empty: STARTER_KIT, exakit's default)
    SERVICE = ""             # a service to start (kit_state["services"]), then its log
    CHECK_AI = False         # check the AI clients' connection to the database (mcp-doctor)
    UPDATE_KIT = False       # bring the kit and its add-ons up to date
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
def _(nb):
    # Your AI model and Langfuse tracing, remembered for every notebook of this kit (readable by you only). The keys are
    # asked in a hidden box. Empty values change nothing; FORGET deletes what was remembered.
    MODEL_ID = ""            # e.g. "claude-opus-5-5"
    PROVIDER_BASE_URL = ""   # e.g. "https://api.anthropic.com/v1/"
    LANGFUSE_BASE_URL = ""   # e.g. "https://cloud.langfuse.com"
    FORGET = False
    if MODEL_ID or PROVIDER_BASE_URL:
        nb.use_model(MODEL_ID, PROVIDER_BASE_URL, remember=True)
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


@app.cell(hide_code=True)
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


@app.cell(hide_code=True)
def _(nb):
    # Cell tags: connect
    connection = nb.connect()
    nb.check_connection(connection)
    return (connection,)


@app.cell(hide_code=True)
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


@app.cell(hide_code=True)
def _(connection, nb):
    # Cell tags: load
    SAMPLE = "amazon_sales"   # or "fraud_transactions", or None
    sample_data = nb.load_sample(connection, SAMPLE)
    return (sample_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    **Load your own data (optional):** set `MY_DATA` to a CSV, Parquet or JSON file, or to a folder of them. Empty skips it.

    Each file becomes one table named after the file, in a schema named after its folder (`MY_SCHEMA` names another). A folder loads like `exakit data-load`. Running the cell again skips what is already loaded.
    """)
    return


@app.cell(hide_code=True)
def _(connection, nb):
    # Cell tags: load
    MY_DATA = ""     # a file or a folder, e.g. "~/sales-data/orders.csv" or "~/sales-data" (Excel works too)
    MY_SCHEMA = ""   # the schema, e.g. "SALES" (empty: the folder's name, ~/sales-data -> SALES_DATA)
    MY_TABLE = ""    # or a table already in the database, e.g. "MY_DATA.ORDERS" (nb.data_map lists them)
    own_data = (nb.use_table(connection, MY_TABLE) if MY_TABLE
                else nb.load_own_file(MY_DATA, MY_SCHEMA, conn=connection, missing_ok=True))
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
def _(nb):
    # Cell tags: load
    connectors = nb.connectors()   # every kind of source CONNECTOR takes: [c["id"] for c in connectors]
    connector_forms = {c["id"]: nb.connector_inputs(c["id"]) for c in connectors}   # what each asks, required ones marked
    source_tips = nb.source_engine("catalog", "--public-ip")["events"]   # this computer's public IP, to allow at a cloud source
    CONNECTOR = ""     # e.g. "postgresql", "mysql", "snowflake" (empty: already connected, or no source)
    SOURCE_NAME = ""   # e.g. "sales": the tables appear as VS_SALES
    SOURCE_URL = ""    # its connection string, e.g. "postgres://reader@192.168.64.1:5432/shop" (a password in it is used, never shown)
    source_reading = nb.read_connection_string(CONNECTOR, SOURCE_URL) if CONNECTOR and SOURCE_URL else None
    SOURCE_INPUTS = {}  # what the string did not give (source_reading["missing"]), e.g. {"user": "reader"}; no string: every input
    SOURCE_INPUTS = {**({"url": SOURCE_URL} if SOURCE_URL else {}), **SOURCE_INPUTS}
    return CONNECTOR, SOURCE_INPUTS, SOURCE_NAME


@app.cell(hide_code=True)
def _(CONNECTOR, SOURCE_INPUTS, SOURCE_NAME, nb):
    # Cell tags: load
    source_test = nb.test_source(CONNECTOR, SOURCE_NAME, **SOURCE_INPUTS) if CONNECTOR else None
    return


@app.cell(hide_code=True)
def _(CONNECTOR, SOURCE_INPUTS, SOURCE_NAME, nb):
    # Cell tags: load
    connected = nb.connect_source(CONNECTOR, SOURCE_NAME, **SOURCE_INPUTS) if CONNECTOR else None
    return (connected,)


@app.cell(hide_code=True)
def _(connected, connection, nb):
    # Cell tags: load
    SOURCE = None   # e.g. "VS_SALES.ORDERS" (None after a connect above: the new source's tables)
    source_data = nb.load_source(connection, SOURCE or connected)
    return (source_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    The notebook uses the source first, then your file, then the sample.
    """)
    return


@app.cell(hide_code=True)
def _(nb, own_data, sample_data, source_data):
    # Cell tags: load
    chosen_data = nb.first(source_data, own_data, sample_data)
    return (chosen_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    ### All your data in one map

    Every table by origin: external source, your data, sample data. Each shows its rows, its column map and the roles in it. *Links* lists columns that join tables, across origins too. A `possible` link only shares a name: check it before a join.
    """)
    return


@app.cell(hide_code=True)
def _(connection, nb):
    # Cell tags: load
    nb.data_map(connection)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 2 · Understand the data

    You approve the column map: the key, the date, the groups and the outcome. The kit proposes it and shows the least certain columns first. Every later step reads this map, so the same notebooks run on any table.
    """)
    return


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


@app.cell(hide_code=True)
def _(chosen_data, connection, nb):
    # Cell tags: review
    role_review = nb.review_roles(connection, chosen_data)
    return (role_review,)


@app.cell(hide_code=True)
def _(role_review):
    # Cell tags: review
    # Or approve in code - what Approve in the column map card does: the roles you change, {"COLUMN": "role"}, and the
    # slots, {"target": "COLUMN"}. Empty: the picker above (or an approval already saved) stands.
    ROLE_CHANGES = {}
    SLOT_CHANGES = {}
    if ROLE_CHANGES or SLOT_CHANGES:
        role_review.approve(ROLE_CHANGES or None, SLOT_CHANGES or None)
    return


@app.cell(hide_code=True)
def _(nb, role_review):
    # Cell tags: review
    dataset = role_review.dataset()
    nb.show_roles(dataset)
    return (dataset,)


@app.cell(hide_code=True)
def _(connection, dataset, nb):
    # Cell tags: review
    leaking = nb.leakage_check(connection, dataset)            # columns that give the outcome away: left out of a model
    versions = nb.column_map_versions(dataset.id)              # every saved version; approving one's roles again restores it
    return


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: review
    mo.md(r"""
    ### Check the map again

    The same map, read again after the approval. The table you approved now shows `approved vN, published` and every slot by name. `not published` means the roles are saved but agents cannot read them yet: approve again to publish.
    """)
    return


@app.cell(hide_code=True)
def _(connection, dataset, nb):
    # Cell tags: review
    dataset  # read after the approval above, so this map shows it
    nb.data_map(connection)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### A first result

    Rows per group, and the % where the target is 1 when the map has a target. Each query shows its SQL before the result.
    """)
    return


@app.cell(hide_code=True)
def _(connection, dataset, nb):
    missing_roles = {missing["role"]: missing["reason"] for missing in dataset.missing}
    GROUP_ROLE, GROUP_COLUMN = dataset.group_by()   # the category, else the entity, else the target
    if GROUP_ROLE != "category":
        print(f"No category ({missing_roles.get('category', 'none approved')}): rows are counted per {GROUP_ROLE} instead.")
    if "label" in missing_roles:
        print(f"No target ({missing_roles['label']}): the target rate is left out. Later steps that need it say so.")
    GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)       # columns named after the data: CATEGORY, ORDER_LINES
    LABEL_PCT_HEADER = nb.name(dataset.col("label"), "PCT") if dataset.has("label") and GROUP_ROLE != "label" else None   # CANCELLED_PCT
    LABEL_RATE_SQL = f",\n       ROUND(100 * AVG({dataset.col('label')}), 1) AS {LABEL_PCT_HEADER}" if LABEL_PCT_HEADER else ""
    first_rows = nb.sql(connection, f"""
    SELECT {GROUP_COLUMN} AS {GROUP_HEADER},
           COUNT(*) AS {COUNT_HEADER}{LABEL_RATE_SQL}
    FROM {dataset.fact_table}
    GROUP BY {GROUP_COLUMN}
    ORDER BY {COUNT_HEADER} DESC
    LIMIT 10""")
    nb.show_sql()
    overall_rate = nb.sql(connection, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({dataset.col('label')}), 1) AS PCT FROM {dataset.fact_table}") if LABEL_PCT_HEADER else None
    nb.note_groups(first_rows, dataset, GROUP_HEADER, COUNT_HEADER, LABEL_PCT_HEADER, overall=(overall_rate["N"][0], overall_rate["PCT"][0]) if LABEL_PCT_HEADER else None)
    first_rows
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Next

    Open `01_explore` to prepare, explore, model and validate (steps 3 to 6). Then open `02_ask_your_data` (step 7) and `03_share` (steps 8 and 9). Each one continues this workflow.
    """)
    return


if __name__ == "__main__":
    app.run()
