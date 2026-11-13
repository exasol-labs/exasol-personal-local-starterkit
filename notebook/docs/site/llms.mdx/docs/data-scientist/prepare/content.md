# Prepare (/data-scientist/prepare)



Before you compute from data, you check that the data says what you think it says. A repeated ID counts a customer twice. An empty cell drops out of an average without a warning. A placeholder such as `Unknown Device` looks like a category, and it means "not known". A column written after the outcome makes a model look perfect. In this stage the kit finds these problems and explains what each one does to a result. It never changes your table. When you ask for a cleaned or joined version, it creates a view next to your table, and that view gets its own approved column map.

<Flow
  caption="Checking the data, then creating a view"
  steps="[
  { title: &#x22;The kit checks the table&#x22;, text: &#x22;Repeats, copies, empty cells, placeholders and a rare outcome. Each finding is one sentence.&#x22;, code: &#x22;nb.data_checks(connection, dataset)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;You decide what to do&#x22;, text: &#x22;Each finding says what it does to a result. The kit does not fix anything by itself.&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;The kit proposes a view&#x22;, text: &#x22;A joined view along the links, or a typed and cleaned view. Nothing is created yet.&#x22;, code: &#x22;nb.typed_view(connection, dataset)&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;You create it&#x22;, text: &#x22;Read the changes and the SQL first. Then create the view.&#x22;, code: &#x22;prepared = proposal.create(connection)&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;The view gets its own column map&#x22;, text: &#x22;Created in EXAKIT_PREPARED, with the roles of the table it came from, and approved&#x22;, tone: &#x22;db&#x22; },
]"
/>

## The flow [#the-flow]

Preparation has two halves. The first half only reads: the checks, the links and the leakage check. The second half creates views, and only when you say so.

1. **Check.** Run the data checks, and read each finding.
2. **Look at the links.** Read the schema map to see which tables link to yours.
3. **Propose a view.** A joined view brings in the linked tables. A typed view fixes types and cleans values. Read the proposal. It shows each change with its evidence and the exact SQL.
4. **Create.** Create only the views you want. Each view is described and approved, and the steps after it read the view.

## Where you do it [#where-you-do-it]

| Guided view                                                                                                                                                  | Notebook code                                                                                                                                                                                                        | Terminal                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **Is the data clean?** in the **Explore and predict** card, with **Linked tables** and **A cleaned copy** under it. Each has a button that creates the view. | `01_explore`, *Prepare the data*: `nb.data_checks`, `nb.describe_schema`, `schema_map.joined_view(...)`, `joined_view_proposal.create(...)`, `nb.typed_view`, `typed_view_proposal.create(...)`, `nb.leakage_check`. | `exakit describe --schema SCHEMA` lists the links. `--approve --link` and `--unlink` change them. No command runs the checks or creates a view. |

In the first cell of `01_explore`, `USE_JOINED = True` and `USE_PREPARED = True` create the proposed views and make the later steps read them. Both are `False` at the start, so nothing is created until you set them.

## In this stage [#in-this-stage]

<Cards>
  <Card title="Data checks" href="/data-scientist/prepare/data-checks" description="Repeats, copies, empty cells, placeholders and a rare outcome, with the fraud_transactions counts" />

  <Card title="Columns that give the answer away" href="/data-scientist/prepare/leakage" description="The leakage check, the rule it uses, and the amazon_sales STATUS column measured" />

  <Card title="Linked tables and the joined view" href="/data-scientist/prepare/linked-tables-view" description="Join linked tables into one wide view of your table" />

  <Card title="A typed, cleaned view" href="/data-scientist/prepare/cleaned-views" description="Fix types, trim text, turn placeholders into NULL, and drop copies, after you read the changes" />

  <Card title="Prepared views" href="/data-scientist/prepare/prepared-views" description="The views EXAKIT_PREPARED holds, their names, and how each gets its column map" />

  <Card title="Features" href="/data-scientist/prepare/features" description="New inputs for a model, tested before you keep them" />

  <Card title="When it goes wrong" href="/data-scientist/prepare/troubleshooting" description="Findings, skipped views, and code columns that stayed text" />
</Cards>

## What you have at the end [#what-you-have-at-the-end]

A checked table, with the findings you have decided on. Optionally, a joined view and a typed view in `EXAKIT_PREPARED`, each with its own approved column map. The steps after this one read the view you created, or your table if you created none.

Next: [Model](/data-scientist/model).

<StageNav n="4" />
