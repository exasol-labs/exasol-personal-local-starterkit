# Load data (/kit/data/load-data)



```bash
exakit data-load
```

On a terminal this opens a menu: the kit's datasets, your own data, or an external source. Name what you want to skip the menu.

<Tabs items="['A kit dataset', 'One file', 'A folder']">
  <Tab value="A kit dataset">
    ```bash
    exakit data-load amazon_sales
    ```

    See [Datasets](/kit/data/datasets) for the list.
  </Tab>

  <Tab value="One file">
    ```bash
    exakit data-load ./sales.csv
    ```

    It asks two things, whatever the file's kind: the file, then `SCHEMA.TABLE`. To answer up front:

    ```bash
    EXAKIT_DATA_FILE=./sales.json EXAKIT_DATA_TABLE=STARTER_KIT.SALES exakit data-load
    ```

    CSV, Parquet and JSON are loaded. JSON is split into tables by an engine the kit installs for you on macOS, Linux and WSL.
  </Tab>

  <Tab value="A folder">
    ```bash
    exakit data-load ~/exports
    ```

    Every CSV, Parquet and JSON file at the folder's top level becomes one table named after the file. The schema is asked once:

    ```bash
    EXAKIT_DATA_FILE=~/exports EXAKIT_SCHEMA=SALES exakit data-load
    ```

    Subfolders are not scanned. Files of other kinds are ignored. Duplicates are skipped with the reason.
  </Tab>
</Tabs>

## Running it again is safe [#running-it-again-is-safe]

* A file already loaded is skipped, not loaded on top of itself.
* A file that a stopped run left half-written is loaded again from scratch.
* A table holding rows this kit did not load is left alone, unless you say otherwise.

```bash
EXAKIT_ON_EXISTING=replace exakit data-load ~/exports
```

`EXAKIT_ON_EXISTING` takes `replace` or `append`. On a terminal you are asked.

## What you get at the end [#what-you-get-at-the-end]

Every file is listed with its table and the rows that landed, or the reason it did not load. A file the loader refuses leaves no empty table behind.

## From a notebook [#from-a-notebook]

```python
nb.exakit("data-load", "fraud_transactions")
own_data = nb.load_own_file("~/sales-data/orders.csv", "SALES", conn=connection)
```

See [Load data in the Data Scientist notebooks](/data-scientist/guides/load-data).

## An external source [#an-external-source]

Data in another database is not copied. It is connected with `exakit connect` and read where it lives. See [Sources](/data-scientist/concepts/sources).
