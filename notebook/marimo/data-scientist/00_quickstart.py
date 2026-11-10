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
    # Start here: access and understand your data

    **Dataset:** `amazon_sales` (default), `fraud_transactions` or your own file.

    ![Steps 0 Kit, 1 Access and 2 Understand of nine: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](data:image/svg+xml;base64,PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnIHdpZHRoPSc4ODAnIGhlaWdodD0nOTQnIHZpZXdCb3g9JzAgMCA4ODAgOTQnPjxyZWN0IHg9JzEuMCcgeT0nMScgd2lkdGg9Jzc1LjInIGhlaWdodD0nNTgnIHJ4PScxMCcgZmlsbD0nIzFGNkZFQicgc3Ryb2tlPScjMUY2RkVCJy8+PHRleHQgeD0nMzguNicgeT0nMjYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTgnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyNGRkZGRkYnPjA8L3RleHQ+PHRleHQgeD0nMzguNicgeT0nNDYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTEuNScgZmlsbD0nI0ZGRkZGRic+S2l0PC90ZXh0PjxwYXRoIGQ9J004MC4yIDI0IEw4Ni4yIDMwIEw4MC4yIDM2JyBmaWxsPSdub25lJyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMicgc3Ryb2tlLWxpbmVjYXA9J3JvdW5kJyBzdHJva2UtbGluZWpvaW49J3JvdW5kJy8+PHJlY3QgeD0nOTAuMicgeT0nMScgd2lkdGg9Jzc1LjInIGhlaWdodD0nNTgnIHJ4PScxMCcgZmlsbD0nIzFGNkZFQicgc3Ryb2tlPScjMUY2RkVCJy8+PHRleHQgeD0nMTI3LjgnIHk9JzI2JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzE4JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjRkZGRkZGJz4xPC90ZXh0Pjx0ZXh0IHg9JzEyNy44JyB5PSc0NicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMS41JyBmaWxsPScjRkZGRkZGJz5BY2Nlc3M8L3RleHQ+PHBhdGggZD0nTTE2OS40IDI0IEwxNzUuNCAzMCBMMTY5LjQgMzYnIGZpbGw9J25vbmUnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScyJyBzdHJva2UtbGluZWNhcD0ncm91bmQnIHN0cm9rZS1saW5lam9pbj0ncm91bmQnLz48cmVjdCB4PScxNzkuNCcgeT0nMScgd2lkdGg9Jzc1LjInIGhlaWdodD0nNTgnIHJ4PScxMCcgZmlsbD0nIzFGNkZFQicgc3Ryb2tlPScjMUY2RkVCJy8+PHRleHQgeD0nMjE3LjAnIHk9JzI2JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzE4JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjRkZGRkZGJz4yPC90ZXh0Pjx0ZXh0IHg9JzIxNy4wJyB5PSc0NicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMS41JyBmaWxsPScjRkZGRkZGJz5VbmRlcnN0YW5kPC90ZXh0PjxwYXRoIGQ9J00yNTguNiAyNCBMMjY0LjYgMzAgTDI1OC42IDM2JyBmaWxsPSdub25lJyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMicgc3Ryb2tlLWxpbmVjYXA9J3JvdW5kJyBzdHJva2UtbGluZWpvaW49J3JvdW5kJy8+PHJlY3QgeD0nMjY4LjYnIHk9JzEnIHdpZHRoPSc3NS4yJyBoZWlnaHQ9JzU4JyByeD0nMTAnIGZpbGw9JyNGMkY0RjcnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9JzMwNi4yJyB5PScyNicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxOCcgZm9udC13ZWlnaHQ9JzcwMCcgZmlsbD0nIzM0NDA1NCc+MzwvdGV4dD48dGV4dCB4PSczMDYuMicgeT0nNDYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTEuNScgZmlsbD0nIzQ3NTQ2Nyc+UHJlcGFyZTwvdGV4dD48cGF0aCBkPSdNMzQ3LjggMjQgTDM1My44IDMwIEwzNDcuOCAzNicgZmlsbD0nbm9uZScgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzInIHN0cm9rZS1saW5lY2FwPSdyb3VuZCcgc3Ryb2tlLWxpbmVqb2luPSdyb3VuZCcvPjxyZWN0IHg9JzM1Ny44JyB5PScxJyB3aWR0aD0nNzUuMicgaGVpZ2h0PSc1OCcgcng9JzEwJyBmaWxsPScjRjJGNEY3JyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSczOTUuNCcgeT0nMjYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTgnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyMzNDQwNTQnPjQ8L3RleHQ+PHRleHQgeD0nMzk1LjQnIHk9JzQ2JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzExLjUnIGZpbGw9JyM0NzU0NjcnPkV4cGxvcmU8L3RleHQ+PHBhdGggZD0nTTQzNy4wIDI0IEw0NDMuMCAzMCBMNDM3LjAgMzYnIGZpbGw9J25vbmUnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScyJyBzdHJva2UtbGluZWNhcD0ncm91bmQnIHN0cm9rZS1saW5lam9pbj0ncm91bmQnLz48cmVjdCB4PSc0NDcuMCcgeT0nMScgd2lkdGg9Jzc1LjInIGhlaWdodD0nNTgnIHJ4PScxMCcgZmlsbD0nI0YyRjRGNycgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNDg0LjYnIHk9JzI2JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzE4JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjMzQ0MDU0Jz41PC90ZXh0Pjx0ZXh0IHg9JzQ4NC42JyB5PSc0NicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMS41JyBmaWxsPScjNDc1NDY3Jz5Nb2RlbDwvdGV4dD48cGF0aCBkPSdNNTI2LjIgMjQgTDUzMi4yIDMwIEw1MjYuMiAzNicgZmlsbD0nbm9uZScgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzInIHN0cm9rZS1saW5lY2FwPSdyb3VuZCcgc3Ryb2tlLWxpbmVqb2luPSdyb3VuZCcvPjxyZWN0IHg9JzUzNi4yJyB5PScxJyB3aWR0aD0nNzUuMicgaGVpZ2h0PSc1OCcgcng9JzEwJyBmaWxsPScjRjJGNEY3JyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSc1NzMuOCcgeT0nMjYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTgnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyMzNDQwNTQnPjY8L3RleHQ+PHRleHQgeD0nNTczLjgnIHk9JzQ2JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzExLjUnIGZpbGw9JyM0NzU0NjcnPlZhbGlkYXRlPC90ZXh0PjxwYXRoIGQ9J002MTUuNCAyNCBMNjIxLjQgMzAgTDYxNS40IDM2JyBmaWxsPSdub25lJyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMicgc3Ryb2tlLWxpbmVjYXA9J3JvdW5kJyBzdHJva2UtbGluZWpvaW49J3JvdW5kJy8+PHJlY3QgeD0nNjI1LjQnIHk9JzEnIHdpZHRoPSc3NS4yJyBoZWlnaHQ9JzU4JyByeD0nMTAnIGZpbGw9JyNGMkY0RjcnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9JzY2My4wJyB5PScyNicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxOCcgZm9udC13ZWlnaHQ9JzcwMCcgZmlsbD0nIzM0NDA1NCc+NzwvdGV4dD48dGV4dCB4PSc2NjMuMCcgeT0nNDYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTEuNScgZmlsbD0nIzQ3NTQ2Nyc+QXNrIHdpdGggQUk8L3RleHQ+PHBhdGggZD0nTTcwNC42IDI0IEw3MTAuNiAzMCBMNzA0LjYgMzYnIGZpbGw9J25vbmUnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScyJyBzdHJva2UtbGluZWNhcD0ncm91bmQnIHN0cm9rZS1saW5lam9pbj0ncm91bmQnLz48cmVjdCB4PSc3MTQuNicgeT0nMScgd2lkdGg9Jzc1LjInIGhlaWdodD0nNTgnIHJ4PScxMCcgZmlsbD0nI0YyRjRGNycgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNzUyLjInIHk9JzI2JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzE4JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjMzQ0MDU0Jz44PC90ZXh0Pjx0ZXh0IHg9Jzc1Mi4yJyB5PSc0NicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMS41JyBmaWxsPScjNDc1NDY3Jz5TaGFyZTwvdGV4dD48cGF0aCBkPSdNNzkzLjggMjQgTDc5OS44IDMwIEw3OTMuOCAzNicgZmlsbD0nbm9uZScgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzInIHN0cm9rZS1saW5lY2FwPSdyb3VuZCcgc3Ryb2tlLWxpbmVqb2luPSdyb3VuZCcvPjxyZWN0IHg9JzgwMy44JyB5PScxJyB3aWR0aD0nNzUuMicgaGVpZ2h0PSc1OCcgcng9JzEwJyBmaWxsPScjRjJGNEY3JyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSc4NDEuNCcgeT0nMjYnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTgnIGZvbnQtd2VpZ2h0PSc3MDAnIGZpbGw9JyMzNDQwNTQnPjk8L3RleHQ+PHRleHQgeD0nODQxLjQnIHk9JzQ2JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzExLjUnIGZpbGw9JyM0NzU0NjcnPkhhbmQgb2ZmPC90ZXh0PjxyZWN0IHg9JzEuMCcgeT0nNjYnIHdpZHRoPScyNTMuNicgaGVpZ2h0PSc0JyByeD0nMicgZmlsbD0nIzFGNkZFQicvPjx0ZXh0IHg9JzEyNy44JyB5PSc4OCcgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmb250LXdlaWdodD0nNjAwJyBmaWxsPScjMUY2RkVCJz5UaGlzIG5vdGVib29rPC90ZXh0Pjwvc3ZnPg==)

    At the end you have a connection, an approved column map and a first result. No AI model is needed. Kit commands run from these cells, so you do not need a terminal.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 0 · Check the kit

    Shows what is installed and running: the database, each add-on and the loaded datasets. It changes nothing.

    Other kit commands run the same way, with the log in the cell:

    - `nb.exakit("update")` updates the kit.
    - `nb.exakit("marketplace", "dash-server")` adds an add-on.
    - `nb.exakit("logs")` shows the logs.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    kit_state = nb.kit_check()
    return (nb,)


@app.cell
def _():
    # Things you would otherwise do in a terminal - take the # off one line and run the cell; its log shows here.
    # nb.exakit("update")                            # bring the kit and its add-ons up to date
    # nb.exakit("marketplace", "dash-server")        # add an add-on (Share, step 8, needs this one)
    # nb.exakit("data-load", "fraud_transactions")        # load another of the kit's datasets
    # nb.exakit("logs")                              # every log the kit keeps
    # nb.exakit("mcp-setup", env={"EXAKIT_MCP_CLIENTS": "claude"})   # connect an AI client to the database
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 1 · Access the data

    Connects to the database, starts a workflow and loads a dataset: a practice dataset, your own file or a connected source.
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
    print(f'Every step below is logged under it: exakit workflow show {workflow_id}')
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

    The kit has two practice datasets:

    - `amazon_sales`: online fashion orders, one row per order line.
    - `fraud_transactions`: card and bank payments with a fraud label. It has repeats, gaps and placeholders on purpose.

    Set `SAMPLE` to one of them. The first run downloads it (internet needed). Later runs reuse it. Keep `SOURCE = None` for this walkthrough.
    """)
    return


@app.cell
def _(connection, nb):
    # Cell tags: load
    SAMPLE = "amazon_sales"   # or "fraud_transactions", or None
    sample_data = nb.load_sample(connection, SAMPLE)
    return (sample_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    **Your own file (optional):** set `OWN_FILE` (CSV, Parquet or JSON) and `OWN_TABLE`. A missing file is skipped.
    """)
    return


@app.cell
def _(connection, nb):
    # Cell tags: load
    OWN_FILE = "~/my-data/transactions.csv"   # .csv, .parquet or .json
    OWN_TABLE = "MY_DATA.TRANSACTIONS"
    own_data = nb.load_own_file(OWN_FILE, OWN_TABLE, conn=connection, missing_ok=True)
    return (own_data,)


@app.cell(hide_code=True)
def _(mo):
    # Cell tags: load
    mo.md(r"""
    **A connected source (optional):** set `SOURCE = "SCHEMA.TABLE"` for a virtual-schema table. `None` skips it.
    """)
    return


@app.cell
def _(connection, nb):
    # Cell tags: load
    SOURCE = None   # e.g. "VS_SALES.ORDERS"
    source_data = nb.load_source(connection, SOURCE)
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
    chosen_data = nb.first(source_data, own_data, sample_data)
    return (chosen_data,)


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

    The kit proposes the map from the data. A proposal can be wrong. In `amazon_sales`, `STATUS` gives the answer away. Check the map before any query uses it.

    **Roles:** `key` (one per row), `time`, `measure` (a number to add up), `category` (a few repeated values), `flag` (yes/no), `text`, `identifier` (names or codes) and `other`.

    **Slots:** the one column each step uses for `key`, `time`, `text`, `target` (the outcome to predict), `category` (groups to compare) and `entity` (who or what a row is about).

    | Dataset | `key` | `time` | `text` | `target` | `category` | `entity` |
    |---|---|---|---|---|---|---|
    | Amazon sales | `ORDER_LINE_ID` | `ORDER_DATE` | — | `CANCELLED` | `CATEGORY` | `SHIP_STATE` |
    | Fraud transactions | `ROW_ID` | — | — | `FRAUDULENT` | `TRANSACTION_TYPE` | `LOCATION` |

    Neither dataset has a text column. The text steps skip and say why.

    The kit never guesses the **target**. You choose it. Leave a slot as **—** when no column fits.

    **Do now:**

    1. Look at *Check these first*. These are the columns the kit was least sure about.
    2. Correct what is wrong.
    3. Click **Approve descriptor**. No click is needed if the map is already approved and you change nothing.
    4. Run the next cell.

    Approval checks the data again and warns about a column that gives the target away.

    In plain Python: `review.approve({"COLUMN": "role"}, {"target": "COLUMN"})`.
    """)
    return


@app.cell
def _(chosen_data, connection, nb):
    # Cell tags: review
    role_review = nb.review_roles(connection, chosen_data)
    return (role_review,)


@app.cell
def _(nb, role_review):
    # Cell tags: review
    dataset = role_review.dataset()
    nb.show_roles(dataset)
    return (dataset,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### A first result

    Rows per group, and the % where the label is 1 when the map has a label. Each query shows its SQL before the result.
    """)
    return


@app.cell
def _(connection, dataset, nb):
    missing_roles = {missing["role"]: missing["reason"] for missing in dataset.missing}
    GROUP_ROLE, GROUP_COLUMN = dataset.group_by()   # the category, else the entity, else the target
    if GROUP_ROLE != "category":
        print(f"No category role ({missing_roles.get('category', 'none approved')}): rows are counted per {GROUP_ROLE} instead.")
    if "label" in missing_roles:
        print(f"No label role ({missing_roles['label']}): the label rate is left out; the steps that need it later say so.")
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
    ## Next: steps 3 to 6

    Open `01_explore.ipynb` to prepare, explore, model and validate. Then open `02_ask_your_data.ipynb` (step 7) and `03_share.ipynb` (steps 8 and 9). Each one continues this workflow.
    """)
    return


if __name__ == "__main__":
    app.run()
