# Sample data

This folder holds the kit's **bundled datasets** — nothing to install, everything is
committed to the repo. Each dataset is a self-contained folder under
[`datasets/`](datasets/):

```
datasets/<id>/
  dataset.conf          # id, menu label, marker tables (loaded-detection)
  01_create_schema.sql  # exact types + primary keys (optional — exapump can
                        # infer and create tables from bare CSVs)
  data/*.csv            # bulk files: one table per file, named after the file
  02_load_data.sql      # optional transform / SQL-generated data
  03_verify_setup.sql   # post-load checks — a FAIL row blocks "loaded"
```

Each dataset loads into its **own schema** (`schema=` in `dataset.conf`, default the id
uppercased). The read-only MCP user has database-wide read (`USE ANY SCHEMA` + `SELECT ANY
TABLE`), so the AI client sees every schema — these datasets and anything you add later —
without a per-schema grant. The `exakit data-load` menu discovers datasets from these
folders and only offers ones **not already in the database** (verified against the marker
tables, not just a manifest flag).

| Dataset | Schema | Contents |
|---|---|---|
| [`datasets/tpch/`](datasets/tpch/) | `TPCH` | TPC-H retail benchmark (below) — the original sample |
| [`datasets/energy/`](datasets/energy/) | `ENERGY` | 50 smart meters + 108,000 hourly readings (SQL-generated time series) |
| [`datasets/weather/`](datasets/weather/) | `WEATHER` | 10 European cities, ~11k days of daily weather (2023–2025) |

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
name, type, description, keys, and allowed values for every table.

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
