# What is a persona (/kit/personas/what-is-a-persona)



A **persona** is a named set of answers to the questions the installer asks: which datasets to load, which AI clients to connect and which add-ons to install. Choosing a persona is choosing what this computer is for.

A persona names things. It never holds a secret or a path on your machine.

## The personas in this kit [#the-personas-in-this-kit]

| Persona                               | Datasets                             | Add-ons                                                    | First notebook                 |
| ------------------------------------- | ------------------------------------ | ---------------------------------------------------------- | ------------------------------ |
| **Data Scientist** (`data-scientist`) | `amazon_sales`, `fraud_transactions` | `dash-server`, `notebook`, `json-tables`, `semantic-views` | `data-scientist/00_quickstart` |
| **General** (`general`)               | `tpch`, `energy`, `weather`          | none                                                       | none                           |
| **ML Engineer** (`ml-engineer`)       | `amazon_sales`, `fraud_transactions` | `notebook`, `udf-devkit`                                   | `ml-engineer/00_quickstart`    |

Every persona connects all the AI clients found on this computer.

<Callout type="warn">
  ML Engineer is kept in the kit but **not offered in this release**. It cannot be newly selected. A kit that was set up with it before keeps working.
</Callout>

## What each one is for [#what-each-one-is-for]

**Data Scientist.** Four notebooks that take a table from loading to a shared dashboard: agree what each column means, prepare, explore, train a small model, ask questions in plain language and hand the work off. It gets the dashboard server first and then the notebooks, because the notebooks' Share step publishes a dashboard there. See [Data Scientist](/data-scientist).

**General.** The kit's own sample data and nothing else: a database to query with SQL or an AI client. Its datasets are bundled with the kit and load without internet.

**ML Engineer.** In-database training and scoring. It also starts a local MLflow server and installs the UDF runtime.

## Personas combine [#personas-combine]

Personas are not exclusive. Choosing two loads the datasets of both and installs the add-ons of both, each once. Choosing all of them gives you everything.

General is ticked to begin with in the install question, and combines with the others like any persona.

## What a persona does not do [#what-a-persona-does-not-do]

* It does not lock anything. Any dataset or add-on can be added later, whatever the persona.
* It does not remove anything when you leave it. Removing a persona only removes the membership; the data, notebooks and add-ons stay.

## Further reading [#further-reading]

* [User-defined functions (UDFs)](https://docs.exasol.com/db/latest/database_concepts/udf_scripts.htm) and [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm), the two parts of the UDF runtime that the ML Engineer persona uses.
* [exasol/exasol-personal](https://github.com/exasol/exasol-personal), the local database the kit deploys.
* [Add-ons](/kit/tools/add-ons), with each add-on's repository and documentation.

Next: [choose and change a persona](/kit/personas/choose-and-change).
