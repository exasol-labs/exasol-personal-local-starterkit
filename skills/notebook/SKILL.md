---
name: notebook
addon: notebook
description: Open notebooks already connected to the local Exasol database with the notebook add-on, built on Exasol's notebook connector (the package AI Lab installs) — covering exakit notebook, --marimo, --positron, --setup, --check and --stop, the install's checklist of notebook tools (JupyterLab, Marimo, Positron), JupyterLab and Marimo as on-demand background services with their status, the persona folders of the kit's notebooks (AI Scientist and ML Engineer quickstarts, explore, train, score), the Exasol (Starter Kit) kernel, the exakit.nb helpers, why no notebook ever holds a host, user or password, opt-in Langfuse tracing of model calls, and which AI Lab notebooks run on a local database. Triggers — "open a notebook", "start Jupyter", "open Marimo", "use Positron with Exasol", "where are the starter kit notebooks", "JupyterLab on my Exasol", "notebook connected to the database", "install the notebook add-on", "exakit notebook", "stop JupyterLab", "is my notebook running", "use AI Lab notebooks locally", "trace my LLM calls to Langfuse", "my notebook cannot connect".
---

# notebook — JupyterLab, Marimo or Positron connected to the local database

`notebook` is a **marketplace add-on**. It installs Exasol's notebook connector
(`exasol-notebook-connector`, the package Exasol's AI Lab is built on),
pyexasol, the Langfuse and OpenAI clients, the kit's helper package `exakit.nb`
(`exakit_nb` still imports) and a Jupyter kernel, **Exasol (Starter Kit)**, in an environment of their own.

**The notebook tools are the user's choice: one checklist at the install, all
three ticked.** JupyterLab: one already on the machine is used as it is, with the
kit's kernel added (VS Code and other Jupyter front ends see it too); with none,
the kit's is installed (the connector's `[jupyter]` extra) because it was ticked. Marimo: installed into the kit's
notebook environment. Positron: never installed - when the user has it, the
notebooks folder is set to the kit's Python (`.vscode/settings.json`, their other
settings kept); when not, the folder is ready for it. Pre-answer only on the
user's word: `EXAKIT_NOTEBOOK_FRONTENDS=jupyterlab,marimo,positron` (or `none`),
or `EXAKIT_NOTEBOOK_JUPYTER=skip` / `EXAKIT_NOTEBOOK_MARIMO=skip` to leave one out.
The JupyterLab and Marimo versions are pinned in the kit's `versions.json`
(`components.notebook.frontends`) and move with `exakit update notebook`.

The kit's notebooks are in `~/.exasol-starter-kit/notebooks/starter-kit-notebooks/`,
one folder per persona, with a README naming the order to open them in:
`data-scientist/00_quickstart` then `01_explore` (AI Scientist), and
`ml-engineer/00_quickstart`, `01_train`, `02_score_external_model` (ML Engineer);
`00_shared/` holds the cells both quickstarts use. Marimo's copies are in
`notebooks/marimo/<persona>/`. A file there is the user's: the kit never overwrites it.

Install it with `exakit marketplace notebook`. Never tell a user to
`pip install exasol-notebook-connector` themselves: that copy has no
connection, no helpers and no notebooks.

## Open it

```bash
exakit notebook                      # start JupyterLab in the background and open it in the browser
exakit notebook --marimo             # the same notebooks in Marimo (installs it when the user says yes)
exakit notebook --positron           # the user's Positron on the notebooks folder, with the kit's Python
exakit notebook --stop               # stop JupyterLab and Marimo (--stop --marimo: only Marimo)
exakit notebook --setup              # register the kernel, find or offer JupyterLab, start nothing
exakit notebook --no-browser --port 8890
exakit notebook --check              # connect and report (and whether JupyterLab runs), start nothing
```

JupyterLab runs in the background until it is stopped, so `exakit notebook`
returns at once; with `--no-browser` it opens no browser and prints the address
(without the token). It is an on-demand
service: `exakit start` (everything) does not start it and it never starts at
login. `exakit notebook --check` says whether it runs.
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

For a dataset with a descriptor (`pharma_trials`, `banking_complaints`, or a
`descriptor.yaml` the user wrote for their own table), the roles become SQL
names, checked against the database first:

```python
ds = nb.dataset(conn, "pharma_trials")             # or a descriptor.yaml path, or a data file with one beside it
nb.sql(conn, f"SELECT {ds.col('category')}, AVG({ds.col('label')}) FROM {ds.fact_table} GROUP BY 1")
nb.load_own_file("~/data/claims.csv", "MY_DATA.CLAIMS", {"entity": "CUSTOMER", ...})   # CSV, Parquet or JSON
```

`data-scientist/01_explore` is built that way: one assignment (`DATASET = ...`) picks the
data, every query is printed before its result, a small scikit-learn model
runs on this computer, and a text step calls the user's own model endpoint
only when `EXAKIT_NB_MODEL` is set (endpoint and key in `OPENAI_BASE_URL` and
`OPENAI_API_KEY`). Point a user who gets "does not match the database" at
`exakit data-load <dataset>`.

`ml-engineer/01_train` trains inside the database: `exasol_mlflow.create_script(schema)`
makes a training UDF, the query feeds it the roles, and
`with exasol_mlflow.start_run(conn, params=...) as run: run.execute(sql)` checks
the UDF's answer and logs one MLflow run (params, metrics, `training.sql`, the model, and the
`exasol.session_id` / `exasol.statement_id` / `exasol.deployment` tags) from
the client. The run goes to `MLFLOW_TRACKING_URI`, or to a local store in
`mlflow/` beside the notebook; the UDF never holds MLflow credentials.

The connection lives in the connector's **encrypted** configuration store,
written by the kit and refreshed on every `exakit notebook`, so a database
restart or a port change needs no edit. Never paste a host, user or password
into a notebook, and never print the store's contents.

## Tracing model calls (opt-in)

With `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_HOST` exported
before `exakit notebook`, `nb.trace(conn, "label")` records the model
calls made inside it in the user's own Langfuse project, tagged with the
database session and the last SQL; `trace(conn, "label", dataset=ds)` adds the
dataset and the descriptor's digest. Without those variables it prints that tracing is off and
the notebook runs unchanged. The kit ships no model: the user's
`OPENAI_BASE_URL` may point at a local endpoint such as Ollama.

## AI Lab notebooks on a local database

AI Lab notebooks that use only the database run here. Those that upload to
BucketFS, install the Transformers or Text AI extensions, or deploy a container
through BucketFS do not: a local Exasol Personal database has no BucketFS
upload service. For UDFs use the udf-devkit add-on (`exakit udf-setup`,
`exakit udf-use`, `exakit model put`); `ml-engineer/02_score_external_model` scores a model trained
anywhere with the udf-devkit's scoring template.

## When something is wrong

| Symptom | Do this |
|---|---|
| "The notebook add-on is not installed" | `exakit marketplace notebook` |
| "JupyterLab is not installed" (the user unticked it) | `exakit notebook --setup` |
| "No connection to the kit's database was found" | Run it with the kit's notebook Python (the kernel Exasol (Starter Kit)); a new add-on: `exakit notebook --check` |
| A notebook cannot connect | `exakit notebook --check` |
| Another Jupyter answers on the port | `exakit notebook --port 8890` |
| Is it running? where is it? | `exakit notebook --check`; its logs: `exakit logs notebook`, `exakit logs notebook-marimo` |
| `import exakit.nb` fails | `exakit update notebook` (it refreshes the kit's helpers) |
