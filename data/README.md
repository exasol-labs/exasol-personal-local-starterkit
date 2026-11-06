# Sample data

This folder holds the kit's **bundled datasets**. Each dataset is a self-contained folder
under [`datasets/`](datasets/):

```
datasets/<id>/
  dataset.conf          # id, menu label, marker tables (loaded-detection)
  01_create_schema.sql  # exact types + primary keys (optional — exapump can
                        # infer and create tables from bare CSVs)
  data/*.csv            # bulk files: one table per file, named after the file
  02_load_data.sql      # optional transform / SQL-generated data
  03_verify_setup.sql   # post-load checks — a FAIL row blocks "loaded"
```

A *reference dataset* adds `descriptor.yaml`, `manifest.json`, `README.md` and
`examples.sql` - see [Reference datasets](#reference-datasets).

Each dataset loads into its **own schema** (`schema=` in `dataset.conf`, default the id
uppercased). The read-only MCP user has database-wide read (`USE ANY SCHEMA` + `SELECT ANY
TABLE`), so the AI client sees every schema — these datasets and anything you add later —
without a per-schema grant. The `exakit data-load` menu discovers datasets from these
folders and only offers ones **not already in the database** (verified against the marker
tables, not just a manifest flag).

**Adding a dataset needs no code.** Put its folder under `datasets/` and check it:

```bash
python3 tools/dataset_check.py data/datasets/<id>
```

The check reads the files first - UTF-8 without a byte-order mark, every CSV against its
`CREATE TABLE` (names, order, row widths, empty `NOT NULL` values, repeated primary keys),
Exasol's reserved words, the schema it creates, the markers and the verify script - then
loads the dataset into your database as `exakit data-load` does, verifies it and drops it
again (`--offline` skips the load; `--keep` leaves it; `--replace` reloads a schema that
is already there). The kit offers every folder that has a `dataset.conf`. A reference
dataset is checked for more - see [Reference datasets](#reference-datasets) below.

The kit offers six datasets:

| Dataset | Schema | Contents |
|---|---|---|
| [`datasets/tpch/`](datasets/tpch/) | `TPCH` | TPC-H retail benchmark (below) — the original sample |
| [`datasets/energy/`](datasets/energy/) | `ENERGY` | 50 smart meters + 108,000 hourly readings (SQL-generated time series) |
| [`datasets/weather/`](datasets/weather/) | `WEATHER` | 10 European cities, ~11k days of daily weather (2023–2025) |
| [`datasets/walmart_sales/`](datasets/walmart_sales/) | `WALMART` | 6,435 weeks of sales from 45 Walmart stores (February 2010-October 2012) with holiday weeks, temperature, fuel price, CPI and unemployment, and a label (the week beat the store's median week); 0.4 MB of CSV, a 0.1 MB download ([README](datasets/walmart_sales/README.md)) |
| [`datasets/amazon_sales/`](datasets/amazon_sales/) | `AMAZON` | 128,975 order lines of one fashion seller on Amazon.in (March 31-June 29 2022): status, fulfilment, product, size, amount and where it shipped, with a label (cancelled, 14.2%); 22 MB of CSV, a 4.5 MB download ([README](datasets/amazon_sales/README.md)) |
| [`datasets/fraud_transactions/`](datasets/fraud_transactions/) | `FRAUD` | 51,000 card and bank transactions of 4,000 users with a fraud label (4.9%) - messy on purpose: 1,000 repeated transaction ids, about 5% gaps in five columns and two placeholder values, for the Prepare and Validate steps; no date, only the hour; 3.9 MB of CSV, a 1 MB download ([README](datasets/fraud_transactions/README.md)) |

The first three are the kit's own samples: they ship inside the kit, load with no
internet and are what the General persona loads (`default=yes` in their `dataset.conf`).
The other three are what the Data Scientist persona loads (the ML Engineer, disabled for now,
takes the first two), each downloaded from the kit's `datasets` release only when it is picked.
All three are *reference datasets*:
data with a
`README.md` (source, terms, data dictionary), a `manifest.json` (source, terms, snapshot
date, rows and SHA-256 of every CSV, and the release asset they ship as) and a descriptor;
the builders that make them again live in [`tools/datasets/`](../tools/datasets/).
None has a free-text column, and `fraud_transactions` has no date, so the notebook steps that need one skip on it and say why.
Every table and column has a `COMMENT` in its `01_create_schema.sql`, so the database itself
describes the data; the narrative and the join map for every dataset are in
[data-dictionary.md](data-dictionary.md).

## Reference datasets

`walmart_sales`, `amazon_sales` and `fraud_transactions` are *reference datasets*. Each
folder holds:

| File | What it is | Checked by `tools/dataset_check.py` |
|---|---|---|
| `descriptor.yaml` | the role of every column and the columns the notebooks use - [the semantic layer](#the-descriptor-the-semantic-layer) | it validates; it lists every column of its table in table order with the schema digest the CREATE TABLE declares; the key and target slots are set |
| `manifest.json` | source, terms (and whether redistribution is confirmed), snapshot date, rows and SHA-256 of every CSV, the release asset | every field is there, the files match the CSVs, the asset is the archive these CSVs make |
| `README.md` | what the data is, the source and terms, a **Data dictionary** section | the data dictionary names every table and column |
| `examples.sql` | at least ten example questions, each a `--` comment above its reference SQL | ten or more, each a read-only `SELECT` on the dataset's schema with its question |

Without `--offline` the check also loads the dataset and runs every example query against
it; each must return rows.

### The descriptor: the semantic layer

The notebooks and the training template never name a dataset's tables or columns. They
read a YAML descriptor that gives **every column of the table one role** - with how sure the
kit is and the numbers that decided it - and names, in its **slots**, the columns the
notebooks need. The same notebook therefore runs on Walmart, on Amazon, on a table you
loaded yourself or on a table in a virtual schema.

```yaml
descriptor: 1                     # format version
dataset: "support_tickets"
source:
  kind: "local"                   # local | file | virtual
  object: "MY_DATA.TICKETS"
  schema_digest: "sha256:5d1f8c0b9e6a4f27c3b8d2e1a0f9c7b6e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0"   # names and types, in order
  profiled_rows: 1840             # 10000 for a virtual table: "first 10,000 rows"
version: 2
status: "approved"                # draft | approved
owner: "dana"
approved_at: "2026-11-03T10:14:00Z"
grain: "one row per support ticket"
slots:
  key: "TICKET_ID"
  time: "OPENED_ON"
  text: "BODY"
  target: "ESCALATED"             # only ever set by a person
  category: "CHANNEL"
  entity: null                    # empty on purpose: slot_evidence says why
slot_evidence:
  entity: "no short string column with more than 20 values"
columns:
  "TICKET_ID": {role: "key", confidence: "high", evidence: "1,840 distinct, no nulls"}
  "OPENED_ON": {role: "time", confidence: "high", evidence: "DATE, 2025-01-02 to 2025-10-30"}
  "CHANNEL": {role: "category", confidence: "high", evidence: "3 distinct"}
  "CUSTOMER_EMAIL": {role: "identifier", confidence: "high", evidence: "email 100%", sensitive: true}
  "ESCALATED": {role: "flag", confidence: "high", evidence: "0 91.2%, 1 8.8%"}
  "BODY": {role: "text", confidence: "high", evidence: "avg 214 chars, 97.5% distinct"}
```

The two reference datasets ship theirs in the same shape:
[`walmart_sales`](datasets/walmart_sales/descriptor.yaml) and
[`amazon_sales`](datasets/amazon_sales/descriptor.yaml).

**The roles.** Eight, and no more: `key`, `time`, `measure`, `category`, `flag`, `text`,
`identifier` and `other`. Three things are read: the column's type, its numbers (rows, values
present, distinct values, length) and the shape of its values - the profile counts the values
that look like a code (one token holding a digit: `SKU-1042`, `B09KXVBD7Z`), a number written as
text, three words or more, a date, an e-mail. The name is read last, and only settles what the
numbers leave open: `QTY` with ten values is a measure, `STORE` with forty-five a category.

Sensitivity is decided first and kept whatever the role: a string column is `sensitive` when 90%
or more of its values look like an e-mail address, a phone number, an IBAN or a 5-digit postcode,
or its name says postcode (ZIP, POSTAL, PLZ) and 90% are shaped like one, or its name says a
person's name (`FIRST_NAME`, `SURNAME`, `CUSTOMER_NAME`, `DRIVER_NAME`) or a street address - a
sensitive column is never charted, grouped or sent to a model. Then the first rule that matches
wins ([`setup/lib/descriptor/roles.py`](../setup/lib/descriptor/roles.py), each threshold pinned
by a test; "distinct share" is distinct values over the values present):

| Rule | Role |
|---|---|
| every value null | `other` |
| `DATE` or `TIMESTAMP`, or 98%+ of the values match one date pattern (`YYYY-MM-DD`, `DD.MM.YYYY`, slash dates - DD/MM or MM/DD told apart by a part over 12) | `time` |
| an integer named like a time (`TS`, `EPOCH`, `..._AT`) holding Unix seconds or milliseconds | `time` |
| sensitive | `identifier` |
| one value in every row (or one value, else empty) | `other` - it tells no row apart |
| string, distinct share 0.5+, and average length 40+; or three words or more in half the values and average 15+; or named as text (`COMMENT`, `NOTES`, `DESCRIPTION`, `REVIEW`) and average 10+ | `text` |
| no nulls, every value distinct, and an integer - or a string that is code-shaped or named like a key | `key` |
| `BOOLEAN`, or exactly two non-null values (counted exactly) | `flag` |
| `DOUBLE`, or `DECIMAL` with a scale | `measure` |
| integer named as an identifier (a whole word id, no, nr or key, or a run-together `..KEY`: `O_CUSTKEY`) | `identifier` |
| integer named as an amount (`QTY`, `PRICE`, `AGE`, `..._PCT`, `AVAILQTY`) | `measure` |
| 50 distinct values or fewer, or a string with distinct/rows 0.02 or less | `category` |
| string of numbers named as an amount | `measure` |
| string, 90%+ code-shaped | `identifier` |
| string, distinct share 0.9+ | `identifier` |
| string, average length under 40, distinct share 0.5 or less (cities, job titles) | `category` |
| integer | `measure` |
| anything else | `other` |

Confidence is `low` wherever the draft is a guess: the deciding number within 10% of its
threshold (for a share, 10% of the room up to 100%), a role taken from a name alone, a number with
few values and nothing in its name (a store number, a rating), short labels, a lone integer; `high`
otherwise. A reviewer reads the `low` ones first, and approving reports the ones nobody changed.

**How good the first draft is.** `python3 tools/descriptor_benchmark.py` scores a fresh draft of
twenty-four tables - the kit's datasets, five synthetic ones and five held out (written after the
rules, never tuned to) - against a reviewer's answers: every role and slot right, every sensitive
column marked, and every role a reviewer might disagree with marked `low`. The held-out tables'
first run got 98.1% of roles right; the two it missed are fixed and recorded in the tool.

**The slots.** `key` takes a key column (an identifier-like name first, then the leftmost);
with none it stays empty, "no single unique column". `time` takes the time column with the
fewest nulls, the leftmost of a tie (a table puts the row's own event date first; follow-up
dates have gaps), `text` a column named as text first, then the longest. `target` is **never
drafted**: it stays empty until a person sets it, and training stops with that reason - a
guessed target trains on the wrong label and nobody notices. `category` is a non-sensitive
string category with 2 to 20 values (the grouping to compare): one named as a grouping first
(`CATEGORY`, `SEGMENT`, `..._TYPE`), one named as an outcome last (`STATUS` is often the label
itself), then the leftmost. `entity` is a non-sensitive short string column with more than 20
values but at most one per two rows (who or where a row comes from): one named so first
(`CUSTOMER`, `STORE`, `CITY`), then the most values. An empty slot always says why in
`slot_evidence`, and the notebook steps that need it skip with that reason.

**Drafting is deterministic.** The same table gives the same bytes: no timestamps in a draft,
a fixed key order, the columns in table order. A model may add a one-line `note` per column;
it never decides a role. `tools/descriptor_draft.py <dataset folder>` drafts a shipped
dataset from its CSV offline with the very code `exakit describe` runs on the database, and
the tests check that a fresh draft of each reference dataset gives the roles and the key,
time and text slots it ships.

**Your own data.** Describe a table you loaded - a CSV, Parquet or JSON file, or anything you
created - from a notebook:

```python
d = exakit_nb.describe("MY_DATA.TICKETS")         # profile, draft the next version, show it
d.set(CHANNEL="category", EMAIL="identifier")     # corrections, chainable
d.slot(target="ESCALATED")                        # target=None leaves it empty on purpose
d.approve()                                       # check, write, publish
```

or with `exakit describe MY_DATA.TICKETS` on the command line. Approving writes
`~/.exasol-starter-kit/descriptors/<SCHEMA>.<TABLE>/v<n>.yaml` (a version is never
rewritten) and `current.yaml`, a copy of the approved one; `EXAKIT_HOME` moves the store.
It then publishes the roles as a view, `EXAKIT_SEMANTIC.<SCHEMA>__<TABLE>`, whose column
comments carry them, so an AI client connected over MCP sees them.
The table must not have changed since it was profiled: the schema digest is checked again.
Approving then looks at the data once more: a key slot whose column repeats or has a gap, or a
target that does not hold exactly two values (a yes/no outcome), is refused with what to change;
a column that gives the target away (values where it is nearly always one way, covering most
rows - an order's `STATUS` once it was cancelled) and the `low` roles approved unchanged are
listed as warnings, and the approval goes through.

**Several tables: the schema map.** `exakit describe --schema MY_DATA` (or
`nb.describe_schema(conn, "MY_DATA")`) describes the whole schema: every table with its rows
and key, and every many-to-one link between them - a foreign key the database declares, or a
column that names another table's key and whose every value is in it (a name alone never makes
a link). Correct it with `--link TABLE.COLUMN=TABLE.KEY` / `--unlink TABLE.COLUMN` and approve
with `--approve`: `~/.exasol-starter-kit/descriptors/<SCHEMA>/v<n>.json` and `current.json`, the
links published as `EXAKIT_SEMANTIC.<SCHEMA>__RELATIONS` for AI clients. In Explore,
`schema_map.joined_view(dataset).create(conn)` turns it into one view,
`EXAKIT_PREPARED."<SCHEMA>__<TABLE>__JOINED"`, with its own approved column map.

**Where a descriptor is read from.** `nb.dataset(conn, name)` takes, in this order: a path
(a descriptor file, or a folder holding `descriptor.yaml`); for a data file of your own,
`<name>.descriptor.yaml` beside it; for an id, the approved version in the kit's store, then
the descriptor the kit ships under `data/datasets/<id>/`. `ds.descriptor_path` and
`ds.descriptor_origin` say which was used.

**Older descriptors.** A file with `schema_version: 1` or `2` (one role per *role* - entity,
category, date, label, text - rather than per column) still reads everywhere, with its
rules in [`tools/descriptor_rules.py`](../tools/descriptor_rules.py); describing its table
again writes the role-per-column shape.

### How a reference dataset reaches the database

The CSVs of a reference dataset are in this repository - the builders' output, readable in
review - but not in the kit archive the installer downloads (`.gitattributes`,
`export-ignore`). They ship as one **release asset** per dataset, `<id>-<snapshot>.tar.gz`,
recorded in the dataset's `manifest.json`:

```json
"asset": {
  "file": "amazon_sales-2026-11-05.tar.gz",
  "sha256": "b7ed9c1034ef023c0fb61bf2d0ebc29c4ce06e82b52963de72fe565a6a3ce80e",
  "size": 4535714,
  "tar_sha256": "f5614184ab9e61d68c6561e8d937b132f21ec62ac1c5c7f3583e5a37c5ba75b3",
  "url": "https://github.com/{repo}/releases/download/datasets/amazon_sales-2026-11-05.tar.gz"
}
```

`exakit data-load` takes a reference dataset's CSVs from, in this order:

1. **the kit copy** - `data/*.csv` in the dataset's folder, when every file is there with
   the SHA-256 the manifest lists (a checkout of this repository, an `EXAKIT_LOCAL_KIT`
   install); a copy that does not match is passed over;
2. **the cache** - `~/.exasol-starter-kit/cache/datasets/<id>/<sha256>/`, an extraction
   that was verified when it was made, and is checked again;
3. **the release asset** - downloaded (with retries and timeouts) from
   `EXAKIT_DATASETS_MIRROR` when it is set (a folder, a `file://` URL or an `https://` base
   URL holding the archive), else from the manifest's URL with `{repo}` =
   `EXAKIT_DATASETS_REPO`, default the repository the kit was installed from. With
   `GITHUB_TOKEN` (or `GH_TOKEN`) set, a private repository's release works too: its plain
   download link answers 404 even with a token, so the archive is found through the GitHub
   API and fetched from there - the token goes to `api.github.com` only, never on a command
   line or into the log - and the plain link is still tried after. The archive
   must match the manifest's SHA-256 (a mismatch is deleted and nothing loads); every member
   must be a plain `data/<name>.csv` the manifest lists - no links, no absolute paths, no
   `..`; and every CSV must match its own digest. Only then is it cached and loaded.

The menu names the download (`Amazon sales - 4.5 MB download`) while one is
needed. Offline with nothing cached, the load stops with the URL it tried and the
`EXAKIT_DATASETS_MIRROR` way out; the other datasets still load. Datasets without an asset
block (`tpch`, `energy`, `weather`) load from the kit copy, as always.

**Publishing a new snapshot:** rebuild it (`python3 tools/datasets/<id>.py`, which rewrites
the CSVs and the manifest), then `python3 tools/datasets/package.py <id>` - it writes
`dist/<id>-<snapshot>.tar.gz` and the manifest's `asset` block. The archive is
deterministic (members sorted, fixed mtime, uid and gid, gzip mtime 0): the same CSVs give
the same bytes. Upload it to the one release every archive lives in, tagged `datasets`
(`gh release upload datasets dist/<id>-<snapshot>.tar.gz`; never delete an asset a released
kit's manifest still names), then
`python3 tools/dataset_check.py --all --offline` checks that the manifest, the CSVs and the
local archive agree.

## The TPC-H dataset (`datasets/tpch/`)

Standard **TPC-H** data at **scale factor 0.02** (~21 MB total). TPC-H is a well-known
wholesale/retail benchmark: customers place orders, each order has line items for parts
supplied by suppliers, across nations and regions. Because the data is *generated*, it is
fully self-consistent — every foreign key resolves and every order has line items.

| File | Rows | What it is |
|------|-----:|------------|
| `region.csv`   | 5       | Geographic regions |
| `nation.csv`   | 25      | Nations, each in a region |
| `customer.csv` | 3,000   | Customers, each in a nation |
| `supplier.csv` | 200     | Suppliers, each in a nation |
| `part.csv`     | 4,000   | Products that can be sold |
| `partsupp.csv` | 16,000  | Which supplier can supply which part, at what cost |
| `orders.csv`   | 30,000  | Customer orders (header level) |
| `lineitem.csv` | ~120K   | Individual product lines within each order (the fact table) |

Format: comma-delimited, header row, standard TPC-H column names (`l_orderkey`,
`o_orderkey`, …).

## How the tables relate

```
region ─< nation ─< customer ─< orders ─< lineitem
                 └< supplier ──────────────┘  (also -> part)
part ──< partsupp >── supplier
part ───────────────< lineitem
```

- `lineitem` is the **fact table** — where the money lives
  (`l_extendedprice`, `l_discount`, `l_quantity`). Revenue is typically
  `l_extendedprice * (1 - l_discount)`.
- `orders.o_totalprice` is the order-level total; `orders.o_orderdate` drives time analysis.
- Slice sales by customer / nation / region (via `orders`) or by part / supplier (via `lineitem`).

## Column reference

See **[data-dictionary.md](data-dictionary.md)** for the full per-column reference —
name, type, description, keys, and allowed values for every table of all five datasets.

## Regenerating at a different size (optional)

You do **not** need to do this to use the kit — the CSVs are already here. Only regenerate
if you want a bigger or smaller dataset. The data was generated with DuckDB's built-in
TPC-H generator (no compiler needed):

```bash
pip install duckdb        # one-off, only for regenerating

python3 - <<'PY'
import duckdb, os
SF = 0.02   # scale factor: 0.01≈10MB, 0.02≈21MB, 0.05≈50MB, 0.1≈105MB, 1≈1GB
con = duckdb.connect()
con.execute("INSTALL tpch; LOAD tpch;")
con.execute(f"CALL dbgen(sf={SF})")
for t in ["region","nation","customer","supplier","part","partsupp","orders","lineitem"]:
    con.execute(f"COPY {t} TO '{t}.csv' (HEADER, DELIMITER ',')")
    print(t, con.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0], "rows")
PY
```

Run it from this `data/` folder; it overwrites the CSVs in place. Larger scale factors
produce large files — keep an eye on GitHub's 50 MB/file warning and 100 MB/file limit
(SF=0.02 stays well under both).
