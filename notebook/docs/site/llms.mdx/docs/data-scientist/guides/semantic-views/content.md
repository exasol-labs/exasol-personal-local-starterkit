# Build semantic views (/data-scientist/guides/semantic-views)



Approving a column map already published it in **Exasol Semantic Views**: the schema's model, with the table as an entity, its time, category and flag columns as dimensions and its measures as `total_` and `average_` metrics. This step builds one model across sources, so a question that needs orders **and** deliveries **and** targets is answered from one place.

## Before you start [#before-you-start]

* Every table you want in the model has an approved column map ([Approve the column map](/data-scientist/guides/approve-column-map)).
* An AI model is set up if you want it to propose the fields ([Set up a model](/data-scientist/guides/set-up-a-model)). Without one, the fields keep the names the column maps give.

## In the guided view [#in-the-guided-view]

1. Open **Understand** and scroll to **Semantic views**.
2. Tick the tables. They are listed with their origin: sample data, your data, external source. Pick as many as the question needs.
3. Give the model a name, for example `sales_360`.
4. Add the links across schemas, one per line: `SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY`. The approved links inside each schema are used by themselves.
5. Tick **Let the AI propose business names, synonyms and metrics**.
6. Click **Preview**. Read the dimensions and metrics of each view, what the AI proposed, and what was refused and why. Nothing is written yet.
7. Click **Publish the model**.

**Models in the database** lists every model. **Refresh it** rebuilds a model the kit built from the column maps and links approved since.

## In the notebook [#in-the-notebook]

The cell after the data map:

```python
SEMANTIC_NAME = "sales_360"
SEMANTIC_TABLES = ["AMAZON.ORDER_LINES", "MY_DATA.TARGETS", "VS_LOGISTICS.COURIER_DAILY"]
SEMANTIC_LINKS = ["AMAZON.ORDER_LINES.SHIP_STATE=VS_LOGISTICS.STATE_LOGISTICS.STATE"]
PUBLISH_SEMANTIC = False                 # True to publish
semantic = nb.semantic_model(connection, SEMANTIC_NAME, tables=SEMANTIC_TABLES, links=SEMANTIC_LINKS, ai=None,
                             preview=not PUBLISH_SEMANTIC)
semantic
```

`ai=None` asks the AI only when a model is set up. Run the cell, read the preview, then set `PUBLISH_SEMANTIC = True` and run it again. Semantic Views is installed the first time it is needed.

## What the AI is sent [#what-the-ai-is-sent]

Names, types, grains, column notes and a category's most frequent values. Never a row, never a sensitive column. Every metric it proposes is checked before it is used, and Semantic Views validates it again: a refused one is skipped and named.

## Ask the model [#ask-the-model]

```python
nb.semantic_sql(connection, """
SELECT ship_state, total_amount, orders_count
FROM SEM_SALES_360.ORDER_LINES
GROUP BY ship_state
""")
```

Your AI clients ask the same model through the Exasol MCP server.

## Keep it current [#keep-it-current]

Approving a column map rebuilds every model its table is in. After a new link or table:

```python
nb.refresh_semantic(connection, "sales_360")
```

## What you get at the end [#what-you-get-at-the-end]

A published semantic model, `SEM_<NAME>`, that notebooks and AI clients answer from by its business names. Its definition is kept in `~/.exasol-starter-kit/semantic/<name>.json`, so a refresh rebuilds it the same way.

For the commands behind it, see [Semantic views](/kit/data/semantic-views).
