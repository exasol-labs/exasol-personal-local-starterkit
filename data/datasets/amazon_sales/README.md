# amazon_sales - what sells online, and which orders get cancelled

**128,975 order lines of one fashion seller on Amazon.in**, March 31 to June
29 2022: the order and its status, how it was fulfilled and shipped, the
product (style, SKU, category, size), quantity and amount in rupees, and the
city and state it went to. 18,332 lines (14.2%) were cancelled.

```bash
exakit data-load amazon_sales
```

It loads into the `AMAZON` schema in under a minute (22 MB of CSV). Both
personas use it: the Data Scientist asks what sells and where, the ML Engineer
trains a model of which orders get cancelled.

## Tables

| Table | Rows | One row is |
|---|---:|---|
| `AMAZON.ORDER_LINES` | 128,975 | one product line of an order |

## Data dictionary

`ORDER_LINES`

| Column | Type | Meaning |
|---|---|---|
| `ORDER_LINE_ID` | DECIMAL(6,0) | row number in the source, from 1 (primary key) |
| `ORDER_ID` | VARCHAR(19) | Amazon order number; an order can have several lines |
| `ORDER_DATE` | DATE | day the order was placed |
| `STATUS` | VARCHAR(30) | `Shipped`, `Cancelled`, `Shipped - Delivered to Buyer` and ten more |
| `FULFILMENT` | VARCHAR(8) | `Amazon` or `Merchant` |
| `SALES_CHANNEL` | VARCHAR(10) | `Amazon.in` or `Non-Amazon` |
| `SHIP_SERVICE_LEVEL` | VARCHAR(9) | `Expedited` or `Standard` |
| `STYLE_CODE` | VARCHAR(8) | the seller's style code (`Style` in the source; STYLE is a reserved word) |
| `SKU` | VARCHAR(30) | stock keeping unit: style, colour and size |
| `CATEGORY` | VARCHAR(13) | `Set`, `kurta`, `Western Dress`, `Top` and five more |
| `SIZE` | VARCHAR(4) | `XS` to `6XL`, or `Free` |
| `ASIN` | VARCHAR(10) | Amazon's product number |
| `COURIER_STATUS` | VARCHAR(9) | `Shipped`, `Unshipped`, `Cancelled`, or NULL - **not a feature** |
| `QTY` | DECIMAL(3,0) | units ordered; 0 on most cancelled lines - **not a feature** |
| `CURRENCY` | VARCHAR(3) | `INR`, or NULL with the amount |
| `AMOUNT` | DECIMAL(9,2) | the line's amount in rupees; NULL for some cancelled lines |
| `SHIP_CITY` | VARCHAR(50) | city shipped to, upper case |
| `SHIP_STATE` | VARCHAR(25) | Indian state shipped to, upper case |
| `SHIP_POSTAL_CODE` | VARCHAR(6) | PIN code shipped to |
| `SHIP_COUNTRY` | VARCHAR(2) | `IN` |
| `HAS_PROMOTION` | DECIMAL(1,0) | 1 when the line carried a promotion |
| `IS_B2B` | DECIMAL(1,0) | 1 when the buyer is a business |
| `FULFILLED_BY` | VARCHAR(9) | `Easy Ship` for merchant-shipped lines, else NULL |
| `CANCELLED` | DECIMAL(1,0) | 1 when the order was cancelled - **the label** |

`STATUS`, `COURIER_STATUS`, `QTY` and `AMOUNT` all change once an order is
cancelled, so a model that uses them only learns the answer it was given.
Leave them out of features; the notebooks do (they build features from the
date, category and state only).

## The descriptor

[`descriptor.yaml`](descriptor.yaml) gives every column its role with the
evidence that chose it, and names the columns the persona notebooks use:

| Slot | Column | Why |
|---|---|---|
| key | `ORDER_LINE_ID` | one row per order line |
| time | `ORDER_DATE` | when the order was placed |
| target | `CANCELLED` | the outcome a model predicts |
| category | `CATEGORY` | the grouping to compare (not `STATUS`: that is the answer) |
| entity | `SHIP_STATE` | where the order went |
| text | - | empty: the source has no free text |

## Example questions

[`examples.sql`](examples.sql) has thirteen queries, each runnable as it stands:
cancellations overall, by who ships, by category and with promotions; revenue
by category, state, style and week; sizes, statuses, shipping speed, business
buyers and multi-line orders.

## Source, terms and reproducibility

- **Source:** "Amazon Sale Report", a CSV published on Kaggle. The exact page
  it came from was not recorded; the manifest links a Kaggle search for its
  title.
- **Terms:** not confirmed (`terms.confirmed` is false in the manifest): check
  the Kaggle page's licence before redistributing it.
- **Rebuild:** `python3 tools/datasets/amazon_sales.py "<the CSV>"` rewrites
  the CSV and the manifest; the same file gives the same CSV.
- **Transformations:** columns named in SQL style (`Style` as `STYLE_CODE`), dates as ISO (the source
  writes MM-DD-YY), postal codes without a trailing `.0`, True/False as 1/0,
  city and state upper case, a `CANCELLED` flag from the status. Left out: an
  empty column (`Unnamed: 22`) and the promotion IDs (internal codes up to
  2,300 characters), kept as `HAS_PROMOTION`.

## Download

The CSV is in this folder in the repository, but not in the kit archive the
installer downloads: `exakit data-load amazon_sales` fetches it as one
release asset, `amazon_sales-<snapshot>.tar.gz`, whose SHA-256, size and URL
are in [`manifest.json`](manifest.json) (`asset`), checks it and caches it
under `~/.exasol-starter-kit/cache/datasets/amazon_sales/`. Offline, point
`EXAKIT_DATASETS_MIRROR` at a folder (or an `https://` URL) holding the archive.
`python3 tools/datasets/package.py amazon_sales` rebuilds the archive and the
manifest's `asset` block.
