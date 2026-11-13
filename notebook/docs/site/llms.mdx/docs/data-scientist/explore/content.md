# Explore and understand (/data-scientist/explore)



Before you compute anything from data, you need to know what each column means. Is `CUSTOMER_ID` a name or a count? Is `ORDER_DATE` the day of the order or the day of delivery? Which column is the outcome you want to predict? In this stage the kit proposes an answer for every column, and you confirm it. Once you approve the answers, every later step reads them, and so does every AI client that asks the database.

<Flow
  caption="What happens when you approve a column map"
  steps="[
  { title: &#x22;You approve&#x22;, text: &#x22;Approve the column map in the card, or call approve in a cell&#x22;, code: &#x22;role_review.approve({...}, {...})&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;The kit checks&#x22;, text: &#x22;Every column has a role, no column sits in two slots, the table has not changed&#x22;, code: &#x22;exakit describe AMAZON.ORDER_LINES --approve&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;A new version is saved&#x22;, text: &#x22;The next version of the column map, under the kit's own folder on this computer&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;The semantic model is rebuilt&#x22;, text: &#x22;The schema's model in Exasol Semantic Views, the database's semantic layer&#x22;, tone: &#x22;db&#x22;, href: &#x22;/kit/data/semantic-views&#x22; },
]"
/>

## The flow [#the-flow]

Explore has three parts. Each one reads the approved column map.

1. **The column map.** The kit proposes a role for every column. You approve the roles and the slots.
2. **The semantic model.** Approving publishes the schema's model in Exasol Semantic Views. A semantic model is a named layer over the tables. It says which columns are groups, which are numbers to add up, and how tables link. You can also build one model that spans several sources.
3. **Explore and ask.** You compare groups and trends, and ask questions. A question you ask runs only after you approve its SQL.

## Where you do it [#where-you-do-it]

| Guided view                                                                                    | Notebook code                                                                                                                                                                                                                                                                  | Terminal                                                                                                                                                               |
| ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Understand** in `00_quickstart`: the **Column map** card and the **Semantic views** section. | `00_quickstart`, *Approve the column map*: `nb.review_roles`, `role_review.approve(...)`, `nb.show_roles`, `nb.leakage_check`, `nb.column_map_versions`, `nb.data_map`. *Semantic views*: `nb.semantic_model`, `nb.semantic_sql`, `nb.refresh_semantic`, `nb.semantic_models`. | `exakit describe SCHEMA.TABLE` to draft. `--approve` to approve. `--show`, `--versions`. `--schema` for links. `--model`, `--refresh`, `--models` for semantic models. |
| **Working on** and **Compare groups and see trends** in `01_explore`.                          | `01_explore`: `nb.sql` with `nb.show_sql()`, `nb.note_groups`, `nb.note_trend`.                                                                                                                                                                                                | None. These run in the notebook.                                                                                                                                       |
| **Ask** in `02_ask_your_data`.                                                                 | `02_ask_your_data`: `nb.example_questions`, `nb.draft_question`, `nb.ask`, `proposal.edit(...)`, `proposal.approve()`, `proposal.run()`.                                                                                                                                       | None.                                                                                                                                                                  |

The notebooks keep their choices in their first cell. `DATASET = None` follows the dataset you approved last.

## One button: Fill everything in with AI [#one-button-fill-everything-in-with-ai]

Under **Choose your data**, the **Fill in with AI** card has one button. It runs once for every table you chose, from all your sources together, and fills the cards below it.

| What it does                                                                                       | Where the answer goes                                                                                                         |
| -------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Reads every chosen table, then fills each one's column map with the others in view                 | **What each column means**: the meanings it would change, the other choices and a description per column, on each table's tab |
| Notes which columns mean the same thing across your tables, then checks each pair against the data | **Semantic views**: the links, each with what the data says                                                                   |
| Says what each table and each link is, and names the model                                         | **Semantic views**: the sentence under each table and link, the model's name and what it is about                             |

The model reads names, types and what the kit measured. It is not shown a row, and a personal-data column is left out. A pair it reads as "the same thing" is only a reading: it becomes a link when the values agree, and a pair of plain numbers still waits for your tick.

It fills in. It does not approve a column map or publish a model: you look each card over, change what is wrong, then approve and publish. A part that fails is named on the card, and the rest stands.

In the cards, explanations are behind the **(i)** beside each title.

## In this stage [#in-this-stage]

<Cards>
  <Card title="The column map" href="/data-scientist/explore/column-map" description="What each column is for: roles, slots, the target, and drafts" />

  <Card title="Approve the column map" href="/data-scientist/explore/approve-the-column-map" description="What approval checks and writes, the amazon_sales example, and versions" />

  <Card title="Semantic views" href="/data-scientist/explore/semantic-views" description="Publish a model, ask it in Semantic SQL, and measured results" />

  <Card title="Linked tables" href="/data-scientist/explore/linked-tables" description="The schema map: which tables link, and how to correct the links" />

  <Card title="Compare groups and trends" href="/data-scientist/explore/compare-groups" description="Count rows by group and over time, with notes you can read" />

  <Card title="Ask questions in plain language" href="/data-scientist/explore/questions" description="Draft a read-only query, read it, approve it, then run it" />

  <Card title="Is my data sent anywhere?" href="/data-scientist/explore/data-privacy" description="What leaves this computer, and when" />

  <Card title="When it goes wrong" href="/data-scientist/explore/troubleshooting" description="Approval, semantic model, and question errors, with the fix" />
</Cards>

## What you have at the end [#what-you-have-at-the-end]

An approved column map, saved as a version, and a published semantic model that AI clients can read. You have also seen how the tables link, and you have compared groups and asked questions with queries you approved.

Next: [Prepare](/data-scientist/prepare).

<StageNav n="3" />
