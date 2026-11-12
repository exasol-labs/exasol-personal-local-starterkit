# Where things live (/data-scientist/develop/where-things-live)



Everything is under the kit's home, `~/.exasol-starter-kit` (or `EXAKIT_HOME` when set).

| Path                                         | What it holds                                                                |
| -------------------------------------------- | ---------------------------------------------------------------------------- |
| `notebooks/starter-kit-notebooks/<persona>/` | Your copies of the notebooks                                                 |
| `notebooks/marimo/<persona>/`                | The Marimo versions                                                          |
| `descriptors/`                               | Approved column maps, one folder per table, every version kept               |
| `last-dataset`                               | The dataset approved last, which the notebooks follow                        |
| `workflows/<id>.jsonl`                       | Workflow logs                                                                |
| `last-workflow`                              | The workflow started or resumed last                                         |
| `bundles/<workflow id>/`                     | Hand-off bundles, each also as a zip                                         |
| `handoffs/`                                  | Training handoffs for the ML Engineer                                        |
| `exakit.env`                                 | Settings such as the model's id and address                                  |
| `credentials/`                               | Secrets, readable by you only. Never read or print these from a notebook.    |
| `kit/`                                       | The kit copy: scripts, datasets, the notebook package and this documentation |

## In the database [#in-the-database]

| Schema                                                 | What it holds                                                                  |
| ------------------------------------------------------ | ------------------------------------------------------------------------------ |
| `SEMANTIC_CATALOG`, `SEMANTIC_ADMIN`, `SEMANTIC_AGENT` | Exasol Semantic Views: the semantic models built from the approved column maps |
| `SEM_<MODEL>`                                          | A model's published semantic views, queried with Semantic SQL                  |
| `EXAKIT_PREPARED`                                      | Joined views and typed, cleaned views you chose to create                      |
| `VS_<NAME>`                                            | The tables of an external source named `<NAME>`                                |

## What an update touches [#what-an-update-touches]

* A kit notebook you did not edit is refreshed when the kit's version changes.
* A notebook you edited, or a file of your own, is never overwritten.
* A notebook you deleted is not copied back.
* Approved column maps, workflow logs and bundles are yours and are left alone.
