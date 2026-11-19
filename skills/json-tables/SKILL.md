---
name: json-tables
addon: json-tables
description: Load JSON-shaped data into the local Exasol database with the JSON Tables add-on, which shreds nested JSON into relational tables — covering why exapump alone cannot load JSON, how the add-on is offered automatically during a data load, the fact that its ingest engine ships prebuilt so no Rust toolchain is ever needed, and querying a wrapped surface with JSON paths on any connection with no session setup. Triggers — "load a JSON file into Exasol", "import JSON data", "exapump will not take my .json", "install JSON Tables", "exasol-json-tables", "flatten nested JSON into tables", "do I need Rust for this", "query JSON paths in SQL", "exasol-json-tables wrap", "JVS-PATH-ERROR", "do I need ALTER SESSION for JSON Tables".
---

# JSON Tables — JSON into Exasol

`json-tables` is a **marketplace add-on** that ingests, queries and reshapes
JSON-shaped data, shredding a nested tree into relational tables the database
can actually work with.

## Why it exists

`exapump upload` loads **CSV and Parquet**. It does not load JSON, and that is
not an oversight — JSON is a nested tree, not a table, so something has to
decide how the nesting becomes rows and columns. That is this add-on's job.

## The easy path — let the data load offer it

You usually do not install this by hand. Hand `exakit data-load` a `.json`
file and the kit explains the gap and offers the add-on **on the spot**, then
continues the load automatically once it is installed:

```bash
exakit data-load
```

Driving that non-interactively, answer with the marketplace variable:

```bash
EXAKIT_MARKETPLACE_ADDONS=json-tables exakit data-load
```

| Value | Effect at the JSON prompt |
|---|---|
| `json-tables` or `all` | install it and continue the load |
| `none` | do not install; the file is **not** loaded |
| unset | interactive prompt; a non-TTY run does not load the file |

If the add-on is not available on this machine at all, the kit says so and
notes that CSV and Parquet still load without it — convert the file, or load it
from a supported machine.

## Installing it directly

```bash
EXAKIT_MARKETPLACE_ADDONS=json-tables exakit marketplace
```

## Using it

```bash
exasol-json-tables --help
exasol-json-tables ingest --input <file.json>
```

The launcher is installed on `PATH` by the kit. Run `--help` before composing
a command — read the real flags rather than guessing them. `--help` is also
where the full subcommand list lives (`ingest`, `ingest-and-wrap`, `wrap`,
`describe`, `compile`, `validate`, `structured-results`), and each subcommand
has its own `--help`.

## After the ingest — find out what it made

An ingest is not finished until you can tell the user **where their data
landed**. Never guess a table name; ask, in this order.

```bash
exasol-json-tables describe wrappers          # what the add-on itself recorded
```

`describe wrappers` lists the wrapper surfaces the add-on discovered from its
helper-schema metadata tables — it exists for exactly this, and it is the only
answer that knows which of them came from your ingest. `describe wrapper` (no
`s`) drills into one of them. Run `exasol-json-tables describe --help` for the
exact flags before composing either, including whether this build offers a
machine-readable output flag.

Then confirm against the database itself, which is the ground truth for what a
query can name:

```bash
exakit sql "SELECT TABLE_NAME FROM SYS.EXA_ALL_TABLES WHERE TABLE_SCHEMA = 'STARTER_KIT' ORDER BY 1"
exakit sql "SELECT VIEW_NAME  FROM SYS.EXA_ALL_VIEWS  WHERE VIEW_SCHEMA  = 'STARTER_KIT' ORDER BY 1"
```

`STARTER_KIT` is the kit's default target schema; substitute the schema you or
the user actually loaded into. Report the real names back to the user with a
sample query — `exakit sql "SELECT * FROM STARTER_KIT.<table> LIMIT 5"` — rather
than telling them the load succeeded and leaving them to find it.

## Querying with JSON syntax — after a wrap

An ingest gives relational tables (one per nesting level, joined by id). A
**wrap** adds a JSON-friendly surface over them in a wrapper schema — dotted
paths (`"customer.address.city"`), array access (`"tags[LAST]"`), iteration and
`TO_JSON(*)`:

```bash
exasol-json-tables ingest-and-wrap --input <file.json> ...   # or: wrap install / wrap deploy
```

When a wrap succeeds through the kit's launcher, the kit rebuilds its JSON
Tables module for every wrapper in the database and registers it with the kit's
SQL preprocessor framework. From then on **JSON queries work on every
connection, for every user — the MCP tools included — with no session setup**:

```bash
exakit sql 'SELECT "order_id", "customer.address.city" FROM ORDERS_VIEW."orders" ORDER BY 1'
```

In Windows PowerShell 5.1, use `exakit sql --file <path>` or pipe the statement in: PowerShell drops the double quotes inside a native command's argument (`exakit sql --help` says the same).

- **Never run the `ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = ...` that
  `exasol-json-tables` prints as its next step** (its `activationSql` and
  "session-scoped" warnings are upstream's advice for a database without the
  framework). On this kit it would take the framework, and every other add-on's
  module, out of that session.
- Only a statement that **names a wrapper schema** is treated as a JSON query;
  every other statement reaches the database unchanged.
- A JSON query JSON Tables cannot answer — a mistyped field, a path through a
  derived table — fails with JSON Tables' own message, for example
  `JVS-PATH-ERROR: "customer.nmae": Field "nmae" is not visible on object path
  "customer"`. Read it and fix the path; `exasol-json-tables describe wrapper`
  lists the real fields.
- A JSON query fails with `object "customer.name" not found` instead: the
  module is not registered (the framework is not active, or the database's
  slot holds the user's own preprocessor). `exakit update` registers it once
  the framework is in place.
- A database user created after the module was registered gets JSON queries
  after the next `exakit update`, which refreshes the framework's rule
  resolution for every user.

## No Rust toolchain, ever

This is the fact users most need reassuring about. Upstream, the tool is a
Python package **plus a Rust ingest engine**, and the published wheel does not
contain the engine — so a plain `pip install` cannot ingest even on a machine
that *has* Rust.

The kit solves that for the user: the engine binaries are **built once per
platform by the kit's own packaging workflow**, published as an immutable
`json-tables-<version>` release whose asset digests `versions.json` pins, and
downloaded **digest-verified** at install time. Nothing is compiled on the
user's machine and no Rust toolchain is required.

To make the upstream CLI use that prebuilt engine, the kit places a small
`cargo` shim in front of it. **That shim is visible only to processes the kit's
launcher starts** — the user's real `cargo`, if they have one, is untouched
everywhere else. Do not "clean up" the shim; it is load-bearing.

A consequence worth knowing: what is *installable* here is what the kit's
packaging workflow has published, not whatever upstream tagged most recently.
So a version you see upstream may legitimately not be offered yet.

## Managing it

```bash
exakit version                   # its row shows installed vs advertised
exakit update        # also the repair command
exakit logs json-tables
exakit uninstall                 # selectable on its own
```

## When it fails

| Symptom | Do |
|---|---|
| The add-on is not offered at all | it is already installed, or not applicable on this machine — check `exakit marketplace` output for the reason |
| Ingest errors | `exakit logs json-tables`, then `exakit update` to repair |
| `exasol-json-tables: command not found` | it is not installed — `EXAKIT_MARKETPLACE_ADDONS=json-tables exakit marketplace` |
| A JSON load did nothing | the prompt was answered `none`, or the run had no TTY and no `EXAKIT_MARKETPLACE_ADDONS` |

## Guardrails

- **Never tell the user to install Rust** to make this work. If ingest fails,
  the fix is `exakit update`, not a toolchain.
- **Do not bypass the kit's launcher** to run the upstream CLI directly — the
  `cargo` shim it sets up is what lets the CLI find the prebuilt engine, and a
  wrap run through it is what makes the new wrapper's JSON syntax work on every
  connection.
- **Never switch the session's preprocessor** for JSON syntax, whatever the
  tool's own output says: no `ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT`.
- **Loading data writes to the database.** Confirm the target schema and table
  with the user first; uploads default to the `STARTER_KIT` schema.
- **Do not invent** `exasol-json-tables` subcommands or flags. Run `--help`.
- **Do not invent table names either.** After an ingest, learn them from
  `exasol-json-tables describe wrappers` and `SYS.EXA_ALL_TABLES` — see
  *After the ingest*, above.
