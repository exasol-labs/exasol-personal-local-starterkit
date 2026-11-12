# Get the data (/data-scientist/get-the-data)



Every data project starts with data that is in one place, can be read again, and is the same each time you read it. In this stage you put a table in front of the kit. The kit offers three origins: a sample dataset that comes with the kit, your own file or folder, and an external database or lake that the kit reads live. Each origin ends in a table the rest of the workflow can describe.

<Flow
  caption="Choosing an origin, loading it and reading it in the data map"
  steps="[
  { title: &#x22;You pick an origin&#x22;, text: &#x22;A kit dataset, your own file or folder, a table already in the database, or an external source&#x22;, tone: &#x22;you&#x22;, href: &#x22;/kit/data/load-data&#x22; },
  { title: &#x22;The kit loads it&#x22;, text: &#x22;A sample or your file is copied into a table. An external source is connected, not copied.&#x22;, code: &#x22;exakit data-load amazon_sales&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;The table is in the database&#x22;, text: &#x22;AMAZON.ORDER_LINES, MY_DATA.ORDERS or VS_SALES.ORDERS&#x22;, tone: &#x22;db&#x22; },
  { title: &#x22;The data map lists it&#x22;, text: &#x22;Every table by origin, with its rows, its column map and its links&#x22;, code: &#x22;nb.data_map(connection)&#x22;, tone: &#x22;kit&#x22; },
]"
/>

The flow is the same for all three origins. Only the first loading step differs. A sample dataset loads once and stays. Your file is copied into a table. An external source stays where it is: the kit creates a **virtual schema**, a schema in your local database whose tables point at a database or lake somewhere else. Its name is `VS_<NAME>`, where `<NAME>` is the name you gave the connection. Its tables are read when you query them.

You do not need a terminal for this stage. Every step runs from a cell or a card. The terminal commands are listed for scripts and for people who prefer them.

## Where you do it [#where-you-do-it]

| Guided view                                                                                                | Notebook code                                                                                                                                                                                                                                           | Terminal                                                                                           |
| ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| The **Choose your data** card in `00_quickstart`. Pick a kit dataset, your own data or an external source. | The shared cells in `00_quickstart`, under *Choose a dataset*, *Load your own data*, *An external source*: `SAMPLE`, `MY_DATA`, `MY_SCHEMA`, `MY_TABLE`, `CONNECTOR`, `SOURCE_URL`, `SOURCE`, then `nb.first(...)`, which picks the first loaded source | `exakit data-load` for a kit dataset, a file or a folder. `exakit connect` for an external source. |

## In this stage [#in-this-stage]

<Cards>
  <Card title="Sample datasets" href="/data-scientist/get-the-data/sample-datasets" description="amazon_sales and fraud_transactions: what is in each, with the numbers" />

  <Card title="Your own file" href="/data-scientist/get-the-data/your-own-files" description="Load a CSV, Parquet, JSON or Excel file, a folder, or a table already in the database" />

  <Card title="External sources" href="/data-scientist/get-the-data/external-sources" description="Connect a database or lake that stays where it is, step by step, and handle passwords" />

  <Card title="The data map" href="/data-scientist/get-the-data/the-data-map" description="Every table by origin, its column map state and its links" />

  <Card title="The dataset" href="/data-scientist/get-the-data/the-dataset" description="A table with its approved column map, and how a notebook picks one" />

  <Card title="Troubleshooting" href="/data-scientist/get-the-data/troubleshooting" description="File, source and table problems" />
</Cards>

## What you have at the end [#what-you-have-at-the-end]

A table that the kit can describe, chosen by `nb.first(...)` as `chosen_data`, and a data map that shows it. The table has no approved column map yet. The next stage reviews the roles and approves them.

Next: [Explore and understand](/data-scientist/explore).

<StageNav n="2" />
