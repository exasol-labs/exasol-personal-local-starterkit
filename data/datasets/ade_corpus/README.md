# ade_corpus - does this sentence report an adverse drug effect?

**20,960 sentences from PubMed case reports**, each read by annotators for an
adverse drug effect (ADE-Corpus-V2, Gurulingappa et al., 2012): **4,272 report
one** (20.4%) - the drug and the effect they name are in their own table - and
16,688 do not.

```bash
exakit data-load ade_corpus
```

It loads into the `ADE` schema in a few seconds (3.3 MB of CSV). It is a
medical text dataset with a real label, for both personas: the Data Scientist
explores which drugs and effects come up and reads the sentences; the ML
Engineer trains a classifier on `HAS_ADE` or an extractor for the drug and the
effect.

## Tables

| Table | Rows | One row is |
|---|---:|---|
| `ADE.ADE_SENTENCES` | 20,960 | a sentence, with the label |
| `ADE.ADE_DRUG_EFFECTS` | 6,633 | a drug and the adverse effect a sentence names |
| `ADE.ADE_DRUG_DOSES` | 269 | a drug and the dose a sentence names |

## Data dictionary

`ADE_SENTENCES`

| Column | Type | Meaning |
|---|---|---|
| `SENTENCE_ID` | DECIMAL(6,0) | sentence id (primary key) |
| `PUBMED_ID` | DECIMAL(9,0) | PubMed id of the article the sentence is from (2,972 articles) |
| `SENTENCE` | VARCHAR(1000) | the sentence, as published |
| `HAS_ADE` | DECIMAL(1,0) | 1 when the sentence reports an adverse drug effect - **the label** |

`ADE_DRUG_EFFECTS`

| Column | Type | Meaning |
|---|---|---|
| `PAIR_ID` | DECIMAL(6,0) | pair id (primary key) |
| `SENTENCE_ID` | DECIMAL(6,0) | the sentence (`ADE_SENTENCES`) |
| `DRUG` | VARCHAR(100) | the drug, as written |
| `ADVERSE_EFFECT` | VARCHAR(200) | the adverse effect, as written |

`ADE_DRUG_DOSES`

| Column | Type | Meaning |
|---|---|---|
| `PAIR_ID` | DECIMAL(6,0) | pair id (primary key) |
| `SENTENCE_ID` | DECIMAL(6,0) | the sentence (`ADE_SENTENCES`) |
| `DRUG` | VARCHAR(100) | the drug, as written |
| `DOSE` | VARCHAR(100) | the dose, as written |

The pair tables exist only for sentences labelled 1, so they are **never
features** for predicting `HAS_ADE`: a sentence with a pair is a sentence with
the answer. Use them to read, or as the target of an extraction model.

## What was cleaned

The seven repeated lines among the sentences without an effect and the 188
repeated drug-effect pairs are kept once; the character offsets (they point
into the abstracts, which the corpus does not ship) are dropped; text is
folded to one line. Nothing else changes: the builder is
[`tools/datasets/ade_corpus.py`](../../../tools/datasets/ade_corpus.py).

## The descriptor

[`descriptor.yaml`](descriptor.yaml) gives every column of `ADE_SENTENCES`
its role and names the columns the persona notebooks use: key `SENTENCE_ID`,
text `SENTENCE`, target `HAS_ADE`.

## Source and terms

H. Gurulingappa, A. M. Rajput, A. Roberts, J. Fluck, M. Hofmann-Apitius and
L. Toldo, *Development of a benchmark corpus to support the automatic
extraction of drug-related adverse effects from medical case reports*,
Journal of Biomedical Informatics 45(5), 2012,
https://doi.org/10.1016/j.jbi.2012.04.008. The corpus asks to be cited; it
names no licence, so its redistribution terms are **still to be confirmed**
(manifest.json, `terms.confirmed`).

## Example questions

[`examples.sql`](examples.sql) holds ten, each a query that runs as it stands.
