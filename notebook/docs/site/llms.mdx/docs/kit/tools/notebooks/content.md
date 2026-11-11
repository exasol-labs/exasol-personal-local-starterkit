# Notebooks (/kit/tools/notebooks)



The notebook add-on brings JupyterLab and Marimo, the kit's notebooks and the helpers they use. Install it with a persona that has notebooks, or with `exakit marketplace notebook`.

## Open [#open]

```bash
exakit notebook                 # choose a tool on a terminal; JupyterLab otherwise
exakit notebook jupyterlab
exakit notebook marimo
```

It starts on this computer only and opens in your browser, already signed in. The kernel is **Exasol (Starter Kit)**.

Every run first writes the kit's current connection into the notebooks' encrypted store, so a database restart or a port change needs no edit. It also copies any kit notebook you do not have yet. Yours are never overwritten.

## Check, set up, stop [#check-set-up-stop]

```bash
exakit notebook check           # prove the connection; start nothing
exakit notebook setup           # settle JupyterLab; start nothing
exakit notebook stop            # stop the one the kit started
exakit notebook marimo --no-browser --port 2720
```

## Where the notebooks are [#where-the-notebooks-are]

| Tool       | Folder                                                             |
| ---------- | ------------------------------------------------------------------ |
| JupyterLab | `~/.exasol-starter-kit/notebooks/starter-kit-notebooks/<persona>/` |
| Marimo     | `~/.exasol-starter-kit/notebooks/marimo/<persona>/`                |

## What an update does to them [#what-an-update-does-to-them]

* A kit notebook you did not edit is refreshed when the kit's version changes.
* A notebook you edited is never overwritten.
* A notebook you deleted is not copied back.

## A notebook of your own [#a-notebook-of-your-own]

Put it in the same persona folder, named with the next step number and a short topic, for example `04_churn_by_region.ipynb`. Start it with:

```python
import exakit.nb as nb

connection = nb.connect()
```

## The documentation, from a notebook [#the-documentation-from-a-notebook]

```python
nb.docs()
```

See [Data Scientist](/data-scientist) for the four notebooks and their nine steps.
