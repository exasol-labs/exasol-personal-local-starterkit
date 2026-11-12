# What changed, and where you go (/data-scientist/monitor/what-changed)



Not every change is noticed. This table says, for each kind of change, what the kit notices on its own and what it does not. The last column names the stage to return to.

## What changed, what the kit notices, where you go [#what-changed-what-the-kit-notices-where-you-go]

| What changed                               | What the kit notices                                                                                                           | What you do                                           | Go back to                                                     |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------- | -------------------------------------------------------------- |
| Columns added, removed, renamed or retyped | `describe` returns a draft, because the schema digest no longer matches                                                        | Review the draft and approve a new version            | [Explore](/data-scientist/explore): the column map             |
| New roles in an approved column map        | Every semantic model the table is in is rebuilt by the approval                                                                | Check the result of the new roles                     | [Model](/data-scientist/model), to see the effect on the score |
| Rows changed, with no column change        | Nothing on its own. Approval checks the data again, and a training hand-off is refused when its data digest no longer matches. | Run Prepare and Explore again, and look at what moved | [Prepare](/data-scientist/prepare)                             |
| A new table, or a new link between tables  | Nothing, until the model is rebuilt                                                                                            | Refresh the semantic model                            | [Semantic views](/kit/data/semantic-views)                     |
| The model's inputs or settings changed     | Nothing. The fitted model is not saved, so each run trains it again.                                                           | Rerun the lab, then score it again                    | [Model](/data-scientist/model)                                 |
| The dashboard's query changed              | Nothing. The preview was made from the old query.                                                                              | Make a new dashboard draft and preview it             | [Communicate and deploy](/data-scientist/communicate)          |
| The AI model or its settings changed       | Nothing                                                                                                                        | Run `nb.model_settings()` to check what is set        | [Set up Exasol](/data-scientist/set-up)                        |

## The table changed [#the-table-changed]

`nb.describe` compares the table's column names and types with the approved version. If they match, the approved version comes back. If they do not, it makes a draft:

* Roles for the columns whose name and type did not change are carried over.
* Changed or new columns are flagged with low confidence, and the evidence says the column changed since the approved version.
* The approved version stays approved for the old columns. Nothing is overwritten.

`approve` refuses if the table changed since it was described, and says to describe it again. Explore, Ask and Share read only an approved column map. If a step reports that the map is not approved, open the quickstart and approve it.

The kit checks columns and types when you describe. It does not compare every row on each run. Rows are checked when you approve, and again by a training hand-off's staleness check.

Back to [Monitor and iterate](/data-scientist/monitor). Next: [The workflow log](/data-scientist/monitor/the-workflow-log).
