# medication_sigs - prescription directions to read the dose, route and timing from

**50 prescription directions ("sigs")** as prescribers write them - "1 cap po
tid x7 days", "take 1 capsule (100 mg total) by mouth 3 (three) times a day as
needed for cough" - abbreviations, Latin and plain English mixed.

```bash
exakit data-load medication_sigs
```

It loads into the `MEDSIGS` schema in a second. It is a small text set for
both personas: read how much, how, how often and for how long out of free
text, and check a model or an AI client that does it against rows you can read
in full.

## Tables

| Table | Rows | One row is |
|---|---:|---|
| `MEDSIGS.MEDICATION_SIGS` | 50 | a prescription direction |

## Data dictionary

`MEDICATION_SIGS`

| Column | Type | Meaning |
|---|---|---|
| `SIG_ID` | DECIMAL(4,0) | direction id (primary key) |
| `WORD_COUNT` | DECIMAL(3,0) | words in the direction |
| `SIG_TEXT` | VARCHAR(300) | the direction, as written: `po` by mouth, `bid` twice a day, `tid` three times, `qid` four times, `qhs` at bedtime, `prn` as needed |

## What was cleaned

Spaces folded; the text otherwise as written - lower case and abbreviations
kept, they are the point. The builder is
[`tools/datasets/medication_sigs.py`](../../../tools/datasets/medication_sigs.py).

## Describe it yourself

It ships without a descriptor: it is text to read the dose, the route and the
timing from, not a prediction problem. Describe it like any table of your
own. The draft reads `SIG_TEXT` as a key rather than as text - every value is
different, and at 35 characters on average the directions are shorter than
the 40 the text rule asks for - so set the text slot before you approve:

```python
import exakit_nb
d = exakit_nb.describe("MEDSIGS.MEDICATION_SIGS")
d.set(SIG_TEXT="text")
d.slot(text="SIG_TEXT")
d.approve()
```

## Source and terms

Generic prescription directions with no patient, prescriber or pharmacy named,
supplied with the kit's requirements. Their origin and terms are **still to be
confirmed** (manifest.json, `terms.confirmed`).

## Example questions

[`examples.sql`](examples.sql) holds ten, each a query that runs as it stands.
