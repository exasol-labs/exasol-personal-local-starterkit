# Evaluate (/data-scientist/evaluate)



Evaluation answers one question: how well will this model do on rows it has not seen? A score on the rows it learned from says little, because a model can memorise them. The kit holds rows out before it trains, reports the metric that fits your task, and warns you about the traps it can detect: columns that give the answer away, rare answers, and held-out sets that are too small. It does not run significance tests. The page on comparing models says what to do about that.

<Flow
  caption="Hold rows out, train on the rest, score the unseen rows, read the result"
  steps="[
  { title: &#x22;Hold rows out&#x22;, text: &#x22;The newest rows (time), a random share (stratified for yes or no), or whole groups&#x22;, code: 'nb.model_lab(connection, dataset, &#x22;predict_yes_no&#x22;, split_method=&#x22;time&#x22;)', tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/evaluate/hold-out&#x22; },
  { title: &#x22;Train on the rest&#x22;, text: &#x22;Cross-validation on the training rows chooses the model&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/model/the-models&#x22; },
  { title: &#x22;Score the unseen rows&#x22;, text: &#x22;The held-out rows are scored once, with the metrics for the task&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/evaluate/metrics&#x22; },
  { title: &#x22;Read the note&#x22;, text: &#x22;The kit says what the number means, in words&#x22;, code: &#x22;nb.note_model(roc_auc, dataset, rows=len(model_rows))&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/evaluate/readout-notes&#x22; },
  { title: &#x22;You decide&#x22;, text: &#x22;Is the score real? Check the leakage, the baseline and the size of the held-out set&#x22;, tone: &#x22;you&#x22; },
]"
/>

<Flow
  caption="When the score looks too good"
  steps="[
  { title: &#x22;A near-perfect score&#x22;, text: &#x22;Treat it as a warning, not good news&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;Look for leakage&#x22;, text: &#x22;Columns whose values decide the answer on their own&#x22;, code: &#x22;nb.leakage_check(connection, dataset)&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/evaluate/leakage&#x22; },
  { title: &#x22;Leave them out&#x22;, text: &#x22;The baseline and the lab skip the flagged columns&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;Train again on the same split&#x22;, text: &#x22;The seed is fixed, so the two scores compare fairly&#x22;, tone: &#x22;you&#x22; },
]"
/>

## Where you do it [#where-you-do-it]

| Guided view                                                                                                    | Notebook code                                                                                                                                       | Terminal                               |
| -------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `01_explore`: the **Build a model** card runs the same lab, and its results show the leaderboard and the pick. | The cells **Score on unseen rows** and **The model lab (optional)** in `01_explore`. `lab.board`, `lab.importance` and `lab.note` hold the results. | None. Scoring happens in the notebook. |

## How we used it [#how-we-used-it]

On `amazon_sales`, the notebook baseline is scored on a quarter of the rows it did not train on, with ROC AUC. The notebook prints the score. This repository does not record a value for it, so these pages quote none.

Two results are measured on the real database and are the basis of the warnings:

* **The leakage trap.** `STATUS` is `Cancelled` on exactly the 18,332 rows whose `CANCELLED` is 1. A model that reads `STATUS` learns the answer it was given. See [Leakage](/data-scientist/evaluate/leakage).
* **The rare answer.** `fraud_transactions` has 2,510 fraud rows out of 51,000 (4.9%). A model that always says "not fraud" is about 95% accurate, so accuracy is the wrong score. See [Rare answers](/data-scientist/evaluate/rare-answers).

## In this stage [#in-this-stage]

<Cards>
  <Card title="Hold-out: how rows are kept apart" href="/data-scientist/evaluate/hold-out" description="The time, random and group splits, and the warnings for a small held-out set" />

  <Card title="Metrics" href="/data-scientist/evaluate/metrics" description="The score each task uses, and what the board's columns mean" />

  <Card title="Reading ROC AUC" href="/data-scientist/evaluate/roc-auc" description="What the number means, and what the note says for each range" />

  <Card title="Rare answers" href="/data-scientist/evaluate/rare-answers" description="Why accuracy fails when the answer is rare, and which score the kit uses instead" />

  <Card title="Leakage" href="/data-scientist/evaluate/leakage" description="Columns that give the answer away, how the kit finds them, and how to check" />

  <Card title="Comparing models" href="/data-scientist/evaluate/comparing-models" description="What the kit does not test, and what to do about a difference" />

  <Card title="The readout notes" href="/data-scientist/evaluate/readout-notes" description="The plain-language notes under each result" />

  <Card title="The checks" href="/data-scientist/evaluate/checks" description="The functions that check the data and the model before you rely on them" />

  <Card title="When it goes wrong" href="/data-scientist/evaluate/troubleshooting" description="Warnings and suspicious scores, and what to do about them" />
</Cards>

## What you have at the end [#what-you-have-at-the-end]

A score on rows the model did not learn from, what that score means in words, the list of what the model leans on, and the warnings the kit raised. The score shows that the inputs carry signal about the outcome. It does not show that any input causes it. Next, share the result in [Communicate and deploy](/data-scientist/communicate).

<StageNav n="6" />
