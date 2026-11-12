# External sources (/data-scientist/get-the-data/external-sources)



An external source is a database or a lake somewhere else. The kit reads it where it lives. Nothing is copied. The kit connects it as a **virtual schema**, which is a schema in your local database whose tables point at the source. A query fetches the rows it needs at the moment you run it.

The kit connects through its source engine, the same engine `exakit connect` runs.

## The kinds the kit can connect [#the-kinds-the-kit-can-connect]

* PostgreSQL, MySQL, SQL Server, Oracle, Snowflake, BigQuery, Databricks and MongoDB.
* Iceberg and Delta tables through a lakehouse catalog: Iceberg REST, Unity Catalog or AWS Glue.
* A folder of Parquet files, or document files in S3 or Azure Blob Storage.

These helpers list the kinds and what each one asks:

```python
nb.connectors()                        # every kind the kit can connect
nb.connector_inputs("postgresql")      # what that kind asks, with the required inputs marked
nb.connected_sources(connection)       # the sources connected now, with their table counts
nb.load_source(connection, None)       # lists the connected sources, and loads nothing
```

## Connect from this computer [#connect-from-this-computer]

The database runs in its own virtual machine. On macOS, the database cannot reach this computer as `localhost`.

* Use `192.168.64.1` for a database on this computer. If you give `localhost` or `127.0.0.1` on macOS, the kit replaces it with that address and prints one line about it. The source must then listen on that address too, not only on the loopback address.
* For a cloud source, allow this computer's public IP address at the source. The card shows the address. `exakit connect` shows it as its first line on a terminal.

## A lakehouse [#a-lakehouse]

A lakehouse is one connector for several things. It has two settings: a catalog, and where its files are. Each combination asks for different details. In the **Data source** list it appears as a tree. Pick a leaf and both settings are chosen. Pick the lakehouse itself and the settings are asked one at a time.

```python
form = nb.connector_inputs("lakehouse")
form["tree"]                                                       # the picks, as the tree shows them
form = nb.connector_inputs("lakehouse", catalog="unity", files="s3")
form["inputs"]                                                     # what that combination asks
nb.connect_source("lakehouse", "lake", catalog="unity", files="s3", workspace_url="https://...", namespace="main.sales")
```

Some combinations have two secrets: the catalog login and the storage keys. The catalog login is asked like any password. The storage keys go to the kit in a file only you can read, and the file is removed as soon as the kit has read it.

## An example: a PostgreSQL source [#an-example-a-postgresql-source]

This example reads a PostgreSQL database that runs on this computer. Your connector, host, database and table will differ.

```python
CONNECTOR = "postgresql"
SOURCE_NAME = "sales"                                   # its tables appear as VS_SALES
SOURCE_URL = "postgres://reader@192.168.64.1:5432/shop" # the password is asked in a hidden box
source_reading = nb.read_connection_string(CONNECTOR, SOURCE_URL)
source_test = nb.test_source(CONNECTOR, SOURCE_NAME, url=SOURCE_URL)
connected = nb.connect_source(CONNECTOR, SOURCE_NAME, url=SOURCE_URL)
SOURCE = None                                           # or "VS_SALES.ORDERS"
source_data = nb.load_source(connection, SOURCE or connected)
```

Run the cells in order. The reading shows what the connection string did not give. The test checks the inputs and whether this computer reaches the host and port. It changes nothing. The connect step runs the kit's connect command and makes the virtual schema.

## Step by step: a new external source [#step-by-step-a-new-external-source]

Under **External sources**, the **Choose your data** card lists the connections you have. Tick one or more and the tables to read from each, then press **Use this data**.

Tick **New connection…** and a single form opens under the list, two fields to a row. There is no step to press through: you pick the source, fill in the form, and press one button.

<Steps>
  <Step>
    ### Data source [#data-source]

    One list of every kind of source the kit connects, each with a line saying what it is. Type in the box at its top to narrow it. The list opens inside the card, under the field, so it never covers the page.

    The card does not hold this list. It asks the kit (`nb.connectors()`), which answers with what `exakit connect` offers. A source added to the kit appears here without a change to the notebook.
  </Step>

  <Step>
    ### The source's own settings [#the-sources-own-settings]

    Shown only for a source that has several kinds in one. Each setting is its own list, in the order the kit asks them. A lakehouse, for example, asks for its catalog, then where its files are, then how to sign in.

    A choice decides what the next lists offer. The card asks the kit again after each pick (`nb.connector_inputs(source, catalog=...)`) and takes the kit's default for the settings that follow, so the details below are always the ones that combination needs. A choice the kit does not support yet is shown greyed out with its reason.
  </Step>

  <Step>
    ### How to fill it in [#how-to-fill-it-in]

    **Fill in the details** shows every question below. **Paste a connection string** adds a box for the string: paste it and the kit reads it (`nb.read_connection_string`), fills in the details, and marks only what the string did not hold.
  </Step>

  <Step>
    ### Details and optional settings [#details-and-optional-settings]

    Everything `exakit connect` asks for that source, in one place:

    | Part              | What is in it                                                                                                                                                                          |
    | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
    | Details           | The name (alias) first: lower case, for example `sales`, and its tables appear as `VS_SALES`. Then every required input, such as the host, the database, the account and the password. |
    | Optional settings | A port, a schema, TLS, a CA certificate file and the like. Each shows the kit's default. Change one only to use another value.                                                         |

    The password goes into a hidden box. It is never shown, saved or logged by the card.
  </Step>

  <Step>
    ### Test connection, then Connect and use this data [#test-connection-then-connect-and-use-this-data]

    **Test connection** checks the inputs and whether this computer reaches the source. It changes nothing and needs no password. **Connect and use this data** runs the kit's connect command with the password on its standard input, then loads what you ticked.
  </Step>
</Steps>

From an empty card that is two picks and one button: tick **New connection…**, pick the data source, fill in the form, press **Connect and use this data**.

<Flow
  caption="A new external source"
  steps="[
  { title: &#x22;You name the source&#x22;, text: &#x22;The kind, a connection string or the details, and a name&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;The kit checks the inputs&#x22;, text: &#x22;Every input, the way the kit's connect form checks it&#x22;, code: &#x22;nb.test_source(...)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;This computer reaches the source&#x22;, text: &#x22;The host and port answer from here&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;You enter the password&#x22;, text: &#x22;In a hidden box. It goes to the kit only.&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;The kit connects&#x22;, text: &#x22;A connection is saved and a virtual schema is made&#x22;, code: &#x22;nb.connect_source(...)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;The tables read live&#x22;, text: &#x22;VS_SALES.ORDERS is read from the source when you query it&#x22;, tone: &#x22;db&#x22; },
]"
/>

## Passwords [#passwords]

* A password is asked in a hidden box. The kit receives it on its standard input.
* It is never written into a cell, the code view, a command line or the workflow log.
* A password inside a connection string is used and never shown.
* In Marimo there is no hidden box. Pass a password field, `mo.ui.text(kind="password")`, as the `password` argument, or pass a `password_file`.

## Live sources and AI [#live-sources-and-ai]

A table from an external source is read from the source as you query it. Before sampled rows from a live source go to a model, the notebook names the source and asks. Only a yes sends them. A table in the database does not ask.

Back to [Get the data](/data-scientist/get-the-data). Next: [The data map](/data-scientist/get-the-data/the-data-map).
