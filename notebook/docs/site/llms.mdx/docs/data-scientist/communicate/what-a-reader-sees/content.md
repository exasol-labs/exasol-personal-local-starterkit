# What a reader sees (/data-scientist/communicate/what-a-reader-sees)



## What a reader sees [#what-a-reader-sees]

The dashboard is a view of the reviewed SQL result. It is not a new calculation over the table. Its page says so.

* **Filters.** Categories, a Show setting (10 by default), Sort by, and Chart layout (horizontal or vertical bars). Top N applies after the filters. **Reset filters** clears them.
* **Category comparison.** A bar chart of the values in the current selection.
* **Composition.** A share-of-total chart. The kit draws it only when you pass `measure="count"`, because a total of a measure that is not a count has no meaning. With more than eight rows shown, the note says smaller categories are grouped as Other.
* **Behind the charts.** The same filtered rows as a table, sortable, with **Export CSV**.

## Check the figures against the SQL [#check-the-figures-against-the-sql]

When you check a preview, compare three things with the query on [Build the dashboard query](/data-scientist/communicate/dashboard-query):

1. The category names in the table match the values in the query's first column.
2. The counts match the counts the query returns. `nb.show_sql()` prints the last query the notebook ran.
3. The composition chart's Other group equals the sum of the categories it groups.

```python
nb.show_sql()   # the SQL the last query ran
```

Back to [Preview, check, publish](/data-scientist/communicate/preview-check-publish). Next: [The hand-off bundle](/data-scientist/communicate/hand-off-bundle).
