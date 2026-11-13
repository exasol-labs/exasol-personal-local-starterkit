# The hand-off bundle (/data-scientist/communicate/hand-off-bundle)



## The hand-off bundle [#the-hand-off-bundle]

`nb.handoff_bundle(connection, dataset)` writes one folder to `~/.exasol-starter-kit/bundles/<workflow id>/`, with a zip beside it. It needs no Dash Server and holds no password. The folder is named after the workflow. A bundle made with no workflow is named after the dataset.

<Flow
  caption="From the approved roles to a folder a colleague can repeat"
  steps="[
  { title: &#x22;The approved column map&#x22;, text: &#x22;descriptor.yaml and the schema map, as approved&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/kit/data/column-maps&#x22; },
  { title: &#x22;Every query the workflow ran&#x22;, text: &#x22;queries.sql, each query with its SHA-256 and row count&#x22;, code: &#x22;handoff = nb.handoff_bundle(connection, dataset)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;The log and the README&#x22;, text: &#x22;workflow.jsonl and README.md, which say what was approved and published&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;One folder and a zip&#x22;, text: &#x22;Nothing in it is a password&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;A colleague repeats the work&#x22;, text: &#x22;From the README, with the same column map and queries&#x22;, tone: &#x22;you&#x22; },
]"
/>

## What is in the bundle [#what-is-in-the-bundle]

| File              | What it is                                                                                                                                                                                            |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `README.md`       | What the data is, which column map version the numbers rest on, which questions were approved, which dashboards were previewed or published, which model traces were made, and how to repeat the work |
| `descriptor.yaml` | The approved column map, copied from the kit's store                                                                                                                                                  |
| `schema-map.json` | The approved schema map, when the schema has one                                                                                                                                                      |
| `queries.sql`     | Every distinct query the workflow ran, each with its SHA-256 and row count                                                                                                                            |
| `workflow.jsonl`  | The workflow log, as it is                                                                                                                                                                            |

For `amazon_sales`, the folder holds the approved column map, the queries the workflow ran, the workflow log and the README.

## Writing it [#writing-it]

```python
handoff = nb.handoff_bundle(connection, dataset)
```

Running it again for the same workflow replaces the folder and the zip. It is a snapshot. Nothing in it checks itself against the data later. The page on [A training hand-off that went stale](/data-scientist/monitor/stale-hand-off) describes the one check the kit makes, and the bundle has no such check.

## Repeating the work [#repeating-the-work]

A colleague follows the README:

1. Load the same table. For a kit dataset, run `exakit data-load <id>`.
2. Open the approved column map with `nb.dataset(connection, "<id>")`, or `exakit describe <id> --show`.
3. Run the statements in `queries.sql` in order.

Back to [Communicate and deploy](/data-scientist/communicate). Next: [The training hand-off](/data-scientist/communicate/training-hand-off).
