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
| `data-scientist/` | `00_quickstart` (steps 0-2), `01_explore` (3-6), `02_ask_your_data` (7), `03_share` (8-9) |
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
unchanged. A kit notebook nobody edited is refreshed when the kit's version changes (cells are compared, outputs do
not count); one the user edited, or a file of their own, is never overwritten, and one the user deletes is not copied
back (`.kit-copied` records what was copied, with each notebook's cells digest). Uninstall keeps the folder, the kit
MLflow server's runs and the Dash dashboards unless `EXAKIT_UNINSTALL_NOTEBOOKS=remove`. Installing never
fetches notebooks from GitHub: a new notebook reaches users only with a kit release.

To refresh the examples library from a reviewed, pinned Notebook Connector checkout:
`python3 tools/bundle_connector_notebooks.py /path/to/notebook-connector`.

## The Data Scientist's journey

The four Data Scientist notebooks are one path with nine numbered steps, each a `## Step N · ...` heading with a
three-line plain explanation of what happens there (no jargon) and `###` parts under it: **1 Access** (connect, start a
workflow, load) and **2 Understand** (approve the column map) in `00_quickstart`; **3 Prepare** (checks, schema map and
joined view, typed view), **4 Explore** (groups, over time), **5 Model** (leakage set aside, a small model trained) and
**6 Validate** (scored on unseen rows, what it leans on) in `01_explore`; **7 Ask with AI** in `02_ask_your_data`;
**8 Share** (Dash Server installed and started from the notebook, preview, publish) and **9 Hand off** (one folder and
zip: the column map, every query with its digest, the dashboards, the workflow log, a README) in `03_share`. Each
notebook's first cell says which steps it holds. A **step 0** opens the quickstart: the kit itself, from the notebook.

**No terminal.** `nb.kit_check()` prints what is installed and running; `nb.exakit("update")`,
`nb.exakit("marketplace", "dash-server")`, `nb.exakit("data-load", "fraud_transactions")`, `nb.exakit("logs")` run the same
`exakit` the terminal runs, with its output streaming into the cell and the exit code in the result; `nb.addon_ready(id)`
installs and starts an add-on when it is missing or stopped. The command runs with no terminal, so a question it would
ask takes its default; a choice goes in up front (`nb.exakit("mcp-setup", env={"EXAKIT_MCP_CLIENTS": "claude"})`).
`nb.handoff_bundle(conn, ds)` writes the hand-off into `~/.exasol-starter-kit/bundles/<workflow id>/` (and `.zip`).

## Rules every notebook follows

- **Descriptor-driven**: queries come from the dataset's approved roles (`ds.col("label")`, `ds.fact_table`); no table
  or column name is hard-coded.
- **One assignment picks the data**: `DATASET = "..."` (`SAMPLE = "..."` in the quickstarts): a dataset id, a
  descriptor, or the user's own CSV, Parquet or JSON file with its `<name>.descriptor.yaml` beside it.
- **The first cell states the dataset and what must be loaded** (no run-time estimate: it depends on the machine and the first download).
- **No host, user or password** anywhere; the connection comes from the kit's kernel, **Exasol (Starter Kit)**.
- **Marimo-ready**: each name is assigned in one cell only.
- **AI is opt-in**: `USE_AI_THEMES = False` in explore, `DRAFT_WITH_MODEL = False` in ask; a model never approves roles.
- **A step whose role is missing skips and says why**: `amazon_sales` and `fraud_transactions` have no text column, so
  explore's small text model and AI themes skip on them; 03_score_external_model's stand-in then learns from the
  category and entity only.
- **Each important idea is explained where it first appears**, in three or four plain lines (what it is, why we use
  it): the dataset, the descriptor and its approval, the baseline, the handoff, the feature view, MLflow, the UDF.

## Model settings

`EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL`, `EXAKIT_PROVIDER_API_KEY`, and optionally `EXAKIT_PROVIDER_HEADERS`
and `EXAKIT_MODEL_TEMPERATURE` (not sent unless set; Claude Opus 4.7+ refuses temperature).
`LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_BASE_URL` turn tracing on. Set them in the terminal that
starts `exakit notebook` (keys through a hidden `read -rs`, or `Read-Host -AsSecureString` on Windows), keep the
model's id and address in `~/.exasol-starter-kit/exakit.env`, or fill in the *Your AI model and Langfuse* cell in
Explore or Ask. `nb.model_setup()` says what is set and prints the lines for the machine it runs on;
`nb.model_settings()` reports them without secrets. The recipes, both shells, and the providers in
detail: [MODEL-PROVIDERS.md](MODEL-PROVIDERS.md).

## The training handoff

Each persona stands alone: the ML Engineer needs no Data Scientist notebook. `ml-engineer/01_train` writes the handoff
from the approved column map when there is none: one JSON file in `~/.exasol-starter-kit/handoffs/<id>-v<n>.json`
holding the descriptor version and digest, a data digest, the SQL feature view, the label, the reproducible split and
the training SQL. A stale one is refused (`nb.handoff_is_stale` names what changed and the fix). It trains in a Python
UDF, compares macro-F1 with a majority baseline and logs to MLflow. The view is plain SQL, so `02_rust_score` scores
the same columns with a Rust UDF. `nb.write_handoff(conn, ds)` writes one from any notebook.
Training's `CLASS_WEIGHT` defaults to `"balanced"`, which helps a rare label (`amazon_sales`: 14.2% of order lines
cancelled) and changes little on an even one; `None` weighs
every row the same.

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
  --dataset fraud_transactions --timeout 600 --output /tmp/executed
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
