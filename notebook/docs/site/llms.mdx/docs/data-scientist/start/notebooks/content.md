# The notebooks and the nine steps (/data-scientist/start/notebooks)



## Open the notebooks [#open-the-notebooks]

```bash
exakit notebook            # JupyterLab
exakit notebook marimo     # Marimo
```

Both open in your browser on the kit's own Python, with the kernel **Exasol (Starter Kit)**. That kernel knows where the kit's connection is, so no notebook asks for a host, a user or a password.

Your copies are in `~/.exasol-starter-kit/notebooks/starter-kit-notebooks/data-scientist/`. A notebook you edited is never overwritten by an update.

## The path [#the-path]

Run the notebooks in order. Each one continues the workflow the first one started, so nothing is copied between them.

| Notebook           | Steps                                     | What you have at the end                                                    |
| ------------------ | ----------------------------------------- | --------------------------------------------------------------------------- |
| `00_quickstart`    | 0 Check the kit, 1 Access, 2 Understand   | A connection, a loaded dataset and an approved column map                   |
| `01_explore`       | 3 Prepare, 4 Explore, 5 Model, 6 Validate | Clean data, comparisons by group and over time, a small model and its score |
| `02_ask_your_data` | 7 Ask with AI                             | An answer from SQL you read and approved                                    |
| `03_share`         | 8 Share, 9 Hand off                       | A published dashboard and one folder a colleague can repeat the work from   |

## The nine steps [#the-nine-steps]

<Steps>
  <Step>
    ### Access [#access]

    Connect, start a workflow and load data: a kit dataset, your own file, or an external source. See [Load data](/data-scientist/guides/load-data).
  </Step>

  <Step>
    ### Understand [#understand]

    Approve the column map: which column is the key, the date, the group and the outcome. See [Descriptor and approval](/data-scientist/concepts/descriptor).
  </Step>

  <Step>
    ### Prepare [#prepare]

    Check the data is clean, see the tables linked to it, and optionally create a typed, cleaned view. See [Prepared views](/data-scientist/concepts/prepared-views).
  </Step>

  <Step>
    ### Explore [#explore]

    Compare groups and look at the data over time. Each query shows its SQL before its result.
  </Step>

  <Step>
    ### Model [#model]

    Set aside columns that give the answer away, then train a small baseline model.
  </Step>

  <Step>
    ### Validate [#validate]

    Score the model on rows it has not seen and see what it leans on.
  </Step>

  <Step>
    ### Ask with AI [#ask-with-ai]

    Ask in plain language, read the proposed SQL, approve it, run it read-only. See [Ask your data](/data-scientist/guides/ask).
  </Step>

  <Step>
    ### Share [#share]

    Turn one checked result into a dashboard: a preview first, published after you check the figures. See [Share a dashboard](/data-scientist/guides/share).
  </Step>

  <Step>
    ### Hand off [#hand-off]

    Pack the column map, every query, the dashboards and the workflow log into one folder and a zip.
  </Step>
</Steps>

Step 0, at the top of the quickstart, checks the kit itself from the notebook. See [Run the kit from a notebook](/data-scientist/guides/run-the-kit).

## Rules every notebook follows [#rules-every-notebook-follows]

* **One assignment picks the data.** `SAMPLE = "..."` in the quickstart, `DATASET = "..."` in the others. `None` means the dataset approved last.
* **No column name is typed.** Queries are built from the approved roles, so the same notebook runs on any table.
* **AI is opt-in.** A model never approves roles, and no rows are sent to one.
* **A step that cannot run says why.** A dataset with no text column skips the text steps and tells you.
