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

    **Steps:** 1 Access, 2 Understand, 3 Prepare, 4 Explore, 5 Model, 6 Validate, 7 Ask with AI, **8 Share, 9 Hand off**. **This notebook: steps 8 and 9.**

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
