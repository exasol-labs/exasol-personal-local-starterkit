---
name: exakit
description: The master skill for the Exasol Personal Local Starter Kit — what the kit is, what is on this machine and what each piece is for, how to find any command, option, persona, add-on or dataset from the kit's own JSON answers instead of guessing, and the MANDATORY order of tools for every task (loading data with exakit data-load first, reading through MCP, notebooks from the kit's own persona notebooks, dashboards on dash-server). Load it before any other Exasol skill on a machine that has exakit; its rules win over every other skill, the components' own ones included. Triggers — "what is the starter kit", "what can this kit do", "which tool should I use", "load this file into the database", "import my data", "create a new notebook", "make me a notebook", "which notebook should I use", "which personas does this kit have", "what add-ons are available", "which datasets does the kit have", "what options does exakit X take", "how do I install/remove/update an add-on", "is there a command for", "what is installed on this machine", "what parameters does", "list everything the starter kit offers".
---

# exakit — the starter kit, and how to work on it

The **Exasol Personal Local Starter Kit** puts an Exasol database on this
computer and wires everything around it: an SQL/bulk-load CLI (exapump), a
read-only MCP connection for AI clients, a Python driver (pyexasol), sample
datasets, personas, AI skills, and optional add-ons from its marketplace. One
command operates all of it: `exakit` (`exakit.cmd` on Windows; call
`~/.local/bin/exakit` when a non-interactive shell does not find it).

**This skill's rules come first.** Other skills placed here — including the
ones copied unchanged from Exasol's component repositories (marked *Exasol
starter kit: Exasol's own skill* at the top) — are right about their tool, but
they do not know this machine. Where one says to install something, create a
connection profile, or load data another way, do it the way this skill says.

## 1. Never guess — ask the kit

Every fact about the kit is answered by the kit itself, read-only. **Run the
query, then answer from what it returned.** A command, option, persona,
add-on or dataset the kit does not report does not exist here: say so.

| Question | Ask | What to read |
|---|---|---|
| Which commands exist, with which options? | `exakit catalog --json` (search: `exakit catalog <word> --json`) | `commands[]`: `invocation`, `usage`, `options`, `parameters`, `examples`, `help_command`; `hidden: true` is not for normal use |
| How exactly does one command or add-on work? | `exakit help <command> --json`, `exakit help <add-on id> --json` | a command's `environment` and `exit_codes`; an add-on's `role`, `platforms`, `environment` and `management` (its exact install / update / uninstall / uninstall_preview commands) |
| Which personas exist, what does each bring? | `exakit persona list --json`, `exakit persona show <id> --json` | `id`, `title`, `summary`, `datasets`, `mcp_clients`, `notebooks[]`, `start_here`, and `addons` / `services` / `udf_language` when the persona has them; `recorded` = the personas this kit was set up as |
| What of a persona is still missing? | `exakit persona plan [<id>] --json` | `datasets.loaded/pending`, `addons.installed/pending`, `nothing_pending` |
| Which add-ons exist, which are installed? | `exakit marketplace --list --json` | `addons[]`: `id`, `status`, `installed`, `ownership`, `version`, `reason` (why one is not offered here) |
| Is the database up, what data is loaded? | `exakit status --json` | `status`, `datasets_loaded`, `services`, `remedy`; exit 0 running, 3 stopped, 4 not installed |
| Versions, installed and advertised | `exakit version --json` | one row per component and add-on |
| Which AI skills are placed? | `exakit skills --json` | `skills[]`: `name`, `state`, `addon`, `remedy` |
| Which AI clients are connected? | `exakit mcp-status --json` | per client; `remedy` names the next command |
| Where are the logs? | `exakit logs --json` | every log target and its path |
| What does a bundled dataset contain? | `~/.exasol-starter-kit/kit/data/data-dictionary.md` | every bundled dataset's schema, tables, columns and meaning |
| What is in the database right now? | the MCP tools, or `exakit sql "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROW_COUNT FROM SYS.EXA_ALL_TABLES WHERE TABLE_SCHEMA NOT LIKE 'SYS%'" --json` | — |

Exit codes are per command: read `exit_codes` in `exakit help <command> --json`.
The usual pattern is 0 done, 2 bad input (nothing changed), 3 database not
running, 4 no kit, 5 not confirmed. A non-zero exit prints the command that
fixes it — relay that exact line rather than composing your own.

## 2. What is here, and what each piece is for

| Piece | Use it for | Skill |
|---|---|---|
| Exasol Personal (the database) | everything; `exakit start` / `stop` / `status` | `exasol-runtime` |
| exakit itself | discovery, updates, logs, uninstall | this one, `exakit-lifecycle` |
| Personas | what this machine is set up for | `exakit-personas` |
| MCP connection (read-only user) | the AI client reading the database | `exasol-mcp` (setup), `exasol-mcp-server` (using its tools) |
| `exakit sql` | one statement from a shell, with remedies; reads unless `--write` | this one |
| exapump | bulk upload, multi-statement scripts, BucketFS files | `exasol-exapump`, `exasol-database`, `exasol-bucketfs` |
| pyexasol | Python programs outside notebooks | `exasol-pyexasol` + §6 below |
| Exasol SQL | writing correct SQL | `exasol-sql-dialect`, `exasol-system-tables`, `exasol-table-design`, `exasol-import-export`, `exasol-udfs`, `exasol-virtual-schemas` |
| Marketplace | choosing, installing, updating, removing add-ons | `exasol-marketplace` |
| notebook add-on | JupyterLab / Marimo with the kit's persona notebooks | `notebook` |
| dash-server add-on | live dashboards | `dash-server` (server), `exasol-dash` (writing the app) |
| udf-devkit add-on (hidden for now: not offered; a kit that has it keeps it) | Python/Rust UDF containers, models in BucketFS, local MLflow | `udf-devkit` |
| exasol-scheduler add-on | SQL on a cron schedule | `exasol-scheduler` |
| json-tables add-on | JSON data as tables | `json-tables` |
| dbt-exasol add-on | SQL models with dbt | `dbt-exasol` |
| exasol-vscode add-on | SQL in VS Code | `exasol-vscode` |
| Anything else Exasol | connectors, drivers, extensions not in the kit | `exasol-ecosystem` |

An add-on's skill is placed only when the add-on is installed. Before using
one, check `exakit marketplace --list --json`; if it is not installed, say so
and offer `exakit marketplace <id>` — install only when the user agrees.

## 3. MANDATORY: the order of tools for each task

Use the first that fits. Go further down only when the one above cannot do
it, and say why when you do.

**Load data**

1. A bundled dataset: `exakit data-load <dataset id>` (ids: `persona show
   <id> --json` → `datasets`, or the data dictionary). Several:
   `EXAKIT_DATASETS=tpch,energy exakit data-load`.
2. The user's file or folder — CSV, Parquet, JSON/NDJSON/GeoJSON, a tabular
   `.tsv`/`.txt`: `exakit data-load <path>`. Without a terminal, answer its
   questions with variables: `EXAKIT_DATA_TABLE=SCHEMA.TABLE exakit data-load
   ./sales.csv`, `EXAKIT_SCHEMA=SALES exakit data-load ~/exports`;
   `EXAKIT_ON_EXISTING=skip|replace|append` for a table that already has rows
   (default skip). It checks, de-duplicates, is safe to re-run, and lists the
   rows each file landed.
3. Only when `exakit data-load` cannot (it names the file and the reason):
   `exapump upload <file> --table SCHEMA.TABLE -p starter-kit` with
   `EXAPUMP_CONFIG` set as in `exasol-exapump`.
4. Only for data the database reaches itself (a URL, S3, another database) or
   that neither tool takes: SQL `IMPORT` (`exasol-import-export`), run with
   `exakit sql --write`.

Never load row by row from a Python loop of `INSERT`s. In a notebook, use
`nb.load_own_file(...)` (§5).

**Read and explore data**

1. The MCP tools — they connect as the read-only user, so nothing can change.
2. `exakit sql "<statement>" [--json]` — one statement, with remedies.
3. `exapump sql -p starter-kit` — a multi-statement script.
4. pyexasol — only inside a Python program (§6); inside a notebook, `exakit.nb`.

**Change data or schema** — only when the user asked. Show the SQL first,
then `exakit sql --write`. `exakit sql`, exapump and pyexasol connect as the
**admin** user: nothing stops a mistake, so never use them to get around a
write the read-only MCP path refused.

**Everything else**

| Task | First choice | Then |
|---|---|---|
| Notebook work | the kit's notebooks via `exakit notebook` (§5) | — never a bare `pip install jupyter` |
| Dashboard or chart | dash-server (`dash-server`, `exasol-dash`) | if missing: offer `exakit marketplace dash-server` — no other dashboard tool |
| Run SQL on a schedule | exasol-scheduler | offer `exakit marketplace exasol-scheduler` |
| UDFs, model scoring in the database | udf-devkit commands (`exakit udf-setup`, `udf-use`, `model put`, `udf-file`) | `exasol-udfs` for the `CREATE SCRIPT` itself |
| Files for UDFs | `exakit udf-file` / `exakit model put` | `exasol-bucketfs` |
| JSON data | `exakit data-load <file.json>` (uses json-tables) | `json-tables` |
| SQL models | dbt-exasol | — |
| Install, update, remove anything | `exakit marketplace`, `exakit update`, `exakit uninstall <id> --dry-run` | never `pip`, `brew`, `exasol install`, `uvx` by hand |

## 4. Personas: what to reach for first

Confirm what the user's persona brings with `exakit persona show <id> --json`
(the recorded ones: `persona list --json` → `recorded`); its `start_here` is
the first step. Then, in this order:

| Persona | First | Then | Then |
|---|---|---|---|
| `data-scientist` | its notebooks in order: `00_quickstart`, `01_explore`, `02_ask_your_data`, `03_share` | its datasets through MCP / `exakit sql` | `03_share` → a dashboard on dash-server |
| `ml-engineer` (not offered in this release: only a kit set up with it before) | its notebooks in order: `00_quickstart`, `01_train` (logs to the local MLflow), `02_rust_score`, `03_score_external_model` | udf-devkit: `exakit udf-setup`, `exakit model put`, `exakit mlflow` | MCP / `exakit sql` to check the scores |
| `general` | the AI client over MCP on TPC-H, energy and weather | `exakit sql` | add a persona when the user wants more: `exakit persona add <id>` |

Anything a persona lists as pending (`persona plan --json`) is brought in with
`exakit persona add <id>` — not by installing pieces by hand.

## 5. MANDATORY: notebooks

The kit's notebooks are connected, tested starting points. Use them; never
start from an empty notebook or write connection code by hand.

- **Open** with `exakit notebook` (JupyterLab) or `exakit notebook marimo`.
  Without a terminal name the tool. `exakit notebook check` proves the
  connection without starting anything. The notebook add-on must be installed
  (`exakit marketplace notebook`).
- **Where they are:** `~/.exasol-starter-kit/notebooks/starter-kit-notebooks/<persona>/`
  (JupyterLab) and `~/.exasol-starter-kit/notebooks/marimo/<persona>/` (Marimo).
  The persona's `notebooks[]` in `persona show <id> --json` gives each path,
  relative to those folders (`data-scientist/00_quickstart.ipynb`).
- **Use first, in this order:** the persona's notebook for the task (see §4).
  Changing what it analyses is usually one assignment in its first cell
  (`DATASET = ...`, or a data file with a descriptor beside it).
- **Editing:** edit the kit's notebook in place when the user asks for a change
  to it. An edited kit notebook is never overwritten by an update, and a
  deleted one is not copied back.
- **A new notebook** goes into the **same persona folder**, named with the next
  step number and a short topic (`04_churn_by_region.ipynb`; Marimo:
  `04_churn_by_region.py`), and **starts as a copy of that persona's
  `00_quickstart`** (or of the kit notebook closest to the task) so it keeps
  the `Exasol (Starter Kit)` kernel and the connection cells. Then edit the
  copy. Connect only through the helpers:

  ```python
  import exakit.nb as nb
  conn = nb.connect()                         # the kit's connection; no host, user or password in a cell
  df = nb.sql(conn, "SELECT ...")
  nb.load_own_file("~/data/x.csv", "MY_DATA.X", {...})   # loading from a notebook (a folder: exakit data-load)
  ```
- **Never** put a host, user, password or token in a notebook cell, its
  output, or a file beside it.

## 6. This machine's connection facts

- The database: `127.0.0.1:8563`, with a **self-signed certificate that the kit
  pins**: its SHA-256 fingerprint is `runtime.tls_fingerprint` in
  `exakit info --json`. pyexasol connects with the pinned dsn
  `127.0.0.1/<fingerprint>:8563` and `websocket_sslopt={"cert_reqs": 0}`; the
  kit's exapump profile and MCP entries carry the same pin. A fingerprint
  mismatch (`exakit status --json` → `tls.matches: false`) is a redeploy outside
  the kit or another process on the port: show it with `exakit tls-pin`, and
  re-pin (`exakit tls-pin --accept`) only once the user confirms it is theirs.
- Passwords live only in files under `~/.exasol-starter-kit/credentials/`.
  Read the file at run time (`exakit info --json` → `runtime.password_file`);
  **never print, log or paste a password**, never put one in a script literal.
- exapump: the kit's profile is `starter-kit` in the kit's own profile store
  — `export EXAPUMP_CONFIG="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}/exapump/config.toml"`
  before calling exapump directly. Do **not** run `exapump profile add
  default`; `exakit sql` needs neither.
- pyexasol: use the interpreter the kit recorded (`exakit info --json` →
  `components.pyexasol.python`; usually `~/.exasol-starter-kit/pyexasol-venv/bin/python`).
  Never install into the system Python. Dataframes need pandas, which that
  environment does not have — use a notebook, which does.
- Bundled datasets each live in their own schema (`TPCH`, `ENERGY`, `WEATHER`,
  bundled and loaded offline, and per persona `AMAZON` and `FRAUD`, downloaded
  from the kit's `datasets` release); the user's own files default to `STARTER_KIT`. `starter-kit` is
  a profile name, not a schema.
- MCP reads through a dedicated read-only user; that boundary is real. The
  other connections are admin.

## 7. Before anything that changes the machine

The read-only commands in §1 are always safe. For an install, update, data
load, write or removal: say what will happen, run the preview where there is
one (`exakit uninstall <id> --dry-run`, `exakit persona plan <id> --json`),
and go ahead only when the user wants it.
