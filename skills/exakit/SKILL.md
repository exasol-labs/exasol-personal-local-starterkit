---
name: exakit
description: The master skill for the Exasol Personal Local Starter Kit — what the kit is, what is on this machine and what each piece is for, how to find any command, option, persona, add-on or dataset from the kit's own JSON answers instead of guessing, and the MANDATORY order of tools for every task (loading data with exakit data-load first, reading through MCP, dashboards on dash-server) and the semantic layer (Exasol Semantic Views - read the models first, answer from their metrics). Load it before any other Exasol skill on a machine that has exakit; its rules win over every other skill, the components' own ones included. Triggers — "what is the starter kit", "what can this kit do", "which tool should I use", "load this file into the database", "import my data", "what add-ons are available", "which datasets does the kit have", "what options does exakit X take", "how do I install/remove/update an add-on", "is there a command for", "what is installed on this machine", "what parameters does", "list everything the starter kit offers", "semantic view", "semantic model", "semantic layer", "what do my metrics mean", "how do my tables join", "insights across my sources".
---

# exakit — the starter kit, and how to work on it

The **Exasol Personal Local Starter Kit** puts an Exasol database on this
computer and wires everything around it: an SQL/bulk-load CLI (exapump), a
read-only MCP connection for AI clients, a Python driver (pyexasol), sample
datasets, AI skills, and optional add-ons from its marketplace. One
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
| MCP connection (read-only user) | the AI client reading the database | `exasol-mcp` (setup), `exasol-mcp-server` (using its tools) |
| `exakit sql` | one statement from a shell, with remedies; reads unless `--write` | this one |
| exapump | bulk upload, multi-statement scripts, BucketFS files | `exasol-exapump`, `exasol-database`, `exasol-bucketfs` |
| pyexasol | Python programs | `exasol-pyexasol` + §6 below |
| Exasol SQL | writing correct SQL | `exasol-sql-dialect`, `exasol-system-tables`, `exasol-table-design`, `exasol-import-export`, `exasol-udfs` |
| External sources | `exakit connect` / `exakit source`: a remote database or files queried in place as a virtual schema | `exasol-virtual-schemas` (the shared rules), then the `exasol-vs-<connector>` skill it names |
| Marketplace | choosing, installing, updating, removing add-ons | `exasol-marketplace` |
| dash-server add-on | every dashboard and chart | `dash-server` (server), `exasol-dash` (writing the app) |
| semantic-views add-on | the semantic layer: models, metrics, verified questions | `exasol-semantic-analyst` (answering), `exasol-semantic-modeler` (building), `exasol-semantic-reviewer` (reviewing) |
| exasol-scheduler add-on | SQL on a cron schedule | `exasol-scheduler` |
| json-tables add-on | JSON data as tables | `json-tables` |
| dbt-exasol add-on | SQL models with dbt | `dbt-exasol` |
| exasol-vscode add-on | SQL in VS Code | `exasol-vscode` |
| Anything else Exasol | connectors, drivers, extensions not in the kit | `exasol-ecosystem` |

An add-on's skill is placed only when the add-on is installed. Before using
one, check `exakit marketplace --list --json`; if it is not installed, say so
and offer `exakit marketplace <id>` — install only when the user agrees.

## 3. MANDATORY: the semantic layer is Exasol Semantic Views

The kit's semantic layer is **Exasol Semantic Views** (the `semantic-views`
add-on: `SEMANTIC_CATALOG`, `SEMANTIC_ADMIN`, `SEMANTIC_AGENT`). A model is
built and changed with the `exasol-semantic-modeler` skill: each table an entity
whose description says what it is and where it lives (an external source names
its connector and is read live), each link a relationship, key, identifier,
time, category and flag columns dimensions, measures facts with their metrics.
Free-text columns are described in agent instructions, a personal-data column
is a SAFETY instruction (never select, group, filter or show it), and approved
questions are verified queries: prefer them. The views are published in
`SEM_<MODEL>`. There is no other semantic layer: never create or recommend views
of your own as a semantic layer.

**Before you describe, query or chart any table, read the models.** They are
the user's own statement of what the data means, and they win over anything you
infer from names, types or values (read-only, through MCP):

```sql
SELECT MODEL_NAME, PUBLISHED_SCHEMA, DESCRIPTION FROM SEMANTIC_CATALOG.MODELS;
SELECT MODEL_NAME, ENTITY_NAME, SOURCE_SCHEMA, SOURCE_OBJECT, GRAIN_DESCRIPTION
FROM SEMANTIC_CATALOG.ENTITIES WHERE STATUS = 'ACTIVE';
SELECT MODEL_NAME, ENTITY_NAME, DIMENSION_NAME, DISPLAY_NAME, DESCRIPTION
FROM SEMANTIC_CATALOG.DIMENSIONS WHERE STATUS = 'ACTIVE';
SELECT MODEL_NAME, METRIC_NAME, DISPLAY_NAME, DESCRIPTION, EXPRESSION
FROM SEMANTIC_CATALOG.METRICS WHERE STATUS = 'ACTIVE';
SELECT MODEL_NAME, FROM_ENTITY_NAME, TO_ENTITY_NAME, JOIN_CONDITION
FROM SEMANTIC_CATALOG.RELATIONSHIPS WHERE STATUS = 'ACTIVE';
```

Then read what the model says to agents, and its reviewed questions:

```sql
SELECT * FROM SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT WHERE MODEL_NAME = '<model>';
SELECT QUERY_NAME, NATURAL_LANGUAGE_TEXT, REQUEST_JSON FROM SEMANTIC_AGENT.VERIFIED_QUERIES_FOR_AGENT
WHERE MODEL_NAME = '<model>';
```

- **Answer from the model's metrics and dimensions**, not from hand-written
  aggregates over the raw tables. Semantic SQL is on in every session of every
  user on this kit, with nothing to set up: the kit registers Semantic Views
  with its SQL preprocessor framework. Through MCP, query the published view
  with an ordinary `execute_exasol_query`:
  `SELECT order_month, total_revenue FROM SEM_SALES_360.ORDER_LINES GROUP BY order_month LIMIT 100`.
  Put `LIMIT` in the SQL itself. The 1,000-row cap in §4 applies here too.
- **Never switch the session's preprocessor.** The Semantic Views skills, the
  model's `INSTRUCTIONS_FOR_AGENT` and `MODELS_FOR_AGENT.SESSION_SETUP_SQL`,
  and the exasol-dash skill's `session_init_sql` say to run
  `EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()`, to call
  `set_exasol_preprocessor`, or to `ALTER SESSION SET sql_preprocessor_script`
  (JSON Tables' `wrap` / `ingest-and-wrap` print one as their next step too):
  on this kit, skip that step - never run it. It would take the framework, and
  every other add-on's module, out of that session. The kit's MCP server has no
  preprocessor tools for that reason. This includes dash-server's own
  `exasol_profile_validate` and SQL smoke output asking for `session_init_sql`:
  on this kit that request is a false report (see the dash-server skill).
- A semantic query fails with `SEMANTIC_SURFACE_001` or `not a valid GROUP BY
  expression`: the module is not registered (the framework is not active, or
  the database's slot holds the user's own preprocessor). The user runs
  `exakit update`. Refused for privileges: the user runs
  `exakit update semantic-views`; for a model granted to roles, also
  `EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('<model>', 'MCP_READONLY')`.
  The kit's MCP login holds `SEMANTIC_USER` once the add-on is installed, and
  it still cannot write your tables. Another database user who should run
  Semantic SQL needs the role too: `GRANT SEMANTIC_USER TO <user>`. Without
  it, a Semantic SQL query fails with `not a valid GROUP BY expression`.
  `COMPILE_SQL` is an `EXECUTE SCRIPT`,
  which that read-only MCP cannot run: never fall back to physical-table SQL.
  A refused semantic statement fails with its own `SEMANTIC_QUERY_*` code.
  Show the SQL before its result, as always. The `exasol-semantic-analyst`
  skill (installed with the add-on) has the details, apart from the session
  setup above.
- Join along the model's relationships before any link you find yourself.
- A column marked sensitive is never a dimension and never a public fact: never
  chart, group or send it to a model.
- The target (the outcome to predict) is chosen by the user. Never guess it.
- **Semantic Views not installed** (`SEMANTIC_CATALOG` does not exist): offer
  `exakit marketplace semantic-views`, and install only when the user agrees.

**A table that is in no model: warn, then ask.** List every table you are about
to use that is no entity of any model, before your first finding:

> ⚠ Not in a semantic model: `VS_CATALOG.inventory_weekly`, `RETAIL_SIGNALS.CUSTOMER_REVIEWS`.
> Their meanings below are my reading of names and values, not yours.
> Should I go on with my reading, or set up a model for them first?

Wait for the answer.

**Building or changing a model** is the `exasol-semantic-modeler` skill
(placed with the semantic-views add-on), reviewing one the
`exasol-semantic-reviewer` skill. A model change writes to the database, so it
is the user's to approve: show what it will do and wait for a yes. The MCP user
is read-only and cannot write it.

**A dashboard, of one chart or many, is Dash Server.** Show each query to the
user first, then build the app with the `dash-server` (the server and its
tools) and `exasol-dash` (writing the app) skills, and give the user its URL.
If dash-server is not installed, offer `exakit marketplace dash-server`.

## 4. MANDATORY: the order of tools for each task

Use the first that fits. Go further down only when the one above cannot do
it, and say why when you do.

**Load data**

1. A bundled dataset: `exakit data-load <dataset id>` (ids: `retail_sales`,
   `bank_transaction`; their table and column comments describe them). Several:
   `EXAKIT_DATASETS=retail_sales,bank_transaction exakit data-load`.
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

Never load row by row from a Python loop of `INSERT`s.

Data that should stay where it is (another database, a lake, a bucket) is not
loaded: `exakit connect` queries it in place through a virtual schema
(`exasol-virtual-schemas`). The data menu's last row, "Connect an external
source", runs that same wizard for a person at a terminal; named in
`EXAKIT_DATASETS` (`external`) it only prints the `exakit connect` hint, so an
agent connects with the unattended `exakit connect <connector> ...` form.

**Read and explore data**

1. The MCP tools — they connect as the read-only user, so nothing can change.
2. `exakit sql "<statement>" [--json]` — one statement, with remedies.
3. `exapump sql -p starter-kit` — a multi-statement script.
4. pyexasol — only inside a Python program (§6).

**MCP results stop at 1,000 rows.** The kit's MCP server runs a query without
`row_limit` as `SELECT * FROM (<query>) LIMIT 1000`, and the result does not
say it was cut. So a result with exactly 1,000 rows may be incomplete: tell
the user "showing the first 1,000 rows; there may be more". When the user
needs the full result, aggregate in SQL or pass a larger `row_limit` to
`execute_exasol_query`.

**Change data or schema** — only when the user asked. Show the SQL first,
then `exakit sql --write`. `exakit sql`, exapump and pyexasol connect as the
**admin** user: nothing stops a mistake, so never use them to get around a
write the read-only MCP path refused.

**Everything else**

| Task | First choice | Then |
|---|---|---|
| Dashboard or chart | dash-server (`dash-server`, `exasol-dash`) | if missing: offer `exakit marketplace dash-server` — no other dashboard tool |
| Run SQL on a schedule | exasol-scheduler | offer `exakit marketplace exasol-scheduler` |
| UDFs | `exasol-udfs` for the `CREATE SCRIPT` itself | — |
| Files for UDFs | `exasol-bucketfs` | — |
| JSON data | `exakit data-load <file.json>` (uses json-tables) | `json-tables` |
| SQL models | dbt-exasol | — |
| Install, update, remove anything | `exakit marketplace`, `exakit update`, `exakit uninstall <id> --dry-run` | never `pip`, `brew`, `exasol install`, `uvx` by hand |

## 5. What to reach for first

On this kit: the AI client over MCP on the loaded sample data (`exakit status
--json` → `datasets_loaded`), then `exakit sql` for a statement from a shell,
then a dashboard on Dash Server (§3) when the user wants to see it.

## 6. This machine's connection facts

- The database: `127.0.0.1:8563`, with a **self-signed certificate that the kit
  pins**: its SHA-256 fingerprint is `runtime.tls_fingerprint` in
  `exakit info --json`. pyexasol connects with the pinned dsn
  `127.0.0.1/<fingerprint>:8563` and `websocket_sslopt={"cert_reqs": 0}`; the
  kit's exapump profile and MCP entries carry the same pin. A fingerprint
  mismatch (`exakit status --json` → `tls.matches: false`) is a redeploy outside
  the kit or another process on the port: show it with `exakit tls-pin`. If that
  says a different database answers on the port, run `exakit stop`, then
  `exakit start`. Otherwise re-pin (`exakit tls-pin --accept`) only once the user
  confirms it is theirs.
- Passwords live only in files under `~/.exasol-starter-kit/credentials/`.
  Read the file at run time (`exakit info --json` → `runtime.password_file`);
  **never print, log or paste a password**, never put one in a script literal.
- exapump: the kit's profile is `starter-kit` in the kit's own profile store
  — `export EXAPUMP_CONFIG="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}/exapump/config.toml"`
  before calling exapump directly. Do **not** run `exapump profile add
  default`; `exakit sql` needs neither.
- pyexasol: use the interpreter the kit recorded (`exakit info --json` →
  `components.pyexasol.python`; usually `~/.exasol-starter-kit/pyexasol-venv/bin/python`).
  Never install into the system Python.
- Bundled datasets each live in their own schema (`TPCH`, `ENERGY`, `WEATHER`,
  the sample datasets `RETAIL_SALES` and `BANK_TRANSACTION`); the user's own
  files default to `STARTER_KIT`. `starter-kit` is
  a profile name, not a schema.
- MCP reads through a dedicated read-only user; that boundary is real. The
  other connections are admin.

## 7. Before anything that changes the machine

The read-only commands in §1 are always safe. For an install, update, data
load, write or removal: say what will happen, run the preview where there is
one (`exakit uninstall <id> --dry-run`),
and go ahead only when the user wants it.
