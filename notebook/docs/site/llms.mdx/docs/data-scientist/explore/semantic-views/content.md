# Semantic views (/data-scientist/explore/semantic-views)



A **semantic model** is a named layer over your tables. It says which columns are groups, which are numbers to add up, and how tables link. A question can then name a metric, such as the number of order lines, and a group, such as the month, instead of repeating the formula. The kit publishes the model with **Exasol Semantic Views**, a database add-on that stores the model inside the database. Your AI clients read the same model, so the notebook and the clients give the same answer.

<Flow
  caption="From an approved column map to an answer"
  steps="[
  { title: &#x22;You approve the map&#x22;, text: &#x22;The schema's column maps are approved&#x22;, code: &#x22;role_review.approve(...)&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;The kit builds the model&#x22;, text: &#x22;Tables become entities, columns become dimensions and metrics&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;The model is published&#x22;, text: &#x22;SEM_<SCHEMA> in the database, with views and metrics&#x22;, code: &#x22;semantic.views&#x22;, tone: &#x22;db&#x22; },
  { title: &#x22;You or an AI ask&#x22;, text: &#x22;Semantic SQL names metrics and groups&#x22;, code: &#x22;nb.semantic_sql(connection, ...)&#x22;, tone: &#x22;ai&#x22; },
]"
/>

## What the model holds [#what-the-model-holds]

The model's structure follows the column maps:

* A table is an **entity**.
* A link between tables is a **relationship**, many to one, with its key mapping.
* A time, category or flag column is a **dimension**. A time column also gives a `<column>_month` dimension.
* A measure is a **fact**, with the metrics `total_<column>` and `average_<column>`.
* Every table has a row count, `<entity>_count`.
* A sensitive column is never exposed.

The approval publishes a model for the schema, named after the schema. For `AMAZON.ORDER_LINES` that model is published as `SEM_AMAZON`. The model is built from the approved column maps of the schema and its approved links.

## Publish the semantic model [#publish-the-semantic-model]

The quickstart's semantic cell builds a model that can span several tables:

```python
SEMANTIC_NAME = "my_data"
SEMANTIC_TABLES = [dataset.fact_table]        # add tables of other schemas: "VS_LOGISTICS.COURIER_DAILY", "MY_DATA.TARGETS"
SEMANTIC_LINKS = []                           # e.g. "MY_DATA.ORDERS.STATE=VS_LOGISTICS.STATE_LOGISTICS.STATE"
PUBLISH_SEMANTIC = False
semantic = nb.semantic_model(connection, SEMANTIC_NAME, tables=SEMANTIC_TABLES, links=SEMANTIC_LINKS, ai=None,
                             preview=not PUBLISH_SEMANTIC)
semantic
```

With `PUBLISH_SEMANTIC = False` the cell shows what it would build and writes nothing. Set it to `True` and run the cell again to publish. The published schema is named after the model in upper case: `SEM_MY_DATA`. `semantic.views` lists the views it holds.

A model can span any number of schemas: sample datasets, your own files and folders, and connected external sources, which are read live. Every table in it needs an approved column map first.

## Ask the model in Semantic SQL [#ask-the-model-in-semantic-sql]

Semantic SQL is a query over a semantic view. You name metrics and group them by dimensions. Get the exact names from the model first, then write the query:

```python
semantic.fields                       # one row per dimension and metric: view, kind, name, what it is
nb.semantic_sql(connection, """
SELECT <DIMENSION>, <METRIC>
FROM SEM_MY_DATA.<VIEW>
GROUP BY <DIMENSION>
""")
```

Replace the placeholders with names from `semantic.fields`. The metric names follow the pattern `total_<column>` and `average_<column>`, and every table gets a row-count metric. `nb.semantic_sql` switches Semantic SQL on for the session before it runs your query, and it runs the query read-only.

## Measured on a real database [#measured-on-a-real-database]

These results come from a local Exasol Personal database, measured on 12 November 2026. The queries are read-only.

* `exakit marketplace semantic-views` installed Exasol Semantic Views v0.6.1 into the database.
* A model was built over the approved prepared view `EXAKIT_PREPARED.AMAZON__ORDER_LINES` and over `EXAKIT_PREPARED.RETAIL_SIGNALS__CUSTOMER_REVIEWS__PLAIN`, and published. It has 2 views, 20 dimensions and 6 metrics: `amazon_order_lines_count`, `total_qty`, `average_qty`, `total_amount`, `average_amount`, and the reviews' row count.
* The prepared view `EXAKIT_PREPARED.AMAZON__ORDER_LINES` holds 128,969 rows. The raw table `AMAZON.ORDER_LINES` holds 128,975. The view drops 6 order lines that are the same as another line in every column but their row id: see [Cleaned views](/data-scientist/prepare/cleaned-views).

**Counting by month.** The model counts what its view holds:

```sql
SELECT order_date_month, amazon_order_lines_count
FROM SEM_KIT_TEST.AMAZON_ORDER_LINES
GROUP BY order_date_month
```

| `order_date_month` | `amazon_order_lines_count` |
| ------------------ | -------------------------- |
| 2022-03-01         | 171                        |
| 2022-04-01         | 49,065                     |
| 2022-05-01         | 42,037                     |
| 2022-06-01         | 37,696                     |

The four months add up to 128,969, the same as `SELECT COUNT(*)` on the view.

**Counting by category.** Grouping by `category` gives the top rows:

| `category`    | `amazon_order_lines_count` | `total_amount` |
| ------------- | -------------------------- | -------------- |
| Set           | 50,281                     | 39,202,022.03  |
| kurta         | 49,874                     | 21,299,013.70  |
| Western Dress | 15,500                     | 11,216,072.69  |

**A metric the AI proposed.** An AI-style proposal added `cancelled_amount`, the sum of `amount` where `status` is `Cancelled`. Its value is 6,919,284.30. That equals `SELECT SUM(AMOUNT) ... WHERE STATUS = 'Cancelled'` on the table. The proposal also added `cancelled_share`, which is `cancelled_amount / total_amount`. It is 0.088, or 8.8%.

**A metric that does not exist.** A proposed metric that names a fact the model does not have was refused, and the refusal gave the reason.

**Reading from an AI client.** The read-only MCP user, the one AI clients use, read the model's metrics from `SEMANTIC_CATALOG.METRICS`.

**Rebuilding on approval.** Approving a column map rebuilt its schema's model. It also refreshed every multi-source model that the table is in.

Measured values are for this database and these tables. Your numbers differ if your data differs.

## One model across sources [#one-model-across-sources]

In the guided view, open **Understand** and scroll to **Semantic views**. Then:

1. Tick the tables. They are listed with their origin: sample data, your data or an external source. Tick as many as the question needs.
2. Give the model a name, for example `sales_360`.
3. Add the links across schemas, one per line, in the form `SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY`. The approved links inside each schema are used on their own.
4. Tick **Let the AI propose business names, synonyms and metrics**, if you have an AI model set up.
5. Click **Preview**. Read the dimensions and metrics of each view, what the AI proposed, and what was refused and why. Nothing is written yet.
6. Click **Publish the model**.

**Models in the database** lists every model. **Refresh it** rebuilds a model the kit built, from the column maps and links approved since.

## The AI proposes the fields [#the-ai-proposes-the-fields]

With `ai=None`, the notebook asks the AI only when a model is set up. The AI proposes business names, comments, synonyms and the metrics people will ask for. It works from names, types, grains, column notes and a category's most frequent values. It never receives a row, and never a sensitive column.

Every metric the AI proposes is checked before the kit offers it. Semantic Views checks it again when the model is built. A refused metric is skipped, and the preview names it. Without a model, the fields keep the names the column maps give.

To set up the AI model, see [Set up Exasol](/data-scientist/set-up/ai-and-langfuse).

## Keep the model current [#keep-the-model-current]

Approving a column map rebuilds every model its table is in. After you add a link or a table, refresh the model yourself:

```python
nb.refresh_semantic(connection, "sales_360")
```

```bash
exakit describe --model sales_360 --refresh
```

Your AI clients read the same model through the Exasol MCP server. The notebook and the clients answer from one meaning.

Back to [Explore and understand](/data-scientist/explore). Previous: [Approve the column map](/data-scientist/explore/approve-the-column-map). Next: [Linked tables](/data-scientist/explore/linked-tables).
