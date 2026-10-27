# The notebook add-on's content

| Path | What it is |
|---|---|
| `catalog.json` | Which notebooks the kit ships, for which persona, in which order (the requirements' notebook catalogue) |
| `notebooks/<persona>/<NN>_<name>.py` | A notebook's source (jupytext percent format); `<NN>_<name>.ipynb` is built from it |
| `notebooks/00_shared/data_paths.py` | The cells both quickstarts are built with: connection check, schema listing, one loader per way data comes in |
| `marimo/<persona>/<NN>_<name>.py` | The same notebook for Marimo, converted from the `.ipynb` |
| `package/exakit_nb/` | The helpers every notebook imports as `exakit.nb`: `import exakit.nb as nb; conn = nb.connect()` |
| `package/exakit/` | The `exakit.nb` name: the very same module as `exakit_nb`, which older notebooks keep importing |
| `kit/` | The scripts both installers run (the store, the kernel, placing the notebooks, Marimo) |

The notebooks, in the order a new user opens them (numbers are never reused):

| Folder | Notebook | What it does |
|---|---|---|
| `data-scientist/` | `00_quickstart` | Opens connected; one cell per way data comes in (a sample dataset, your own CSV, Parquet or JSON file, a connected source); the descriptor's roles; a first query |
| | `01_explore` | The landscape question with the SQL visible, a small scikit-learn model, the text step traced to your Langfuse; another dataset or your own file is one assignment |
| `ml-engineer/` | `00_quickstart` | The container, MLflow and the bucket directory, one check each with its fix; then the same loader cells |
| | `01_train` | Features in SQL from the descriptor, a classifier trained inside a Python UDF under `exasol_mlflow.start_run`, the run in your MLflow |
| | `03_score_external_model` | A model trained elsewhere, dropped with `exakit model put` and scored by a UDF |

Numbers follow the requirements document's Appendix B and are never reused: the ML
Engineer's `02` is `02_rust_score` (to come), so the score notebook is `03`.

On a machine, `exakit marketplace notebook` copies each notebook into
`~/.exasol-starter-kit/notebooks/starter-kit-notebooks/<persona>/` (the shared
cells into its `00_shared/`, and the Marimo ones into `notebooks/marimo/<persona>/`),
with a README naming the order. A file already there is the user's and is never
overwritten, and one the user deletes is not copied again (`.kit-copied` in each
folder records what the kit copied). A catalog entry whose notebook this kit copy
does not carry yet is skipped. The notebooks folder is the user's work: an
uninstall keeps it, the full `exakit uninstall` too unless
`EXAKIT_UNINSTALL_NOTEBOOKS=remove`.

Every notebook has its `.py` source; `python3 tools/notebooks.py --check` fails
when an `.ipynb` is not built from it (`--check --marimo` also compares `marimo/`
with a fresh conversion, and runs `marimo check` on it, when uv is installed).
`--check` never writes. A quickstart takes the shared cells with one line,
`# %% [include] ../00_shared/data_paths.py <tag>`: the build puts in its place
every cell of that file tagged `<tag>` (`tags=["connect"]`, `tags=["load"]`), so
both quickstarts carry the very same cells and each built notebook stands on its
own in JupyterLab, Marimo and Positron alike.

## The rules every notebook follows

- **Descriptor-driven.** Every query is built from the descriptor's roles
  (`ds.col("label")`, `ds.text_sql()`, `ds.fact_table`): no dataset's table or
  column is named in the code, so the same cells run on Pharma, Banking, a
  user's own file or a table in a connected source.
- **One assignment picks the data**: `DATASET = "pharma_trials"`, a dataset id,
  a descriptor file, or the path of the user's own CSV, Parquet or JSON file
  with its roles in `<name>.descriptor.yaml` beside it (the quickstart's
  own-file cell writes that file).
- **The first cell states the dataset, what must be loaded and how long it takes.**
- **No host, user or password** in any notebook or helper output; the
  connection comes from the kit's kernel (`tests/notebook-addon.sh` and
  `tests/test_notebook_contents.py` grep for them).
- **Marimo-ready**: a name is assigned in one cell only (Marimo refuses two).

## The front ends' versions

JupyterLab and Marimo, when the kit installs them, are pinned in
`versions.json` (`components.notebook.frontends`), read by both installers and
by `tools/notebooks.py --marimo`; `EXAKIT_NOTEBOOK_JUPYTERLAB_VERSION` and
`EXAKIT_NOTEBOOK_MARIMO_VERSION` override a pin. Bumping a pin there is the
whole change: `exakit update notebook` moves a front end the kit installed to
it. Positron is the user's own and only ever configured.

## Adding a notebook

No code. Three steps:

1. Write `notebooks/<persona>/<NN>_<name>.py` and build it: `python3 tools/notebooks.py`
   (`--marimo` also writes `marimo/<persona>/<NN>_<name>.py`; it needs uv).
2. Add one entry to `catalog.json`:

   | Key | Value |
   |---|---|
   | `id` | the notebook's id |
   | `persona` | the persona folder it goes in: an id from `personas/` |
   | `step` | its number `<NN>`: the order a new user opens it in, within its persona |
   | `title`, `summary`, `needs` | what the README says about it |
   | `jupyter` | its `.ipynb` file name |
   | `marimo` | its Marimo file name |

3. `bash tests/notebook-addon.sh` checks that every entry's files exist and
   that no notebook holds an address or a credential;
   `python3 -m unittest tests.test_notebook_contents` that every call it makes
   exists and its first cell states the dataset and run time;
   `tests/personas.sh` checks the persona exists.

A new persona is one file in `personas/` (see `personas/README.md`); a new
dataset is one folder in `data/datasets/` (see `data/README.md`).
