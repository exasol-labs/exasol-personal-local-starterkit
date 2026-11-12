# Your AI model in this stage (/data-scientist/model/ai-model)



## Your AI model in this stage [#your-ai-model-in-this-stage]

The AI model is optional. Every step in the model stage runs without one. Without a model, `nb.feature_ideas(lab)` still returns the rule-based ideas. With a model, `nb.feature_ideas(lab, ai=True)` adds up to four more.

Your model has one job here: it suggests feature ideas. It never sees rows, never approves a column map, and never runs SQL.

<Flow
  caption="An AI suggestion, from names to a tested idea"
  steps="[
  { title: &#x22;The kit sends names and roles&#x22;, text: &#x22;Column names, roles, the model scores so far, the five kinds it may use, and the target's name. Never a row or a value.&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;Your model suggests up to four&#x22;, text: &#x22;Only of the five kinds below, each built from existing columns&#x22;, code: &#x22;nb.feature_ideas(lab, ai=True, conn=connection)&#x22;, tone: &#x22;ai&#x22; },
  { title: &#x22;The kit checks each suggestion&#x22;, text: &#x22;Suggestions that name the target, or a column the data does not have, are dropped&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;The kit tests the rest&#x22;, text: &#x22;Each one goes through the same verdict as any other idea&#x22;, code: &#x22;nb.try_feature(lab, idea)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;You read the SQL and decide&#x22;, text: &#x22;No idea is kept without you&#x22;, tone: &#x22;you&#x22; },
]"
/>

## What it is sent [#what-it-is-sent]

The code in `lab.py` builds one request with these parts:

* the target's name
* every column name and its role. A column marked sensitive is left out.
* the cross-validated score of each model so far, rounded to three decimals
* the five kinds of idea it may suggest
* a rule: suggest up to four, use only those kinds and existing column names, and never use the target or a column filled in after the outcome

No row and no value is sent.

## What it may suggest [#what-it-may-suggest]

Five kinds only. The kit builds each one as SQL and tests it like any other idea.

| Kind             | Columns                  | The SQL the kit writes                    |
| ---------------- | ------------------------ | ----------------------------------------- |
| `ratio_to_group` | a measure and a category | `"m" / AVG("m") OVER (PARTITION BY "c")`  |
| `combine`        | two categories           | `` `"a" \|\| ' · ' \|\| "b"` ``           |
| `days_since`     | a date                   | `DAYS_BETWEEN(CURRENT_DATE, "d")`         |
| `as_number`      | one column               | `CAST("c" AS DOUBLE)`                     |
| `is_missing`     | one column               | `CASE WHEN "c" IS NULL THEN 1 ELSE 0 END` |

A suggestion of another kind, or with the wrong number of columns, is dropped.

## What the kit checks, and what it cannot [#what-the-kit-checks-and-what-it-cannot]

The kit checks two things. It drops a suggestion that names the target, and a suggestion that names a column the data does not have. It reads up to four suggestions and no more.

The prompt also tells the model not to use a column written after the outcome. The kit cannot check that by itself. The verdict from `nb.try_feature` and your reading of the SQL are the check. An idea that scores above 0.98 on the held-out rows gets the verdict `suspicious`, and the kit tells you not to keep it.

## Where the data goes [#where-the-data-goes]

The model is the endpoint you set. It is called only when you pass `ai=True`, or when you run the themes step. With a model set up, feature ideas send names and roles, never rows.

The optional themes step in `01_explore` is different. It sends a sample of the newest texts on each side of the target to your model, so it needs a text column. The practice datasets have none, so the step skips.

## Tracing [#tracing]

When Langfuse is set up, each call is traced. Pass `conn=connection` to `nb.feature_ideas`, and the call goes into one trace named `feature-ideas`, tagged with the database session. Set-up is on [AI and Langfuse](/data-scientist/set-up/ai-and-langfuse).

## Set it up [#set-it-up]

Run `nb.model_setup()` in a notebook, or call `nb.use_model(MODEL_ID, PROVIDER_BASE_URL)` yourself. Without one, `nb.feature_ideas(lab, ai=True)` stops with the message "No AI model is set up". Check what is set with `nb.model_settings()`. The providers and where to find their keys are on [Set up Exasol](/data-scientist/set-up).

The model is never asked to approve anything, and it never changes your data.

Back to [Model](/data-scientist/model). Troubleshooting is on [Model: when it goes wrong](/data-scientist/model/troubleshooting).
