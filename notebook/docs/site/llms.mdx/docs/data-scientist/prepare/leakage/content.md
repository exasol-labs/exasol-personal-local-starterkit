# Columns that give the answer away (/data-scientist/prepare/leakage)



A column whose values almost decide the target on their own makes a model look better than it is. Such a column is usually written after the outcome. A cancelled order gets a cancelled status, so the status is known only once the outcome is known. A model that reads it learns the answer, not a pattern, and scores well on the data it was trained on. For an order whose outcome is not yet known, the same column cannot help.

`nb.leakage_check(connection, dataset)` looks for these columns. It is the check the approval runs, and the model lab leaves out every column it lists.

## Columns that give the answer away [#columns-that-give-the-answer-away]

The check flags a column when all three of these hold:

* it has between two and 50 distinct values,
* at least 95% of its rows sit in values where the target is almost always 1, or almost always 0 (at least 99% or at most 1%), and
* those values hold at least 90% of all the rows where the target is 1.

The check looks at every column except the target, the key, identifiers and text. It lists the flagged columns and prints why each one was flagged. The rule is in `leakage_check` in `notebook/package/exakit_nb/data_checks.py`.

A flagged column is a warning, not an error. The column stays in the column map. The model does not use it.

## The proof on amazon_sales [#the-proof-on-amazon_sales]

The approval warns about `STATUS` in `AMAZON.ORDER_LINES`. A cancelled order has a cancelled status, so the status gives the answer away. You can check this on the table. These two queries are read-only, and both were run on a real database on 12 November 2026:

```sql
SELECT COUNT(*) FROM AMAZON.ORDER_LINES WHERE STATUS = 'Cancelled';
-- 18,332

SELECT COUNT(*) FROM AMAZON.ORDER_LINES WHERE STATUS = 'Cancelled' AND CANCELLED = 1;
-- 18,332
```

Both counts are 18,332. Every row with `STATUS = 'Cancelled'` has `CANCELLED = 1`, and the table holds no other row with `CANCELLED = 1`. The status alone gives the target away completely.

<Flow
  caption="Why the rule flags STATUS"
  steps="[
  { title: &#x22;Cancelled status&#x22;, text: &#x22;18,332 rows: every one has CANCELLED = 1&#x22;, tone: &#x22;db&#x22; },
  { title: &#x22;Every other status&#x22;, text: &#x22;Its rows have CANCELLED = 0&#x22;, tone: &#x22;db&#x22; },
  { title: &#x22;The rule fires&#x22;, text: &#x22;The value 'Cancelled' decides the target, and it holds all the 1s&#x22;, code: &#x22;nb.leakage_check(connection, dataset)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;The model leaves it out&#x22;, text: &#x22;STATUS stays in the column map, and no model uses it&#x22;, tone: &#x22;kit&#x22; },
]"
/>

The check prints this line for `STATUS`:

```text
- STATUS gives CANCELLED away: CANCELLED is 1 whenever STATUS is 'Cancelled'. It was probably written after the outcome - leave it out of any model.
```

The printed text is generated from the data. The line above is what the check prints for these measured counts.

The dataset README also names `COURIER_STATUS`, `QTY` and `AMOUNT` as changing once an order is cancelled. The check reports the columns it finds from the data, not the ones the README names. So read the printed list rather than assume it.

## Run the check [#run-the-check]

```python
leaking = nb.leakage_check(connection, dataset)
```

The quickstart and `01_explore` run this check. Each run prints one line per flagged column, and returns the list of column names. The model lab calls the same check when you do not pass a list of your own (`nb.model_lab(..., leaks=...)` in `notebook/package/exakit_nb/lab.py`), and it leaves the flagged columns out.

If the list is empty, the check prints that no column decides the target on its own.

Back to [Prepare](/data-scientist/prepare). Previous: [Data checks](/data-scientist/prepare/data-checks). Next: [Linked tables and the joined view](/data-scientist/prepare/linked-tables-view).
