# walmart_sales - what a store sells, week by week

**6,435 weeks of sales from 45 Walmart stores**, February 2010 to October
2012: the week's sales, whether a holiday fell in it, and four things around
the store that week - temperature, fuel price, consumer price index and
unemployment.

```bash
exakit data-load walmart_sales
```

It loads into the `WALMART` schema in a few seconds (0.4 MB of CSV). Both
personas can use it: sales by store and season, and a model of which weeks
beat the store's usual week.

## Tables

| Table | Rows | One row is |
|---|---:|---|
| `WALMART.WEEKLY_SALES` | 6,435 | one store's sales in one week |

## Data dictionary

`WEEKLY_SALES`

| Column | Type | Meaning |
|---|---|---|
| `SALES_ID` | DECIMAL(5,0) | row number, by store then week (primary key) |
| `STORE` | DECIMAL(2,0) | store number, 1 to 45 |
| `WEEK_DATE` | DATE | the date that ends the sales week |
| `WEEKLY_SALES` | DECIMAL(12,2) | the store's sales that week, US dollars |
| `HOLIDAY_WEEK` | DECIMAL(1,0) | 1 when a holiday falls in the week (450 weeks: Super Bowl, Labor Day, Thanksgiving, Christmas) |
| `TEMPERATURE_F` | DECIMAL(5,2) | average temperature in the region, Fahrenheit |
| `FUEL_PRICE` | DECIMAL(5,3) | fuel price in the region, dollars per gallon |
| `CPI` | DECIMAL(12,7) | consumer price index |
| `UNEMPLOYMENT` | DECIMAL(6,3) | unemployment rate in the region, percent |
| `ABOVE_STORE_MEDIAN` | DECIMAL(1,0) | 1 when the week sold more than this store's median week (3,195 weeks) - **the label**, added by the kit |

## The descriptor

[`descriptor.yaml`](descriptor.yaml) gives every column its role (key,
measure, category, ...) with the evidence that chose it, and names the
columns the persona notebooks use:

| Slot | Column | Why |
|---|---|---|
| key | `SALES_ID` | one row per store and week |
| time | `WEEK_DATE` | the week the sales belong to |
| category | `STORE` | the grouping to compare |
| target | `ABOVE_STORE_MEDIAN` | the outcome a model predicts: a strong week for the store |
| entity | - | empty |
| text | - | empty: the source has no free text |

The steps that need text or an entity skip on this dataset and say why.

## Example questions

[`examples.sql`](examples.sql) has eleven queries, each runnable as it stands:
the top stores, holiday weeks, sales by month and year, unemployment and
temperature bands, strong weeks by store and month, best weeks, fuel prices
and a week-over-week change.

## Source, terms and reproducibility

- **Source:** "Walmart Data Analysis and Forcasting", a CSV published on
  Kaggle. The exact page it came from was not recorded; the manifest links a
  Kaggle search for its title.
- **Terms:** not confirmed (`terms.confirmed` is false in the manifest): check
  the Kaggle page's licence before redistributing it.
- **Rebuild:** `python3 tools/datasets/walmart_sales.py "<the CSV>"` rewrites
  the CSV and the manifest; the same file gives the same CSV.
- **Transformations:** dates as ISO (the source writes DD-MM-YYYY), columns
  named in SQL style, a row number as the key, and one added column,
  `ABOVE_STORE_MEDIAN` (from `WEEKLY_SALES`, per store); values are unchanged.

## Download

The CSV is in this folder in the repository, but not in the kit archive the
installer downloads: `exakit data-load walmart_sales` fetches it as one
release asset, `walmart_sales-<snapshot>.tar.gz`, whose SHA-256, size and URL
are in [`manifest.json`](manifest.json) (`asset`), checks it and caches it
under `~/.exasol-starter-kit/cache/datasets/walmart_sales/`. Offline, point
`EXAKIT_DATASETS_MIRROR` at a folder (or an `https://` URL) holding the archive.
`python3 tools/datasets/package.py walmart_sales` rebuilds the archive and the
manifest's `asset` block.
