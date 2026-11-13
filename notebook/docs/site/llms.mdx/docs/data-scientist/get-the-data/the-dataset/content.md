# The dataset (/data-scientist/get-the-data/the-dataset)



A **dataset** is a table with its approved column map. The column map says what each column is for: its role, and the slot the steps use. The notebooks never read a table directly. They read a dataset and build every query from its roles.

```python
dataset_id = nb.chosen_dataset(DATASET)        # DATASET = None: the dataset approved last
dataset = nb.dataset(connection, dataset_id)   # refuses a column map that is not approved
dataset.fact_table                              # the table or view the steps query
dataset.has("label")                            # is there a target?
dataset.col("label")                            # its column, quoted for SQL
dataset.missing                                 # the roles no column plays, each with the reason
```

`nb.dataset(...)` refuses a column map that is not approved. You approve a column map in [Explore and understand](/data-scientist/explore).

## Pick the dataset for each notebook [#pick-the-dataset-for-each-notebook]

One assignment picks the data for each notebook: `SAMPLE = "..."` in the quickstart and `DATASET = "..."` in the other notebooks. With `DATASET = None`, each notebook follows the dataset you approved last. Approve a different one in the quickstart. The other notebooks pick it up when you run their first cell again.

To pin one notebook to one dataset, set `DATASET = "..."` in that notebook.

## Why queries come from roles [#why-queries-come-from-roles]

Because queries come from roles, the same cell runs on `amazon_sales`, on `fraud_transactions` and on your own table. A role no column fits is never guessed. `dataset.has(...)` is false, the step that needs it skips, and the step says why.

Back to [Get the data](/data-scientist/get-the-data). Next: [Troubleshooting](/data-scientist/get-the-data/troubleshooting).
