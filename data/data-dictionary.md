# Data dictionary — the nine bundled datasets

TPCH (TPC-H at SF=0.02), ENERGY, WEATHER, ESOPHAGEAL (`esophageal_posts`), BANKING
(`banking_complaints`), BANKMKT (`bank_marketing`), ADE (`ade_corpus`), PUBMED
(`pubmed_abstracts`) and MEDSIGS (`medication_sigs`). Each loads into its own schema; there are no joins across schemas.

> The same descriptions ship **inside the database** as table and column comments
> (`SYS.EXA_ALL_TABLES.TABLE_COMMENT`, `SYS.EXA_ALL_COLUMNS.COLUMN_COMMENT`) and are
> readable by the read-only MCP user, so an agent never needs this file to learn the
> shape of the data. This file adds the narrative: keys, joins and conventions.

Reference for every table and column in this folder. Use it to write correct SQL
(and to ground an AI assistant) without guessing what a column means. The six downloaded
datasets (ESOPHAGEAL, BANKING, BANKMKT, ADE, PUBMED, MEDSIGS) also have a README of their own with the source, the
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

## ESOPHAGEAL — posts about esophageal cancer (schema `ESOPHAGEAL`, dataset id `esophageal_posts`)

40,987 public posts about esophageal cancer from January 2018 to September 2022 - the web
(blogs, forums), Twitter, print and TV - from a social-listening export, **de-identified**: no
person, account or location below the country (what was removed and why:
[datasets/esophageal_posts/README.md](datasets/esophageal_posts/README.md)). Descriptor slots:
`POST_ID` (key), `CREATED_TIME` (time), `MESSAGE` (text), `IS_NEGATIVE` (target),
`SOCIAL_NETWORK` (category), `SOURCE_DOMAIN` (entity).

### ESOPHAGEAL_POSTS  (40,987 rows) — fact table
Grain: one post. **PK:** `POST_ID`.

| Column | Type | Description | Example / values |
|---|---|---|---|
| POST_ID | DECIMAL(9,0) | Post number in time order (PK); not the source's id | 1 |
| CREATED_TIME | TIMESTAMP | When it was published, 2018-01-16 to 2022-09-30 | 2022-09-30 07:44:42 |
| SOCIAL_NETWORK | VARCHAR(20) | Where it was published | WEB (19,652), TWITTER (15,487), PRINT (3,588), TV (2,252) |
| MESSAGE_TYPE | VARCHAR(40) | Kind of post (13 distinct) | Blog Post, Twitter Update, Forums, Twitter Reply |
| IS_REPLY | DECIMAL(1,0) | 1 when it answers another post (877) | 0 |
| LANGUAGE | VARCHAR(40) | Language (29 distinct) | English (40,391) |
| COUNTRY | VARCHAR(60) | Country the listening tool assigned (7 distinct) | United States, United Kingdom |
| SOURCE_DOMAIN | VARCHAR(100) | Website, when 10 or more posts share it; NULL otherwise | community.macmillan.org.uk |
| MEDIA_TYPES | VARCHAR(300) | Media attached, comma-separated | LINK, PHOTO, VIDEO |
| CLIENT_APP | VARCHAR(60) | App a tweet was made with, when 10 or more posts share it | Twitter for iPhone |
| RETWEETS | DECIMAL(9,0) | Times shared | 0 |
| FAVORITES | DECIMAL(9,0) | Times liked | 0 |
| SENTIMENT | VARCHAR(10) | The listening tool's score | NEUTRAL (29,941), NEGATIVE (6,466), POSITIVE (4,580) |
| IS_NEGATIVE | DECIMAL(1,0) | 1 when SENTIMENT is NEGATIVE (15.8%) — **the label** | 0 |
| TITLE | VARCHAR(300) | Title of a blog post, article or thread; NULL for tweets | Oesophageal cancer |
| MESSAGE | VARCHAR(1000) | The text, cut at 1,000 characters; @handles, links and e-mails replaced | Hey, that's great news ... |

Typical questions: negative share by network, kind of post or website, posts per quarter, what
gets shared, treatment words in the text. The label is the listening tool's sentiment, not a
person's judgement.

## BANKMKT — bank marketing (schema `BANKMKT`, dataset id `bank_marketing`)

45,211 clients a Portuguese bank phoned in its term-deposit campaigns, May 2008 to November 2010
(Moro, Rita and Cortez 2014, UCI, CC BY 4.0;
[datasets/bank_marketing/README.md](datasets/bank_marketing/README.md)). Descriptor slots:
`CLIENT_ID` (key), `SUBSCRIBED` (target), `JOB` (category); no time column (the source has no
year), no text and no entity.

### BANK_CLIENTS  (45,211 rows) — fact table
Grain: one client. **PK:** `CLIENT_ID`.

| Column | Type | Description | Example / values |
|---|---|---|---|
| CLIENT_ID | DECIMAL(6,0) | Row number in the source file (PK) | 1 |
| AGE | DECIMAL(3,0) | Age in years, 18 to 95 | 58 |
| JOB | VARCHAR(20) | Kind of job (12 distinct) | management, blue-collar, technician |
| MARITAL | VARCHAR(10) | Marital status | married, single, divorced |
| EDUCATION | VARCHAR(10) | Education | primary, secondary, tertiary, unknown |
| CREDIT_IN_DEFAULT | DECIMAL(1,0) | 1 when the client has credit in default | 0 |
| BALANCE | DECIMAL(9,0) | Average yearly balance, euros | 2143 |
| HOUSING_LOAN | DECIMAL(1,0) | 1 with a housing loan | 1 |
| PERSONAL_LOAN | DECIMAL(1,0) | 1 with a personal loan | 0 |
| CONTACT_TYPE | VARCHAR(10) | How the client was reached | cellular, telephone, unknown |
| LAST_CONTACT_DAY | DECIMAL(2,0) | Day of the month of the last contact | 5 |
| LAST_CONTACT_MONTH | VARCHAR(3) | Month of the last contact (no year in the source) | may |
| CALL_DURATION | DECIMAL(6,0) | Seconds of the last call - known only after the call: **not a feature** | 261 |
| CAMPAIGN_CONTACTS | DECIMAL(3,0) | Contacts in this campaign | 1 |
| DAYS_SINCE_PREVIOUS | DECIMAL(4,0) | Days since a previous campaign's contact; -1 never | -1 |
| PREVIOUS_CONTACTS | DECIMAL(4,0) | Contacts before this campaign | 0 |
| PREVIOUS_OUTCOME | VARCHAR(10) | Outcome of the previous campaign | success, failure, other, unknown |
| SUBSCRIBED | DECIMAL(1,0) | 1 when the client subscribed (5,289, 11.7%) — **the label** | 0 |

Typical questions: subscription rate by job, age band, previous outcome, month or number of
contacts - and why `CALL_DURATION` must stay out of a model.

## BANKING — consumer complaints (schema `BANKING`, dataset id `banking_complaints`)

214,742 complaints about credit cards, mortgages and checking or savings accounts that the U.S.
Consumer Financial Protection Bureau received from October 2025 to September 2026, every one closed
(from the full export of 2026-11-02).
The CFPB no longer publishes complaint narratives, so the text is short (issue, sub-issue,
public response). Source and terms: [datasets/banking_complaints/README.md](datasets/banking_complaints/README.md).
Descriptor slots: `COMPLAINT_ID` (key), `DATE_RECEIVED` (time), `MONETARY_RELIEF` (target),
`PRODUCT` (category), `COMPANY` (entity); no text slot, since the CFPB no longer publishes
narratives.

```
banking_complaints 1─1 banking_responses   (the label's source; never a feature)
```

### BANKING_COMPLAINTS  (214,742 rows) — fact table
Grain: one complaint. **PK:** `COMPLAINT_ID`.

| Column | Type | Description | Example / values |
|---|---|---|---|
| COMPLAINT_ID | DECIMAL(12,0) | CFPB complaint id (PK) | 16258358 |
| DATE_RECEIVED | DATE | When the CFPB received it, 2025-10-01 to 2026-09-30 | 2025-10-01 |
| DATE_SENT_TO_COMPANY | DATE | When the CFPB sent it to the company | 2025-10-01 |
| PRODUCT | VARCHAR(60) | Product | Credit card (94,705), Checking or savings account (87,332), Mortgage (32,705) |
| SUB_PRODUCT | VARCHAR(100) | Sub-product the consumer chose (14 distinct) | General-purpose credit card or charge card |
| ISSUE | VARCHAR(120) | Issue the consumer chose (24 distinct) | Managing an account |
| SUB_ISSUE | VARCHAR(200) | Sub-issue (106 distinct); NULL for 169 | Deposits and withdrawals |
| COMPANY | VARCHAR(200) | Company complained about (1,394 distinct) | CAPITAL ONE FINANCIAL CORPORATION |
| CONSUMER_STATE | VARCHAR(2) | Consumer's U.S. state or territory, two letters; NULL for 1,627 | TX |
| SUBMITTED_VIA | VARCHAR(20) | Channel | Web, Phone, Referral, Postal mail |
| TAGS | VARCHAR(40) | Consumer's own tags; NULL for most | Servicemember, Older American, Older American, Servicemember |
| TIMELY | DECIMAL(1,0) | 1 when the company answered in time (3,111 did not) | 1 |
| MONETARY_RELIEF | DECIMAL(1,0) | 1 when closed with monetary relief (26,996, 12.6%), else 0 — **the label** | 0 |
| COMPANY_PUBLIC_RESPONSE | VARCHAR(300) | Company's optional public response, one of ten set phrases; NULL for 55% | Company believes it acted appropriately as authorized by contract or law |

### BANKING_RESPONSES  (214,742 rows)
Grain: one complaint's closing. **PK:** `COMPLAINT_ID` (FK → `BANKING_COMPLAINTS`, documented,
not enforced). The label is derived from it: read it, never use it as a feature.

| Column | Type | Description | Values |
|---|---|---|---|
| COMPLAINT_ID | DECIMAL(12,0) | Complaint (PK, FK) | 16258358 |
| COMPANY_RESPONSE | VARCHAR(60) | How the company closed it | Closed with explanation (170,588), Closed with non-monetary relief (16,093), Closed with monetary relief (26,996), Untimely response (1,065) |

Typical questions: relief rate by product or company, the issues that pay, complaints per
day, how fast companies get the complaint.

## ADE — adverse drug effects in PubMed sentences (schema `ADE`, dataset id `ade_corpus`)

20,960 sentences from PubMed case reports, each annotated for an adverse drug effect
(ADE-Corpus-V2, Gurulingappa et al., 2012): 4,272 report one (20.4%). Source and terms:
[datasets/ade_corpus/README.md](datasets/ade_corpus/README.md). Descriptor slots:
`SENTENCE_ID` (key), `SENTENCE` (text), `HAS_ADE` (target); no time, category or entity.

```
ade_sentences 1─n ade_drug_effects   (only for HAS_ADE = 1: never a feature for the label)
ade_sentences 1─n ade_drug_doses
```

### ADE_SENTENCES  (20,960 rows) — fact table
Grain: one sentence. **PK:** `SENTENCE_ID`.

| Column | Type | Description | Example / values |
|---|---|---|---|
| SENTENCE_ID | DECIMAL(6,0) | Sentence id (PK) | 1 |
| PUBMED_ID | DECIMAL(9,0) | PubMed id of the article (2,972 articles) | 10030778 |
| SENTENCE | VARCHAR(1000) | The sentence, as published (avg 126 chars) | Intravenous azithromycin-induced ototoxicity. |
| HAS_ADE | DECIMAL(1,0) | 1 when the sentence reports an adverse drug effect (4,272), else 0 — **the label** | 1 |

### ADE_DRUG_EFFECTS  (6,633 rows)
Grain: one drug and adverse effect a sentence names. **PK:** `PAIR_ID`; `SENTENCE_ID` → `ADE_SENTENCES`.

| Column | Type | Description | Example / values |
|---|---|---|---|
| PAIR_ID | DECIMAL(6,0) | Pair id (PK) | 1 |
| SENTENCE_ID | DECIMAL(6,0) | The sentence (FK) | 1 |
| DRUG | VARCHAR(100) | Drug, as written (1,318 distinct) | azithromycin |
| ADVERSE_EFFECT | VARCHAR(200) | Adverse effect, as written (3,340 distinct) | ototoxicity |

### ADE_DRUG_DOSES  (269 rows)
Grain: one drug and dose a sentence names. **PK:** `PAIR_ID`; `SENTENCE_ID` → `ADE_SENTENCES`.

| Column | Type | Description | Example / values |
|---|---|---|---|
| PAIR_ID | DECIMAL(6,0) | Pair id (PK) | 1 |
| SENTENCE_ID | DECIMAL(6,0) | The sentence (FK) | 20 |
| DRUG | VARCHAR(100) | Drug, as written | methotrexate |
| DOSE | VARCHAR(100) | Dose, as written | 1500 mg/m2 |

Typical questions: which drugs and effects come up most, what a classifier on `SENTENCE`
learns for `HAS_ADE`, which doses go with which effects.

## PUBMED — clinical-study abstracts (schema `PUBMED`, dataset id `pubmed_abstracts`)

1,409 PubMed abstracts of clinical studies, for medical text extraction. Source and terms:
[datasets/pubmed_abstracts/README.md](datasets/pubmed_abstracts/README.md). No descriptor ships:
describe it yourself (`exakit describe PUBMED.PUBMED_ABSTRACTS`).

### PUBMED_ABSTRACTS  (1,409 rows) — fact table
Grain: one abstract. **PK:** `ABSTRACT_ID`.

| Column | Type | Description | Example / values |
|---|---|---|---|
| ABSTRACT_ID | DECIMAL(5,0) | Abstract id (PK) | 1 |
| FIRST_SECTION | VARCHAR(40) | Opening heading; NULL for an unstructured abstract (660) | BACKGROUND, OBJECTIVE, ... |
| WORD_COUNT | DECIMAL(5,0) | Words in the abstract (median 235) | 243 |
| ABSTRACT_TEXT | VARCHAR(8000) | The abstract, as published | BACKGROUND: Interferon beta-1a ... |

## MEDSIGS — prescription directions (schema `MEDSIGS`, dataset id `medication_sigs`)

50 prescription directions as prescribers write them. Source and terms:
[datasets/medication_sigs/README.md](datasets/medication_sigs/README.md). No descriptor ships.

### MEDICATION_SIGS  (50 rows)
Grain: one direction. **PK:** `SIG_ID`.

| Column | Type | Description | Example / values |
|---|---|---|---|
| SIG_ID | DECIMAL(4,0) | Direction id (PK) | 1 |
| WORD_COUNT | DECIMAL(3,0) | Words in the direction (1 to 18) | 6 |
| SIG_TEXT | VARCHAR(300) | The direction, as written | 1 cap(s) po tid,x7 day(s) |

## Writing SQL against this data (Exasol notes)

- **Column names are UPPERCASE** and resolve unquoted (`p_type`, `l_extendedprice` — Exasol folds
  identifiers to uppercase). No double-quoting needed.
- **Upper-case names everywhere:** every bundled table and column is upper-case
  (`ESOPHAGEAL.ESOPHAGEAL_POSTS.MESSAGE`), so unquoted SQL resolves it.
- **0/1 labels:** `IS_NEGATIVE`, `MONETARY_RELIEF` and `SUBSCRIBED` are
  `DECIMAL(1,0)`, so `AVG(label)` is the rate and `SUM(label)` the count.
- **Row limit:** Exasol uses `LIMIT n` (or `LIMIT n OFFSET m`) — **not** `FETCH FIRST … ROWS ONLY`
  or `TOP n`.
- **Revenue** (kit convention): `l_extendedprice * (1 - l_discount)` — net of line discount,
  excludes tax, does not subtract returns. Add `WHERE l_returnflag <> 'R'` to exclude returned lines.

See **[example-questions.md](example-questions.md)** for 14 ready-to-ask TPC-H questions with
validated reference SQL you can inspect before running. ESOPHAGEAL, BANKING and BANKMKT each ship at least
ten runnable example queries in `datasets/<id>/examples.sql`.
