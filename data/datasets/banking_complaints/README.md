# banking_complaints - consumer complaints from the CFPB

A snapshot of **6,754 consumer complaints about credit cards, mortgages and
checking or savings accounts that the U.S. Consumer Financial Protection
Bureau received from 1 to 14 January 2025**, taken from the CFPB Consumer
Complaint Database on 2026-10-20. Every complaint is closed, so the question
"which complaints end in monetary relief?" has an answer in the data: 801 of
them (11.9%) did.

```bash
exakit data-load banking_complaints
```

It loads into the `BANKING` schema in a few seconds (1.9 MB of CSV). An installed
kit downloads the CSVs first, as one checksummed archive of 0.1 MB (see
[Download](#download)).

## No complaint narratives

The CFPB stopped publishing consumers' written narratives in 2026: neither the
API nor the bulk download carries them (checked 2026-10-20). The text columns
here are therefore short: the **issue** and **sub-issue** the consumer picked,
and the company's optional **public response**, which is one of a few set
phrases. The notebooks' text step works on them, but expect short, repetitive
text rather than prose. For long free text, use `pharma_trials`.

The public response is written when the company answers, so it could hint at
the outcome. In this snapshot it hardly does: behind each response given
ten times or more, the relief rate ranges from 0% to 16% against 12% overall
(example 11; the rarer phrases, given one to six times, are too few to read),
so the notebooks' model reads it with the other text.

## Tables

| Table | Rows | One row is |
|---|---:|---|
| `BANKING.BANKING_COMPLAINTS` | 6,754 | a complaint |
| `BANKING.BANKING_RESPONSES` | 6,754 | how the company closed it |

## Data dictionary

`BANKING_COMPLAINTS`

| Column | Type | Meaning |
|---|---|---|
| `COMPLAINT_ID` | DECIMAL(12,0) | CFPB complaint id (primary key) |
| `DATE_RECEIVED` | DATE | when the CFPB received it |
| `DATE_SENT_TO_COMPANY` | DATE | when the CFPB sent it to the company |
| `PRODUCT` | VARCHAR(60) | `Credit card`, `Mortgage` or `Checking or savings account` |
| `SUB_PRODUCT` | VARCHAR(100) | e.g. `General-purpose credit card or charge card` |
| `ISSUE` | VARCHAR(120) | the issue the consumer picked |
| `SUB_ISSUE` | VARCHAR(200) | the sub-issue; empty for 2 complaints |
| `COMPANY` | VARCHAR(200) | the company complained about (324 distinct) |
| `CONSUMER_STATE` | VARCHAR(2) | the consumer's U.S. state; empty for 37 |
| `SUBMITTED_VIA` | VARCHAR(20) | `Web`, `Phone`, `Referral` or `Postal mail` |
| `TAGS` | VARCHAR(40) | `Servicemember`, `Older American`, both, or empty |
| `TIMELY` | DECIMAL(1,0) | 1 when the company answered in time |
| `MONETARY_RELIEF` | DECIMAL(1,0) | 1 when closed with monetary relief, else 0 - **the label** |
| `COMPANY_PUBLIC_RESPONSE` | VARCHAR(300) | the company's public response; empty for about half |

`BANKING_RESPONSES`: `COMPLAINT_ID`, `COMPANY_RESPONSE` (`Closed with
explanation`, `Closed with non-monetary relief`, `Closed with monetary
relief` or `Untimely response`). It is kept apart on purpose: the label is
derived from it, so it gives the label away. Read it; never use it as a
model feature.

## The descriptor

[`descriptor.yaml`](descriptor.yaml) tells the persona notebooks which column
plays each role:

| Role | Column | Why |
|---|---|---|
| entity | `COMPANY` | who the complaint is about |
| category | `PRODUCT` | the grouping to compare |
| date | `DATE_RECEIVED` | when the complaint arrived |
| label | `MONETARY_RELIEF` | the outcome a model predicts |
| text | `ISSUE`, `SUB_ISSUE`, `COMPANY_PUBLIC_RESPONSE` | the text there is |

## Example questions

[`examples.sql`](examples.sql) has twelve queries, each runnable as it stands:
outcomes, relief by product, complaints per day, the biggest companies, top
issues per product, the issues that pay, servicemembers and older Americans,
channels, states, time to the company, public responses and a text question.

## Source, terms and reproducibility

- **Source:** the Consumer Complaint Database of the U.S. Consumer Financial
  Protection Bureau,
  https://www.consumerfinance.gov/data-research/consumer-complaints/. The
  exact query is in [`manifest.json`](manifest.json).
- **Terms:** the data are dedicated to the public domain (CC0 1.0; the API
  answers with that licence), see
  https://www.consumerfinance.gov/complaint/data-use/. The CFPB does not
  verify complaints, and a complaint is not a finding against the company.
  The owner still confirms that the kit may ship the snapshot
  (`terms.confirmed` in the manifest).
- **Rebuild:** `python3 tools/datasets/banking_complaints.py` fetches the same
  query again and rewrites the CSVs and the manifest. A later run can differ
  where the CFPB updated records; the manifest records the snapshot date, the
  row counts and the SHA-256 of every file, and the kit's tests check that the
  shipped files match it.
- **Transformations:** company names and public responses have their
  whitespace folded; ZIP codes are left out; timestamps become dates; nothing
  else is changed.

## Download

The CSVs are in this folder in the repository, but not in the kit archive the
installer downloads: `exakit data-load banking_complaints` fetches them as one
release asset, `banking_complaints-<snapshot>.tar.gz`, whose SHA-256, size and
URL are in [`manifest.json`](manifest.json) (`asset`). The archive is checked
against that digest and every CSV against its own before anything is loaded,
and the verified files are kept under
`~/.exasol-starter-kit/cache/datasets/banking_complaints/`, so a reload does not
download again. A checkout of the repository loads the CSVs here directly when
they match the manifest. Offline, point `EXAKIT_DATASETS_MIRROR` at a folder (or
an `https://` URL) holding the archive. `python3 tools/datasets/package.py
banking_complaints` rebuilds the archive (the same CSVs give the same bytes) and
the manifest's `asset` block.
