---
name: notebook
addon: notebook
description: Open notebooks already connected to the local Exasol database with the notebook add-on, built on Exasol's notebook connector (the package AI Lab installs) — covering exakit notebook (on a terminal a multi-select of the notebook tools, each saying its state), marimo, setup, check and stop, what it repairs before it opens anything (the database stopped or the connection lost, JupyterLab or Marimo deleted, the notebook environment broken, a port taken, the notebooks folder or the connection store deleted), the notebook tools (JupyterLab and Marimo) as child rows of the notebook in the marketplace's add-ons table, JupyterLab and Marimo as on-demand background services with their status, the persona folders of the kit's notebooks (Data Scientist and ML Engineer quickstarts, explore, ask, share, train, Rust scoring, score), the Exasol (Starter Kit) kernel, the exakit.nb helpers, why no notebook ever holds a host, user or password, opt-in Langfuse tracing of model calls, and which AI Lab notebooks run on a local database. Triggers — "open a notebook", "start Jupyter", "open Marimo", "where are the starter kit notebooks", "JupyterLab on my Exasol", "notebook connected to the database", "install the notebook add-on", "exakit notebook", "stop JupyterLab", "is my notebook running", "I deleted JupyterLab", "exakit notebook says the database is not running", "use AI Lab notebooks locally", "trace my LLM calls to Langfuse", "my notebook cannot connect".
---

# notebook — JupyterLab or Marimo connected to the local database

`notebook` is a **marketplace add-on**. It installs Exasol's notebook connector
(`exasol-notebook-connector`, the package Exasol's AI Lab is built on),
pyexasol, the Langfuse and OpenAI clients, the kit's helper package `exakit.nb`
(`exakit_nb` still imports) and a Jupyter kernel, **Exasol (Starter Kit)**, in an environment of their own.
It is not offered on Linux Arm or an Intel Mac (a connector dependency publishes
no build for either): the marketplace shows it as not applicable, and a persona that brings it
skips it and says why. It runs on Linux x86_64, macOS on Apple silicon and Windows.

**The notebook tools are the user's choice: they are the notebook row's child
rows in the marketplace's add-ons table, both ticked, each saying before
anything installs what will become of it and then how it settled**
(`installed <version>`, `yours, kernel added`, `skipped`, or
`not installed - see the log`; a scripted
install that draws no table asks one checklist instead). JupyterLab: one already on the machine is used as it is, with the
kit's kernel added (VS Code and other Jupyter front ends see it too); with none,
the kit's is installed (the connector's `[jupyter]` extra) because it was ticked. Marimo: installed into the kit's
notebook environment. The install names each part on its activity line as it
goes: creating the environment, the notebook connector, JupyterLab, Marimo,
validating, then placing the notebooks and the kernel. Pre-answer only on the
user's word: `EXAKIT_NOTEBOOK_FRONTENDS=jupyterlab,marimo` (or `none`),
or `EXAKIT_NOTEBOOK_JUPYTER=skip` / `EXAKIT_NOTEBOOK_MARIMO=skip` to leave one out.
The JupyterLab and Marimo versions are pinned in the kit's `versions.json`
(`components.notebook.frontends`) and move with `exakit update notebook`.

The kit's notebooks are in `~/.exasol-starter-kit/notebooks/starter-kit-notebooks/`,
one folder per persona, with a README naming the order to open them in:
`data-scientist/00_quickstart`, `01_explore`, `02_ask_your_data`, `03_share` (Data Scientist),
and `ml-engineer/00_quickstart`, `01_train`, `02_rust_score`, `03_score_external_model` (ML Engineer),
plus Exasol's examples library as `exasol-examples/`.
Only the picked personas' folders are copied; a persona added later (`exakit persona add`) brings its own.
The add-on installed with no persona recorded brings every persona's; removing a persona never brings the
other's. Marimo's copies are in `notebooks/marimo/<persona>/`. Each persona stands alone: no notebook needs
the other persona's.

A kit notebook nobody edited is refreshed when the kit's version changes (cells are compared; outputs from
running it do not count). One the user edited, or a file of their own, is never overwritten, and one the user
deleted is not copied back.

**Use the kit's notebooks; a new one is a copy of them.** Start from the
persona's notebook for the task, and edit it in place when the user asks for a
change to it. When the user wants a new notebook, put it in the **same persona
folder**, named with the next step number and a short topic
(`starter-kit-notebooks/data-scientist/04_churn_by_region.ipynb`; Marimo:
`marimo/data-scientist/04_churn_by_region.py`), and make it a **copy of that
persona's `00_quickstart`** (or of the kit notebook closest to the task), then
edit the copy: it keeps the `Exasol (Starter Kit)` kernel and connects through
`exakit.nb`. Never start from an empty notebook, never write connection code
by hand, never put a host, user or password in a cell.

Install it with `exakit marketplace notebook`. Never tell a user to
`pip install exasol-notebook-connector` themselves: that copy has no
connection, no helpers and no notebooks.

## Open it

```bash
exakit notebook                      # on a terminal: pick the tools to open; without one: JupyterLab
exakit notebook marimo             # the same notebooks in Marimo (installs it when the user says yes)
exakit notebook stop               # stop JupyterLab and Marimo (stop marimo: only Marimo)
exakit notebook setup              # register the kernel, find or offer JupyterLab, start nothing
exakit notebook --no-browser --port 8890
exakit notebook check              # connect and report (and whether JupyterLab runs), start nothing
```

**On a terminal, plain `exakit notebook` asks one multi-select, "Open which
notebook tools?"**, with a JupyterLab row and a Marimo row, each saying its
tool's state before anything happens:
JupyterLab `running at http://127.0.0.1:<port>/lab`, `starting on port <port>`,
`ready (the kit's <version>)`, `ready (yours: <path>)`, or
`missing - reinstall it` / `not installed - installs it` (into the kit's environment);
Marimo `running at ...`, `starting on port <port>`, `ready`, `missing - reinstall it`
or `not installed - installs it`; and
`Skip - open nothing`. The tools the user chose at install
are ticked (JupyterLab when none). Each one picked opens in turn - one line each
with its address - then one line says how to stop them. Windows shows the same
menu. **Without a terminal
(an agent's shell) it never asks**: plain `exakit notebook` opens JupyterLab, as
it always did; `--port N` also means JupyterLab, without the menu. An agent
should name the tool it means: `exakit notebook jupyterlab` or
`exakit notebook marimo` (tool names in any case).

JupyterLab runs in the background until it is stopped, so `exakit notebook`
returns at once; with `--no-browser` it opens no browser and prints the address
(without the token). It is an on-demand
service: `exakit start` (everything) does not start it and it never starts at
login. `exakit notebook check` says whether it runs.
Start it only when the user asks for notebooks; never print the login token
(it lives in the kit's credentials folder; the address `exakit notebook` prints has
none, and only the browser gets the logged-in address).

## In a notebook

```python
import exakit.nb as nb
conn = nb.connect()                                # the kit's connection, no secrets in the cell
df = nb.sql(conn, "SELECT * FROM TPCH.NATION")
nb.show_sql()                                      # the statement that produced df
```

For a dataset with a descriptor (`amazon_sales`, `walmart_sales`, or a
`descriptor.yaml` the user wrote for their own table), the roles become SQL
names, checked against the database first:

```python
ds = nb.dataset(conn, "amazon_sales")                 # or a descriptor.yaml path, or a data file with one beside it
nb.sql(conn, f"SELECT {ds.col('category')}, AVG({ds.col('label')}) FROM {ds.fact_table} GROUP BY 1")
nb.load_own_file("~/data/claims.csv", "MY_DATA.CLAIMS", {"entity": "CUSTOMER", ...})   # CSV, Parquet or JSON
```

`data-scientist/01_explore` is built that way: its settings are all in the first cell, one
assignment (`DATASET = ...`) picks the data, every query is printed before its result, a small
scikit-learn model runs on this computer, and a text step calls the user's own model endpoint
only when `USE_AI_THEMES = True` and `EXAKIT_MODEL_ID` / `EXAKIT_PROVIDER_BASE_URL`
are configured; on a dataset with no text column (both `amazon_sales` and
`walmart_sales`) it skips and says why. That step (`nb.themes`) sends the newest texts on each side of the label,
one call per side, and the model sorts each side into two to four themes: a table of theme,
count, share and example. With Langfuse set up it is one trace, `explore-themes`.

`DATASET = None` in the later notebooks means the dataset approved last in a quickstart
(else `amazon_sales`); each says which in one line. Result columns are named after the
data (`CATEGORY`, `ORDERS`, `CANCELLED_PCT`; `nb.name`, `nb.count_name`), and a note in
plain words sits under each result (`nb.note_groups`, `nb.note_trend`, `nb.note_model`).

`data-scientist/02_ask_your_data`: `proposal = nb.ask(ds, question)` drafts SQL with the
user's model from the whole approved column map (every column's role, evidence and note; a
sensitive column is named with its role only and never selected). With
`DRAFT_WITH_MODEL = False` it starts from the notebook's own SQL instead. The proposal shows
the question, the SQL one clause per line, what the model assumed and what to check. Nothing
runs until `proposal.approve()`; `proposal.run()` runs exactly the approved text as the
read-only MCP user, and `proposal.edit("...")` clears the approval.

`EXAKIT_PROVIDER_API_KEY` supplies the provider's key; an unauthenticated
local server can leave it unset. The same names apply to optional Ask SQL drafting
and profiling notes. No temperature is sent unless `EXAKIT_MODEL_TEMPERATURE` is set
(newer Claude models refuse it). `nb.model_settings()` is a read-only, redacted configuration
check. Optional `EXAKIT_PROVIDER_HEADERS` is a JSON map for routing such as
`anthropic-workspace-id`; it cannot replace authentication headers. The provider
guide at `notebook/MODEL-PROVIDERS.md` cites the official Claude, Ollama, LM Studio,
vLLM and Gemini compatibility endpoints and separates local HTTP contracts from
live-provider verification. Never call an endpoint verified merely because its
documentation is compatible. Point a user who gets "does not match the database" at
`exakit data-load <dataset>`.

`ml-engineer/01_train` starts from the training handoff in
`~/.exasol-starter-kit/handoffs/`; when there is none it writes one from the approved column
map, so `02_rust_score` finds it and no Data Scientist notebook is needed. A stale handoff is
refused with its fix, `nb.write_handoff(conn, ds)`. It trains inside the database: `exasol_mlflow.create_script(schema)`
makes a training UDF, the query feeds it the roles, and
`with exasol_mlflow.start_run(conn, params=...) as run: run.execute(sql)` checks
the UDF's answer and logs one MLflow run (params, metrics, `training.sql`, the model, and the
`exasol.session_id` / `exasol.statement_id` / `exasol.deployment` tags) from
the client. The run goes to `MLFLOW_TRACKING_URI`, or to a local store in
`mlflow/` beside the notebook; the UDF never holds MLflow credentials. MLflow's and dbt's
usage telemetry is off in the notebook process and kernel (`MLFLOW_DISABLE_TELEMETRY=true`,
`DBT_SEND_ANONYMOUS_USAGE_STATS=false`, as Exasol's is), unless the user set them.

`exakit uninstall` keeps the user's work in the kit home: the notebooks
(`~/.exasol-starter-kit/notebooks`), the kit MLflow server's runs and models
(`~/.exasol-starter-kit/mlflow`) and the Dash dashboards; a reinstall picks them up.
`EXAKIT_UNINSTALL_NOTEBOOKS=remove` removes them too.

The connection lives in the connector's **encrypted** configuration store,
written by the kit and refreshed on every `exakit notebook`, so a database
restart or a port change needs no edit. Never paste a host, user or password
into a notebook, and never print the store's contents.

## Tracing model calls (opt-in)

With `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_BASE_URL` exported (`LANGFUSE_HOST` is accepted as an alias)
before `exakit notebook`, `nb.trace(conn, "label")` records the model
calls made inside it in the user's own Langfuse project, tagged with the
database session and the last SQL; `trace(conn, "label", dataset=ds)` adds the
dataset and the descriptor's digest. Without those variables it prints that tracing is off and
the notebook runs unchanged. The kit ships no model: the user's
`EXAKIT_PROVIDER_BASE_URL` may point at a local endpoint such as Ollama.

## AI Lab notebooks on a local database

AI Lab notebooks that use only the database run here. Those that upload to
BucketFS, install the Transformers or Text AI extensions, or deploy a container
through BucketFS do not: a local Exasol Personal database has no BucketFS
upload service. For UDFs use the udf-devkit add-on (`exakit udf-setup`,
`exakit udf-use`, `exakit model put`); `ml-engineer/03_score_external_model` scores a model trained
anywhere with the udf-devkit's scoring template.

## When something is wrong

Before it opens anything, `exakit notebook` checks what the notebooks need and
says each problem in one line. On a terminal it offers the fix (yes is the
default); without one it asks nothing, names the one command that fixes it, and
exits non-zero when nothing could open. Relay that command to the user.

| What happened | On a terminal | Without one |
|---|---|---|
| The database is stopped, or the connection was lost | offers to start it (as `exakit start` does), rewrites the notebooks' connection and checks it; still no connection: nothing opens, see `exakit status`, `exakit logs` | `exakit start` |
| JupyterLab deleted (the kit's, or the user's own gone from PATH) | the row says `missing`; picking it offers to reinstall the kit's at its pin | `exakit notebook setup` (installs it, no question) |
| Marimo deleted | the row says `missing`; picking it offers to reinstall it | `exakit notebook marimo` (installs it) |
| The notebook environment deleted or not importing | offers the repair (the install again, about 1 GB) | `exakit update notebook` |
| Another program holds the port | the next free port (up to 20 above), said and recorded; with `--port N` it refuses instead | the same |
| The notebooks folder deleted | made again with the kit's notebooks (one notebook deleted from a folder that is still there stays deleted) | the same |
| The connection store or its master password deleted | a new store is written from the kit's connection | the same |
| The kernel removed | registered again on every launch | the same |
| The browser cannot open | the address, and the file the login token is in | the same |
| A tool is already running | opened where it runs, no second server | the same |

| Symptom | Do this |
|---|---|
| "The notebook add-on is not installed" | `exakit marketplace notebook` |
| "JupyterLab is not installed" (the user unticked it) | `exakit notebook setup` |
| "No connection to the kit's database was found" | Run it with the kit's notebook Python (the kernel Exasol (Starter Kit)); a new add-on: `exakit notebook check` |
| A notebook cannot connect | `exakit notebook check` |
| "Port N is in use by another program" (it was given with `--port`) | `exakit notebook --port <another>`, or leave `--port` out and a free one is used |
| Is it running? where is it? | `exakit notebook check`; its logs: `exakit logs notebook`, `exakit logs notebook-marimo` |
| `import exakit.nb` fails | `exakit update notebook` (it refreshes the kit's helpers) |


## Repeatable acceptance checks

Source notebooks remain the user's starting point. For the reference training recipes, Walmart sales (about half the weeks above the
store's median) uses `CLASS_WEIGHT = None`; Amazon sales (14.2% of lines cancelled)
uses `CLASS_WEIGHT = "balanced"`. Record the choice and compare with the same
held-out baseline. Do not claim that a model beats the baseline unless that held-out
comparison shows it.

Headless controls are explicit: `tools/notebooks.py --run --ai-themes`,
`--class-weight none|balanced`, `--approve-sql`, and
`--allow-database-restart`. Their shell twins are
`EXAKIT_NOTEBOOK_AI_THEMES=1`, `EXAKIT_NOTEBOOK_CLASS_WEIGHT=...`,
`EXAKIT_NOTEBOOK_APPROVE_SQL=1`, `EXAKIT_NOTEBOOK_ALLOW_RESTART=1`.
Never infer restart or dashboard figure approval from a passing health check.
The runner leaves `FIGURES_CHECKED = False`; the user checks and promotes.
`tools/ask_benchmark.py` requires `--approve-proposals` before automated read-only
SQL execution. Report its result scores, errors and exact model IDs; a provider
connection test does not prove answer quality.

Share's category filters, Top N and bar orientation update both charts and the
table together. The count notebook explicitly passes `measure="count"` for
count totals and composition. The generic helper defaults to `measure="value"`
and does not sum a rate or other unreviewed measure. Check the filtered and
unfiltered figures before promoting a revision.
