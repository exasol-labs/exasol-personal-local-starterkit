# How it fits together (/data-scientist/development/how-it-fits)



## Three layers [#three-layers]

| Layer           | Where                                                    | What it owns                                                                  |
| --------------- | -------------------------------------------------------- | ----------------------------------------------------------------------------- |
| The kit         | `setup/`, the `exakit` command                           | The database, connections, loading, connectors, add-ons, the describe service |
| The helpers     | `notebook/package/exakit_nb/` (`import exakit.nb as nb`) | One Python call for each thing a notebook does                                |
| The guided view | `notebook/package/exakit_guide/` (`exakit.guide`)        | Cards that call the helpers; UI only                                          |

A notebook is cells that call the helpers. A card is a form that calls the same helpers. Neither talks to the database on its own.

## The helpers [#the-helpers]

`exakit.nb` exports about 110 names, listed in [All commands](/data-scientist/development/reference). The rules they follow:

* **The connection comes from the kit.** `nb.connect()` opens it from the kit's encrypted store. No helper prints or returns a host, a user or a password.
* **The kit does the work.** Describing a table is the kit's describe service; loading is `exakit data-load`; connecting a source is `exakit connect`. The helpers call these, they do not reimplement them.
* **SQL is shown.** `nb.sql` records the statement, `nb.show_sql()` prints it, and the workflow logs it.
* **Reads are live.** `nb.components()`, `nb.addons()`, `nb.connectors()` and the rest ask the kit when called.

## The guided view [#the-guided-view]

```text
notebook/package/exakit_guide/
  actions.py     every action: one or more lines of exakit.nb code, and its notebook
  session.py     the notebook's namespace the actions run in
  card.py        the widget; a button's code comes from its action
  screens/       one module per page (home, understand, explore, ask, share): UI only
  static/        card.js and card.css: the renderer, no facts
```

`actions.code(id, **values)` is the exact cell text. `actions.run(id, **values)` runs that text in the notebook's namespace and logs it. A screen changes nothing except through `actions.run`, which is why **Code** can always show what a card did.

## Rules the tests enforce [#rules-the-tests-enforce]

* An action's call exists in its notebook's code section, and calls something `exakit.nb` exports.
* No screen names a dataset, connector, add-on or notebook. Those are read from the kit.
* No action shows a secret: a key is bound at run time, never written into the code.
* Every exported helper has a page in these docs, and every link in them leads somewhere.

## Notebooks [#notebooks]

Sources are `notebook/notebooks/<persona>/<NN>_<name>.py` in jupytext percent format. The `.ipynb` and the Marimo version are built from them:

```bash
python3 tools/notebooks.py --marimo            # rebuild
python3 tools/notebooks.py --check --marimo    # fail when a built file is stale
```

## Further reading [#further-reading]

* [pyexasol](https://github.com/exasol/pyexasol), the Python driver that `nb.connect()` opens, with its [documentation](https://exasol.github.io/pyexasol/master/index.html).
* [exapump](https://github.com/exasol-labs/exapump), the command-line client the kit uses for SQL and loading.
* [Exasol MCP server](https://exasol.github.io/mcp-server/main/index.html), the server behind the AI clients, and its [repository](https://github.com/exasol/mcp-server).
* [virtual-schemas](https://github.com/exasol/virtual-schemas), behind the `VS_<NAME>` schemas of external sources.
* [Exasol Personal](https://github.com/exasol/exasol-personal), the local database the kit deploys.
* [Security](/security), how the layers above handle credentials, the network and models.
