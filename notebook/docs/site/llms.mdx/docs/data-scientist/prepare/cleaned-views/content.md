# A typed, cleaned view (/data-scientist/prepare/cleaned-views)



Numbers and dates often arrive as text, when a file loads as text. Blank cells, placeholders and copies make a result quietly wrong. The **typed view** fixes these. It is a view, a stored query that reads your table, so your table is never changed. The kit proposes the changes first, and creates the view only when you call `create`.

## Propose the view [#propose-the-view]

```python
proposal = nb.typed_view(connection, dataset)    # the proposal: what changes, why, and the CREATE VIEW
proposal                                         # read it first
prepared = proposal.create(connection)           # only when you want it
```

The kit reads the table's values, not only its names. It then proposes these changes:

* **Types.** A text column whose every value is a number becomes `DECIMAL`. A column with exponents becomes `DOUBLE`. A text column whose every value is a date becomes `DATE`, in one of these formats: `YYYY-MM-DD`, `DD-MM-YYYY`, `DD.MM.YYYY`, `MM/DD/YYYY`, or `DD/MM/YYYY`. A timestamp becomes `TIMESTAMP`, and true or false becomes `BOOLEAN`.
* **Kept as text.** An identifier or key column stays text. So does a number with a leading zero, and a column named like a code, such as a postal code, a phone number, an SKU, or a name ending in `_ID`.
* **Cleaning.** Text is trimmed. A blank cell becomes `NULL`. A placeholder becomes `NULL`, where the placeholder can be listed.
* **Copies.** Rows that are exact copies of another row are dropped. The first row, by the key, is kept. When the table has no key, a row that copies another in every column is dropped.

Nothing changes until `create()`. The proposal shows each change with the evidence for it.

<Flow
  caption="From a table to a typed view"
  steps="[
  { title: &#x22;The kit reads the values&#x22;, text: &#x22;Types, blanks, placeholders and copies, from the data itself&#x22;, code: &#x22;nb.typed_view(connection, dataset)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;You read the proposal&#x22;, text: &#x22;Each change, its evidence, and the CREATE VIEW&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;The view is created&#x22;, text: &#x22;EXAKIT_PREPARED, with its own column map&#x22;, code: &#x22;prepared = proposal.create(connection)&#x22;, tone: &#x22;db&#x22;, href: &#x22;/data-scientist/prepare/prepared-views&#x22; },
]"
/>

## How we used it: fraud_transactions [#how-we-used-it-fraud_transactions]

The typed view proposes what it will change. For this table it turns each placeholder into `NULL` and drops the copies:

```python
typed_view_proposal = nb.typed_view(connection, dataset)
typed_view_proposal          # the changes, the cleaning and the CREATE VIEW. Nothing is created.
```

The proposal lists the cleaning in the same form as the checks, for example `DEVICE_USED: 'Unknown Device' (1,530 rows) becomes NULL`. The copies are counted after cleaning, so the number can differ from the check's number. The check's counts are on [Data checks](/data-scientist/prepare/data-checks).

## How we used it: amazon_sales [#how-we-used-it-amazon_sales]

The measured semantic model was built on `EXAKIT_PREPARED.AMAZON__ORDER_LINES`, the typed view of `AMAZON.ORDER_LINES`. The view holds 128,969 rows and the table 128,975. Every row of the table is distinct (`SELECT COUNT(*) FROM (SELECT DISTINCT * FROM AMAZON.ORDER_LINES)` returns 128,975), so the 6 rows are not exact copies. The view's own SQL (`SELECT VIEW_TEXT FROM SYS.EXA_ALL_VIEWS WHERE VIEW_NAME = 'AMAZON__ORDER_LINES'`) says why: it trims every text value, turns an empty one into NULL, and then keeps one row of each group that is the same in every column except `ORDER_LINE_ID` (`ROW_NUMBER() OVER (PARTITION BY` every other column `ORDER BY ORDER_LINE_ID)`, `WHERE COPY_ = 1`). Six order lines were copies of another line apart from their row id, and the view dropped them. The semantic model's measurements are on [Semantic views](/data-scientist/explore/semantic-views).

Back to [Prepare](/data-scientist/prepare). Previous: [Linked tables and the joined view](/data-scientist/prepare/linked-tables-view). Next: [Prepared views](/data-scientist/prepare/prepared-views).
