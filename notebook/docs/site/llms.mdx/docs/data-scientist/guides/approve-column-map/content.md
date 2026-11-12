# Review and approve the column map (/data-scientist/guides/approve-column-map)



This is step 2 of `00_quickstart`. Until the map is approved, Explore, Ask and Share have nothing to read. For what the roles and slots mean, see [Column map and approval](/data-scientist/concepts/descriptor).

<Steps>
  <Step>
    ### Open the review [#open-the-review]

    ```python
    role_review = nb.review_roles(connection, chosen_data)
    ```

    The kit profiles the table and proposes a role for every column.
  </Step>

  <Step>
    ### Check the uncertain columns first [#check-the-uncertain-columns-first]

    **Check these first** lists the columns the kit was least sure about, each with the evidence that chose its role. Start there.
  </Step>

  <Step>
    ### Correct roles and choose the target [#correct-roles-and-choose-the-target]

    Change a role where it is wrong. Choose the **target**: the outcome you want to predict. The kit never chooses it. Leave a slot empty when no column fits.
  </Step>

  <Step>
    ### Approve [#approve]

    Press **Approve column map**, or in code:

    ```python
    role_review.approve({"ZIP_CODE": "identifier"}, {"target": "CANCELLED"})
    ```

    The first argument is the roles you change, the second the slots. With nothing to change, the saved approval stands.
  </Step>

  <Step>
    ### Read it back [#read-it-back]

    ```python
    dataset = role_review.dataset()
    nb.show_roles(dataset)
    ```
  </Step>
</Steps>

## What you get at the end [#what-you-get-at-the-end]

An approved column map. It is saved as a new version, and the schema's [semantic model](/data-scientist/guides/semantic-views) in Exasol Semantic Views is rebuilt with it, so AI clients read the same meaning. Explore, Ask and Share read only an approved map.

## After approving [#after-approving]

```python
leaking = nb.leakage_check(connection, dataset)       # columns that give the outcome away
versions = nb.column_map_versions(dataset.id)         # every saved version
nb.data_map(connection)                               # all your data in one map
```

<Callout>
  Approval checks the data again. A warning about a column that gives the target away is not an error: the column stays in the map and is left out of the model.
</Callout>

## Change your mind later [#change-your-mind-later]

Open the quickstart, change the roles and approve again. That writes a new version. The other notebooks follow the newest approval when you run their first cell again.
