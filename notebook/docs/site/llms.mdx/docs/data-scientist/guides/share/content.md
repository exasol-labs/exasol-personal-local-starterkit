# Share a dashboard and hand off (/data-scientist/guides/share)



<Steps>
  <Step>
    ### Prepare the dashboard [#prepare-the-dashboard]

    ```python
    dataset = nb.dataset(connection, nb.chosen_dataset(None))
    dashboard_draft = nb.share(dataset, dashboard_query, "Orders by category", "orders-by-category", measure="count")
    ```

    The dashboard is built from approved roles and a query you can read.
  </Step>

  <Step>
    ### Start Dash Server [#start-dash-server]

    ```python
    nb.addon_ready("dash-server")
    ```

    It installs Dash Server when it is missing and starts it when it is stopped. This is what `exakit marketplace dash-server` and `exakit start dash-server` do.
  </Step>

  <Step>
    ### Preview [#preview]

    ```python
    dash_server = nb.dash_tools()
    preview_path = dashboard_draft.preview(dash_server)
    print("Preview:", dash_server.url + preview_path)
    ```

    Open it. Check that the categories and counts match your SQL, and that the filters update both charts and the table.
  </Step>

  <Step>
    ### Publish [#publish]

    ```python
    live_path = dashboard_draft.confirm(dash_server, figures_checked=True)
    ```

    Set `figures_checked=True` only when the preview matches the query. Keep the live address with your workflow id.
  </Step>

  <Step>
    ### Hand off [#hand-off]

    ```python
    handoff = nb.handoff_bundle(connection, dataset)
    ```

    One folder and a zip under `~/.exasol-starter-kit/bundles/`. It needs no Dash Server and holds no password. See [Sharing and hand-off](/data-scientist/concepts/sharing-and-handoff).
  </Step>
</Steps>
