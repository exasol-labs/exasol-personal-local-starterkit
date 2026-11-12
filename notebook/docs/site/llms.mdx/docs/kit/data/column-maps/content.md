# Column maps (/kit/data/column-maps)



A **column map** (the descriptor) gives every column of a table a role. Notebooks and AI clients read it, so they all work from the same meaning. For the idea behind it, see [Column map and approval](/data-scientist/concepts/descriptor).

## Draft [#draft]

```bash
exakit describe AMAZON.ORDER_LINES
```

The table is profiled with SELECTs only. Nothing is written to the database. Every column gets one of eight roles, with its confidence and the evidence that chose it:

`key`, `time`, `measure`, `category`, `flag`, `text`, `identifier`, `other`.

* The draft is deterministic: the same table gives the same draft.
* A column whose values look like e-mail addresses, phone numbers, IBANs or postcodes is marked **sensitive**.
* The **target** is never drafted. Only a person sets it.

## Approve [#approve]

```bash
exakit describe AMAZON.ORDER_LINES --approve --role target=CANCELLED --owner dana
```

`--role <slot>=<COLUMN>` corrects a slot: `key`, `time`, `text`, `target`, `category`, `entity`. `<slot>=-` leaves it empty.

Approval:

* checks that every column has a role, that none sits in two slots, and that the table has not changed since it was profiled
* writes a new version, never rewriting an old one
* publishes the roles in [Exasol Semantic Views](/kit/data/semantic-views): the schema's semantic model is rebuilt with this table as an entity, readable by the read-only AI user. Semantic Views is installed first when the database does not have it yet.

Your own table is never commented. If publishing fails, the approval still stands and the message says why.

## What you get at the end [#what-you-get-at-the-end]

A new version of the column map, kept under `~/.exasol-starter-kit/descriptors/`, and the schema's semantic model (its views in `SEM_<SCHEMA>`) rebuilt from it. The notebooks and AI clients read the approved version from then on.

## See and compare [#see-and-compare]

```bash
exakit describe amazon_sales --show              # the current version
exakit describe amazon_sales --show --version 1  # an earlier one
exakit describe amazon_sales --versions          # every version
exakit describe orders --comments                # rebuild the schema's semantic model again
```

Add `--json` to any of them for a script.

## A whole schema [#a-whole-schema]

```bash
exakit describe --schema TPCH
```

This lists every table with its rows and key, and every many-to-one link between tables with its evidence. A link is a foreign key the database declares, or a column whose values are in another table's key (at most 0.1% of them may be missing). A name alone never makes a link.

```bash
exakit describe --schema TPCH --approve --unlink ORDERS.O_CLERK
```

`--link TABLE.COLUMN=TABLE.KEY` adds a link and `--unlink TABLE.COLUMN` removes one. The approved links become relationships of the schema's semantic model. To join tables of different schemas, build a [multi-source model](/kit/data/semantic-views).

## Where they are kept [#where-they-are-kept]

`~/.exasol-starter-kit/descriptors/<SCHEMA>.<TABLE>/`: the draft, every approved version and the current one.

## When the table changes [#when-the-table-changes]

Columns whose name and type did not change keep their approved roles. The rest are flagged, and you approve again.

## With an AI model [#with-an-ai-model]

When a model is set up, one call adds a one-line note per column. It is sent each column's name, type, role, evidence and top values, never a row and never a sensitive column. A note never decides a role.

## From a notebook [#from-a-notebook]

```python
draft = nb.describe("AMAZON.ORDER_LINES")
draft.slot(target="CANCELLED")
dataset = draft.approve()
```

See [Review and approve the column map](/data-scientist/guides/approve-column-map).
