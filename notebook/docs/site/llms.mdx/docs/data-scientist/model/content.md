# Model (/data-scientist/model)



Modelling turns the columns you approved into a prediction: will this order be cancelled, is this payment fraud, which rows look unusual. A model is only useful if it beats a simple guess, so start with the simplest one and improve it step by step. The kit gives you a baseline model in `01_explore`, a model lab that trains several models on the same rows, and feature ideas that you test before you keep them. Everything trains on this computer with scikit-learn, the Python machine-learning library the kit includes.

## The flow [#the-flow]

<Flow
  caption="From approved roles to a model you can judge"
  steps="[
  { title: &#x22;You approve the roles&#x22;, text: &#x22;The target and the groups come from the column map&#x22;, tone: &#x22;you&#x22;, href: &#x22;/data-scientist/explore&#x22; },
  { title: &#x22;Train the baseline&#x22;, text: &#x22;A small logistic regression, with the answer-givers left out&#x22;, code: &#x22;nb.leakage_check(connection, dataset)&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/model/baseline&#x22; },
  { title: &#x22;Run the model lab&#x22;, text: &#x22;Every model of one task trains on the same rows&#x22;, code: 'nb.model_lab(connection, dataset, &#x22;predict_yes_no&#x22;)', tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/model/model-lab&#x22; },
  { title: &#x22;Try feature ideas (optional)&#x22;, text: &#x22;Each idea is retrained on the same split before you keep it&#x22;, code: &#x22;nb.try_feature(lab, ideas[0])&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/model/feature-ideas&#x22; },
  { title: &#x22;You decide what to keep&#x22;, text: &#x22;A verdict says whether an idea helped. Scoring on unseen rows is in Evaluate.&#x22;, tone: &#x22;you&#x22;, href: &#x22;/data-scientist/evaluate&#x22; },
]"
/>

## Where you do it [#where-you-do-it]

| Guided view                                                                                                 | Notebook code                                                                          | Terminal                             |
| ----------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------ |
| `01_explore`: the **Build a model** card runs the model lab. The baseline's result is in the same notebook. | The cells **Train a baseline model** and **The model lab (optional)** in `01_explore`. | None. Training runs in the notebook. |

The first cell of `01_explore` holds the settings. `DATASET` picks the data. `USE_PREPARED = True` makes the model read the typed, cleaned view that [Prepare](/data-scientist/prepare) creates. The lab cell looks like this:

```python
LAB_TASK = "predict_yes_no"   # or "predict_number", "find_groups", "find_unusual"
lab_data = nb.lab_data(connection, dataset)   # read once; lab_data.left_out says what was left out and why
kept_features = {}
lab = nb.model_lab(connection, dataset, LAB_TASK, model="all", target_number=None, data=lab_data, features=kept_features)
```

## How we used it [#how-we-used-it]

The sample dataset `amazon_sales` is the table `AMAZON.ORDER_LINES`. It has 128,975 order lines. 18,332 of them (14.2%) are cancelled, which is the target `CANCELLED`.

* **The baseline** uses three inputs only: the category, the state and the month of `ORDER_DATE`. It does not read `STATUS`, which gives the target away. See [Start with a baseline](/data-scientist/model/baseline).
* **The lab** scores with ROC AUC, because the rarer answer is above 5%. It splits by time, so it learns from the older rows and is tested on the newer ones. See [The model lab](/data-scientist/model/model-lab).

The messy dataset, `fraud_transactions`, has a rare answer, no date and placeholder values. Its differences are listed in [The model lab](/data-scientist/model/model-lab).

## In this stage [#in-this-stage]

<Cards>
  <Card title="Start with a baseline" href="/data-scientist/model/baseline" description="The simplest model, and the score a real model must beat" />

  <Card title="The model lab" href="/data-scientist/model/model-lab" description="What the lab reads, how it splits the rows, and what it leaves out" />

  <Card title="The models the lab tries" href="/data-scientist/model/the-models" description="Every model, the rule that picks one, and the settings" />

  <Card title="Feature ideas" href="/data-scientist/model/feature-ideas" description="New inputs built from your columns, and the verdict for each" />

  <Card title="Your AI model in this stage" href="/data-scientist/model/ai-model" description="What an AI model may suggest here, and what it is sent" />

  <Card title="Saving, MLflow and training in the database" href="/data-scientist/model/saving-and-mlflow" description="What is kept after a run, and where the in-database path starts" />

  <Card title="When it goes wrong" href="/data-scientist/model/troubleshooting" description="The warnings and errors you see while you model" />
</Cards>

## What you have at the end [#what-you-have-at-the-end]

A baseline score, the lab's leaderboard with the model it picked, the importance list, and the feature ideas you kept with their verdicts. The next step is to check the score on rows the model never trained on, in [Evaluate](/data-scientist/evaluate).

<StageNav n="5" />
