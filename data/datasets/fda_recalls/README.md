# fda_recalls - food, drug and device recalls from openFDA

A snapshot of **5,459 recalled products the U.S. Food and Drug Administration
reported in 2024** - 3,393 devices, 1,409 foods and 657 drugs from 1,043
firms - taken from openFDA's recall enforcement reports on 2026-10-21. Each
recall carries free text (why it was recalled, what the product is) and the
FDA's verdict on how dangerous it is, so the question "which recalls are
serious?" has an answer in the data: 994 of them (18.2%) are Class I.

```bash
exakit data-load fda_recalls
```

It loads into the `FDA` schema in a few seconds (4 MB of CSV).

It is the AI / Data Scientist persona's text dataset: the reason for a recall
is short, specific prose ("Potential salmonella contamination", "Undeclared
milk", "Lack of sterility assurance"), so a text classifier learns both the
product type and the seriousness from it - the kind of task Spark NLP's
classification examples demonstrate, here on Exasol with scikit-learn.

## Tables

| Table | Rows | One row is |
|---|---:|---|
| `FDA.FDA_RECALLS` | 5,459 | a recalled product |
| `FDA.FDA_CLASSIFICATIONS` | 5,459 | the FDA's classification of it |

## Data dictionary

`FDA_RECALLS`

| Column | Type | Meaning |
|---|---|---|
| `RECALL_NUMBER` | VARCHAR(20) | FDA recall number (primary key), e.g. `F-1671-2024` |
| `EVENT_ID` | DECIMAL(10,0) | the recall event; 1,806 events cover the 5,459 products |
| `PRODUCT_TYPE` | VARCHAR(20) | `Food`, `Drugs` or `Devices` |
| `RECALLING_FIRM` | VARCHAR(200) | the firm that recalled it |
| `FIRM_STATE` | VARCHAR(40) | the firm's state or region |
| `FIRM_COUNTRY` | VARCHAR(60) | the firm's country |
| `VOLUNTARY_MANDATED` | VARCHAR(60) | firm initiated, FDA requested or FDA mandated |
| `INITIAL_NOTIFICATION` | VARCHAR(80) | how the firm first told its customers |
| `RECALL_STATUS` | VARCHAR(20) | `Ongoing`, `Completed` or `Terminated` |
| `DISTRIBUTION_PATTERN` | VARCHAR(420) | where the product went |
| `PRODUCT_DESCRIPTION` | VARCHAR(620) | the product, in the FDA's words |
| `REASON_FOR_RECALL` | VARCHAR(620) | why it was recalled |
| `RECALL_INITIATION_DATE` | DATE | when the firm started the recall |
| `REPORT_DATE` | DATE | when the FDA published it |
| `SERIOUS` | DECIMAL(1,0) | 1 when the FDA classified it Class I, else 0 - **the label** |

`FDA_CLASSIFICATIONS`: `RECALL_NUMBER`, `CLASSIFICATION` (`Class I`: 994,
`Class II`: 4,270, `Class III`: 195) and `CLASSIFICATION_DATE`. It is kept
apart on purpose: the label is derived from it, so it gives the label away.
Read it; never use it as a model feature.

## The descriptor

[`descriptor.json`](descriptor.json) tells the persona notebooks which column
plays each role:

| Role | Column | Why |
|---|---|---|
| entity | `RECALLING_FIRM` | who recalled the product |
| category | `PRODUCT_TYPE` | the grouping to compare - and the class the text classifier predicts |
| date | `REPORT_DATE` | when the FDA reported it |
| label | `SERIOUS` | the outcome a model predicts |
| text | `REASON_FOR_RECALL`, `PRODUCT_DESCRIPTION` | the free text |

## Example questions

[`examples.sql`](examples.sql) has twelve queries, each runnable as it stands:
the classes, the serious rate by product type, recalls per month, the busiest
firms, the commonest reasons, contamination words, voluntary or mandated,
status, days to the report, countries, multi-product events and a text
question.

## Source, terms and reproducibility

- **Source:** openFDA's recall enforcement reports (food, drug and device
  endpoints) of the U.S. Food and Drug Administration,
  https://open.fda.gov/apis/food/enforcement/. The exact query is in
  [`manifest.json`](manifest.json).
- **Terms:** openFDA data are a work of the U.S. government and in the public
  domain (CC0 1.0), see https://open.fda.gov/license/. openFDA says its data
  are not for clinical use; a recall report is the FDA's record of a firm's
  action, not medical advice. The owner still confirms that the kit may ship
  the snapshot (`terms.confirmed` in the manifest).
- **Rebuild:** `python3 tools/datasets/fda_recalls.py` fetches the same query
  again and rewrites the CSVs and the manifest. A later run can differ where
  the FDA updated records; the manifest records the snapshot date, the row
  counts and the SHA-256 of every file, and the kit's tests check that the
  shipped files match it.
- **Transformations:** text has its whitespace folded and is cut at 600
  characters on a word; dates become ISO dates; addresses and lot codes are
  left out; one report without a recall number is dropped; nothing else is
  changed.
