# Column map and approval (/data-scientist/concepts/descriptor)



A **column map** says what each column of a table is for. Its technical name is the **descriptor**, which is the word you see in code and in some file names. Every later query is built from the column map, so no notebook types your column names.

## Roles: what a column is [#roles-what-a-column-is]

The kit profiles the table in SQL and gives every column one of eight roles, with the evidence that chose it.

| Role         | Meaning                       |
| ------------ | ----------------------------- |
| `key`        | One value per row             |
| `time`       | A date or timestamp           |
| `measure`    | A number to add up or average |
| `category`   | A few repeated values         |
| `flag`       | Yes or no                     |
| `text`       | Free text                     |
| `identifier` | Names or codes                |
| `other`      | None of the above             |

## Slots: which column each step uses [#slots-which-column-each-step-uses]

A slot names the one column a step reads.

| Slot       | Used for                      |
| ---------- | ----------------------------- |
| `key`      | Counting rows without repeats |
| `time`     | Anything over time            |
| `text`     | The text steps                |
| `target`   | The outcome to predict        |
| `category` | The groups to compare         |
| `entity`   | Who or what a row is about    |

For the kit's datasets:

| Dataset            | `key`           | `time`       | `text` | `target`     | `category`         | `entity`     |
| ------------------ | --------------- | ------------ | ------ | ------------ | ------------------ | ------------ |
| Amazon sales       | `ORDER_LINE_ID` | `ORDER_DATE` | none   | `CANCELLED`  | `CATEGORY`         | `SHIP_STATE` |
| Fraud transactions | `ROW_ID`        | none         | none   | `FRAUDULENT` | `TRANSACTION_TYPE` | `LOCATION`   |

<Callout>
  In code, two slots keep their older names: `dataset.col("date")` is the `time` slot and `dataset.col("label")` is the `target`.
</Callout>

## Draft and approved [#draft-and-approved]

A column map starts as a **draft**: the kit's proposal. A proposal can be wrong. In `amazon_sales`, `STATUS` gives the answer away; the kit warns about it and the model leaves it out.

Nothing downstream uses a draft. Explore, Ask and Share open only an **approved** dataset. A step given a draft raises `DescriptorNotApproved`, and the message says how to approve it.

## Who approves [#who-approves]

**You do.** Approval is the step where a person confirms the roles the kit proposed. A model never approves roles, and the kit never chooses the **target** for you.

<Tabs items="['Guided card', 'Code', 'Terminal']">
  <Tab value="Guided card">
    In the quickstart, on the column map card: look at **Check these first**, correct what is wrong, then press **Approve column map**.
  </Tab>

  <Tab value="Code">
    ```python
    role_review = nb.review_roles(connection, chosen_data)
    role_review.approve({"ZIP_CODE": "identifier"}, {"target": "CANCELLED"})   # the roles and slots you change
    dataset = role_review.dataset()
    ```

    Or, on a table directly:

    ```python
    draft = nb.describe("AMAZON.ORDER_LINES")
    draft.set(PRODUCT="category")
    draft.slot(target="CANCELLED")
    dataset = draft.approve()
    ```
  </Tab>

  <Tab value="Terminal">
    ```bash
    exakit describe AMAZON.ORDER_LINES --approve
    ```
  </Tab>
</Tabs>

## What approval checks and writes [#what-approval-checks-and-writes]

* Every column has a role, and no column sits in two slots.
* The table has not changed since it was profiled.
* The data is checked again, and a column that gives the target away is reported.
* The next **version** is written to the kit's store on this computer, under `~/.exasol-starter-kit/descriptors/`.
* The roles are published as column comments on a view in the `EXAKIT_SEMANTIC` schema. If publishing fails, the approval still stands and the message says why.
* The active workflow's log gets one line.

## Versions [#versions]

Every approval is a new version. Nothing is overwritten.

```python
nb.column_map_versions(dataset.id)     # every saved version, oldest first
nb.current_version(dataset.id)         # the approved one
```

Approving an older version's roles again brings it back as the newest version.

## Reference [#reference]

[`nb.describe`](/data-scientist/reference/describe#describe), [`nb.Draft`](/data-scientist/reference/describe#Draft), [`nb.review_roles`](/data-scientist/reference/role-picker#review_roles), [`nb.show_roles`](/data-scientist/reference/quickstart#show_roles), [`nb.column_map_versions`](/data-scientist/reference/descriptor-store#column_map_versions), [`nb.DescriptorNotApproved`](/data-scientist/reference/dataset#DescriptorNotApproved).
