# Linked tables and the joined view (/data-scientist/prepare/linked-tables-view)



A **joined view** is a view that combines your table with the tables it links to. Each row of your table keeps one row, and the linked columns are added beside it. You need one when the questions you ask use columns that live in another table. The links come from the schema map, which you check in [Linked tables](/data-scientist/explore/linked-tables) in the Explore stage.

## Linked tables [#linked-tables]

```python
schema_map = nb.describe_schema(connection, dataset)   # the tables and links of the schema, as found now
schema_map                                             # every table, its rows and key, and every link with its evidence
```

A link adds the other table's columns without adding rows. A link is many to one: each row of your table matches at most one row of the other table. The joined view follows links up to three tables away from your table. A table reached along two paths is joined once for each path. The joined table's key is left out, because your table's key identifies the row.

To correct the map before you create a view:

```python
schema_map.link("ORDERS.CUSTOMER_REF", "CUSTOMERS.ID")   # a link the search missed
schema_map.unlink("ORDERS.O_CLERK")                      # a link that is wrong
```

## Create the joined view [#create-the-joined-view]

Create the joined view when you want it:

```python
proposal = schema_map.joined_view(dataset)   # the proposal: each join, and the SQL. Nothing is created.
proposal                                     # read it first
joined = proposal.create(connection)         # only when you want it
```

<Flow
  caption="From linked tables to a joined view"
  steps="[
  { title: &#x22;The kit finds the links&#x22;, text: &#x22;Every many-to-one link, with its evidence&#x22;, code: &#x22;nb.describe_schema(connection, dataset)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;You correct the map&#x22;, text: &#x22;Add a missed link, or remove a wrong one&#x22;, code: &#x22;schema_map.link(...)&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;You read the proposal&#x22;, text: &#x22;Each join, and the SQL. Nothing is created yet.&#x22;, code: &#x22;schema_map.joined_view(dataset)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;The view is created&#x22;, text: &#x22;EXAKIT_PREPARED with the joined columns, and approved&#x22;, code: &#x22;joined = proposal.create(connection)&#x22;, tone: &#x22;db&#x22; },
]"
/>

`create` approves the schema map if it is still a draft. It creates the view `EXAKIT_PREPARED."<SCHEMA>__<TABLE>__JOINED"`. It describes the view and approves its column map, with your table's roles carried over. The steps after it then read the joined data. The view is described in [Prepared views](/data-scientist/prepare/prepared-views).

## How we used it: amazon_sales [#how-we-used-it-amazon_sales]

The dataset loads one table into the `AMAZON` schema. The schema map finds no link to another table, so there is no joined view to build:

```python
schema_map = nb.describe_schema(connection, dataset)
joined_view_proposal = schema_map.joined_view(dataset)
joined_view_proposal          # AMAZON.ORDER_LINES links to no other table: there is nothing to join.
```

The schema map says `No links: every table stands on its own.` That is the right result for one table. The proposal creates nothing.

## When there is nothing to join [#when-there-is-nothing-to-join]

If your table links to no other table in its schema, the proposal says so and creates nothing. The schema map shows which links the search found. To add a link the search missed, use `schema_map.link(...)`. A link needs every value of the column in the other table's key, with at most 0.1% missing. A name alone never makes a link.

Back to [Prepare](/data-scientist/prepare). Previous: [Columns that give the answer away](/data-scientist/prepare/leakage). Next: [A typed, cleaned view](/data-scientist/prepare/cleaned-views).
