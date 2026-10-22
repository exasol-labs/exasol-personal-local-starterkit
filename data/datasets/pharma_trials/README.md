# pharma_trials - clinical trials from ClinicalTrials.gov

A snapshot of **5,169 industry-sponsored, interventional Phase 2 and Phase 3
trials that started in 2016-2018 and ended COMPLETED or TERMINATED**, taken
from the ClinicalTrials.gov API v2 on 2026-10-20. Their outcomes are known, so
the question "which trials stop early?" has an answer in the data: 915 of
them (17.7%) were terminated.

```bash
exakit data-load pharma_trials
```

It loads into the `PHARMA` schema in a few seconds (12.8 MB of CSV). An installed
kit downloads the CSVs first, as one checksummed archive of 3.9 MB (see
[Download](#download)).

## Tables

| Table | Rows | One row is |
|---|---:|---|
| `PHARMA.PHARMA_TRIALS` | 5,169 | a trial |
| `PHARMA.PHARMA_SPONSORS` | 6,674 | the lead sponsor or a collaborator of a trial |
| `PHARMA.PHARMA_CONDITIONS` | 7,291 | a condition a trial studies |
| `PHARMA.PHARMA_INTERVENTIONS` | 12,384 | a drug, device or procedure a trial tests |
| `PHARMA.PHARMA_STOP_REASONS` | 887 | the reason a sponsor gave for stopping |

## Data dictionary

`PHARMA_TRIALS`

| Column | Type | Meaning |
|---|---|---|
| `NCT_ID` | VARCHAR(11) | ClinicalTrials.gov identifier, e.g. `NCT01336660` (primary key) |
| `BRIEF_TITLE` | VARCHAR(400) | short title |
| `PHASE` | VARCHAR(20) | `PHASE2`, `PHASE3`, `PHASE1/PHASE2` or `PHASE2/PHASE3` |
| `OVERALL_STATUS` | VARCHAR(12) | `COMPLETED` or `TERMINATED` |
| `TERMINATED` | DECIMAL(1,0) | 1 when the trial was terminated early, else 0 - **the label** |
| `START_DATE` | DATE | start (the first of the month when only the month is published) |
| `PRIMARY_COMPLETION_DATE` | DATE | primary completion, actual or as last reported |
| `ENROLLMENT` | DECIMAL(9,0) | participants enrolled; empty for 3 trials |
| `LEAD_SPONSOR` | VARCHAR(200) | the company running the trial (1,575 distinct) |
| `ALLOCATION` | VARCHAR(20) | `RANDOMIZED`, `NON_RANDOMIZED` or `NA` |
| `PRIMARY_PURPOSE` | VARCHAR(40) | e.g. `TREATMENT`, `PREVENTION`, `DIAGNOSTIC` |
| `MASKING` | VARCHAR(12) | blinding: `NONE`, `SINGLE`, `DOUBLE`, `TRIPLE`, `QUADRUPLE` |
| `HAS_RESULTS` | DECIMAL(1,0) | 1 when results are posted |
| `BRIEF_SUMMARY` | VARCHAR(2100) | the sponsor's summary, whitespace folded; a longer one is cut on a word and ends in ` …`, at most 2,000 characters in all |
| `ELIGIBILITY_CRITERIA` | VARCHAR(2100) | inclusion and exclusion criteria, folded and cut the same way (every trial in this snapshot has them) |

`PHARMA_SPONSORS`: `NCT_ID`, `SEQ` (1 is the lead sponsor - the same name as
`LEAD_SPONSOR` - then the collaborators in record order), `SPONSOR_ROLE`
(`LEAD` or `COLLABORATOR`), `SPONSOR_NAME`, `SPONSOR_CLASS` (`INDUSTRY`,
`OTHER`, `NIH`, `FED`, `OTHER_GOV`, `NETWORK`, `INDIV`, `AMBIG`, `UNKNOWN`).
`PHARMA_CONDITIONS`: `NCT_ID`, `CONDITION_NAME` (as the sponsor wrote it).
`PHARMA_INTERVENTIONS`: `NCT_ID`, `SEQ` (protocol order, from 1),
`INTERVENTION_TYPE` (`DRUG`, `BIOLOGICAL`, `DEVICE`, ...), `INTERVENTION_NAME`.
`PHARMA_STOP_REASONS`: `NCT_ID`, `WHY_STOPPED`.

`PHARMA_STOP_REASONS` is kept apart on purpose: a stop reason exists only for
a stopped trial, so it gives the label away. Read it to understand the
terminations; never use it as a model feature.

## The descriptor

[`descriptor.yaml`](descriptor.yaml) tells the persona notebooks which column
plays each role:

| Role | Column | Why |
|---|---|---|
| entity | `LEAD_SPONSOR` | who runs the trial |
| category | `PHASE` | the grouping to compare |
| date | `START_DATE` | when the trial began |
| label | `TERMINATED` | the outcome a model predicts |
| text | `BRIEF_SUMMARY`, `ELIGIBILITY_CRITERIA` | free text for the model and the text step, joined in this order |

## Example questions

[`examples.sql`](examples.sql) has fourteen queries, each runnable as it stands:
outcomes, termination by phase, starts per quarter, the biggest sponsors, the
commonest conditions, blinding, enrollment and duration, intervention types,
placebo control, stop reasons, posted results, collaborators and two text
questions (summaries and eligibility criteria).

## Source, terms and reproducibility

- **Source:** ClinicalTrials.gov API v2, U.S. National Library of Medicine,
  https://clinicaltrials.gov/api/v2/studies. The exact query is in
  [`manifest.json`](manifest.json).
- **Terms:** https://clinicaltrials.gov/about-site/terms-conditions - the data
  are offered by NLM; cite ClinicalTrials.gov as the source and do not imply
  NLM endorsement. **Redistribution in the kit is still to be confirmed by the
  owner** (`terms.confirmed` in the manifest); until then this dataset is a
  release blocker.
- **Rebuild:** `python3 tools/datasets/pharma_trials.py` fetches the same
  query again and rewrites the CSVs and the manifest. A later run can differ
  by the records sponsors updated since; the manifest records the snapshot date,
  the row counts and the SHA-256 of every file, and the kit's tests check that
  the shipped files match it.
- **Transformations:** whitespace folded; summaries and eligibility criteria
  cut on a word at 2,000 characters (the ` …` included), titles at 300; a
  month-only date is the first of that month;
  trials without a summary are left out (none in this snapshot); nothing else
  is changed.

## Download

The CSVs are in this folder in the repository, but not in the kit archive the
installer downloads: `exakit data-load pharma_trials` fetches them as one
release asset, `pharma_trials-<snapshot>.tar.gz`, whose SHA-256, size and URL
are in [`manifest.json`](manifest.json) (`asset`). The archive is checked
against that digest and every CSV against its own before anything is loaded,
and the verified files are kept under
`~/.exasol-starter-kit/cache/datasets/pharma_trials/`, so a reload does not
download again. A checkout of the repository loads the CSVs here directly when
they match the manifest. Offline, point `EXAKIT_DATASETS_MIRROR` at a folder (or
an `https://` URL) holding the archive. `python3 tools/datasets/package.py
pharma_trials` rebuilds the archive (the same CSVs give the same bytes) and the
manifest's `asset` block.
