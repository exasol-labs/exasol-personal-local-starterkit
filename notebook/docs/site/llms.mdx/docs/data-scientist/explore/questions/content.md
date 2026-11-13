# Ask questions in plain language (/data-scientist/explore/questions)



You can ask a question in English. The kit drafts one read-only SQL query. You read it, approve it, and only then does it run. Nothing runs against your data before you approve the exact text, and the query runs as a read-only user.

## Questions in plain language [#questions-in-plain-language]

Ask a question in English. The kit drafts one read-only SQL query. You read it, approve it, and only then does it run.

<Flow
  caption="What happens to a question"
  steps="[
  { title: &#x22;You ask&#x22;, text: &#x22;A question in plain language, about an approved dataset&#x22;, code: &#x22;nb.draft_question(connection, dataset, QUESTION)&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;A query is drafted&#x22;, text: &#x22;The kit's rules, or your AI model from the column map. No rows are sent.&#x22;, code: &#x22;proposal.sql&#x22;, tone: &#x22;ai&#x22; },
  { title: &#x22;You read and approve&#x22;, text: &#x22;Read the SQL, edit it if it is wrong, then approve the exact text&#x22;, code: &#x22;proposal.approve()&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;It runs read-only&#x22;, text: &#x22;Through the Exasol MCP server, as the read-only user. At most 1,000 rows come back.&#x22;, code: &#x22;answer = proposal.run()&#x22;, tone: &#x22;db&#x22; },
]"
/>

```python
QUESTION = "How many rows are in each category?"
dataset = nb.dataset(connection, nb.chosen_dataset(None))
nb.example_questions(dataset)                          # questions this column map can answer

proposal = nb.draft_question(connection, dataset, QUESTION)      # the kit's rules: no model
proposal = nb.ask(dataset, QUESTION)                             # your AI model drafts it from the column map
proposal = nb.ask(dataset, QUESTION, proposed_sql="SELECT ...")  # SQL you wrote yourself
```

The three ways differ in who drafts the SQL:

| Way                             | Who drafts                                                                                                                                                         | Sent anywhere                                      |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------- |
| `nb.draft_question(...)`        | The kit's rules. They match common question shapes: a rate, count, total or average per group, a top N, a trend over time, a filter by year or by a group's value. | Nothing leaves this computer. No model is called.  |
| `nb.ask(dataset, question)`     | Your AI model                                                                                                                                                      | The approved column map and the question. No rows. |
| `nb.ask(..., proposed_sql=...)` | You                                                                                                                                                                | Nothing                                            |

The rules drafter needs no model. `nb.ask` needs one, which you set up with `nb.model_setup()`. Without a model, `nb.ask` stops and says to pass `proposed_sql=` with SQL you wrote. To set up a model, see [Set up Exasol](/data-scientist/set-up/ai-and-langfuse).

### Answers come from the semantic model [#answers-come-from-the-semantic-model]

When a semantic model covers your data, your AI model answers from it. It is shown the model's metrics and dimensions, writes Semantic SQL over the published view, and Exasol Semantic Views compiles that into the plain SQL you read and approve. An AI client over MCP uses the same definitions, so the notebook and the client give the same number for the same question.

Measured: for *revenue by region*, the draft `SELECT region, total_amount FROM SEM_XSRC_TEST.ORDER_LINES GROUP BY region` compiled to a `SUM(AMOUNT)` over `AMAZON.ORDER_LINES` with a `LEFT JOIN` to the state table, the join the model defines. A draft naming a metric the model does not have was refused (`SEMANTIC_QUERY_020`).

The proposal says which model answered and shows the Semantic SQL under *What the model assumed*. If no model covers the data, or the question cannot be put in the model's terms, the SQL is drafted from the approved column map and the proposal says so under *Check before you approve*.

## Read, edit and approve [#read-edit-and-approve]

Read the proposal, and edit it if it is wrong:

```python
proposal.edit("SELECT ...")      # replaces the SQL and removes any approval
```

Approve it, then run it:

```python
proposal.approve()
answer = proposal.run()
```

In the notebook, set `APPROVE_SQL = True` in the Ask cell and run it again. Nothing runs before approval.

Only the exact text you approved runs. `run()` checks the text against the approval. Any change after approval, including an edit, means the query must be approved again.

Each approval adds a line to the workflow log with the question, the approved SQL, its digest and the column map version. Each run adds a line with the row count.

## What the kit allows [#what-the-kit-allows]

The kit accepts one `SELECT` or `WITH` statement. It refuses a second statement, and any statement that writes, such as `INSERT`, `UPDATE`, `DELETE`, `CREATE`, `DROP`, `GRANT` or `COPY`.

The query runs through the Exasol MCP server, on the read-only user, and never on the notebook's connection. The server returns at most 1,000 rows. The notebook says so when it returns that many.

## The worked example [#the-worked-example]

The worked example is the question in the notebook: `How many rows are in each category?` on `amazon_sales`. For a rate, the rules drafter's own documentation uses the question `Which category has the highest cancellation rate?` on the same table.

Read the SQL the kit returns before you approve it. The repository does not record the SQL or the answer for either question. To see the SQL the kit drafts, draft the question and read the proposal's SQL. Drafting is not approval, so nothing runs:

```python
proposal = nb.draft_question(connection, dataset, "Which category has the highest cancellation rate?")
proposal.sql
```

Check the figures against the SQL yourself.

Back to [Explore and understand](/data-scientist/explore). Previous: [Compare groups and trends](/data-scientist/explore/compare-groups). Next: [Is my data sent anywhere?](/data-scientist/explore/data-privacy).
