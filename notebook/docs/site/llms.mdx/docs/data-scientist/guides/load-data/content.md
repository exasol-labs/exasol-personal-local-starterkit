# Load data (/data-scientist/guides/load-data)



All of this happens in step 1 of `00_quickstart`. On the **Choose your data** card you pick one of three boxes. The code below is what each box runs.

```python
import exakit.nb as nb

connection = nb.connect()
nb.check_connection(connection)
```

<Tabs items="['A kit dataset', 'Your own data', 'An external source']">
  <Tab value="A kit dataset">
    ```python
    nb.sample_datasets()                                   # what the kit has, and which are loaded
    sample_data = nb.load_sample(connection, "amazon_sales")
    ```

    A dataset that is not loaded yet is loaded first. Nothing else is needed.
  </Tab>

  <Tab value="Your own data">
    A file or a folder:

    ```python
    own_data = nb.load_own_file("~/sales-data/orders.csv", "SALES", conn=connection)
    ```

    CSV, Parquet, JSON and Excel work. Leave the schema empty and it is named after the folder: `~/sales-data` becomes `SALES_DATA`.

    A table that is already in the database:

    ```python
    own_data = nb.use_table(connection, "MY_DATA.ORDERS")
    ```

    `nb.data_map(connection)` lists the tables in the database. The kit's own schemas are left out unless you pass `include_kit=True`.
  </Tab>

  <Tab value="An external source">
    The card walks through it one step at a time: an existing connection or a new one, the kind of source, a connection string or manual details, a name, the password, and optional settings.

    ```python
    nb.connectors()                                         # every kind of source
    reading = nb.read_connection_string("postgresql", "postgres://reader@192.168.64.1:5432/shop")
    reading["missing"]                                      # what the string did not give

    test = nb.test_source("postgresql", "sales", url="postgres://reader@192.168.64.1:5432/shop")
    connected = nb.connect_source("postgresql", "sales", url="postgres://reader@192.168.64.1:5432/shop")
    source_data = nb.load_source(connection, "VS_SALES.ORDERS")
    ```

    A source with several kinds in one, such as a Lakehouse, shows its choices as a tree under it in the **Data source** list. Pick the catalog and where its files are; the steps after it ask only what that combination needs. See [Sources](/data-scientist/concepts/sources).

    * **Test connection** checks the inputs and reaches the source from this computer. It changes nothing.
    * **Connect and use this data** runs `exakit connect`. The tables then appear as `VS_SALES`.
    * The password is asked in a hidden box. It is never part of the code.
  </Tab>
</Tabs>

## Use what you chose [#use-what-you-chose]

```python
chosen_data = nb.first(source_data, own_data, sample_data)   # the first one that is set
```

## What you get at the end [#what-you-get-at-the-end]

`chosen_data` is the table you picked, ready for the column map step.

Next: [approve the column map](/data-scientist/guides/approve-column-map).

<Callout type="warn">
  A source on this computer is not `localhost` from the database's point of view. On macOS use `192.168.64.1`. For a cloud source, allow this computer's public IP there; the card shows it.
</Callout>
