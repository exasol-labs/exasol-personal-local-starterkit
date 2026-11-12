# The readout notes (/data-scientist/evaluate/readout-notes)



The readout helpers print a plain-language note under each result and return it as text. Nothing is computed that the result does not hold. If a note would need a number the result lacks, it leaves the sentence out.

## The readout notes [#the-readout-notes]

* **`nb.note_groups`** is for a per-group result. It says what one row is, the overall figure, the highest and the lowest group, which groups have too few rows to trust (fewer than 30), and that a difference between groups is not a cause.
* **`nb.note_trend`** is for a per-period result. It names the busiest period and the highest and lowest percentage, leaves out periods with fewer than 30 rows, and says that a change over time shows when something moved, not why.
* **`nb.note_model`** is for the small model's score. It says what the score means in words (the ranges are on [Reading ROC AUC](/data-scientist/evaluate/roc-auc)), how many rows the model learned from, and the baseline to beat.

The 30-row limit is one constant, `SMALL`, in `readout.py`. It is the same for groups and periods.

## Where the words come from [#where-the-words-come-from]

The notes take their words from the column map. The grain "one row per order line" makes the note say "order lines", and the count column is named `ORDER_LINES`. Three helpers do that naming:

* `nb.name` gives a column's readable name.
* `nb.count_name` gives the name of the count column for the dataset.
* `nb.noun` gives the plural noun for one row.

The note is printed under the table and also returned as a string, so you can copy it next to the figures in a report.

Back to [Evaluate](/data-scientist/evaluate). Next: [The checks](/data-scientist/evaluate/checks).
