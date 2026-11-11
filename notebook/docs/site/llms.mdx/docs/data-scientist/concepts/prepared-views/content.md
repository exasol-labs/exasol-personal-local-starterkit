# Prepared views (/data-scientist/concepts/prepared-views)



Step 3, Prepare, looks at the data before anything is computed from it. It never changes your table. What it creates, when you ask, are views in the `EXAKIT_PREPARED` schema.

## Is the data clean? [#is-the-data-clean]

```python
findings = nb.data_checks(connection, dataset)
```

It looks for repeated keys, exact copies, gaps, placeholder values and a rare target. Each finding is one plain sentence that says what it does to a result. Deciding what to do about it is yours.

## Linked tables [#linked-tables]

```python
schema_map = nb.describe_schema(connection, dataset)
```

The schema map shows the tables that link to this one, with the evidence for each link. A link adds the other table's columns without adding rows.

To correct it: `schema_map.unlink("TABLE.COLUMN")` or `schema_map.link("TABLE.COLUMN", "TABLE.KEY")`.

The **joined view** combines the table with every linked table. It is a proposal until you create it:

```python
proposal = schema_map.joined_view(dataset)
joined = proposal.create(connection)       # only when you want it
```

## A typed, cleaned view [#a-typed-cleaned-view]

```python
proposal = nb.typed_view(connection, dataset)
prepared = proposal.create(connection)     # only when you want it
```

It proposes correct types for numbers and dates stored as text, turns blanks and placeholders into NULL, and removes exact copies. Read what changes before you create it.

In `01_explore`, `USE_JOINED = True` and `USE_PREPARED = True` in the first cell create these views and make the later steps read them.

## Columns that give the answer away [#columns-that-give-the-answer-away]

```python
leaking = nb.leakage_check(connection, dataset)
```

A column whose values almost decide the target on their own would make a model look better than it is. These columns are listed and left out of the model.

## Reference [#reference]

[Data checks](/data-scientist/reference/data-checks), [Schema map and joined view](/data-scientist/reference/schema-map), [Typed view](/data-scientist/reference/prepare).
