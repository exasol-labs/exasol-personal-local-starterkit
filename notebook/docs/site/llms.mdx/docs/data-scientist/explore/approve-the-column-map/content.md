# Approve the column map (/data-scientist/explore/approve-the-column-map)



Approval makes a draft column map count. The kit checks it, saves it as a new version, and publishes it for the schema's semantic model. Use the guided card or the notebook. The same checks run either way.

<Flow
  caption="What happens when you approve a column map"
  steps="[
  { title: &#x22;You approve&#x22;, text: &#x22;Approve column map in the card, or call approve in a cell&#x22;, code: &#x22;role_review.approve({...}, {...})&#x22;, tone: &#x22;you&#x22; },
  { title: &#x22;The kit checks&#x22;, text: &#x22;roles, slots, the table unchanged, the leakage check&#x22;, code: &#x22;exakit describe <id> --approve&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;Semantic model rebuilt&#x22;, text: &#x22;SEM_<SCHEMA> in Exasol Semantic Views&#x22;, tone: &#x22;db&#x22;, href: &#x22;/data-scientist/explore/semantic-views&#x22; },
]"
/>

## The card, top to bottom [#the-card-top-to-bottom]

The **What each column means** card is laid out in the order you work:

| Part                            | What it is for                                                                                                                                                                            |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tables                          | Shown when you chose more than one table in **Choose your data**. One tab per table. A tick means its column map is approved, a ring means it is not. The card works on the tab you pick. |
| Check the kit's guesses with AI | Optional. One button asks your AI model which guesses it would change.                                                                                                                    |
| The three questions             | What to predict, the guesses the kit was unsure of, and the other choices.                                                                                                                |
| Approve column map              | Saves this table's map as a new version.                                                                                                                                                  |
| Next table                      | Shown after an approval when other tables are left. It says how many are approved and opens the next one. After the last one it points to **Semantic views**.                             |

Each table is approved on its own. Switching tabs with changes you have not approved asks once before leaving them.

### A second look by AI [#a-second-look-by-ai]

The kit drafts each role from measurements: how many distinct values a column has, its type, how many rows are empty. A number that is really a code, such as an account number, can look like an amount to add up. A model reads the name the way a person does.

**Check with AI** runs `nb.check_roles(role_review)`. The model set up for the kit is shown the table's name and, for each column, its name, type, the drafted role with its confidence, the kit's measured evidence and the column's note. It is not shown a row. A column the map marks as personal data is left out entirely.

The answer is a list of suggestions: the column, the kit's role, the role the model would use, and one sentence of why. The kit keeps a suggestion only when it names a real column and one of the eight roles and differs from the draft. **Use** changes that one choice in the card, and **Use all** changes every one. Nothing is saved until you press **Approve column map**.

Without a model the bar says where to set one up, and the rest of the card works as before. In a notebook cell, set `AI_CHECK = True` in the cell under the review.

## What approval checks and writes [#what-approval-checks-and-writes]

* Every column has a role, and no column sits in two slots.
* The table has not changed since the kit profiled it.
* The data is checked again. A column that gives the target away is reported. The column stays in the map and is left out of the model. See [Columns that give the answer away](/data-scientist/prepare/leakage).
* The next **version** is written to the kit's store on this computer, under `~/.exasol-starter-kit/descriptors/`.
* The roles are published in Exasol Semantic Views. The schema's model is rebuilt: its time, category and flag columns become dimensions, and its measures become facts with `total_` and `average_` metrics. A sensitive column is never exposed. If publishing fails, the approval still stands, and the message says why.
* The active workflow's log gets one line.

When the kit has no Semantic Views in the database, it installs the semantic-views add-on first, the same as `exakit marketplace semantic-views`.

## Worked example: amazon_sales [#worked-example-amazon_sales]

The worked example uses `amazon_sales`, the sample orders table: `AMAZON.ORDER_LINES`. The kit ships an approved column map for it. The map is the one you would get if you approved the proposal without change.

The shipped map gives these slots:

| Slot       | Column          | Why                          |
| ---------- | --------------- | ---------------------------- |
| `key`      | `ORDER_LINE_ID` | one row per order line       |
| `time`     | `ORDER_DATE`    | when the order was placed    |
| `text`     | none            | the table has no free text   |
| `target`   | `CANCELLED`     | the outcome a model predicts |
| `category` | `CATEGORY`      | the groups to compare        |
| `entity`   | `SHIP_STATE`    | where the order went         |

Three things in the map are worth reading before you approve it:

* **Check these first.** The card lists the columns the kit was least sure about, first. `SHIP_CITY` and `SHIP_STATE` are both drafted at low confidence. The kit's evidence for `SHIP_STATE` is 47 distinct values. The card shows that evidence beside it.
* **Personal data.** `SHIP_POSTAL_CODE` is marked sensitive. It is never charted, grouped or sent to a model.
* **The answer.** `STATUS` is a category with 13 values, and it gives the answer away: a cancelled order has a cancelled status. The approval warns about it, and the model leaves it out. The [leakage check](/data-scientist/prepare/leakage) explains how.

Approve in the card with **Approve column map**, or in the notebook:

```python
role_review = nb.review_roles(connection, chosen_data)
role_review.approve({"SHIP_CITY": "identifier"}, {"target": "CANCELLED"})   # for example: a role you change, and a slot you set
dataset = role_review.dataset()
nb.show_roles(dataset)
```

The first argument holds the roles you change. The second holds the slots. With nothing to change, the saved approval stands.

On a table directly, with no review:

```python
draft = nb.describe("AMAZON.ORDER_LINES")
draft.set(SHIP_CITY="identifier")      # for example: a role you change
draft.slot(target="CANCELLED")         # the outcome to predict: you choose it
dataset = draft.approve()
```

After the approval, the cell that follows it runs the leakage check. The printed line for a column that gives the answer away has this form:

```text
- STATUS gives CANCELLED away: CANCELLED is 1 whenever STATUS is '...'. It was probably written after the outcome - leave it out of any model.
```

The text in the quotes depends on the data, so the cell prints the value it found.

## Versions [#versions]

Every approval is a new version. Nothing is overwritten.

```python
nb.column_map_versions(dataset.id)     # every saved version, oldest first
nb.current_version(dataset.id)         # the approved one
```

Approving an older version's roles again brings it back as the newest version. In the card, **Version history** lists each version with what changed, and **Restore** saves an older version's choices as a new one.

To change the roles later, open the quickstart, change them and approve again. The other notebooks follow the newest approval when you run their first cell again.

Back to [Explore and understand](/data-scientist/explore). Previous: [The column map](/data-scientist/explore/column-map). Next: [Semantic views](/data-scientist/explore/semantic-views).
