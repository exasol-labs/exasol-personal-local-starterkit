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
| | `01_explore` | The landscape question with the SQL visible, a small scikit-learn model, the text step traced to your Langfuse; another dataset or your own file is one assignment; ends by writing the handoff for the ML Engineer |
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

## Running the notebooks headless

`python3 tools/notebooks.py --run` executes the notebooks without a front end,
on the kit's own kernel (**Exasol (Starter Kit)**, the one the add-on
registers; `EXAKIT_NOTEBOOK_KERNEL` names another) against the local database,
so the cells run exactly as a user runs them: same kernel, same connection from
the kit's store, same environment. It needs an installed kit with a running
database and the notebook add-on, plus `nbclient` in the add-on's environment
(`uv pip install --python ~/.exasol-starter-kit/notebook-venv/bin/python
nbclient`; the add-on does not ship it, and `--run` says so when it is missing).
Run with any Python: when the one running it has no nbclient, `--run` re-runs
itself with the kit's notebook Python (`EXAKIT_NOTEBOOK_PYTHON`, else
`$EXAKIT_HOME/notebook-venv`).

```bash
python3 tools/notebooks.py --run                                   # every catalog notebook, each on its own dataset
python3 tools/notebooks.py --run --dataset pharma_trials --dataset banking_complaints
python3 tools/notebooks.py --run notebook/notebooks/data-scientist/01_explore.py --dataset banking_complaints --timeout 600
python3 tools/notebooks.py --run --output /tmp/executed           # keep each executed .ipynb, outputs included
```

- `--dataset <id>` rewrites the notebook's one dataset assignment (`DATASET = "..."`
  in explore, train and score; `SAMPLE = "..."` in the quickstarts' shared load
  cell) to that id, so the "one assignment switches the data" promise is
  exercised rather than assumed; given several, each notebook runs once per
  dataset. A notebook with no such assignment refuses the option.
- A cell tagged `skip-ci` (`# %% tags=["skip-ci"]` in the `.py`) is left out
  of the run: for a cell that needs a person (a picker, a question) or a
  service the runner does not have. Tag sparingly: a skipped cell is not
  proven.
- The kernel sees the caller's environment except `LANGFUSE_*`, which are
  dropped (nothing headless writes to anyone's Langfuse). `EXAKIT_NB_MODEL`,
  `OPENAI_BASE_URL` and `OPENAI_API_KEY` pass through, so the text step runs
  when they point at an endpoint; `MLFLOW_TRACKING_URI` passes through when
  set, else MLflow uses its local store. Each run has a temporary folder as its
  working directory (`mlflow/`, `models/` land there, never in the tree).
- Exit 0 when every cell of every run finished; 1 with the failing cell's
  index, source and traceback printed; 2 when the run itself could not start
  (no nbclient, no such kernel, no such file).

`bash tests/notebooks-run.sh` is the CI form (AC-DS3.1, AC-ML3.1): it starts
`tests/lib/stub_model_server.py` - a standard-library stand-in for an
OpenAI-compatible endpoint (`POST /v1/chat/completions`, `GET /v1/models`),
answering each prompt with a fixed theme chosen by the prompt's hash so two runs
compare equal - points the model variables at it, and runs every shipped
notebook on `pharma_trials` and `banking_complaints`. Without a database that
answers it prints `SKIP` and exits 0, with the same probe
`tests/mcp-readonly-sql-matrix.sh` uses; `EXAKIT_REQUIRE_DB=1` makes that a
failure with exit 3 (the `notebooks-live` job in `.github/workflows/versions.yml`
sets it, so CI can never skip silently). `EXAKIT_NOTEBOOK_DATASETS`,
`EXAKIT_NOTEBOOK_CELL_TIMEOUT` and `EXAKIT_NOTEBOOK_RUN_OUTPUT` adjust it; the
executed notebooks are the job's artifact when it fails.

The same script then runs one AI Lab notebook as the connector ships it
(AC-DS1.4): `first_steps.ipynb` from `exasol-notebook-connector` 3.1.0
(`exasol/nb_connector/resources/notebooks/`, what `ai-lab start` deploys),
copied unchanged into a temporary folder and executed on the kit's kernel
through its connection cell (`jupysql.init(ai_lab_config)`), with its bytes
checked against the package's afterwards. AI Lab notebooks open their store
with a widget (a path, a password, an Open button that pushes `ai_lab_config`
into the kernel), which nobody can click headless, so the run starts with one
cell that does what that button does, on the kit's store, and then runs the
notebook's own cells in order. `EXAKIT_NOTEBOOK_AI_LAB=only|0` runs just that
notebook or leaves it out (the CI job runs it as its own step),
`EXAKIT_AI_LAB_NOTEBOOK` names another notebook from that folder, and
`EXAKIT_AI_LAB_CELLS=all` runs every cell (for `first_steps` that needs the
Internet: its data is imported from a public CSV and an S3 bucket). The
connection is re-read on every `exakit notebook` (AC-DS1.5): the launcher
writes the kit's recorded host and port into the store each time, which
`tests/notebook-addon.sh` and its PowerShell twin prove with a port that
changes between two launches.

## The handoff from explore to train

`01_explore` ends by writing the **handoff**, `nb.write_handoff(conn, ds)`:
one JSON file, `~/.exasol-starter-kit/handoffs/<descriptor id>-v<n>.json`
(0600, under `EXAKIT_HOME`), that the ML Engineer's `01_train` starts from
without opening the descriptor. It holds the descriptor's id, version and
digest (`digest_kind` says whether that is the table digest the descriptor was
approved on or, until one is computed, the descriptor file's SHA-256), a
digest of the data (`data_digest_kind`: the table digest, else one over the
row count and the span of the date role - one `COUNT`, so the file costs three
statements), the **feature view** built from the roles as `CREATE OR REPLACE
VIEW STARTER_KIT.<ID>_FEATURES_V<n>` SQL - category one-hot over the top-20
values plus `CAT_OTHER` (the values from one `GROUP BY`, recorded in the
file), date to `DATE_YEAR`, `DATE_MONTH`, `DATE_DOW` (ISO) and
`DATE_DAYS_SINCE_MIN`, entity to `ENTITY_FREQ`, each text column to its
`LENGTH` - the label with its positive class (the minority class from the
profiler's evidence, else from one query), the split, the **training SQL**
(every view column for the labelled rows, `SPLIT_` train for the earliest
`train_share` by `PERCENT_RANK()` over the date role, so train and test are
the same on every run) and the input and output schemas. The view is SQL only
on purpose: a model that is linear over its columns can be scored by a Rust
UDF on the very same view, so TF-IDF stays out of it (token flags computed in
SQL are recorded as deferred). The view is not created by explore; train
creates it. Every identifier in the generated SQL is double-quoted. Without a
date role the split is `random` with the reason (a hash of the row's role
columns orders it, reproducibly). `nb.read_handoff("pharma_trials")` reads
the latest one (`"<id>-v<n>"` or a path reads one), `nb.handoff_from(conn,
ds)` builds the record from an approved descriptor without explore, and
`nb.handoff_is_stale(conn, handoff, ds)` is the check train runs: `None`, or
one line naming what changed (descriptor version, descriptor digest, data)
and the fix. An active workflow logs one `handoff` line with the path.

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
