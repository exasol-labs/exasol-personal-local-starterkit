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

In the guided view, open **Understand** and scroll to **Semantic views**. The card builds the model by hand, in three parts.

| Part             | What you do                                                                                                                                                                                                                                                                                                                             |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The tables       | Every schema is listed with its tables under it, and where it comes from: sample data, your data or an external source. Tick the tables the model is about. The tables you chose in **Choose your data** start ticked. A schema's own box ticks or clears all its tables. Under each ticked table, say in a sentence what the table is. |
| How they connect | **Find links between the ticked tables** compares their values and lists each link with what the data says. Tick the ones to use, and say in a sentence why the two belong together. Add a link of your own from four lists: this table, by this column, points at that table, which holds the values in that column.                   |
| The model        | Give it a name, for example `sales_360`, and say what it is about. **Preview** shows the dimensions and metrics of each view and writes nothing. **Publish the model** builds it.                                                                                                                                                       |

A table needs an approved column map to be ticked. One without is shown greyed, with where to approve it.

The model takes the tables you ticked, not every table of their schemas. Two tables of the same schema are compared for links too.

Tick **Let the AI help** to have your model propose links from what the columns mean, and business names, synonyms and metrics for the model. It is shown names, types and notes, never a row.

### A link of your own is checked first [#a-link-of-your-own-is-checked-first]

**Check it against the data and add it** runs the same check a found link gets (`nb.find_links(connection, tables=[...], check=[...])`). When the data backs the pair, it is added to the list with its evidence, marked *Yours, checked*. When it does not, it is not added and the card says what the data showed: too few values match, the two columns are of different kinds, or the column on the right does not hold each value once.

### The same in a cell [#the-same-in-a-cell]

```python
tables = ["AMAZON.ORDER_LINES", "AMAZON.RETURNS", "VS_LOGISTICS.STATE_LOGISTICS"]
found_links = nb.find_links(connection, tables=tables)
model_links = [link for link in found_links["links"] if link["confidence"] == "high"]
model_links.append({"from": "AMAZON.RETURNS.ORDER_ID", "to": "AMAZON.ORDER_LINES.ORDER_ID", "note": "A return belongs to one order."})
semantic = nb.semantic_model(connection, "sales_360", tables=tables, links=model_links,
                             table_notes={"VS_LOGISTICS.STATE_LOGISTICS": "Average delivery days per state."}, preview=True)
```

**Models in the database** lists every model. **Refresh it** rebuilds a model the kit built, from the column maps and links approved since.

## Links across sources [#links-across-sources]

Tables of different sources rarely declare how they join, and the same thing is often named differently: a customer number in one, a client id in another. The kit finds such a link from the values the columns hold. It does not match column names, and it needs no foreign key.

<Flow
  caption="How a link between two sources is found"
  steps="[
  { title: &#x22;Pick the schemas&#x22;, text: &#x22;Sample data, your files, external sources&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;Find the keys&#x22;, text: &#x22;Columns whose every value is present and different&#x22;, code: &#x22;one aggregate per table&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;Compare values&#x22;, text: &#x22;Up to 500 values of a column, asked of each key&#x22;, code: &#x22;COUNT ... WHERE key IN (...)&#x22;, tone: &#x22;db&#x22; },
  { title: &#x22;Count the rows&#x22;, text: &#x22;A text link may miss at most 0.1% of its rows&#x22;, tone: &#x22;db&#x22; },
  { title: &#x22;You confirm&#x22;, text: &#x22;Tick or untick each link, then publish&#x22;, tone: &#x22;you&#x22; },
]"
/>

In the **Semantic views** card, tick the tables and click **Find links between the ticked tables**. In a cell, name the tables, or whole schemas:

```python
found_links = nb.find_links(connection, tables=["AMAZON.ORDER_LINES", "AMAZON.RETURNS", "VS_LOGISTICS.STATE_LOGISTICS"])
found_links = nb.find_links(connection, ["AMAZON", "RETAIL_SIGNALS", "VS_LOGISTICS"])     # every table of these schemas
```

With `tables=`, two tables of one schema are compared too. With schemas, only tables of different schemas are.

```bash
exakit describe --links AMAZON,RETAIL_SIGNALS,VS_LOGISTICS
```

Each link comes back with its evidence. Measured on a real database, between the Amazon sample data and a PostgreSQL source read live:

```text
[high] AMAZON.ORDER_LINES.SHIP_STATE -> VS_LOGISTICS.STATE_LOGISTICS.SHIP_STATE:
       128,921 of 128,942 rows have a value in the key; 21 do not
       (not matching: LAKSHADWEEP, ORISSA, RAJSHTHAN, NL, RAJSTHAN)
```

Only 36 of the 47 different state names match (77%), because 11 are misspelt or abbreviated. Those 11 are 21 rows out of 128,942. The kit counts rows, so the link stands and the misspellings are listed for you to clean.

### What a link's confidence means [#what-a-links-confidence-means]

| Confidence | When                                                                    | What to do                                                   |
| ---------- | ----------------------------------------------------------------------- | ------------------------------------------------------------ |
| high       | A text column (a code, a name) whose rows are in another table's key    | It is ticked for you. Untick it if the meaning is wrong      |
| low        | A link between two plain number columns                                 | Tick it only if you know the two columns mean the same thing |
| partial    | Text values that only partly match, with more than 0.1% of rows missing | Not a link. Look at the spellings first                      |

Numbers get the low mark for a measured reason. A key that is simply 1, 2, 3 and so on holds every small number. On a database with six schemas, the first version of this search proposed 18 links into one such key: a meter id, a quantity and a count of delayed shipments all "matched" an order line id. So a number column is only considered when it spans at least half the key's range and something else supports it: a similar name, an approved column map that calls it a key or an identifier, or a pair proposed by you or an AI. Even then the data can only contradict such a link, never prove it. Two were still proposed between unrelated order numbers, which is why the last word is yours.

### Let an AI, or an AI client, propose links [#let-an-ai-or-an-ai-client-propose-links]

An AI reads what the columns mean; the search above does not. With **Let the AI help** ticked (or `--ai`), your model proposes pairs from column names, types and notes. It is never sent a value. Each pair is then checked against the data like any other.

An AI client such as Claude Code or Codex does the same with its own reading. It checks a pair with:

```bash
exakit describe --links AMAZON,CRM --link AMAZON.ORDER_LINES.CUST_NO=CRM.CUSTOMERS.CUSTOMER_ID
```

A pair the data contradicts comes back as `[rejected]`.

### What is stored [#what-is-stored]

A link you publish becomes a relationship of the model. Its evidence is stored with it: who proposed it, how many rows matched, which values did not, and the sentence you wrote about it. What you said each table is becomes that table's description in the model. An AI client or a colleague who reads the model sees how the tables connect and why. Read the links back with:

```sql
SELECT SCOPE_NAME, DATA_JSON FROM SEMANTIC_CATALOG.CUSTOM_EXTENSIONS
WHERE MODEL_NAME = 'sales_360' AND VENDOR_NAME = 'exakit'
```

The model also lists each table it is built on and whether it is a table in this database or an external source read live.

### What it costs on large data [#what-it-costs-on-large-data]

Every statement of the search is bounded: one aggregate per table, one `SELECT DISTINCT ... LIMIT 500` per column, one count with a list of values per pair, and at most 400 pairs. Measured: six schemas with 25 tables took 223 statements and about 60 seconds, most of it the live source. Three schemas took 26 statements and 23 seconds.

Queries on the published model were measured on 10,002,745 rows joined to a 30,000-row table:

| Query                                          | Semantic SQL | Hand-written SQL |
| ---------------------------------------------- | ------------ | ---------------- |
| Group by a category                            | 0.20 s       | 0.13 s           |
| Join, group by priority and month (415 groups) | 0.27 s       | 0.21 s           |
| Join with a filter                             | 0.12 s       | not measured     |

The totals were identical in all 415 groups, and the row counts added up to the table. The SQL the model compiles is one scan of the main table, one `LEFT JOIN` per table a dimension needs (none when the dimensions are the main table's own), and one `GROUP BY`. See it for any query with `EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL('<your Semantic SQL>')`.

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
