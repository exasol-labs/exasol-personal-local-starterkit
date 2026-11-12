# Start with a baseline (/data-scientist/model/baseline)



A model with every column is only worth keeping if it does better than a simple rule. The baseline is that simple rule. If a real model cannot beat it, the columns carry little signal about the outcome. The kit has two baselines.

## Start with a baseline [#start-with-a-baseline]

* **The notebook baseline** is a small logistic regression in `01_explore`. It uses three inputs: the category, the state and the month of the date.
* **The lab's baseline** is the model called `baseline` in each prediction task. For yes or no, it always gives the common answer. A constant prediction scores 0.5 ROC AUC, so any real model should score above 0.5.

<Flow
  caption="The notebook baseline, in 01_explore"
  steps="[
  { title: &#x22;Read the roles&#x22;, text: &#x22;The category, the entity and the date come from the approved column map&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;Leave out the answer-givers&#x22;, text: &#x22;A flagged category or entity is skipped. The date is used only as its month.&#x22;, code: &#x22;nb.leakage_check(connection, dataset)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;Train on three quarters&#x22;, text: &#x22;A logistic regression, with one 0 or 1 column for each value&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;Keep one quarter back&#x22;, text: &#x22;It is scored on the rows the model never saw. See Evaluate.&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/evaluate&#x22; },
]"
/>

## The notebook baseline [#the-notebook-baseline]

The cell reads the newest 20,000 rows when the table has a date, or the first 20,000 by key when it has none. The key makes a rerun read the same rows. The cell builds the features from the category, the state and the month, then trains this pipeline:

```python
model = Pipeline([
    ("onehot", OneHotEncoder(handle_unknown="ignore")),
    ("classifier", LogisticRegression(max_iter=1000, class_weight="balanced")),
])
```

* `OneHotEncoder` turns each value of the category, the state and the month into a 0 or 1 column.
* `class_weight="balanced"` tells the model to weigh the rarer answer more, so it does not just predict the common one.
* The split is stratified, which keeps the same share of 1s on both sides, with a fixed seed (`random_state=0`). A quarter of the rows is kept back.

The cell prints how many rows it trained on and how many it kept back. It uses a category or an entity only when that column is not flagged by `nb.leakage_check`. The notebook's comment gives the reason for the check: a column written after the outcome "predicts the target perfectly on old rows and fails on new rows."

For `amazon_sales`, the baseline reads `CATEGORY`, `SHIP_STATE` and the month of `ORDER_DATE`. It never reads `STATUS`.

## Do not judge a rare answer by accuracy [#do-not-judge-a-rare-answer-by-accuracy]

When the answer is rare, accuracy is misleading. A model that always says "not fraud" is about 95% accurate on `fraud_transactions`, because 2,510 of its 51,000 rows are fraud (4.9%). `nb.data_checks` reports the rare answer and says what the always-common guess achieves. The readout note also compares every score with that guess. The reasons, and the metric the kit uses instead, are on the [rare answers](/data-scientist/evaluate/rare-answers) page of Evaluate.

## Where to go next [#where-to-go-next]

The lab trains many models on the same rows: [The model lab](/data-scientist/model/model-lab). Back to [Model](/data-scientist/model).
