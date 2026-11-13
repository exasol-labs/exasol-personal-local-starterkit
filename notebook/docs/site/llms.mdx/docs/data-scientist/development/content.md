# Development (/data-scientist/development)



This section is for people who build on the kit, or who want the commands behind the notebooks. The stage pages tell you what to do. These pages tell you how it works underneath.

<Cards>
  <Card title="How it fits together" href="/data-scientist/development/how-it-fits">
    The three layers, and the rules that keep them honest.
  </Card>

  <Card title="Command reference" href="/data-scientist/development/reference">
    Every public helper of 

    `exakit.nb`

    , generated from its docstrings.
  </Card>

  <Card title="Where things live" href="/data-scientist/development/where-things-live">
    The files and folders the notebooks read and write.
  </Card>

  <Card title="Add a command" href="/data-scientist/development/add-a-command">
    Write a helper, wire it to a card, and get its page.
  </Card>

  <Card title="These docs" href="/data-scientist/development/docs-site">
    How this site is written, built and shipped.
  </Card>
</Cards>

## How the pieces fit [#how-the-pieces-fit]

Three layers do the work. Each has one job.

| Layer           | Where it lives                                               | What it owns                                                                     |
| --------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| The kit         | `setup/` and the `exakit` command                            | The database, connections, loading, connectors, add-ons and the describe service |
| The helpers     | `notebook/package/exakit_nb/`, imported as `exakit.nb`       | One Python call for each thing a notebook does                                   |
| The guided view | `notebook/package/exakit_guide/`, imported as `exakit.guide` | The cards, which call the helpers. They have no logic of their own.              |

A notebook is cells that call the helpers. A card is a form that calls the same helpers. Neither talks to the database on its own.

Every step follows the same path, whether you run a cell or click a card:

<Flow
  caption="From a notebook cell to the database"
  steps="[
  { title: &#x22;Notebook cell&#x22;, text: &#x22;Or a card button, which runs the same code&#x22;, code: 'dataset = nb.dataset(connection, &#x22;amazon_sales&#x22;)', tone: &#x22;you&#x22; },
  { title: &#x22;exakit.nb helper&#x22;, text: &#x22;Builds the SQL from the approved roles, shows it and logs the step&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;Kit service or CLI&#x22;, text: &#x22;The describe service, exakit data-load or exakit connect. The helper calls these and does not reimplement them.&#x22;, code: &#x22;exakit describe AMAZON.ORDER_LINES&#x22;, tone: &#x22;kit&#x22; },
  { title: &#x22;The database&#x22;, text: &#x22;The Exasol database on this computer&#x22;, tone: &#x22;db&#x22; },
]"
/>

The rules the helpers follow:

* **The connection comes from the kit.** `nb.connect()` opens it from the kit's encrypted store. No helper prints or returns a host, a user or a password.
* **The kit does the work.** Describing a table is the kit's describe service. Loading is `exakit data-load`. Connecting a source is `exakit connect`.
* **SQL is shown.** `nb.sql` records each statement, `nb.show_sql()` prints the last one, and the workflow logs it.
* **Reads are live.** `nb.components()`, `nb.addons()`, `nb.connectors()` and the rest ask the kit when they are called.

Inside the guided view, `actions.py` lists every action as one or more lines of `exakit.nb` code. `actions.code(id, ...)` gives the exact cell text, and `actions.run(id, ...)` runs that text in the notebook's namespace and logs it. A screen changes nothing except through `actions.run`, which is why the **Code** view can always show what a card did.

The tests enforce a few more rules: every action calls something the helpers export, no screen names a dataset or a connector (the kit supplies those), no action shows a secret, and every helper has a page in these docs.

## The command reference [#the-command-reference]

The [command reference](/data-scientist/development/reference) lists every public helper of `exakit.nb`, 116 in all, with a one-line summary and a link to its page. The pages are generated from the docstrings in `exakit_nb`, one page per module.

From a notebook, the docs open at a command's page:

```python
import exakit.nb as nb
nb.docs(nb.describe)     # open one command's page
nb.docs("words")         # search the docs
```

The `exakit` commands are described in `setup/help/exakit.json`. `exakit <command> --help` shows a command's reference and changes nothing.

## Where things live [#where-things-live]

Everything is under the kit's home, `~/.exasol-starter-kit`, or `EXAKIT_HOME` when it is set. The main folders are:

| Path                     | What it holds                                                             |
| ------------------------ | ------------------------------------------------------------------------- |
| `descriptors/`           | Approved column maps, one folder per table, every version kept            |
| `workflows/<id>.jsonl`   | Workflow logs                                                             |
| `bundles/<workflow id>/` | Hand-off bundles, each also as a zip                                      |
| `handoffs/`              | Training hand-offs for the ML Engineer                                    |
| `exakit.env`             | Settings such as the model's id and address                               |
| `credentials/`           | Secrets, readable by you only. Never read or print these from a notebook. |

The full table, including what an update touches and the schemas in the database, is in [Where things live](/data-scientist/development/where-things-live).

## Adding a command [#adding-a-command]

Four steps, and a test:

1. Add a function with a docstring to a module in `notebook/package/exakit_nb/`. Export it in `exakit_nb/__init__.py` and add its name to `__all__`.
2. Call it from the notebook it belongs to, guarded by a variable when it is optional.
3. Add one entry to `actions.ACTIONS` in `exakit_guide/actions.py`, so a card can have a button for it.
4. Regenerate the notebooks and the command reference with `python3 tools/notebooks.py --marimo` and `python3 tools/nb_docs.py`.

Then run `python3 -m unittest tests.test_notebook_guide tests.test_notebook_helpers tests.test_notebook_docs`. The full steps, with examples, are in [Add a command](/data-scientist/development/add-a-command).

## The notebooks [#the-notebooks]

The notebook sources are `notebook/notebooks/<persona>/<NN>_<name>.py`, in jupytext percent format. The `.ipynb` files and the Marimo versions are built from them:

```bash
python3 tools/notebooks.py --marimo            # rebuild
python3 tools/notebooks.py --check --marimo    # fail when a built file is stale
```

## Building these docs [#building-these-docs]

The documentation is MDX pages in `notebook/docs/content/docs/`, one folder per persona. The folder layout is the sidebar, and each folder's `meta.json` sets its title and page order.

```bash
npm install && npm run dev          # in notebook/docs: preview at http://localhost:3000/docs
npm run build                       # writes notebook/docs/out
python3 tools/nb_docs.py --publish  # copies it to notebook/docs/site, stamped with a digest
python3 tools/nb_docs.py --check    # fails when a generated page or the shipped site is stale
```

Users never need Node. The built site travels with the kit, and `nb.docs()` serves it from the kit's own Python, on this computer only. The full steps are in [These docs](/data-scientist/development/docs-site).

Everything under a persona's `reference/` folder is generated. Change the docstring and run `python3 tools/nb_docs.py`; do not edit the generated page.

## When the documentation does not open [#when-the-documentation-does-not-open]

`nb.docs()` reads the site from the kit copy. If it says the site is not there, run:

```python
nb.exakit("update", "notebook")
```

The site is served on this computer at one of the ports 8790 to 8809, the first one free. A port another program holds is skipped. When all of them are taken, any free port is used. To choose the port, set `EXAKIT_DOCS_PORT` before you start the notebooks.

If the notebook runs on another machine than your browser, the frame cannot reach the site. Run `nb.docs(browser=True)` on the machine that runs the kit.

To go back to the story, see [The data science workflow](/data-scientist).
