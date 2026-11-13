# Leakage (/data-scientist/evaluate/leakage)



Leakage means a column carries the answer. Its values are written after the outcome happens, so a model that reads it learns the answer it was given, not a pattern that works on new rows. A model with leakage looks excellent on the rows it learned from and fails on new rows.

## The case on amazon_sales [#the-case-on-amazon_sales]

`STATUS` is the classic trap. The dataset README says `STATUS`, `COURIER_STATUS`, `QTY` and `AMOUNT` all change once an order is cancelled. So a cancelled order says so in `STATUS`, and the target `CANCELLED` is 1 for that order.

This was measured on the sample table, `AMAZON.ORDER_LINES`, on 12 November 2026. The queries are read-only:

```sql
SELECT COUNT(*) FROM AMAZON.ORDER_LINES WHERE STATUS = 'Cancelled';                    -- 18,332
SELECT COUNT(*) FROM AMAZON.ORDER_LINES WHERE STATUS = 'Cancelled' AND CANCELLED = 1;  -- 18,332
SELECT COUNT(*) FROM AMAZON.ORDER_LINES WHERE CANCELLED = 1;                           -- 18,332
```

The three counts are equal. Every row with `CANCELLED` = 1 has `STATUS` = `Cancelled`, and no other row does. So `STATUS` gives the target away completely. A model that reads it will look perfect.

The notebook's comment puts the problem this way: such a column "predicts the target perfectly on old rows and fails on new rows."

## How the kit finds it [#how-the-kit-finds-it]

`nb.leakage_check` flags a column when all of these hold:

* It has 2 to 50 distinct values. Columns with more values are not tested.
* Each of its values is nearly always 1 (at least 99% of its rows) or nearly always 0 (at least 99%).
* Those values together cover at least 95% of all rows, and they hold at least 90% of the 1s.

For `STATUS`, the value `Cancelled` has a 1 in every row, and every other status has a 0 in every row. So every value is pure, the pure values cover all the rows, and they hold all the 1s. The rule flags `STATUS`.

Its message, as `nb.leakage_check` prints it, has this form:

```
- STATUS gives CANCELLED away: CANCELLED is 1 whenever STATUS is 'Cancelled'. It was probably written after the outcome - leave it out of any model.
```

## What the kit does with a flagged column [#what-the-kit-does-with-a-flagged-column]

The kit guards against leakage in three places.

* **The approval warns.** When you approve the column map, the card says `STATUS` gives the answer away, because it is filled in after the outcome, and that the model step leaves it out.
* **The baseline never reads it.** The notebook baseline skips a flagged category or entity. On `amazon_sales` it reads only the category, the state and the month.
* **The lab leaves it out.** `lab_data.left_out` lists `STATUS` with the reason "gives the answer away".

The quickstart says the check flags `STATUS` on `amazon_sales`. Confirm that on your data, because the check depends on the values present in your table.

## Check it yourself [#check-it-yourself]

```python
leaking = nb.leakage_check(connection, dataset)   # the columns the kit flags
lab_data = nb.lab_data(connection, dataset)
print(lab_data.left_out)                          # every column left out, and why
```

## What the check cannot see [#what-the-check-cannot-see]

The check tests only columns with 2 to 50 distinct values. A numeric column such as `AMOUNT` usually has many more values, so the check skips it. The README says `AMOUNT` changes after a cancellation, so the check cannot be the last word on it.

Two other checks cover the gap:

* **Look at `lab.importance` after every run.** If a column you suspect is at the top, it is a lead to read.
* **Leave it out with `leaks=`.** For example: `leaks = nb.leakage_check(connection, dataset) + ["AMOUNT"]`, then pass `leaks=leaks` to `nb.model_lab`. The model lab page has the full example.

For a number to predict, the lab also drops any measure whose correlation with the target is above 0.98, because it moves with the target almost exactly.

Back to [Evaluate](/data-scientist/evaluate). Next: [Comparing models](/data-scientist/evaluate/comparing-models).
