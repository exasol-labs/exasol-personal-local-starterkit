# Features (/data-scientist/prepare/features)



A **feature** is a new input for a model, built from the columns you have. For example, "how long ago the order date was" is a feature built from one column. The kit proposes feature ideas from your data, and it tests each one before you keep it. The model is trained in the [Model](/data-scientist/model) stage. These helpers belong to the model lab, and you can call them from here.

## Propose and test an idea [#propose-and-test-an-idea]

```python
lab = nb.model_lab(connection, dataset)              # the model lab: the task, the model and the split
ideas = nb.feature_ideas(lab)                        # ideas, each with the SQL that would make it
result = nb.try_feature(lab, ideas[0])               # retrain with one idea added, on the same split
result["verdict"], result["text"]                    # whether it helps, and by how much
```

<Flow
  caption="How a feature idea is tested"
  steps="[
  { title: &#x22;The kit proposes ideas&#x22;, text: &#x22;From rules, and optionally your AI model&#x22;, code: &#x22;nb.feature_ideas(lab)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;The model retrains&#x22;, text: &#x22;With the idea added, on the same split&#x22;, code: &#x22;nb.try_feature(lab, idea)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;Held-out rows decide&#x22;, text: &#x22;The score must rise in cross-validation and not fall on the rows held out&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;You keep it or not&#x22;, text: &#x22;A suspicious idea cannot be kept&#x22;, code: &#x22;nb.model_lab(..., features=...)&#x22;, tone: &#x22;you&#x22; },
]"
/>

## The ideas [#the-ideas]

The ideas come from rules. They include:

* how long ago the time column's date was,
* a value compared with its group's usual value,
* two categories taken together,
* a number read as a number, when it holds counts,
* whether a number is missing, when some rows are blank,
* a flag for words such as `price`, `slow` or `wrong`, in a column of sentences.

The rules are in `notebook/package/exakit_nb/lab.py`, in `feature_ideas`.

## How an idea is judged [#how-an-idea-is-judged]

The lab leaves out the columns that give the answer away and the personal data. See [Columns that give the answer away](/data-scientist/prepare/leakage).

The kit tests each idea on rows the model did not train on. An idea helps when the score rises in cross-validation and does not fall on the held-out rows. An idea that pushes a yes-or-no score almost to perfect is marked suspicious, usually because it gives the answer away. The card does not let you keep a suspicious idea.

## Keep an idea [#keep-an-idea]

Keep an idea by passing its series to the next model lab:

```python
lab = nb.model_lab(connection, dataset, features={idea.id: result["series"]})
```

With an AI model set up, `nb.feature_ideas(lab, ai=True)` adds up to four more ideas. The model receives the column names, their roles and the scores. It never receives a row or a value.

Back to [Prepare](/data-scientist/prepare). Previous: [Prepared views](/data-scientist/prepare/prepared-views). Next: [When it goes wrong](/data-scientist/prepare/troubleshooting).
