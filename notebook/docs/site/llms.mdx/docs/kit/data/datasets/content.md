# Datasets (/kit/data/datasets)



The kit carries sample datasets to practise on. `exakit data-load` lists them and loads the ones you pick.

| Dataset              | Loaded by                   | Where it comes from                          |
| -------------------- | --------------------------- | -------------------------------------------- |
| `tpch`               | General                     | Bundled with the kit, loads without internet |
| `energy`             | General                     | Bundled with the kit, loads without internet |
| `weather`            | General                     | Bundled with the kit, loads without internet |
| `amazon_sales`       | Data Scientist, ML Engineer | Downloaded when you load it                  |
| `fraud_transactions` | Data Scientist, ML Engineer | Downloaded when you load it                  |

## Downloaded datasets [#downloaded-datasets]

`amazon_sales` and `fraud_transactions` are archives in the kit's datasets release. An archive is fetched only when you load that dataset. The kit checks the archive's SHA-256 and every file's digest, and refuses a mismatch.

```bash
exakit data-load amazon_sales
```

## A dataset with a column map [#a-dataset-with-a-column-map]

`amazon_sales` and `fraud_transactions` each ship with an approved [column map](/kit/data/column-maps), so the notebooks can use them straight away. You can approve your own version at any time.

The ML Engineer persona is not offered in this release, so for now only Data Scientist and General load these datasets.

## Load one again [#load-one-again]

```bash
exakit data-load --force amazon_sales
```

<Callout type="warn">
  `--force` drops that dataset's tables and rebuilds them. Anything you changed in its schema is lost.
</Callout>

## Add a dataset to the kit [#add-a-dataset-to-the-kit]

A dataset is one folder in `data/datasets/`. Nothing else names it, so a new folder appears in the menu.
