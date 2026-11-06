# fraud_transactions - which payments were fraud, and can the data be trusted

**51,000 card and bank transactions of 4,000 users**, each with its amount,
type, the hour of day, the device, city and payment method, the user's earlier
fraud count, account age and recent activity, and whether it was fraud
(`FRAUDULENT`, 4.9% of rows).

```bash
exakit data-load fraud_transactions
```

It loads into the `FRAUD` schema in a few seconds (3.9 MB of CSV). It is the
Data Scientist's **messy** dataset, kept that way on purpose: the cleaning a
real file needs is part of the work, so it is here to be found.

## What to clean

Nothing below is fixed by the kit. A fraud rate taken straight off this table
counts some transactions twice and ignores gaps; the first four queries in
[`examples.sql`](examples.sql) find each problem.

| What | How much | What it does to a result |
|---|---:|---|
| `TRANSACTION_ID` repeats | 1,000 ids twice (881 exact copies, 119 that disagree) | counts and rates include copies; `ROW_ID` is the key for that reason |
| empty cells | about 5% each of amount, hour, device, city, payment method | averages and groupings silently drop or bucket them |
| placeholders | 1,530 `Unknown Device`, 1,530 `Invalid Method` | look like categories, mean "not known" |
| rare label | 4.9% fraud | a model that always says "not fraud" is 95% right: compare with that baseline |
| no date | only `TRANSACTION_HOUR` | no time trend, and no split by date: split at random, with a fixed seed |

## Tables

| Table | Rows | One row is |
|---|---:|---|
| `FRAUD.TRANSACTIONS` | 51,000 | one line of the source file: a transaction (1,000 appear twice) |

## Data dictionary

`TRANSACTIONS`

| Column | Type | Meaning |
|---|---|---|
| `ROW_ID` | DECIMAL(6,0) | the line of the source file (primary key, added by the kit) |
| `TRANSACTION_ID` | VARCHAR(10) | the source's transaction id, `T1` to `T50000` - not unique |
| `USER_ID` | DECIMAL(5,0) | the customer, 4,000 of them |
| `TRANSACTION_AMOUNT` | DECIMAL(10,2) | amount in US dollars; NULL in about 5% of rows |
| `TRANSACTION_TYPE` | VARCHAR(20) | ATM Withdrawal, Bank Transfer, Bill Payment, Online Purchase, POS Payment |
| `TRANSACTION_HOUR` | DECIMAL(2,0) | hour of day, 0 to 23 (there is no date); NULL in about 5% |
| `DEVICE_USED` | VARCHAR(20) | Desktop, Mobile, Tablet, or the placeholder `Unknown Device`; NULL in about 5% |
| `LOCATION` | VARCHAR(20) | the city; NULL in about 5% |
| `PREVIOUS_FRAUDULENT_TRANSACTIONS` | DECIMAL(2,0) | how many earlier transactions of the user were fraud, 0 to 4 |
| `ACCOUNT_AGE` | DECIMAL(4,0) | age of the account, 1 to 119 (the source gives no unit) |
| `TRANSACTIONS_LAST_24H` | DECIMAL(3,0) | the user's transactions in the 24 hours before this one |
| `PAYMENT_METHOD` | VARCHAR(20) | UPI, Debit Card, Credit Card, Net Banking, or the placeholder `Invalid Method`; NULL in about 5% |
| `FRAUDULENT` | DECIMAL(1,0) | 1 when the transaction was fraud: the label |

## The descriptor

[`descriptor.yaml`](descriptor.yaml) gives every column its role (key,
measure, category, ...) with the evidence that chose it, and names the
columns the persona notebooks use:

| Slot | Column | Why |
|---|---|---|
| key | `ROW_ID` | one row per transaction as the file lists them (`TRANSACTION_ID` repeats) |
| target | `FRAUDULENT` | the outcome a model predicts |
| category | `TRANSACTION_TYPE` | the grouping to compare |
| entity | `LOCATION` | where it happened, eight cities |
| time | - | empty: the source has no date, only the hour of day |
| text | - | empty: the source has no free text |

The steps that need a date or text skip on this dataset and say why; the
model splits at random with a fixed seed instead of by date.

## Example questions

[`examples.sql`](examples.sql) has twelve queries, each runnable as it stands:
four Prepare and Validate checks (repeated ids, exact copies, gaps,
placeholders), the fraud rate counted once per transaction, and fraud by type,
history, hour, amount, recent activity, city and user.

## Source, terms and reproducibility

- **Source:** "Fraud Detection Dataset", a CSV published on Kaggle. The exact
  page it came from was not recorded; the manifest links a Kaggle search for
  its title.
- **Terms:** not confirmed (`terms.confirmed` is false in the manifest): check
  the Kaggle page's licence before redistributing it.
- **Rebuild:** `python3 tools/datasets/fraud_transactions.py "<the CSV>"`
  rewrites the CSV and the manifest; the same file gives the same CSV.
- **Transformations:** columns named in SQL style, the hour as a whole number
  (the source writes `16.0`), amounts in cents (the source carries float noise
  such as `49997.799999999996`), empty cells as NULL, and a row number as the
  key; nothing is removed or corrected.

## Download

The CSV is in this folder in the repository, but not in the kit archive the
installer downloads: `exakit data-load fraud_transactions` fetches it as one
release asset, `fraud_transactions-<snapshot>.tar.gz`, whose SHA-256, size and
URL are in [`manifest.json`](manifest.json) (`asset`), checks it and caches it
under `~/.exasol-starter-kit/cache/datasets/fraud_transactions/`. Offline,
point `EXAKIT_DATASETS_MIRROR` at a folder (or an `https://` URL) holding the
archive. `python3 tools/datasets/package.py fraud_transactions` rebuilds the
archive and the manifest's `asset` block.
