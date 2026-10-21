# bank_marketing - who says yes to a term deposit

**45,211 clients a Portuguese bank phoned** in its term-deposit campaigns from
May 2008 to November 2010: who they are (age, job, marital status,
education), their money (yearly balance, credit in default, housing and
personal loans), how the campaign reached them, and **whether they
subscribed** - 5,289 did (11.7%).

```bash
exakit data-load bank_marketing
```

It loads into the `BANKMKT` schema in a few seconds (3.6 MB of CSV).

It is the ML Engineer persona's dataset: the notebook
`ml-engineer/bank_marketing_mlflow.ipynb` reads it from Exasol, trains several
classifiers on this computer, logs each run to MLflow (parameters, metrics,
the SQL, the model) and compares them - which clients to call next.

## Table

`BANKMKT.BANK_CLIENTS` - one row per client:

| Column | Meaning |
|---|---|
| `CLIENT_ID` | row number (primary key) |
| `AGE`, `JOB`, `MARITAL`, `EDUCATION` | who the client is |
| `CREDIT_IN_DEFAULT`, `HOUSING_LOAN`, `PERSONAL_LOAN` | 1 or 0 |
| `BALANCE` | average yearly balance, euros |
| `CONTACT_TYPE`, `LAST_CONTACT_DAY`, `LAST_CONTACT_MONTH` | the last contact |
| `CALL_DURATION` | seconds of the last call - **not a feature**: it is known only after the call |
| `CAMPAIGN_CONTACTS` | contacts in this campaign |
| `DAYS_SINCE_PREVIOUS`, `PREVIOUS_CONTACTS`, `PREVIOUS_OUTCOME` | earlier campaigns (-1 days: never contacted) |
| `SUBSCRIBED` | 1 when the client subscribed - **the label** |

`CALL_DURATION` is the classic trap of this dataset: a long call almost
always means a yes, but the length is known only once the call is over, so a
model that uses it cannot help decide whom to call. The notebook leaves it
out and says so. The data has no free text and no full dates, so it carries
no descriptor; its own notebook applies.

## Source, terms and reproducibility

- **Source:** S. Moro, P. Rita and P. Cortez (2014), *Bank Marketing*, UCI
  Machine Learning Repository, https://doi.org/10.24432/C5K306 (the
  `bank-full.csv` file).
- **Terms:** CC BY 4.0 - free to copy, change and redistribute with that
  attribution (https://creativecommons.org/licenses/by/4.0/). The owner still
  confirms that the kit may ship it (`terms.confirmed` in the manifest).
- **Rebuild:** `python3 tools/datasets/bank_marketing.py` downloads the UCI
  archive again and rewrites the CSV and the manifest.
- **Transformations:** columns renamed in plain words (`default` is an SQL
  keyword), yes/no as 1/0, a row number as the key; values are unchanged.
