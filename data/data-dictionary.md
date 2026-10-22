# Data dictionary — the five bundled datasets

TPCH (TPC-H at SF=0.02), ENERGY, WEATHER, PHARMA (`pharma_trials`) and BANKING
(`banking_complaints`). Each loads into its own schema; there are no joins across schemas.

> The same descriptions ship **inside the database** as table and column comments
> (`SYS.EXA_ALL_TABLES.TABLE_COMMENT`, `SYS.EXA_ALL_COLUMNS.COLUMN_COMMENT`) and are
> readable by the read-only MCP user, so an agent never needs this file to learn the
> shape of the data. This file adds the narrative: keys, joins and conventions.

Reference for every table and column in this folder. Use it to write correct SQL
(and to ground an AI assistant) without guessing what a column means. The two reference
datasets (PHARMA, BANKING) also have a README of their own with the source, the
terms and how the snapshot was taken; row counts here are the shipped snapshots'.

## TPCH — TPC-H retail benchmark (schema `TPCH`, dataset id `tpch`)

**Notes on the files**
- CSV, comma-delimited, one header row. Headers are UPPERCASE TPC-H column names, so the loaded
  tables have uppercase columns that plain unquoted SQL resolves (see the SQL notes at the end).
- Fields containing a comma are double-quoted (e.g. `"Customer#000000001"`, comment text).
- CSV itself is untyped text; the *logical* types below are what the columns represent
  (declared by `data/datasets/tpch/01_create_schema.sql`). Money is `DECIMAL(15,2)`,
  dates are `DATE` (`YYYY-MM-DD`).
- Loaded by `exakit data-load` (or `setup/load-data.sh`) into schema `TPCH`, one table per file
  (`lineitem.csv` → `TPCH.LINEITEM`).

### Relationships & keys

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

### region  (5 rows)
Grain: one geographic region. **PK:** `r_regionkey`.

| Column | Type | Description | Example |
|---|---|---|---|
| r_regionkey | INTEGER | Region id (PK) | 0 |
| r_name | VARCHAR | Region name | AFRICA, AMERICA, ASIA, EUROPE, MIDDLE EAST |
| r_comment | VARCHAR | Free-text note | — |

### nation  (25 rows)
Grain: one nation, belonging to a region. **PK:** `n_nationkey`. **FK:** `n_regionkey`→region.

| Column | Type | Description | Example |
|---|---|---|---|
| n_nationkey | INTEGER | Nation id (PK) | 15 |
| n_name | VARCHAR | Nation name | UNITED STATES, GERMANY, JAPAN |
| n_regionkey | INTEGER | Region this nation is in (FK) | 1 |
| n_comment | VARCHAR | Free-text note | — |

### customer  (3,000 rows)
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

### supplier  (200 rows)
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

### part  (4,000 rows)
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

### partsupp  (16,000 rows)
Grain: one part supplied by one supplier. **PK:** `(ps_partkey, ps_suppkey)`.
**FK:** `ps_partkey`→part, `ps_suppkey`→supplier.

| Column | Type | Description | Example |
|---|---|---|---|
| ps_partkey | INTEGER | Part (PK/FK) | 1 |
| ps_suppkey | INTEGER | Supplier (PK/FK) | 2 |
| ps_availqty | INTEGER | Quantity this supplier has available | 3325 |
| ps_supplycost | DECIMAL(15,2) | Cost to source the part from this supplier | 771.64 |
| ps_comment | VARCHAR | Free-text note | — |

### orders  (30,000 rows)
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

### lineitem  (~120K rows) — fact table
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

## ENERGY — smart-meter readings (schema `ENERGY`, ~108k rows)

Hourly household electricity consumption: 50 meters × 90 days × 24 hours. Loaded by
`exakit data-load` (dataset id `energy`) from `data/datasets/energy/`.

### energy_meters  (50 rows)
Grain: one smart meter per household. **PK:** `meter_id`.

| Column | Type | Description | Example |
|---|---|---|---|
| meter_id | DECIMAL(9,0) | Meter id (PK) | 1 |
| household | VARCHAR(25) | Household label the meter belongs to | HH-001 |
| city | VARCHAR(25) | City the household is in | Berlin |
| tariff | VARCHAR(10) | Tariff plan: BASIC, GREEN, or NIGHT | NIGHT |
| base_load_kwh | DECIMAL(6,3) | Typical hourly baseline consumption, kWh | 0.850 |

### energy_readings  (108,000 rows) — fact table
Grain: one reading per meter per hour. **PK:** `(meter_id, reading_ts)`. **FK:** `meter_id`→energy_meters.

| Column | Type | Description | Example |
|---|---|---|---|
| meter_id | DECIMAL(9,0) | Meter that produced the reading (FK) | 1 |
| reading_ts | TIMESTAMP(3) | Hour of the reading, one row per meter per hour | 2025-01-01 13:00:00 |
| kwh | DECIMAL(8,3) | Energy consumed in that hour, kWh | 1.204 |

Typical questions: average hourly consumption per tariff, peak hours per city, meters
whose consumption drifts from their `base_load_kwh`.

## WEATHER — daily city weather history (schema `WEATHER`, ~11k rows)

Daily observations for 10 European cities, 2023-01-01 to 2025-12-31. Loaded by
`exakit data-load` (dataset id `weather`) from `data/datasets/weather/`.

### weather_cities  (10 rows)
Grain: one city. **PK:** `city_id`.

| Column | Type | Description | Example |
|---|---|---|---|
| city_id | DECIMAL(9,0) | City id (PK) | 1 |
| city | VARCHAR(30) | City name | Berlin |
| country | VARCHAR(30) | Country the city is in | Germany |

### weather_daily  (10,960 rows) — fact table
Grain: one row per city per day. **PK:** `(city_id, w_date)`. **FK (documented, not enforced):** `city_id`→weather_cities.

| Column | Type | Description | Example |
|---|---|---|---|
| city_id | DECIMAL(9,0) | City (FK) | 1 |
| w_date | DATE | Calendar day of the observation | 2024-07-14 |
| temp_avg_c | DECIMAL(5,1) | Daily mean temperature, °C | 21.4 |
| temp_min_c | DECIMAL(5,1) | Daily minimum temperature, °C | 15.2 |
| temp_max_c | DECIMAL(5,1) | Daily maximum temperature, °C | 27.9 |
| precip_mm | DECIMAL(6,1) | Total precipitation for the day, mm | 3.2 |
| wind_kmh | DECIMAL(5,1) | Mean wind speed, km/h | 14.0 |

Typical questions: hottest month per city, rainy-day counts per year, a city's
temperature range on a given day.

## PHARMA — clinical trials (schema `PHARMA`, dataset id `pharma_trials`)

5,169 industry-sponsored, interventional Phase 2 and Phase 3 trials from ClinicalTrials.gov
that started in 2016-2018 and ended `COMPLETED` or `TERMINATED` (snapshot 2026-10-20).
Source, terms and the full story: [datasets/pharma_trials/README.md](datasets/pharma_trials/README.md).
A reference dataset: its [descriptor](datasets/pharma_trials/descriptor.yaml) names
`LEAD_SPONSOR` (entity), `PHASE` (category), `START_DATE` (date), `TERMINATED` (label) and
`BRIEF_SUMMARY` + `ELIGIBILITY_CRITERIA` (text).

```
pharma_trials 1─* pharma_sponsors        (SEQ 1 = the lead sponsor)
              1─* pharma_conditions
              1─* pharma_interventions
              1─0..1 pharma_stop_reasons (only stopped trials; gives the label away)
```

All foreign keys are `NCT_ID` → `PHARMA_TRIALS.NCT_ID` (documented, not enforced).

### PHARMA_TRIALS  (5,169 rows) — fact table
Grain: one trial. **PK:** `NCT_ID`.

| Column | Type | Description | Example / values |
|---|---|---|---|
| NCT_ID | VARCHAR(11) | ClinicalTrials.gov identifier (PK) | NCT01336660 |
| BRIEF_TITLE | VARCHAR(400) | Short title, at most 300 characters | — |
| PHASE | VARCHAR(20) | Trial phase | PHASE2, PHASE3, PHASE1/PHASE2, PHASE2/PHASE3 |
| OVERALL_STATUS | VARCHAR(12) | How the trial ended | COMPLETED (4,254), TERMINATED (915) |
| TERMINATED | DECIMAL(1,0) | 1 when terminated early, else 0 — **the label** | 0 |
| START_DATE | DATE | Start; the first of the month when only the month is published | 2017-03-01 |
| PRIMARY_COMPLETION_DATE | DATE | Primary completion, actual or as last reported | 2018-11-01 |
| ENROLLMENT | DECIMAL(9,0) | Participants enrolled; NULL for 3 trials | 56 |
| LEAD_SPONSOR | VARCHAR(200) | The company running the trial (1,575 distinct) | Novartis Pharmaceuticals |
| ALLOCATION | VARCHAR(20) | Randomisation; NULL for 12 | RANDOMIZED, NON_RANDOMIZED, NA |
| PRIMARY_PURPOSE | VARCHAR(40) | Primary purpose; NULL for 6 | TREATMENT, PREVENTION, OTHER, DIAGNOSTIC, SUPPORTIVE_CARE, BASIC_SCIENCE, ... |
| MASKING | VARCHAR(12) | Blinding; NULL for 4 | NONE, SINGLE, DOUBLE, TRIPLE, QUADRUPLE |
| HAS_RESULTS | DECIMAL(1,0) | 1 when results are posted on ClinicalTrials.gov | 1 |
| BRIEF_SUMMARY | VARCHAR(2100) | The sponsor's summary, one line; longer ones cut on a word, ending in ` …`, at most 2,000 characters | — |
| ELIGIBILITY_CRITERIA | VARCHAR(2100) | Inclusion and exclusion criteria, folded and cut the same way (present for every trial) | Inclusion Criteria: * ... |

### PHARMA_SPONSORS  (6,674 rows)
Grain: one organisation of a trial. **PK:** `(NCT_ID, SEQ)`.

| Column | Type | Description | Example / values |
|---|---|---|---|
| NCT_ID | VARCHAR(11) | Trial (FK) | NCT01336660 |
| SEQ | DECIMAL(4,0) | 1 for the lead sponsor (same name as `LEAD_SPONSOR`), then the collaborators in record order | 1 |
| SPONSOR_ROLE | VARCHAR(12) | Role | LEAD (5,169), COLLABORATOR (1,505) |
| SPONSOR_NAME | VARCHAR(200) | Organisation name as the record gives it | Instituto Bioclon S.A. de C.V. |
| SPONSOR_CLASS | VARCHAR(12) | Organisation class | INDUSTRY, OTHER, UNKNOWN, NIH, OTHER_GOV, FED, NETWORK, AMBIG, INDIV |

### PHARMA_CONDITIONS  (7,291 rows)
Grain: one condition a trial studies. **PK:** `(NCT_ID, CONDITION_NAME)`.

| Column | Type | Description | Example |
|---|---|---|---|
| NCT_ID | VARCHAR(11) | Trial (FK) | NCT01336660 |
| CONDITION_NAME | VARCHAR(200) | Condition as the sponsor wrote it, not normalised (`Age-related Macular Degeneration` and `Age-Related Macular Degeneration` both occur) | Atopic Dermatitis |

### PHARMA_INTERVENTIONS  (12,384 rows)
Grain: one intervention a trial tests. **PK:** `(NCT_ID, SEQ)`.

| Column | Type | Description | Example / values |
|---|---|---|---|
| NCT_ID | VARCHAR(11) | Trial (FK) | NCT01336660 |
| SEQ | DECIMAL(4,0) | Position in the protocol, from 1 | 1 |
| INTERVENTION_TYPE | VARCHAR(30) | Type | DRUG, BIOLOGICAL, OTHER, DEVICE, DIETARY_SUPPLEMENT, COMBINATION_PRODUCT, PROCEDURE, RADIATION, GENETIC, BEHAVIORAL, DIAGNOSTIC_TEST |
| INTERVENTION_NAME | VARCHAR(200) | Name as written (`Placebo` and `placebo` both occur) | Nivolumab |

### PHARMA_STOP_REASONS  (887 rows)
Grain: one stopped trial's reason. **PK:** `NCT_ID`. Exists only for a stopped trial, so it
**gives the label away**: read it to understand terminations, never use it as a model feature.

| Column | Type | Description | Example |
|---|---|---|---|
| NCT_ID | VARCHAR(11) | Trial (FK) | NCT02020278 |
| WHY_STOPPED | VARCHAR(600) | The sponsor's reason, at most 500 characters | Sponsor decision |

Typical questions: termination rate by phase or sponsor, the commonest conditions, placebo-
controlled share, how long trials run (`PRIMARY_COMPLETION_DATE - START_DATE`), why trials stop.

## BANKING — consumer complaints (schema `BANKING`, dataset id `banking_complaints`)

6,754 complaints about credit cards, mortgages and checking or savings accounts that the U.S.
Consumer Financial Protection Bureau received from 1 to 14 January 2025 (snapshot 2026-10-20).
The CFPB no longer publishes complaint narratives, so the text is short (issue, sub-issue,
public response). Source and terms: [datasets/banking_complaints/README.md](datasets/banking_complaints/README.md).
Descriptor roles: `COMPANY` (entity), `PRODUCT` (category), `DATE_RECEIVED` (date),
`MONETARY_RELIEF` (label), `ISSUE` + `SUB_ISSUE` + `COMPANY_PUBLIC_RESPONSE` (text).

```
banking_complaints 1─1 banking_responses   (the label's source; never a feature)
```

### BANKING_COMPLAINTS  (6,754 rows) — fact table
Grain: one complaint. **PK:** `COMPLAINT_ID`.

| Column | Type | Description | Example / values |
|---|---|---|---|
| COMPLAINT_ID | DECIMAL(12,0) | CFPB complaint id (PK) | 11333660 |
| DATE_RECEIVED | DATE | When the CFPB received it, 2025-01-01 to 2025-01-14 | 2025-01-03 |
| DATE_SENT_TO_COMPANY | DATE | When the CFPB sent it to the company | 2025-01-07 |
| PRODUCT | VARCHAR(60) | Product | Credit card (3,451), Checking or savings account (2,349), Mortgage (954) |
| SUB_PRODUCT | VARCHAR(100) | Sub-product the consumer chose (14 distinct) | General-purpose credit card or charge card |
| ISSUE | VARCHAR(120) | Issue the consumer chose (24 distinct) | Managing an account |
| SUB_ISSUE | VARCHAR(200) | Sub-issue (101 distinct); NULL for 2 | Deposits and withdrawals |
| COMPANY | VARCHAR(200) | Company complained about (324 distinct) | JPMORGAN CHASE & CO. |
| CONSUMER_STATE | VARCHAR(2) | Consumer's U.S. state or territory, two letters; NULL for 37 | TX |
| SUBMITTED_VIA | VARCHAR(20) | Channel | Web, Phone, Referral, Postal mail |
| TAGS | VARCHAR(40) | Consumer's own tags; NULL for most | Servicemember, Older American, Older American, Servicemember |
| TIMELY | DECIMAL(1,0) | 1 when the company answered in time (25 did not) | 1 |
| MONETARY_RELIEF | DECIMAL(1,0) | 1 when closed with monetary relief (801, 11.9%), else 0 — **the label** | 0 |
| COMPANY_PUBLIC_RESPONSE | VARCHAR(300) | Company's optional public response, one of nine set phrases; NULL for about half | Company believes it acted appropriately as authorized by contract or law |

### BANKING_RESPONSES  (6,754 rows)
Grain: one complaint's closing. **PK:** `COMPLAINT_ID` (FK → `BANKING_COMPLAINTS`, documented,
not enforced). The label is derived from it: read it, never use it as a feature.

| Column | Type | Description | Values |
|---|---|---|---|
| COMPLAINT_ID | DECIMAL(12,0) | Complaint (PK, FK) | 11333660 |
| COMPANY_RESPONSE | VARCHAR(60) | How the company closed it | Closed with explanation (4,922), Closed with non-monetary relief (1,026), Closed with monetary relief (801), Untimely response (5) |

Typical questions: relief rate by product or company, the issues that pay, complaints per
day, how fast companies get the complaint.

## Writing SQL against this data (Exasol notes)

- **Column names are UPPERCASE** and resolve unquoted (`p_type`, `l_extendedprice` — Exasol folds
  identifiers to uppercase). No double-quoting needed.
- **Upper-case names everywhere:** every bundled table and column is upper-case
  (`PHARMA.PHARMA_TRIALS.BRIEF_SUMMARY`), so unquoted SQL resolves it.
- **0/1 labels:** `TERMINATED` and `MONETARY_RELIEF` are
  `DECIMAL(1,0)`, so `AVG(label)` is the rate and `SUM(label)` the count.
- **Row limit:** Exasol uses `LIMIT n` (or `LIMIT n OFFSET m`) — **not** `FETCH FIRST … ROWS ONLY`
  or `TOP n`.
- **Revenue** (kit convention): `l_extendedprice * (1 - l_discount)` — net of line discount,
  excludes tax, does not subtract returns. Add `WHERE l_returnflag <> 'R'` to exclude returned lines.

See **[example-questions.md](example-questions.md)** for 14 ready-to-ask TPC-H questions with
validated reference SQL you can inspect before running. PHARMA and BANKING each ship at least
ten runnable example queries in `datasets/<id>/examples.sql`.
