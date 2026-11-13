# Preview, check, publish (/data-scientist/communicate/preview-check-publish)



## Preview, check, publish [#preview-check-publish]

The code enforces the order. You cannot skip a step.

<Flow
  caption="The order is enforced: a preview that was not checked is never published"
  steps="[
  { title: &#x22;Preview&#x22;, text: &#x22;The kit checks the workflow, the read-only identity and Dash Server's profile, then creates the preview&#x22;, code: &#x22;print(\&#x22;Preview:\&#x22;, dash_server.url + preview_path)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;Check&#x22;, text: &#x22;Open the preview and compare the figures with the SQL&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;Publish&#x22;, text: &#x22;confirm refuses unless figures_checked is True and the preview is healthy&#x22;, code: &#x22;dashboard_draft.confirm(dash_server, figures_checked=True)&#x22;, tone: &#x22;kit&#x22; },
]"
/>

## Before you preview: Dash Server [#before-you-preview-dash-server]

The notebook calls `nb.dash_tools()`, which starts Dash Server if it is stopped. Dash Server is a kit add-on. The add-on is installed with `exakit marketplace dash-server`. The [add-ons page](/kit/tools/add-ons) explains how add-ons work.

```python
dash_server = nb.dash_tools()                     # starts Dash Server if it is stopped
preview_path = dashboard_draft.preview(dash_server)
print("Preview:", dash_server.url + preview_path)
```

### Preview [#preview]

`preview` checks four things before it creates anything:

* that the workflow is the one the dashboard was made in
* that the read-only identity is validated
* that Dash Server's profile is the kit's read-only user on the kit's database
* that the dashboard's name is not already taken by a dashboard that belongs to another dataset, or that has no readable lineage

Then it creates the preview, confirms that the built copy holds the approved SQL and lineage files unchanged, and runs a health check. A preview that fails the health check is marked unhealthy, and the kit will not publish it.

### Check [#check]

Open the preview and compare the figures with the SQL. Use the page described on [What a reader sees](/data-scientist/communicate/what-a-reader-sees). The chart's grouped Other figure is one to check against the query. Only a person can make this check. The notebook never does it for you.

### Publish [#publish]

`FIGURES_CHECKED` is `False` in `03_share`. Set it to `True` after the check, and run the cell. In code:

```python
live_path = dashboard_draft.confirm(dash_server, figures_checked=True)
```

`confirm` refuses unless `figures_checked=True` and the preview is healthy. It promotes that exact revision, starts the app if it is not mounted, and checks the live address. If the live check fails, the error says to roll back in Dash Server.

In automated runs the check is never set, so nothing is published without a person.

## The workflow log [#the-workflow-log]

Each preview and each publish adds a line to the workflow log, with the query's digest, the descriptor version and the revision number. The kinds are listed on [The workflow log](/data-scientist/monitor/the-workflow-log).

Back to [Communicate and deploy](/data-scientist/communicate). Next: [What a reader sees](/data-scientist/communicate/what-a-reader-sees).
