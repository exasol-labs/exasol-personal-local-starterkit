# bank_marketing - who says yes to a term deposit

**45,211 clients a Portuguese bank phoned** in its term-deposit campaigns from
May 2008 to November 2010: who they are (age, job, marital status,
education), their money (yearly balance, credit in default, housing and
personal loans), how the campaign reached them, and **whether they
subscribed** - 5,289 did (11.7%).

```bash
exakit data-load bank_marketing
```

It loads into the `BANKMKT` schema in a few seconds (3.6 MB of CSV). It is the
ML Engineer persona's second banking dataset, beside the CFPB complaints: a
tabular classification problem with a real label.

## Tables

| Table | Rows | One row is |
|---|---:|---|
| `BANKMKT.BANK_CLIENTS` | 45,211 | a client the campaign phoned |

## Data dictionary

`BANK_CLIENTS`

| Column | Type | Meaning |
|---|---|---|
| `CLIENT_ID` | DECIMAL(6,0) | row number in the source file (primary key) |
| `AGE` | DECIMAL(3,0) | age in years |
| `JOB` | VARCHAR(20) | `admin.`, `blue-collar`, `management`, `technician` and eight more, or `unknown` |
| `MARITAL` | VARCHAR(10) | `married`, `single` or `divorced` (divorced includes widowed) |
| `EDUCATION` | VARCHAR(10) | `primary`, `secondary`, `tertiary` or `unknown` |
| `CREDIT_IN_DEFAULT` | DECIMAL(1,0) | 1 when the client has credit in default |
| `BALANCE` | DECIMAL(9,0) | average yearly balance, euros |
| `HOUSING_LOAN` | DECIMAL(1,0) | 1 when the client has a housing loan |
| `PERSONAL_LOAN` | DECIMAL(1,0) | 1 when the client has a personal loan |
| `CONTACT_TYPE` | VARCHAR(10) | `cellular`, `telephone` or `unknown` |
| `LAST_CONTACT_DAY` | DECIMAL(2,0) | day of the month of the last contact |
| `LAST_CONTACT_MONTH` | VARCHAR(3) | `jan` to `dec`; the source has no year |
| `CALL_DURATION` | DECIMAL(6,0) | seconds of the last call - **not a feature**: it is known only after the call |
| `CAMPAIGN_CONTACTS` | DECIMAL(3,0) | contacts in this campaign, the last one included |
| `DAYS_SINCE_PREVIOUS` | DECIMAL(4,0) | days since a previous campaign's contact; -1 when never contacted |
| `PREVIOUS_CONTACTS` | DECIMAL(4,0) | contacts before this campaign |
| `PREVIOUS_OUTCOME` | VARCHAR(10) | `success`, `failure`, `other` or `unknown` |
| `SUBSCRIBED` | DECIMAL(1,0) | 1 when the client subscribed a term deposit - **the label** |

`CALL_DURATION` is the classic trap of this dataset: a long call almost
always means a yes, but the length is known only once the call is over, so a
model that uses it cannot help decide whom to call. Leave it out of features.

## The descriptor

[`descriptor.yaml`](descriptor.yaml) gives every column its role (key, measure,
category, flag, ...) with the evidence that chose it, and names the columns the
persona notebooks use:

| Slot | Column | Why |
|---|---|---|
| key | `CLIENT_ID` | one row per client |
| target | `SUBSCRIBED` | the outcome a model predicts |
| category | `JOB` | the grouping to compare |
| entity | - | empty: no column has more than 20 values to name who a row is |
| time | - | empty: the source has the day and month of the last contact, not the year |
| text | - | empty: the source has no free text |

The steps that need a time, text or entity column skip on this dataset and say why.

## Example questions

[`examples.sql`](examples.sql) has eleven queries, each runnable as it stands:
the subscription rate overall and by job, age band, previous outcome, month,
number of contacts, loans, balance, education and marital status, and contact
channel, plus the call-duration leak.

## Source, terms and reproducibility

- **Source:** S. Moro, P. Rita and P. Cortez (2014), *Bank Marketing*, UCI
  Machine Learning Repository, https://doi.org/10.24432/C5K306 (the
  `bank-full.csv` file).
- **Terms:** CC BY 4.0 - free to copy, change and redistribute with that
  attribution (https://creativecommons.org/licenses/by/4.0/). The owner still
  confirms that the kit may ship it (`terms.confirmed` in the manifest).
- **Rebuild:** `python3 tools/datasets/bank_marketing.py` downloads the UCI
  archive again (or `python3 tools/datasets/bank_marketing.py <zip>` reads a
  copy you have) and rewrites the CSV and the manifest; the same file gives the
  same CSV.
- **Transformations:** columns renamed in plain words (`default` is an SQL
  keyword), yes/no as 1/0, a row number as the key; values are unchanged.

## Download

The CSV is in this folder in the repository, but not in the kit archive the
installer downloads: `exakit data-load bank_marketing` fetches it as one
release asset, `bank_marketing-<snapshot>.tar.gz`, whose SHA-256, size and URL
are in [`manifest.json`](manifest.json) (`asset`), checks it and caches it
under `~/.exasol-starter-kit/cache/datasets/bank_marketing/`. Offline, point
`EXAKIT_DATASETS_MIRROR` at a folder (or an `https://` URL) holding the archive.
`python3 tools/datasets/package.py bank_marketing` rebuilds the archive and the
manifest's `asset` block.
