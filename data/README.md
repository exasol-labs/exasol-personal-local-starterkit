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

The kit offers five datasets:

| Dataset | Schema | Contents |
|---|---|---|
| [`datasets/tpch/`](datasets/tpch/) | `TPCH` | TPC-H retail benchmark (below) — the original sample |
| [`datasets/energy/`](datasets/energy/) | `ENERGY` | 50 smart meters + 108,000 hourly readings (SQL-generated time series) |
| [`datasets/weather/`](datasets/weather/) | `WEATHER` | 10 European cities, ~11k days of daily weather (2023–2025) |
| [`datasets/pharma_trials/`](datasets/pharma_trials/) | `PHARMA` | 5,169 industry Phase 2/3 trials from ClinicalTrials.gov (started 2016-2018), with a label (terminated early), the brief summary and eligibility criteria as text, and tables of sponsors and collaborators, conditions, interventions and stop reasons; 12.8 MB of CSV, a 3.9 MB download ([README](datasets/pharma_trials/README.md)) |
| [`datasets/banking_complaints/`](datasets/banking_complaints/) | `BANKING` | 6,754 CFPB consumer complaints about cards, mortgages and accounts (1-14 January 2025), with a label (monetary relief) and the company responses apart; 1.9 MB of CSV, a 0.1 MB download ([README](datasets/banking_complaints/README.md)) |

The first three are the kit's own samples: they ship inside the kit and are what a kit
without a persona loads (`default=yes` in their `dataset.conf`). The other two are the
*reference datasets* the AI Scientist and ML Engineer personas load: public data with a
`README.md` (source, terms, data dictionary), a `manifest.json` (source query, terms,
snapshot date, rows and SHA-256 of every CSV, and the release asset they ship as) and a
descriptor; the builders that fetch them again live in [`tools/datasets/`](../tools/datasets/).
Every table and column has a `COMMENT` in its `01_create_schema.sql`, so the database itself
describes the data; the narrative and the join map for all five are in
[data-dictionary.md](data-dictionary.md).

## Reference datasets

`pharma_trials` and `banking_complaints` are *reference datasets*. Each folder holds:

| File | What it is | Checked by `tools/dataset_check.py` |
|---|---|---|
| `descriptor.yaml` | which column plays which role - [the semantic layer](#the-descriptor-the-semantic-layer) | it validates, and every column it names is in `01_create_schema.sql` |
| `manifest.json` | source and query, terms (and whether redistribution is confirmed), snapshot date, rows and SHA-256 of every CSV, the release asset | every field is there, the files match the CSVs, the asset is the archive these CSVs make |
| `README.md` | what the data is, the source and terms, a **Data dictionary** section | the data dictionary names every table and column |
| `examples.sql` | at least ten example questions, each a `--` comment above its reference SQL | ten or more, each a read-only `SELECT` on the dataset's schema with its question |

Without `--offline` the check also loads the dataset and runs every example query against
it; each must return rows.

### The descriptor: the semantic layer

The notebooks and the training template never name a dataset's tables or columns. They
read a short YAML descriptor beside the data that names the **fact table** and the column
that plays each **role**, and build their SQL from those roles - so the same notebook runs
on Pharma, on Banking, on a user's own file, or on a table in a virtual schema.

| Key | Required | Value |
|---|---|---|
| `schema_version` | yes | `1` |
| `id` | yes | the dataset id: lower-case letters and digits joined by `-` or `_` (a reference dataset's is its folder name) |
| `fact_table` | yes | `SCHEMA.TABLE`, plain SQL names: the table the rows to analyse are in |
| `roles.entity` | yes | the one column naming *who* (a sponsor, a company, a customer) |
| `roles.category` | yes | the one column to group and compare by |
| `roles.date` | yes | the one column saying *when* |
| `roles.label` | yes | the one 0/1 column a model predicts |
| `roles.text` | yes | one or more free-text columns, joined in the order given |
| `source` | no | where the table lives when it is not loaded data: the alias of an external source (`exakit connect`) whose virtual schema holds `fact_table`; the notebook then says it is querying a live source |

Each role is `{table: SCHEMA.TABLE, column: NAME}`. No column may play two roles, a role
that takes one column takes exactly one, and a key the schema does not know is refused
rather than ignored; nothing is inferred - a missing role is named and the notebook stops.
The file is YAML read by a strict standard-library reader (block and inline mappings and
lists, quoted and plain scalars, comments; anchors, tags and multi-line strings are refused
with their line); a JSON descriptor reads too. The rules are in
[`tools/descriptor_rules.py`](../tools/descriptor_rules.py).

**Pharma** ([`datasets/pharma_trials/descriptor.yaml`](datasets/pharma_trials/descriptor.yaml)):

```yaml
schema_version: 1
id: pharma_trials
fact_table: PHARMA.PHARMA_TRIALS
roles:
  entity:   {table: PHARMA.PHARMA_TRIALS, column: LEAD_SPONSOR}
  category: {table: PHARMA.PHARMA_TRIALS, column: PHASE}
  date:     {table: PHARMA.PHARMA_TRIALS, column: START_DATE}
  label:    {table: PHARMA.PHARMA_TRIALS, column: TERMINATED}
  text:
    - {table: PHARMA.PHARMA_TRIALS, column: BRIEF_SUMMARY}
    - {table: PHARMA.PHARMA_TRIALS, column: ELIGIBILITY_CRITERIA}
```

**Banking** ([`datasets/banking_complaints/descriptor.yaml`](datasets/banking_complaints/descriptor.yaml)):

```yaml
schema_version: 1
id: banking_complaints
fact_table: BANKING.BANKING_COMPLAINTS
roles:
  entity:   {table: BANKING.BANKING_COMPLAINTS, column: COMPANY}
  category: {table: BANKING.BANKING_COMPLAINTS, column: PRODUCT}
  date:     {table: BANKING.BANKING_COMPLAINTS, column: DATE_RECEIVED}
  label:    {table: BANKING.BANKING_COMPLAINTS, column: MONETARY_RELIEF}
  text:
    - {table: BANKING.BANKING_COMPLAINTS, column: ISSUE}
    - {table: BANKING.BANKING_COMPLAINTS, column: SUB_ISSUE}
    - {table: BANKING.BANKING_COMPLAINTS, column: COMPANY_PUBLIC_RESPONSE}
```

**Your own file** - a CSV of support tickets with the columns `TICKET_ID`, `CUSTOMER_ID`,
`CHANNEL`, `OPENED_ON`, `ESCALATED` (0 or 1), `SUBJECT` and `BODY`, described in
`tickets.yaml` beside it and loaded into a table of your choosing:

```yaml
schema_version: 1
id: support-tickets
fact_table: MY_DATA.TICKETS
roles:
  entity:   {table: MY_DATA.TICKETS, column: CUSTOMER_ID}
  category: {table: MY_DATA.TICKETS, column: CHANNEL}
  date:     {table: MY_DATA.TICKETS, column: OPENED_ON}
  label:    {table: MY_DATA.TICKETS, column: ESCALATED}
  text:
    - {table: MY_DATA.TICKETS, column: SUBJECT}
    - {table: MY_DATA.TICKETS, column: BODY}
```

```python
from exakit_nb import load_own_file
data = load_own_file("~/Downloads/tickets.csv", "MY_DATA.TICKETS", "~/Downloads/tickets.yaml")
```

**A table in a virtual schema** - the same shape, with `source` naming the external
source's alias; `fact_table` is the table in its virtual schema:

```yaml
schema_version: 1
id: crm-orders
fact_table: VS_SALES.ORDERS
source: SALES_DB
roles:
  entity:   {table: VS_SALES.ORDERS, column: CUSTOMER_NAME}
  category: {table: VS_SALES.ORDERS, column: REGION}
  date:     {table: VS_SALES.ORDERS, column: ORDER_DATE}
  label:    {table: VS_SALES.ORDERS, column: RETURNED}
  text:     [{table: VS_SALES.ORDERS, column: ORDER_NOTE}]
```

### How a reference dataset reaches the database

The CSVs of a reference dataset are in this repository - the builders' output, readable in
review - but not in the kit archive the installer downloads (`.gitattributes`,
`export-ignore`). They ship as one **release asset** per dataset, `<id>-<snapshot>.tar.gz`,
recorded in the dataset's `manifest.json`:

```json
"asset": {
  "file": "pharma_trials-2026-10-20.tar.gz",
  "sha256": "<SHA-256 of the archive>",
  "size": 3904755,
  "tar_sha256": "<SHA-256 of the uncompressed tar: it depends on the CSVs alone>",
  "url": "https://github.com/{repo}/releases/download/datasets-pharma_trials-2026-10-20/pharma_trials-2026-10-20.tar.gz"
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
   `EXAKIT_DATASETS_REPO`, default the repository the kit was installed from. The archive
   must match the manifest's SHA-256 (a mismatch is deleted and nothing loads); every member
   must be a plain `data/<name>.csv` the manifest lists - no links, no absolute paths, no
   `..`; and every CSV must match its own digest. Only then is it cached and loaded.

The menu names the download (`Pharma clinical trials - 3.9 MB download`) while one is
needed. Offline with nothing cached, the load stops with the URL it tried and the
`EXAKIT_DATASETS_MIRROR` way out; the other datasets still load. Datasets without an asset
block (`tpch`, `energy`, `weather`) load from the kit copy, as always.

**Publishing a new snapshot:** rebuild it (`python3 tools/datasets/<id>.py`, which rewrites
the CSVs and the manifest), then `python3 tools/datasets/package.py <id>` - it writes
`dist/<id>-<snapshot>.tar.gz` and the manifest's `asset` block. The archive is
deterministic (members sorted, fixed mtime, uid and gid, gzip mtime 0): the same CSVs give
the same bytes. Upload it to the release tag in the URL (`datasets-<id>-<snapshot>`), then
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
