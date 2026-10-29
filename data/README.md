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
*reference datasets* the Data Scientist and ML Engineer personas load: public data with a
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
on Pharma, on Banking, on a user's own file, or on a table in a virtual schema. Since
`schema_version: 2` the descriptor is also a **record**: which version it is, whether it is
a draft or approved, who owns it, when it was written and what it was approved on.

| Key | Required | Value |
|---|---|---|
| `schema_version` | yes | `2` (a `1` file still reads, see below) |
| `id` | yes | the dataset id: lower-case letters and digits joined by `-` or `_` (a reference dataset's is its folder name) |
| `fact_table` | yes | `SCHEMA.TABLE`, plain SQL names: the table the rows to analyse are in |
| `source` | no | what the data is: a dataset id (`pharma_trials`), `file:<path>` (an own file, what `load_own_file` writes) or `vs:<alias>` (the alias of an external source from `exakit connect` whose virtual schema holds `fact_table`; the notebook then says it is querying a live source and asks before rows go to a model) |
| `version` | yes | an integer from `1`; approving writes version n+1 and n stays readable |
| `status` | yes | `draft` (proposed, not yet confirmed) or `approved`; training, the question step and sharing refuse a draft, exploring prints it |
| `owner` | yes | who drafted or approved it: `kit` for a shipped descriptor, else `EXAKIT_DESCRIPTOR_OWNER` or the OS user |
| `created` | yes | when this version was written, ISO-8601 (`2026-10-27T10:12:03Z`) |
| `digest` | no | the digest of the table the descriptor was approved on (`sha256:...`), `null` until `exakit describe --approve` computes it |
| `drafted_by` | no | `profile` (`exakit describe`), `shipped` (the kit) or `user` (roles given by hand) |
| `roles.entity` | yes* | the one column naming *who* (a sponsor, a company, a customer) |
| `roles.category` | yes* | the one column to group and compare by |
| `roles.date` | yes* | the one column saying *when* |
| `roles.label` | yes* | the one 0/1 column a model predicts |
| `roles.text` | yes* | one or more free-text columns, joined in the order given |
| `evidence` | no | per role, a mapping with the numbers that chose its column (type, null rate, distinct count, date-parse rate, score, runner-up); the profiler writes it, hand-written descriptors leave it out |
| `notes` | no | per column, one line of text a model wrote about it; never decisive |
| `missing` | no | the roles no column fits, each `{role, reason}`; *such a role may be absent from `roles`, and the steps that need it skip with the reason |

`exakit describe SCHEMA.TABLE` (and `exakit.nb.describe()` in a notebook) drafts a descriptor
from a **profile** of the table - a handful of SELECTs: the column list, `COUNT(*)`, one
aggregate statement per batch of columns and one `GROUPING SETS` statement for the values of
the low-cardinality columns; a virtual table, or a regular one past 5 million rows, is
profiled on a random sample (10,000 rows unless `--sample` says otherwise) and the evidence
says so. The scoring is deterministic and offline (the same table gives the same draft, with
or without a model); roles are assigned in the order date, label, category, entity, text, a
column one role took never offered to the next; the best column takes the role, the second
best is its `runner_up`; a role whose best score is under **0.5** goes under `missing` with
the reason. All-null and constant columns are excluded first (`evidence.excluded`). A name
hint adds a little and never decides on its own.

| Role | Qualifies when | Score |
|---|---|---|
| `date` | `DATE`/`TIMESTAMP`, or text with 95%+ parseable dates (`YYYY-MM-DD`, `DD.MM.YYYY`, `MM/DD/YYYY`, `YYYY-MM-DD HH24:MI:SS`) | 0.8 for a date type, 0.7 x parse rate for text; a name saying the row's own event (start, received, created, opened...) +0.2, a follow-up (end, completion, sent, closed, due...) -0.2; 20%+ nulls -0.2; ties: the widest span, then the earlier column |
| `label` | `BOOLEAN`, or two observed 0/1 values with under 20% nulls | 0.5; a 0/1 or true/false column +0.1; a name saying an outcome (terminated, outcome, disputed, timely, churn, default...) +0.2, a state (is_, has_, flag, status) +0.1; the smallest class 5% or more +0.2, else -0.2 |
| `category` | 2-50 distinct values that repeat (distinct ratio under 0.05), under 20% nulls, not the label | 0.5; under 1% nulls +0.2; the smallest class 1% or more +0.2; 12 values or fewer +0.1; ties: a category-like column name (category, segment, product, phase, type, group, class, channel), then the earlier column |
| `entity` | text or integer, distinct ratio 0.01-0.6 (it repeats, but is not one of a few values), under 5% nulls | 0.5; a name hint (id, name, sponsor, company, customer, account...) +0.2; up to +0.3 by distinct count relative to the most distinct candidate - a unique key is no entity, it names rows |
| `text` | `VARCHAR`, in table order, every column that scores 0.5 or more | average length 40+ with values of 200+ characters +0.3, else average 30+ in a column declared 100+ wide +0.2; average 150+ +0.2; a name saying text (summary, description, criteria, issue, response, comment, note...) +0.3 |

Each role is `{table: SCHEMA.TABLE, column: NAME}`. No column may play two roles, a role
that takes one column takes exactly one, and a key the schema does not know is refused
rather than ignored; nothing is inferred - a missing role is named and the notebook stops,
unless `missing` says why no column plays it. The file is YAML read by a strict
standard-library reader (block and inline mappings and lists, quoted and plain scalars,
integers and decimals, comments; anchors, tags and multi-line strings are refused with
their line); a JSON descriptor reads too. The rules are in
[`tools/descriptor_rules.py`](../tools/descriptor_rules.py).

**Where a descriptor is read from.** `nb.dataset(conn, name)` takes, in this order: a path
(a descriptor file, or a folder holding `descriptor.yaml`); for a data file of your own,
`<name>.descriptor.yaml` beside it; for an id, the approved version in the kit's store
(`~/.exasol-starter-kit/descriptors/<id>/current` names it, the versions are `v<n>.yaml`
beside it; `EXAKIT_HOME` moves the store), then the descriptor the kit ships under
`data/datasets/<id>/`. `ds.descriptor_path` and `ds.descriptor_origin` say which was used.

**Pharma** ([`datasets/pharma_trials/descriptor.yaml`](datasets/pharma_trials/descriptor.yaml)):

```yaml
schema_version: 2
id: pharma_trials
fact_table: PHARMA.PHARMA_TRIALS
source: pharma_trials
version: 1
status: approved
owner: kit
created: 2026-10-27T00:00:00Z
drafted_by: shipped
digest: null
roles:
  entity:   {table: PHARMA.PHARMA_TRIALS, column: LEAD_SPONSOR}
  category: {table: PHARMA.PHARMA_TRIALS, column: PHASE}
  date:     {table: PHARMA.PHARMA_TRIALS, column: START_DATE}
  label:    {table: PHARMA.PHARMA_TRIALS, column: TERMINATED}
  text:
    - {table: PHARMA.PHARMA_TRIALS, column: BRIEF_SUMMARY}
    - {table: PHARMA.PHARMA_TRIALS, column: ELIGIBILITY_CRITERIA}
evidence: {}
missing: []
```

**Banking** ([`datasets/banking_complaints/descriptor.yaml`](datasets/banking_complaints/descriptor.yaml)):

```yaml
schema_version: 2
id: banking_complaints
fact_table: BANKING.BANKING_COMPLAINTS
source: banking_complaints
version: 1
status: approved
owner: kit
created: 2026-10-27T00:00:00Z
drafted_by: shipped
digest: null
roles:
  entity:   {table: BANKING.BANKING_COMPLAINTS, column: COMPANY}
  category: {table: BANKING.BANKING_COMPLAINTS, column: PRODUCT}
  date:     {table: BANKING.BANKING_COMPLAINTS, column: DATE_RECEIVED}
  label:    {table: BANKING.BANKING_COMPLAINTS, column: MONETARY_RELIEF}
  text:
    - {table: BANKING.BANKING_COMPLAINTS, column: ISSUE}
    - {table: BANKING.BANKING_COMPLAINTS, column: SUB_ISSUE}
    - {table: BANKING.BANKING_COMPLAINTS, column: COMPANY_PUBLIC_RESPONSE}
evidence: {}
missing: []
```

**Your own file** - a CSV of support tickets with the columns `TICKET_ID`, `CUSTOMER_ID`,
`CHANNEL`, `OPENED_ON`, `ESCALATED` (0 or 1), `SUBJECT` and `BODY`, described by hand in
`tickets.yaml` beside it and loaded into a table of your choosing. A hand-written
descriptor is a draft until you approve it; the profiler's `evidence` is not needed:

```yaml
schema_version: 2
id: support-tickets
fact_table: MY_DATA.TICKETS
version: 1
status: draft
owner: dana
created: 2026-10-27T10:12:03Z
drafted_by: user
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
import exakit.nb as nb
data = nb.load_own_file("~/Downloads/tickets.csv", "MY_DATA.TICKETS", "~/Downloads/tickets.yaml")
```

Given the roles as a mapping instead (`{"entity": "CUSTOMER_ID", ...}`), `load_own_file`
writes this same shape beside the file as `tickets.descriptor.yaml`, with
`source: "file:<the file's path>"`, `owner` from `EXAKIT_DESCRIPTOR_OWNER` or the OS user,
and `status: draft`.

**A table in a virtual schema** - the same shape, with `source: vs:<alias>` naming the
external source's alias; `fact_table` is the table in its virtual schema. This one was
drafted by `exakit describe`, so it carries the profiler's evidence, and no column held
parseable dates, so the `date` role is listed as missing with the reason instead:

```yaml
schema_version: 2
id: crm-orders
fact_table: VS_SALES.ORDERS
source: vs:SALES_DB
version: 2
status: approved
owner: dana
created: 2026-10-27T11:40:12Z
drafted_by: profile
digest: null
roles:
  entity:   {table: VS_SALES.ORDERS, column: CUSTOMER_NAME}
  category: {table: VS_SALES.ORDERS, column: REGION}
  label:    {table: VS_SALES.ORDERS, column: RETURNED}
  text:     [{table: VS_SALES.ORDERS, column: ORDER_NOTE}]
evidence:
  entity:   {column: CUSTOMER_NAME, type: VARCHAR, null_rate: 0.0, distinct: 812, distinct_ratio: 0.08, score: 0.91}
  category: {column: REGION, type: VARCHAR, null_rate: 0.0, distinct: 6, distinct_ratio: 0.001, score: 0.88}
  label:    {column: RETURNED, type: BOOLEAN, null_rate: 0.0, distinct: 2, score: 1.0}
  text:     {column: ORDER_NOTE, type: VARCHAR, avg_len: 143, max_len: 1920, score: 0.8}
notes:
  CUSTOMER_NAME: "The account that placed the order."
missing:
  - {role: date, reason: "no column has >=95% parseable dates"}
```

**Schema version 1.** A `schema_version: 1` descriptor (the 0.2 kit's shape: the keys
down to `roles`, and `source` as a bare source alias) still reads everywhere. It is
treated as `version: 1`, `status: approved`, `owner: kit`, `drafted_by: shipped`, with no
`digest` and no `created`; the record keys are not accepted in a version-1 file - to use
them, write `schema_version: 2`. The first approve of a version-1 file writes version 2 in
the new shape, its bare `source` alias as `vs:<alias>`.

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
