# The notebook add-on's content

Maintainer notes. Users get the add-on with `exakit marketplace notebook` (or a persona that includes it) and open it
with `exakit notebook` or `exakit notebook marimo`; `exakit update notebook` refreshes it.

| Path | What it is |
|---|---|
| `catalog.json` | The notebooks shipped, per persona, in order, with title, summary and needs |
| `notebooks/<persona>/<NN>_<name>.py` | A notebook's source (jupytext percent format); the `.ipynb` beside it is built from it |
| `notebooks/00_shared/` | Cells both quickstarts include at build time; build input only, never copied to users |
| `marimo/<persona>/` | The Marimo versions, converted from the `.ipynb` |
| `examples/` | The official 50-notebook Exasol examples library (see [examples/README.md](examples/README.md)) |
| `package/exakit_nb/` | The helpers every notebook imports: `import exakit.nb as nb; conn = nb.connect()` |
| `kit/` | The scripts both installers run (store, kernel, copying the notebooks) |

| Persona | Notebooks |
|---|---|
| `data-scientist/` | `00_quickstart`, `01_explore`, `02_ask_your_data`, `03_share` |
| `ml-engineer/` | `00_quickstart`, `01_train`, `02_rust_score`, `03_score_external_model` |

## Build and check

```sh
python3 tools/notebooks.py --marimo          # rebuild every .ipynb from its .py, and marimo/ (needs uv)
python3 tools/notebooks.py --check --marimo  # exit 1 when a built file is stale; writes nothing
```

A quickstart pulls shared cells with `# %% [include] ../00_shared/data_paths.py <tag>`: the build inserts every cell
of that file tagged `<tag>`, so each built notebook stands on its own.

## What users get

`kit/notebooks.py` copies the picked personas' notebooks into
`~/.exasol-starter-kit/notebooks/starter-kit-notebooks/<persona>/` (Marimo: `.../notebooks/marimo/<persona>/`), plus
the examples library as `exasol-examples/` in both. A persona added later (`exakit persona add`) brings its folder;
with no persona that has notebooks, all are copied. A generated `README.md` names the order; it is rewritten only while
unchanged. Files already there are never overwritten, and one the user deletes is not copied back (`.kit-copied`
records what was copied). Uninstall keeps the folder unless `EXAKIT_UNINSTALL_NOTEBOOKS=remove`. Installing never
fetches notebooks from GitHub: a new notebook reaches users only with a kit release.

To refresh the examples library from a reviewed, pinned Notebook Connector checkout:
`python3 tools/bundle_connector_notebooks.py /path/to/notebook-connector`.

## Rules every notebook follows

- **Descriptor-driven**: queries come from the dataset's approved roles (`ds.col("label")`, `ds.fact_table`); no table
  or column name is hard-coded.
- **One assignment picks the data**: `DATASET = "..."` (`SAMPLE = "..."` in the quickstarts): a dataset id, a
  descriptor, or the user's own CSV, Parquet or JSON file with its `<name>.descriptor.yaml` beside it.
- **The first cell states the dataset, what must be loaded and the run time.**
- **No host, user or password** anywhere; the connection comes from the kit's kernel, **Exasol (Starter Kit)**.
- **Marimo-ready**: each name is assigned in one cell only.
- **AI is opt-in**: `USE_AI_THEMES = False` in explore, `DRAFT_WITH_MODEL = False` in ask; a model never approves roles.

## Model settings

`EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL`, `EXAKIT_PROVIDER_API_KEY`, and optionally `EXAKIT_PROVIDER_HEADERS`
and `EXAKIT_MODEL_TEMPERATURE` (not sent unless set; Claude Opus 4.7+ refuses temperature).
`nb.model_settings()` reports them without secrets. Providers in detail: [MODEL-PROVIDERS.md](MODEL-PROVIDERS.md).

## The training handoff

Each persona stands alone: the ML Engineer needs no Data Scientist notebook. `ml-engineer/01_train` writes the handoff
from the approved column map when there is none: one JSON file in `~/.exasol-starter-kit/handoffs/<id>-v<n>.json`
holding the descriptor version and digest, a data digest, the SQL feature view, the label, the reproducible split and
the training SQL. A stale one is refused (`nb.handoff_is_stale` names what changed and the fix). It trains in a Python
UDF, compares macro-F1 with a majority baseline and logs to MLflow. The view is plain SQL, so `02_rust_score` scores
the same columns with a Rust UDF. `nb.write_handoff(conn, ds)` writes one from any notebook.
Training's `CLASS_WEIGHT`: `None` for Esophageal, `"balanced"` for Banking.

## Front-end versions

JupyterLab and Marimo are pinned in `versions.json` (`components.notebook.frontends`); bumping a pin is the whole
change, and `exakit update notebook` applies it. `EXAKIT_NOTEBOOK_JUPYTERLAB_VERSION` and
`EXAKIT_NOTEBOOK_MARIMO_VERSION` override.

## Adding a notebook

1. Write `notebooks/<persona>/<NN>_<name>.py` and run `python3 tools/notebooks.py --marimo`.
2. Add an entry to `catalog.json`: `id`, `persona`, `step`, `title`, `summary`, `needs`, `jupyter`, `marimo`.
3. Run `bash tests/notebook-addon.sh` and `python3 -m unittest tests.test_notebook_contents`.

A new persona is one file in `personas/`; a new dataset is one folder in `data/datasets/`.

## Headless runs

`--run` executes notebooks on the kit's kernel against the local database. It needs an installed kit, a running
database and `nbclient` in the add-on's environment
(`uv pip install --python ~/.exasol-starter-kit/notebook-venv/bin/python nbclient`).

```sh
python3 tools/notebooks.py --run                    # every catalog notebook
python3 tools/notebooks.py --run notebook/notebooks/data-scientist/01_explore.py \
  --dataset banking_complaints --timeout 600 --output /tmp/executed
```

- `--dataset <id>` rewrites the one dataset assignment (repeat it to run once per dataset).
- Opt-ins, off by default: `--ai-themes`, `--approve-sql`, `--allow-database-restart`;
  `--class-weight none|balanced` overrides the source's `CLASS_WEIGHT`.
- A cell tagged `skip-ci` is left out; `LANGFUSE_*` is dropped; exit 1 names the failing cell.

`bash tests/notebooks-run.sh` is the CI form: it runs every notebook against a stub model server and prints `SKIP`
without a database (`EXAKIT_REQUIRE_DB=1` makes that a failure). It takes `EXAKIT_NOTEBOOK_DATASETS`,
`EXAKIT_NOTEBOOK_AI_THEMES`, `EXAKIT_NOTEBOOK_CLASS_WEIGHT`, `EXAKIT_NOTEBOOK_APPROVE_SQL`,
`EXAKIT_NOTEBOOK_ALLOW_RESTART` (booleans are `1`) and `EXAKIT_NOTEBOOK_BIND_CHECKOUT=1` (use this checkout's helpers).

Share's figures and promotion stay a human check: `FIGURES_CHECKED` is never set in automated runs.
