# The notebook add-on's content

| Path | What it is |
|---|---|
| `catalog.json` | Which notebooks the kit ships, for which persona, in which order (the requirements' notebook catalogue) |
| `notebooks/<persona>/<NN>_<name>.py` | A notebook's source (jupytext percent format); `<NN>_<name>.ipynb` is built from it |
| `notebooks/00_shared/data_paths.py` | The cells both quickstarts are built with: connection, three load paths, and column-role review and approval |
| `marimo/<persona>/<NN>_<name>.py` | The same notebook for Marimo, converted from the `.ipynb` |
| `package/exakit_nb/` | The helpers every notebook imports as `exakit.nb`: `import exakit.nb as nb; conn = nb.connect()` |
| `package/exakit/` | The `exakit.nb` name: the very same module as `exakit_nb`, which older notebooks keep importing |
| `kit/` | The scripts both installers run (the store, the kernel, placing the notebooks, Marimo) |

The notebooks, in the order a new user opens them (numbers are never reused):

| Folder | Notebook | What it does |
|---|---|---|
| `data-scientist/` | `00_quickstart` | Opens connected; one cell per way data comes in (a sample dataset, your own file, a connected source); review and approve the proposed column roles; a first query |
| | `01_explore` | Compare groups and trends with visible SQL, try a local scikit-learn model, optionally add AI text themes and Langfuse tracing; another dataset or your own file is one assignment; ends by writing the handoff for the ML Engineer |
| | `02_ask_your_data` | Draft SQL from approved roles, inspect and approve it, then execute under the dedicated read-only database identity |
| | `03_share` | Prepare a Dash Server app from checked SQL, inspect a healthy preview, then explicitly promote the revision |
| `ml-engineer/` | `00_quickstart` | The container, MLflow and the bucket directory, one check each with its fix; then the same loader and role-review cells |
| | `01_train` | Checks the handoff, builds its SQL feature view, trains a classifier inside a Python UDF, compares macro-F1 with a majority baseline, and logs the model and coefficients to MLflow |
| | `02_rust_score` | Builds a Rust UDF from the trained coefficients and checks its labels and probabilities on the same test rows |
| | `03_score_external_model` | A model trained elsewhere, dropped with `exakit model put` and scored by a UDF |

Numbers follow the requirements document's Appendix B and are never reused.

## Follow one investigation across the notebooks

Start with a question: which Pharma trial groups have more terminations, or
which Banking complaint groups receive monetary relief? The quickstart opens
the data and explains the proposed column meanings. Explore compares groups,
checks changes over time and writes a **handoff**, the saved recipe for the
ML Engineer. Ask turns a follow-up question into SQL you inspect. Share takes
a checked result to a Dash Server preview that you review before publishing.

The ML Engineer picks up that recipe, checks the database's Python environment,
trains a reproducible model and records its metrics and artifacts in MLflow.
The scoring lessons check whether another implementation gives the same
predictions. Matching predictions prove consistency; the baseline comparison
is a separate check of model usefulness.

Each lesson explains the question, what to do, how to read the result and the
technical details behind it. Use the supplied code as a starting point, then
adapt it to your own approved column map. The four practice lessons in
[EXAMPLE-GUIDE.md](EXAMPLE-GUIDE.md) teach individual parts of that journey.

The supplied analysis and ML code needs no LLM endpoint. Explore starts with
`USE_AI_THEMES = False`; enable it explicitly to summarize a small text sample.
Ask starts with `DRAFT_WITH_MODEL = False` and supplies SQL you can edit yourself.
Their optional AI sections explain endpoint configuration, what is sent and
how to check the result. Langfuse tracing is another opt-in. Configuring a model
can also enable optional profiling notes; it never assigns or approves roles.
Role suggestions use measured table statistics and column-name rules, and the
review screen explains their evidence and close alternatives.

Model configuration uses the same provider-neutral names everywhere:
`EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL` and `EXAKIT_PROVIDER_API_KEY`.
The API key is optional only when the selected server allows unauthenticated
calls. `nb.model_settings()` reports configuration without key or header values.
See [MODEL-PROVIDERS.md](MODEL-PROVIDERS.md) for Claude, Ollama, LM Studio,
vLLM and Gemini, their official compatibility documentation, optional routing
headers and the exact boundary between local contract tests and live evidence.

## Where the kit stops in the model lifecycle

The model lifecycle is *Develop → Train → Track → Validate → Register → Deploy → Score → Monitor*. The kit's
notebooks cover the path up to **Track** and **Validate**: `01_explore` develops the question and writes the handoff,
`01_train` trains inside the database, tracks the run in MLflow and validates it against a majority baseline on a
held-out split. **Register**, **Deploy** and **Monitor** are not built: there is no model registry, no serving
endpoint and no drift check in the kit, and no cell promotes a run to a stage.

What a tracked run already holds, so a registry can take it later without retraining: the model artefact
(`model/model.pkl`, the fitted pipeline), `coefficients.json` (the weights over the raw feature view, also copied
beside the handoff), `training.sql`, the metrics, and the environment tags `exasol.kit_version`,
`exasol.launcher_version`, `exasol.db_version`, `exasol.language`, `exasol.container_digest`,
`exasol.package_versions`, `exasol.descriptor_id`, `exasol.descriptor_version`, `exasol.data_digest`,
`exasol.workflow_id`, `exasol.session_id` and `exasol.statement_id` - the last two tie the run to the database
session and statement that trained it, so the audit log can confirm what ran.

**Score** is a manual step today: `02_rust_score` builds a scorer from the run's coefficients, and a model trained
anywhere is dropped into the bucket with `exakit model put` and scored by a UDF in `03_score_external_model`. Nothing
registers the model or watches its scores afterwards; that is the user's platform, not the kit.

The Share notebook prepares `app.py`, a live SQL query, and `REVISION.json` with the workflow id, descriptor version
and query digest. Its `ShareDraft.preview(tool)` drives the registered Dash Server MCP control plane: validate the
read-only profile, scaffold, put files, deploy to preview and run a health check. `confirm(tool,
figures_checked=True)` promotes the same revision after the reader checks the figures against the SQL. On Windows
the preview uses `app_build` then `app_start_preview`, because the Windows deploy shortcut has a known path issue.
The tool callable is supplied by the AI client hosting Dash Server MCP; the notebook prints the requests when one
is not attached. The kit never puts database credentials in the dashboard source.

Four additional local lessons adapt the Notebook Connector examples used by AI Lab:
`01_sql_and_dataframes` and `02_decision_tree_baseline` for Data Scientist;
`01_udf_package_check` and `02_decision_tree_udf` for ML Engineer. Each ships
as Jupyter and Marimo. See [EXAMPLE-GUIDE.md](EXAMPLE-GUIDE.md) for the lesson
order and the upstream sources and license. The guide and MIT notices are copied alongside each notebook collection;
source metadata stays inside the kit.

The notebook environment explicitly includes scikit-learn (matching the ML
container's pin), pandas, NumPy, SciPy and joblib. Other libraries keep compatible
ranges so the connector's optional dependencies can resolve. Installing a library
here does not install it in the database: `udf-devkit` prepares and checks the
separate `PYTHON3_ML` runtime for in-database training and scoring. The verified
upstream archive is retained; a cached derivative isolates its language alias
so it can coexist with the official Python container, with both digests recorded.

On a machine, `exakit marketplace notebook` copies each notebook into
`~/.exasol-starter-kit/notebooks/starter-kit-notebooks/<persona>/` (the shared
cells into its `00_shared/`, and the Marimo ones into `notebooks/marimo/<persona>/`),
with a README naming the order. A file already there is the user's and is never
overwritten, and one the user deletes is not copied again (`.kit-copied` in each
folder records what the kit copied). A catalog entry whose notebook this kit copy
does not carry yet is skipped. The notebooks folder is the user's work: an
uninstall keeps it, the full `exakit uninstall` too unless
`EXAKIT_UNINSTALL_NOTEBOOKS=remove`.

After updating, existing working copies keep their older text and your edits.
To use a revised lesson, open its current original under
`~/.exasol-starter-kit/kit/notebook/notebooks/` (Jupyter) or
`~/.exasol-starter-kit/kit/notebook/marimo/`, then save a new working copy with a
different name. A source checkout has the same originals under `notebook/`.
In Jupyter choose the **Exasol (Starter Kit)** kernel.

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
  dropped (nothing headless writes to anyone's Langfuse). `EXAKIT_MODEL_ID`,
  `EXAKIT_PROVIDER_BASE_URL` and `EXAKIT_PROVIDER_API_KEY` pass through to optional AI steps;
  Explore still requires `USE_AI_THEMES = True`. The ordinary headless flow keeps it off.
  `EXAKIT_PROVIDER_HEADERS` also passes through. `MLFLOW_TRACKING_URI` passes through when
  set, else MLflow uses the kit's server if running or its local store. Role proposals are approved automatically
  only when the draft's roles equal the current approved version (`EXAKIT_NB_AUTO_APPROVE=force` approves the
  draft); failed container, MLflow or bucket checks raise an error. Each run has a temporary folder as its
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

The full official 50-notebook collection is prebundled under `examples/` for both tools, with a categorized start page and supporting files. See [INSTALL-AND-UPDATE.md](INSTALL-AND-UPDATE.md) for installation and update behavior.


## Explicit acceptance recipes and runner controls

Training exposes `CLASS_WEIGHT`: leave it `None` for Pharma, set it to
`"balanced"` for the Banking reference recipe. This changes class weights in
logistic regression and records the choice in MLflow. It does not change the
temporal holdout or majority baseline. The unweighted Banking model can equal
its baseline; completing training alone does not establish useful predictions.

The runner changes only the in-memory test copy; it preserves notebook sources
and user copies. Its optional controls are:

| Option | Effect | Default |
|---|---|---|
| `--ai-themes` | Enable Explore's optional model calls | Off |
| `--class-weight none\|balanced` | Select the declared training recipe | Source value |
| `--approve-sql` | Approve the starter SQL proposal in the automated Ask lesson | Off |
| `--allow-database-restart` | Permit the declared Rust deployment restart | Off |

Share's `FIGURES_CHECKED` remains false in automated runs. Preview health is
machine checked; a person must compare the figures and approve promotion.
`APP_NAME = None` derives a dataset-specific dashboard name; Rust's
`UDF_NAME = None` derives a dataset/version-specific scorer name. Choose a new
explicit name for another coefficient revision of the same descriptor.

```sh
EXAKIT_NOTEBOOK_DATASETS=banking_complaints \
EXAKIT_NOTEBOOK_CLASS_WEIGHT=balanced \
EXAKIT_NOTEBOOK_AI_THEMES=1 EXAKIT_REQUIRE_DB=1 \
bash tests/notebooks-run.sh \
  notebook/notebooks/data-scientist/01_explore.py \
  notebook/notebooks/ml-engineer/01_train.py
```

The corresponding shell settings are `EXAKIT_NOTEBOOK_AI_THEMES`,
`EXAKIT_NOTEBOOK_CLASS_WEIGHT`, `EXAKIT_NOTEBOOK_APPROVE_SQL` and
`EXAKIT_NOTEBOOK_ALLOW_RESTART`. Boolean settings require `1`.
`tools/ask_benchmark.py` evaluates opted-in models against complete reference
query results under the read-only MCP user. See
[the acceptance steps](../docs/ACCEPTANCE-REMAINING.md). An endpoint connection
or valid JSON response is not evidence that a model answers correctly.

For a dedicated Mac/Linux CI runner with an existing kit, set
`EXAKIT_NOTEBOOK_BIND_CHECKOUT=1`. The harness binds the checked-out notebook
helpers, MLflow package, dataset/service paths and CLI in a temporary kernel.
It leaves the installed kit and registered user kernel intact. Without this
setting, the registered kit kernel remains the default.

Share includes synchronized category selection, Top N, bar orientation and a
result table. `nb.share(..., measure="count")` enables count totals and the
share-of-displayed-total chart. The default `measure="value"` avoids summing
arbitrary rates or other non-additive values. The supplied Share notebook uses
a reviewed `COUNT(*)` query and declares it as a count. Recheck both charts and
the table after filtering, then confirm figures before publishing.

The Share template uses the Dash Server design tokens across responsive cards,
filters, chart panels and the result table. Search, sort, category selection and
Top N feed one displayed result. Reset clears them together. The table supports
pagination, column sorting and CSV export; table column sorting changes row order
only. The comparison and composition use consistent category colors. Empty,
non-numeric and refresh-failure states remain visible. Lineage is available in
About this shared result rather than crowding the main view.

The responsive view keeps filters in an expandable panel, gives longer bar
comparisons their own scroll area, and groups smaller count categories into
Other for a readable composition legend without changing the displayed total.
CSV downloads neutralize spreadsheet formula text while preserving original
values in the table and charts. Every new preview invalidates earlier approval
state until its files and health checks pass again.
