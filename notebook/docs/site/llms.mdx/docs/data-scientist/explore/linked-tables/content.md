# Linked tables (/data-scientist/explore/linked-tables)



Many datasets are several tables. Orders link to customers, and orders link to products. A **schema map** shows how the tables of one schema fit together. It lists every table with its rows and its key, and every link between tables, with the evidence for it. You check the map here, so that the semantic model and the AI clients can follow the links correctly.

## The schema map: how tables link [#the-schema-map-how-tables-link]

```python
schema_map = nb.describe_schema(connection, dataset)   # the tables and the links, as found now
schema_map
```

```bash
exakit describe --schema AMAZON
```

A link is a column whose values are all in another table's key. The kit finds two kinds:

* a foreign key the database declares, or
* a column that names another table's key, such as `O_CUSTKEY` and `C_CUSTKEY`, or `CUSTOMER_ID` and `CUSTOMERS.ID`, whose values are all in that key. At most 0.1% of its values may be missing. A name alone never makes a link.

The kit's search is in `describe_schema` in `notebook/package/exakit_nb/schema_map.py`. Each link it finds shows the evidence beside it.

## Correct the map [#correct-the-map]

Correct the map when the search misses a link or finds a wrong one:

```python
schema_map.link("ORDERS.CUSTOMER_REF", "CUSTOMERS.ID")   # a link the search missed
schema_map.unlink("ORDERS.O_CLERK")                      # a link that is wrong
schema_map.approve(connection)                           # the links become relationships in the schema's model
```

```bash
exakit describe --schema TPCH --approve --link ORDERS.O_CUSTKEY=CUSTOMER.C_CUSTKEY
exakit describe --schema TPCH --approve --unlink ORDERS.O_CLERK
```

<Flow
  caption="What happens when you approve a schema map"
  steps="[
  { title: &#x22;The kit finds the links&#x22;, text: &#x22;Every many-to-one link, with the evidence for it&#x22;, code: &#x22;nb.describe_schema(connection, dataset)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;You correct the map&#x22;, text: &#x22;Add a link the search missed, or remove a wrong one&#x22;, code: &#x22;schema_map.link(...)&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;You approve it&#x22;, text: &#x22;The next version of the schema map is saved&#x22;, code: &#x22;schema_map.approve(connection)&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;The links become relationships&#x22;, text: &#x22;In the schema's semantic model, for AI clients&#x22;, tone: &#x22;db&#x22;, href: &#x22;/kit/data/semantic-views&#x22; },
]"
/>

Approving the schema map writes its next version. It rebuilds the schema's semantic model with the links as relationships, so AI clients can follow them. The schema's own tables are never changed.

## Where the links go next [#where-the-links-go-next]

* The links become relationships in the semantic model. See [Semantic views](/data-scientist/explore/semantic-views).
* The joined view brings linked columns into one wide view of one table. It is built in the Prepare stage: see [Linked tables and the joined view](/data-scientist/prepare/linked-tables-view).

Back to [Explore and understand](/data-scientist/explore). Previous: [Semantic views](/data-scientist/explore/semantic-views). Next: [Compare groups and trends](/data-scientist/explore/compare-groups).
