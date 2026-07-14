# Data dictionary — sample dataset (TPC-H, SF=0.02)

Reference for every table and column in this folder. Use it to write correct SQL
(and to ground an AI assistant) without guessing what a column means.

**Notes on the files**
- CSV, comma-delimited, one header row. Headers are UPPERCASE TPC-H column names, so the loaded
  tables have uppercase columns that plain unquoted SQL resolves (see the SQL notes at the end).
- Fields containing a comma are double-quoted (e.g. `"Customer#000000001"`, comment text).
- CSV itself is untyped text; the *logical* types below are what the columns represent
  (declared by `data/datasets/tpch/01_create_schema.sql`). Money is `DECIMAL(15,2)`,
  dates are `DATE` (`YYYY-MM-DD`).
- Loaded by `exakit data-load` (or `setup/load-data.sh`) into schema `TPCH`, one table per file
  (`lineitem.csv` → `TPCH.LINEITEM`).

## Relationships & keys

```
region 1─* nation 1─* customer 1─* orders 1─* lineitem
                 1─* supplier
part 1─* partsupp *─1 supplier
part 1─* lineitem *─1 supplier
```

- `nation.n_regionkey` → `region.r_regionkey`
- `customer.c_nationkey` → `nation.n_nationkey`
- `supplier.s_nationkey` → `nation.n_nationkey`
- `partsupp.ps_partkey` → `part.p_partkey`, `partsupp.ps_suppkey` → `supplier.s_suppkey`
- `orders.o_custkey` → `customer.c_custkey`
- `lineitem.l_orderkey` → `orders.o_orderkey`
- `lineitem.l_partkey` → `part.p_partkey`, `lineitem.l_suppkey` → `supplier.s_suppkey`
- `(lineitem.l_partkey, l_suppkey)` → `(partsupp.ps_partkey, ps_suppkey)`

**Key derived metric — revenue:** `l_extendedprice * (1 - l_discount)` (per line item).
`l_extendedprice` already equals `l_quantity * part price`, so revenue applies the discount
but not tax. Order-level total is `orders.o_totalprice`.

---

## region  (5 rows)
Grain: one geographic region. **PK:** `r_regionkey`.

| Column | Type | Description | Example |
|---|---|---|---|
| r_regionkey | INTEGER | Region id (PK) | 0 |
| r_name | VARCHAR | Region name | AFRICA, AMERICA, ASIA, EUROPE, MIDDLE EAST |
| r_comment | VARCHAR | Free-text note | — |

## nation  (25 rows)
Grain: one nation, belonging to a region. **PK:** `n_nationkey`. **FK:** `n_regionkey`→region.

| Column | Type | Description | Example |
|---|---|---|---|
| n_nationkey | INTEGER | Nation id (PK) | 15 |
| n_name | VARCHAR | Nation name | UNITED STATES, GERMANY, JAPAN |
| n_regionkey | INTEGER | Region this nation is in (FK) | 1 |
| n_comment | VARCHAR | Free-text note | — |

## customer  (3,000 rows)
Grain: one customer. **PK:** `c_custkey`. **FK:** `c_nationkey`→nation.

| Column | Type | Description | Example |
|---|---|---|---|
| c_custkey | INTEGER | Customer id (PK) | 1 |
| c_name | VARCHAR | Customer name | Customer#000000001 |
| c_address | VARCHAR | Street address | j5JsirBM9PsCy0O1m |
| c_nationkey | INTEGER | Customer's nation (FK) | 15 |
| c_phone | VARCHAR | Phone number | 25-989-741-2988 |
| c_acctbal | DECIMAL(15,2) | Account balance (can be negative) | 711.56 |
| c_mktsegment | VARCHAR | Market segment | AUTOMOBILE, BUILDING, FURNITURE, HOUSEHOLD, MACHINERY |
| c_comment | VARCHAR | Free-text note | — |

## supplier  (200 rows)
Grain: one supplier. **PK:** `s_suppkey`. **FK:** `s_nationkey`→nation.

| Column | Type | Description | Example |
|---|---|---|---|
| s_suppkey | INTEGER | Supplier id (PK) | 1 |
| s_name | VARCHAR | Supplier name | Supplier#000000001 |
| s_address | VARCHAR | Street address | — |
| s_nationkey | INTEGER | Supplier's nation (FK) | 17 |
| s_phone | VARCHAR | Phone number | 27-918-335-1736 |
| s_acctbal | DECIMAL(15,2) | Account balance (can be negative) | 5755.94 |
| s_comment | VARCHAR | Free-text note | — |

## part  (4,000 rows)
Grain: one sellable product. **PK:** `p_partkey`.

| Column | Type | Description | Example |
|---|---|---|---|
| p_partkey | INTEGER | Part id (PK) | 1 |
| p_name | VARCHAR | Descriptive name (color words) | goldenrod lavender spring chocolate lace |
| p_mfgr | VARCHAR | Manufacturer | Manufacturer#1 |
| p_brand | VARCHAR | Brand | Brand#13 |
| p_type | VARCHAR | Type/material/finish | PROMO BURNISHED COPPER |
| p_size | INTEGER | Size code | 7 |
| p_container | VARCHAR | Container | JUMBO PKG |
| p_retailprice | DECIMAL(15,2) | List retail price | 901.00 |
| p_comment | VARCHAR | Free-text note | — |

## partsupp  (16,000 rows)
Grain: one part supplied by one supplier. **PK:** `(ps_partkey, ps_suppkey)`.
**FK:** `ps_partkey`→part, `ps_suppkey`→supplier.

| Column | Type | Description | Example |
|---|---|---|---|
| ps_partkey | INTEGER | Part (PK/FK) | 1 |
| ps_suppkey | INTEGER | Supplier (PK/FK) | 2 |
| ps_availqty | INTEGER | Quantity this supplier has available | 3325 |
| ps_supplycost | DECIMAL(15,2) | Cost to source the part from this supplier | 771.64 |
| ps_comment | VARCHAR | Free-text note | — |

## orders  (30,000 rows)
Grain: one customer order (header). **PK:** `o_orderkey`. **FK:** `o_custkey`→customer.

| Column | Type | Description | Example / values |
|---|---|---|---|
| o_orderkey | INTEGER | Order id (PK) | 1 |
| o_custkey | INTEGER | Customer who placed it (FK) | 739 |
| o_orderstatus | VARCHAR(1) | Status flag | O = open, F = fulfilled, P = partial |
| o_totalprice | DECIMAL(15,2) | Order total (sum of its line items incl. tax) | 162079.26 |
| o_orderdate | DATE | Date the order was placed | 1996-01-02 |
| o_orderpriority | VARCHAR | Priority | 1-URGENT, 2-HIGH, 3-MEDIUM, 4-NOT SPECIFIED, 5-LOW |
| o_clerk | VARCHAR | Clerk who handled it | Clerk#000000951 |
| o_shippriority | INTEGER | Ship priority (usually 0) | 0 |
| o_comment | VARCHAR | Free-text note | — |

## lineitem  (~120K rows) — fact table
Grain: one product line within an order. **PK:** `(l_orderkey, l_linenumber)`.
**FK:** `l_orderkey`→orders, `l_partkey`→part, `l_suppkey`→supplier, `(l_partkey,l_suppkey)`→partsupp.

| Column | Type | Description | Example / values |
|---|---|---|---|
| l_orderkey | INTEGER | Order this line belongs to (FK) | 1 |
| l_partkey | INTEGER | Part sold (FK) | 3104 |
| l_suppkey | INTEGER | Supplier of the part (FK) | 170 |
| l_linenumber | INTEGER | Line number within the order (part of PK) | 1 |
| l_quantity | DECIMAL(15,2) | Units on this line | 17.00 |
| l_extendedprice | DECIMAL(15,2) | quantity × part price (pre-discount) | 17120.70 |
| l_discount | DECIMAL(15,2) | Discount fraction, 0.00–0.10 | 0.04 |
| l_tax | DECIMAL(15,2) | Tax fraction | 0.02 |
| l_returnflag | VARCHAR(1) | Return status | R = returned, A = accepted, N = none |
| l_linestatus | VARCHAR(1) | Line status | O = open, F = fulfilled |
| l_shipdate | DATE | Ship date | 1996-03-13 |
| l_commitdate | DATE | Committed delivery date | 1996-02-12 |
| l_receiptdate | DATE | Actual receipt date | 1996-03-22 |
| l_shipinstruct | VARCHAR | Shipping instruction | DELIVER IN PERSON, COLLECT COD, NONE, TAKE BACK RETURN |
| l_shipmode | VARCHAR | Ship mode | AIR, FOB, MAIL, RAIL, REG AIR, SHIP, TRUCK |
| l_comment | VARCHAR | Free-text note | — |

---

*Row counts above are for scale factor 0.02. See [README.md](README.md) to regenerate at a
different size (counts scale linearly with SF).*

## Writing SQL against this data (Exasol notes)

- **Column names are UPPERCASE** and resolve unquoted (`p_type`, `l_extendedprice` — Exasol folds
  identifiers to uppercase). No double-quoting needed.
- **Row limit:** Exasol uses `LIMIT n` (or `LIMIT n OFFSET m`) — **not** `FETCH FIRST … ROWS ONLY`
  or `TOP n`.
- **Revenue** (kit convention): `l_extendedprice * (1 - l_discount)` — net of line discount,
  excludes tax, does not subtract returns. Add `WHERE l_returnflag <> 'R'` to exclude returned lines.

See **[example-questions.md](example-questions.md)** for 14 ready-to-ask questions with validated
reference SQL you can inspect before running.
