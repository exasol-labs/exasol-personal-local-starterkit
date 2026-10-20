---
name: notebook
addon: notebook
description: Open notebooks already connected to the local Exasol database with the notebook add-on, built on Exasol's notebook connector (the package AI Lab installs) — covering exakit notebook, --setup, --check and --stop, JupyterLab as an on-demand background service with its status, the Exasol (Starter Kit) kernel, why JupyterLab is offered and never installed unasked, the exakit_nb helpers, why no notebook ever holds a host, user or password, opt-in Langfuse tracing of model calls, and which AI Lab notebooks run on a local database. Triggers — "open a notebook", "start Jupyter", "JupyterLab on my Exasol", "notebook connected to the database", "install the notebook add-on", "exakit notebook", "stop JupyterLab", "is my notebook running", "use AI Lab notebooks locally", "trace my LLM calls to Langfuse", "my notebook cannot connect".
---

# notebook — JupyterLab connected to the local database

`notebook` is a **marketplace add-on**. It installs Exasol's notebook connector
(`exasol-notebook-connector`, the package Exasol's AI Lab is built on),
pyexasol, the Langfuse and OpenAI clients, the kit's helper package `exakit_nb`
and a Jupyter kernel, **Exasol (Starter Kit)**, in an environment of their own.

**JupyterLab is the user's choice.** A JupyterLab already on the machine is used
as it is, with the kit's kernel added (VS Code and other Jupyter front ends see
it too). When there is none, the kit asks before installing one; a skip installs
nothing and prints https://jupyter.org/install and the command to run after,
`exakit notebook`. Never install JupyterLab for the user without asking them:
pre-answer only on their word, with `EXAKIT_NOTEBOOK_JUPYTER=install` or `skip`.

Install it with `exakit marketplace notebook`. Never tell a user to
`pip install exasol-notebook-connector` themselves: that copy has no
connection, no helpers and no notebooks.

## Open it

```bash
exakit notebook                      # start JupyterLab in the background and open it in the browser
exakit notebook --stop               # stop it
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
import exakit_nb
conn = exakit_nb.connect()                         # the kit's connection, no secrets in the cell
df = exakit_nb.sql(conn, "SELECT * FROM TPCH.NATION")
exakit_nb.show_sql()                               # the statement that produced df
```

For a dataset with a descriptor (`pharma_trials`, `banking_complaints`, or a
`descriptor.json` the user wrote for their own table), the roles become SQL
names, checked against the database first:

```python
ds = exakit_nb.dataset(conn, "pharma_trials")      # or a path to a descriptor.json
exakit_nb.sql(conn, f"SELECT {ds.col('category')}, AVG({ds.col('label')}) FROM {ds.fact_table} GROUP BY 1")
```

`explore.ipynb` is built that way: one assignment (`DATASET = ...`) picks the
data, every query is printed before its result, a small scikit-learn model
runs on this computer, and a text step calls the user's own model endpoint
only when `EXAKIT_NB_MODEL` is set (endpoint and key in `OPENAI_BASE_URL` and
`OPENAI_API_KEY`). Point a user who gets "does not match the database" at
`exakit data-load <dataset>`.

`train.ipynb` trains inside the database: `exasol_mlflow.create_script(schema)`
makes a training UDF, the query feeds it the roles, and
`exasol_mlflow.log_training(conn, sql, experiment=...)` checks the UDF's answer
and logs one MLflow run (params, metrics, `training.sql`, the model, and the
`exasol.session_id` / `exasol.statement_id` / `exasol.deployment` tags) from
the client. The run goes to `MLFLOW_TRACKING_URI`, or to a local store in
`mlflow/` beside the notebook; the UDF never holds MLflow credentials.

The connection lives in the connector's **encrypted** configuration store,
written by the kit and refreshed on every `exakit notebook`, so a database
restart or a port change needs no edit. Never paste a host, user or password
into a notebook, and never print the store's contents.

## Tracing model calls (opt-in)

With `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_HOST` exported
before `exakit notebook`, `exakit_nb.trace(conn, "label")` records the model
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
`exakit udf-use`, `exakit udf-file`).

## When something is wrong

| Symptom | Do this |
|---|---|
| "The notebook add-on is not installed" | `exakit marketplace notebook` |
| "JupyterLab is not installed" (the user skipped) | Install it from https://jupyter.org/install, then `exakit notebook --setup` |
| "not running on the kit's kernel" | Choose the kernel Exasol (Starter Kit), or open via `exakit notebook` |
| A notebook cannot connect | `exakit notebook --check` |
| Another Jupyter answers on the port | `exakit notebook --port 8890` |
| Is it running? where is it? | `exakit notebook --check`; its log: `~/.exasol-starter-kit/logs/notebook.log` |
| `import exakit_nb` fails | `exakit update notebook` |
