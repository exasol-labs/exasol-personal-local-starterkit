# Communicate and deploy (/data-scientist/communicate)



Communicating a result means two things: showing the figures to people who will not open the notebook, and leaving enough behind that someone else can repeat the work. The kit does both. A dashboard goes up on Dash Server, a kit add-on that the notebook installs and starts for you. It goes up as a preview first, and only a person can publish it. The hand-off bundle is one folder and a zip, and it needs no server. The kit does not deploy a model from these notebooks. The page on deploying a model explains what exists and where it lives.

## The flow [#the-flow]

<Flow
  caption="A dashboard: preview first, publish only after you check it"
  steps="[
  { title: &#x22;One checked result&#x22;, text: &#x22;A query you have read, built from the approved roles&#x22;, code: &#x22;dashboard_draft = nb.share(dataset, dashboard_query, title, name, measure=\&#x22;count\&#x22;)&#x22;, tone: &#x22;you&#x22;, href: &#x22;/data-scientist/communicate/dashboard-query&#x22; },
  { title: &#x22;Preview on Dash Server&#x22;, text: &#x22;Built from the approved roles, with the query and its lineage&#x22;, code: &#x22;dashboard_draft.preview(dash_server)&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/communicate/preview-check-publish&#x22; },
  { title: &#x22;Exasol runs the query&#x22;, text: &#x22;As the kit's read-only user, through Dash Server's profile&#x22;, tone: &#x22;db&#x22; },
  { title: &#x22;You check the figures&#x22;, text: &#x22;Categories and counts match the SQL. Filters update the charts and the table.&#x22;, tone: &#x22;you&#x22;, href: &#x22;/data-scientist/communicate/what-a-reader-sees&#x22; },
  { title: &#x22;Publish&#x22;, text: &#x22;Only after you confirm, the exact healthy preview is promoted&#x22;, code: &#x22;dashboard_draft.confirm(dash_server, figures_checked=True)&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/communicate/preview-check-publish&#x22; },
]"
/>

<Flow
  caption="The hand-off folder: what is in it and how a colleague uses it"
  steps="[
  { title: &#x22;The approved column map&#x22;, text: &#x22;descriptor.yaml, the roles and their versions&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/kit/data/column-maps&#x22; },
  { title: &#x22;Every query the work ran&#x22;, text: &#x22;queries.sql, each with its digest and row count&#x22;, code: &#x22;handoff = nb.handoff_bundle(connection, dataset)&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/communicate/hand-off-bundle&#x22; },
  { title: &#x22;The log and a README&#x22;, text: &#x22;workflow.jsonl and README.md, which say what was approved and published&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;One folder and a zip&#x22;, text: &#x22;Under the kit's home. Nothing in it is a password.&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;A colleague repeats the work&#x22;, text: &#x22;From the README, with the same column map and queries&#x22;, tone: &#x22;you&#x22; },
]"
/>

## Where you do it [#where-you-do-it]

| Guided view                                                                              | Notebook code                                                                                                                                 | Terminal                                                                                                                                                                                                                            |
| ---------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `03_share`: the **Share** card has the steps Dash Server, Preview, Publish and Hand off. | `03_share`: `nb.share`, `dashboard_draft.preview`, `dashboard_draft.confirm`, `nb.handoff_bundle`. `nb.dash_tools()` connects to Dash Server. | `exakit marketplace dash-server` installs the add-on. `exakit start dash-server` starts it. `exakit status --json` gives its address. `exakit workflow show <id>` lists the workflow's steps. The bundle has no command of its own. |

The publish step is off by default in `03_share`. `FIGURES_CHECKED = False` stops the publish. The cell tells you to "open the healthy preview and check the figures before promoting." Set it to `True` only after you have checked the preview.

## How we used it [#how-we-used-it]

The worked example is `amazon_sales`, a result that counts order lines by category. The notebook builds the query from the approved roles, previews it, and writes the hand-off folder. The steps are on [Build the dashboard query](/data-scientist/communicate/dashboard-query).

For `amazon_sales` the query is `SELECT CATEGORY AS CATEGORY, COUNT(*) AS ORDER_LINES FROM AMAZON.ORDER_LINES GROUP BY 1 ORDER BY ORDER_LINES DESC`. The descriptor records nine distinct values for `CATEGORY`. The chart groups the smallest categories as Other when more than eight rows are shown, so check that grouped figure against the SQL as well.

## In this stage [#in-this-stage]

<Cards>
  <Card title="Build the dashboard query" href="/data-scientist/communicate/dashboard-query" description="The query the notebook builds from the roles, and its title and name" />

  <Card title="Preview, check, publish" href="/data-scientist/communicate/preview-check-publish" description="The order the code enforces, and what each step checks" />

  <Card title="What a reader sees" href="/data-scientist/communicate/what-a-reader-sees" description="The filters, charts and table on the dashboard page" />

  <Card title="The hand-off bundle" href="/data-scientist/communicate/hand-off-bundle" description="The folder and zip a colleague uses to repeat the work" />

  <Card title="The training hand-off" href="/data-scientist/communicate/training-hand-off" description="The file the ML Engineer's training reads, and its split rule" />

  <Card title="Deploying a model" href="/data-scientist/communicate/deploying-a-model" description="What the kit does and does not deploy" />

  <Card title="When it goes wrong" href="/data-scientist/communicate/troubleshooting" description="Dash Server, workflow and publish problems, and their fixes" />
</Cards>

## What you have at the end [#what-you-have-at-the-end]

A dashboard, first as a preview and then, after you check it, as a live address that you keep with the workflow id. You also have one hand-off folder and its zip. The next step is to notice when the data, the column map or the model changes: [Monitor and iterate](/data-scientist/monitor).

<StageNav n="7" />
