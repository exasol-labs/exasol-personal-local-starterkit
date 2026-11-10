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
    # Share the insight and hand it off

    **Dataset:** the one you approved last (else `amazon_sales`), `fraud_transactions` or your own approved descriptor.

    ![Steps 8 Share and 9 Hand off of nine: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](data:image/svg+xml;base64,PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnIHdpZHRoPSc4ODAnIGhlaWdodD0nMjcwJyB2aWV3Qm94PScwIDAgODgwIDI3MCc+PGRlZnM+PG1hcmtlciBpZD0nYScgdmlld0JveD0nMCAwIDEwIDEwJyByZWZYPSc5JyByZWZZPSc1JyBtYXJrZXJXaWR0aD0nNycgbWFya2VySGVpZ2h0PSc3JyBvcmllbnQ9J2F1dG8nPjxwYXRoIGQ9J00wIDAgTDEwIDUgTDAgMTAgeicgZmlsbD0nIzk4QTJCMycvPjwvbWFya2VyPjwvZGVmcz48cmVjdCB4PScxLjAnIHk9JzEnIHdpZHRoPScyNjguNycgaGVpZ2h0PScyNDAnIHJ4PScxMicgZmlsbD0nI0Y4RkFGQycgc3Ryb2tlPScjRDBENUREJyBzdHJva2Utd2lkdGg9JzEnLz48dGV4dCB4PScxMzUuMycgeT0nMjInIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTIuNScgZm9udC13ZWlnaHQ9JzcwMCcgZmlsbD0nIzQ3NTQ2Nyc+R2V0IHRoZSBkYXRhPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nMScgZGF0YS1jdXJyZW50PScwJyB4PScxMy4wJyB5PSczNCcgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nMTM1LjMnIHk9JzU3JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+MTwvdHNwYW4+ICBBY2Nlc3M8L3RleHQ+PGxpbmUgeDE9JzEzNS4zJyB5MT0nNzEnIHgyPScxMzUuMycgeTI9Jzg0JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPScyJyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzEzLjAnIHk9Jzg2JyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PScxMzUuMycgeT0nMTA5JyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+MjwvdHNwYW4+ICBVbmRlcnN0YW5kPC90ZXh0PjxsaW5lIHgxPScyNzIuNycgeTE9JzUyLjAnIHgyPSczMDIuNycgeTI9JzUyLjAnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCB4PSczMDUuNycgeT0nMScgd2lkdGg9JzI2OC43JyBoZWlnaHQ9JzI0MCcgcng9JzEyJyBmaWxsPScjRjhGQUZDJyBzdHJva2U9JyNEMEQ1REQnIHN0cm9rZS13aWR0aD0nMScvPjx0ZXh0IHg9JzQ0MC4wJyB5PScyMicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjNDc1NDY3Jz5QcmVwYXJlIGFuZCBtb2RlbDwvdGV4dD48cmVjdCBkYXRhLXN0ZXA9JzMnIGRhdGEtY3VycmVudD0nMCcgeD0nMzE3LjcnIHk9JzM0JyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSc0NDAuMCcgeT0nNTcnIHRleHQtYW5jaG9yPSdtaWRkbGUnIGZvbnQtZmFtaWx5PSdzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYnIGZvbnQtc2l6ZT0nMTMnIGZpbGw9JyMzNDQwNTQnPjx0c3BhbiBmb250LXdlaWdodD0nNzAwJz4zPC90c3Bhbj4gIFByZXBhcmU8L3RleHQ+PGxpbmUgeDE9JzQ0MC4wJyB5MT0nNzEnIHgyPSc0NDAuMCcgeTI9Jzg0JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc0JyBkYXRhLWN1cnJlbnQ9JzAnIHg9JzMxNy43JyB5PSc4Nicgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nI0ZGRkZGRicgc3Ryb2tlPScjRDBENUREJy8+PHRleHQgeD0nNDQwLjAnIHk9JzEwOScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjQ8L3RzcGFuPiAgRXhwbG9yZTwvdGV4dD48bGluZSB4MT0nNDQwLjAnIHkxPScxMjMnIHgyPSc0NDAuMCcgeTI9JzEzNicgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IGRhdGEtc3RlcD0nNScgZGF0YS1jdXJyZW50PScwJyB4PSczMTcuNycgeT0nMTM4JyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSc0NDAuMCcgeT0nMTYxJyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+NTwvdHNwYW4+ICBNb2RlbDwvdGV4dD48bGluZSB4MT0nNDQwLjAnIHkxPScxNzUnIHgyPSc0NDAuMCcgeTI9JzE4OCcgc3Ryb2tlPScjOThBMkIzJyBzdHJva2Utd2lkdGg9JzEuNScgbWFya2VyLWVuZD0ndXJsKCNhKScvPjxyZWN0IGRhdGEtc3RlcD0nNicgZGF0YS1jdXJyZW50PScwJyB4PSczMTcuNycgeT0nMTkwJyB3aWR0aD0nMjQ0LjcnIGhlaWdodD0nMzYnIHJ4PSc4JyBmaWxsPScjRkZGRkZGJyBzdHJva2U9JyNEMEQ1REQnLz48dGV4dCB4PSc0NDAuMCcgeT0nMjEzJyB0ZXh0LWFuY2hvcj0nbWlkZGxlJyBmb250LWZhbWlseT0nc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmJyBmb250LXNpemU9JzEzJyBmaWxsPScjMzQ0MDU0Jz48dHNwYW4gZm9udC13ZWlnaHQ9JzcwMCc+NjwvdHNwYW4+ICBWYWxpZGF0ZTwvdGV4dD48bGluZSB4MT0nNTc3LjMnIHkxPSc1Mi4wJyB4Mj0nNjA3LjMnIHkyPSc1Mi4wJyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgeD0nNjEwLjMnIHk9JzEnIHdpZHRoPScyNjguNycgaGVpZ2h0PScyNDAnIHJ4PScxMicgZmlsbD0nI0Y4RkFGQycgc3Ryb2tlPScjMUY2RkVCJyBzdHJva2Utd2lkdGg9JzEuNScvPjx0ZXh0IHg9Jzc0NC43JyB5PScyMicgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmb250LXdlaWdodD0nNzAwJyBmaWxsPScjMUY2RkVCJz5Vc2UgYW5kIHNoYXJlPC90ZXh0PjxyZWN0IGRhdGEtc3RlcD0nNycgZGF0YS1jdXJyZW50PScwJyB4PSc2MjIuMycgeT0nMzQnIHdpZHRoPScyNDQuNycgaGVpZ2h0PSczNicgcng9JzgnIGZpbGw9JyNGRkZGRkYnIHN0cm9rZT0nI0QwRDVERCcvPjx0ZXh0IHg9Jzc0NC43JyB5PSc1NycgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nIzM0NDA1NCc+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjc8L3RzcGFuPiAgQXNrIHdpdGggQUk8L3RleHQ+PGxpbmUgeDE9Jzc0NC43JyB5MT0nNzEnIHgyPSc3NDQuNycgeTI9Jzg0JyBzdHJva2U9JyM5OEEyQjMnIHN0cm9rZS13aWR0aD0nMS41JyBtYXJrZXItZW5kPSd1cmwoI2EpJy8+PHJlY3QgZGF0YS1zdGVwPSc4JyBkYXRhLWN1cnJlbnQ9JzEnIHg9JzYyMi4zJyB5PSc4Nicgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nIzFGNkZFQicgc3Ryb2tlPScjMUY2RkVCJy8+PHRleHQgeD0nNzQ0LjcnIHk9JzEwOScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nI0ZGRkZGRic+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjg8L3RzcGFuPiAgU2hhcmU8L3RleHQ+PGxpbmUgeDE9Jzc0NC43JyB5MT0nMTIzJyB4Mj0nNzQ0LjcnIHkyPScxMzYnIHN0cm9rZT0nIzk4QTJCMycgc3Ryb2tlLXdpZHRoPScxLjUnIG1hcmtlci1lbmQ9J3VybCgjYSknLz48cmVjdCBkYXRhLXN0ZXA9JzknIGRhdGEtY3VycmVudD0nMScgeD0nNjIyLjMnIHk9JzEzOCcgd2lkdGg9JzI0NC43JyBoZWlnaHQ9JzM2JyByeD0nOCcgZmlsbD0nIzFGNkZFQicgc3Ryb2tlPScjMUY2RkVCJy8+PHRleHQgeD0nNzQ0LjcnIHk9JzE2MScgdGV4dC1hbmNob3I9J21pZGRsZScgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMycgZmlsbD0nI0ZGRkZGRic+PHRzcGFuIGZvbnQtd2VpZ2h0PSc3MDAnPjk8L3RzcGFuPiAgSGFuZCBvZmY8L3RleHQ+PHJlY3QgeD0nMScgeT0nMjUxJyB3aWR0aD0nMTQnIGhlaWdodD0nMTQnIHJ4PSczJyBmaWxsPScjMUY2RkVCJy8+PHRleHQgeD0nMjInIHk9JzI2MicgZm9udC1mYW1pbHk9J3N5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZicgZm9udC1zaXplPScxMi41JyBmaWxsPScjNDc1NDY3Jz5UaGlzIG5vdGVib29rPC90ZXh0Pjwvc3ZnPg==)

    Builds a dashboard on Dash Server, then packs the work into one folder. No AI model is needed. This notebook installs and starts Dash Server.
    """)
    return


@app.cell
def _():
    import exakit.nb as nb

    DATASET = None  # None: the dataset approved last in a quickstart (else amazon_sales); or "fraud_transactions", or an approved descriptor of your own
    TITLE = None     # None: named after the data ("<dataset> by <column>"); or a title of your own
    APP_NAME = None  # or a name of your own; the default includes the approved dataset ID and the column

    dataset_id = nb.chosen_dataset(DATASET)
    nb.continue_workflow("share")   # the quickstart's workflow, or the last one: nothing to paste

    connection = nb.connect()
    dataset = nb.dataset(connection, dataset_id)
    dataset.require_approved("share")
    GROUP_ROLE, GROUP_COLUMN = dataset.group_by()   # the category, else the entity, else the target
    if GROUP_ROLE != "category":
        print(f"{dataset.id} has no category; the dashboard counts rows per {GROUP_ROLE} ({GROUP_COLUMN}).")
    # Everything below is named after the data: the column it counts by, and what one row is.
    GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)
    dashboard_title = TITLE or f"{dataset.id} by {GROUP_HEADER.lower()}"
    app_name = APP_NAME or (dataset.id.replace("_", "-")[:30] + "-by-" + GROUP_HEADER.lower().replace("_", "-"))[:60]
    dashboard_query = f"SELECT {GROUP_COLUMN} AS {GROUP_HEADER}, COUNT(*) AS {COUNT_HEADER} FROM {dataset.fact_table} GROUP BY 1 ORDER BY {COUNT_HEADER} DESC"
    dashboard_draft = nb.share(dataset, dashboard_query, dashboard_title, app_name, measure="count")
    print("Query digest:", dashboard_draft.query_digest)
    print("Descriptor version:", dataset.version)
    return connection, dashboard_draft, dataset, nb


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 8 · Share the insight

    One checked result becomes a dashboard that others open in a browser. It goes up as a preview first. You publish it after you check the figures.
    """)
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Dash Server

    Installs Dash Server if it is missing and starts it if it is stopped. Then prints its address. This is the same as `exakit marketplace dash-server` and `exakit start dash-server`.
    """)
    return


@app.cell
def _(nb):
    dash_server_state = nb.addon_ready("dash-server")
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Preview

    Open the printed URL. Make sure that:

    - the categories and counts match your SQL;
    - the filters update both charts and the table.
    """)
    return


@app.cell
def _(dashboard_draft, nb):
    dash_server = nb.dash_tools()
    preview_path = dashboard_draft.preview(dash_server)
    print("Preview:", dash_server.url + preview_path)
    return (dash_server,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ### Publish

    Set `FIGURES_CHECKED = True` only when the preview matches the query. Then run the cell. Keep the live URL with your workflow ID.
    """)
    return


@app.cell
def _(dash_server, dashboard_draft):
    FIGURES_CHECKED = False
    if FIGURES_CHECKED:
        live_path = dashboard_draft.confirm(dash_server, figures_checked=True)
        print("Live dashboard:", dash_server.url + live_path)
    else:
        print("Open the healthy preview and check the figures before promoting.")
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(r"""
    ## Step 9 · Hand off

    Packs the work into one folder and a zip: the approved column map, the schema map if there is one, every query with its digest and row count, the dashboards, the workflow log and a README. It contains no passwords. It does not need Dash Server.
    """)
    return


@app.cell
def _(connection, dataset, nb):
    handoff = nb.handoff_bundle(connection, dataset)
    handoff
    return


if __name__ == "__main__":
    app.run()
