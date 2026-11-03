# pubmed_abstracts - clinical-study abstracts to read, search and extract from

**1,409 PubMed abstracts of clinical studies** - interferon beta in multiple
sclerosis, lymphoma, drug safety and more - the kind of text a medical NLP
service reads for drugs, conditions, doses and outcomes.

```bash
exakit data-load pubmed_abstracts
```

It loads into the `PUBMED` schema in a few seconds (2.3 MB of CSV). It is the
long-text medical dataset for both personas: summarise and search abstracts,
or extract entities from them; with `ade_corpus` beside it, find the drugs and
effects that corpus labels.

## Tables

| Table | Rows | One row is |
|---|---:|---|
| `PUBMED.PUBMED_ABSTRACTS` | 1,409 | an abstract |

## Data dictionary

`PUBMED_ABSTRACTS`

| Column | Type | Meaning |
|---|---|---|
| `ABSTRACT_ID` | DECIMAL(5,0) | abstract id (primary key) |
| `FIRST_SECTION` | VARCHAR(40) | the heading the abstract opens with - `BACKGROUND`, `OBJECTIVE`, ... - or empty for an unstructured abstract (660 of them) |
| `WORD_COUNT` | DECIMAL(5,0) | words in the abstract (median 235) |
| `ABSTRACT_TEXT` | VARCHAR(8000) | the abstract, as published |

## What was cleaned

Leading and trailing spaces stripped, the twelve repeated abstracts kept once,
the seven "FDA review" placeholder lines dropped. The text is otherwise as
given: the builder is
[`tools/datasets/pubmed_abstracts.py`](../../../tools/datasets/pubmed_abstracts.py).

## Describe it yourself

It ships without a descriptor: it is text to read, search and extract from,
not a prediction problem, so it has no target for the persona notebooks to
train on. Describe it like any table of your own and approve what you agree
with:

```bash
exakit describe PUBMED.PUBMED_ABSTRACTS
```

The draft reads `ABSTRACT_ID` as the key, `ABSTRACT_TEXT` as text and
`FIRST_SECTION` as a category.

## Source and terms

Abstracts as published in PubMed (U.S. National Library of Medicine,
https://pubmed.ncbi.nlm.nih.gov/). NLM's terms apply and some publishers hold
copyright on their abstracts, so whether they may be redistributed with the
kit is **still to be confirmed** (manifest.json, `terms.confirmed`).

## Example questions

[`examples.sql`](examples.sql) holds ten, each a query that runs as it stands.
