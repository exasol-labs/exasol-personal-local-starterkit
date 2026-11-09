# Skills — agent guidance for the starter kit

> **TL;DR** — These are AI *skills*: small `SKILL.md` recipes that teach an
> agent how to drive this kit. The installer copies them into
> `~/.claude/skills/` and `~/.agents/skills/`; `exakit update` fetches a newer set.

**What is verified, and what is assumed.** Claude Code reads `~/.claude/skills/`
and picks these up on its next start — that path is tested. `~/.agents/skills/`
is written for agents that follow the same convention; whether a given tool reads
it is that tool's business, and the kit does not claim to have verified each one.
Nothing depends on it: an agent that reads no skills at all still gets the whole
contract from [AGENTS.md](../AGENTS.md), which inlines the guardrails (the
ask → inspect → run → validate loop, "exapump and `exakit sql` are the admin
connection", and the `SYS.EXA_USER_SYS_PRIVS` privilege probe) precisely so they
survive a skill-less harness. Skills make an agent better here; they are not what
makes it safe.

## What's here

One skill per thing an agent has to operate — so the agent loads only what the
user's request actually needs, not a manual for the whole kit.

**Start here**

| Skill | Use it when… |
|---|---|
| [`local-agent-ready-starter`](local-agent-ready-starter/SKILL.md) | Setting up the kit and running a first trusted, AI-assisted query — install → connect MCP → load data → ask/inspect/run/validate/rerun. |
| [`exakit`](exakit/SKILL.md) | **The master skill — load it first.** What the kit is and what each piece is for; how to find any command, option, persona, add-on or dataset from the kit's own `--json` answers instead of guessing; and the MANDATORY order of tools: `exakit data-load` before exapump before SQL `IMPORT`, MCP before admin SQL, the kit's persona notebooks (a new one is a copy of the persona's quickstart, in the same folder), dash-server for dashboards. Its rules win over every other skill on this machine. |
| [`exakit-personas`](exakit-personas/SKILL.md) | Personas: listing what each brings, `persona plan` for what is still pending, `persona add` / `remove`, `EXAKIT_PERSONA` at install (and why your own answer replaces the persona's), and defining a new persona as a file. |

**The fixed components** — always installed

| Skill | Use it when… |
|---|---|
| [`exasol-runtime`](exasol-runtime/SKILL.md) | Starting, stopping or diagnosing the local Exasol Personal deployment; autostart. |
| [`exasol-exapump`](exasol-exapump/SKILL.md) | Running SQL, opening a SQL shell, bulk-loading CSV/Parquet — and knowing that the `starter-kit` profile is the **admin**, unsandboxed connection. |
| [`exasol-mcp`](exasol-mcp/SKILL.md) | Connecting AI clients over MCP, diagnosing `mcp-doctor`, repairing config drift, proving the read-only user really is read-only. |
| [`exakit-lifecycle`](exakit-lifecycle/SKILL.md) | Operating the kit itself — versions and what changed, updates, logs, the command surface, where the credential files live, and uninstalling with `--dry-run` first. |
| [`exasol-virtual-schemas`](exasol-virtual-schemas/SKILL.md) | Querying an external source from local Exasol with `exakit connect` / `exakit source` — the rules every connector shares (credentials never as arguments, the `localhost` trap, TLS and a private CA, failure classes, reauth, disconnect vs remove) and the index of the connector skills below. |

**External sources (virtual schemas)** — one skill per connector in `setup/virtual-schemas/catalog.json`; installed with the kit

Each takes an agent from the user's request to a working `VS_<NAME>`: the
connector's inputs, finding them with the source's own CLI, a least-privilege
reader, the network allowlist, the unattended `exakit connect` line, verifying
it, and that connector's failures. The shared rules stay in
`exasol-virtual-schemas`; `tests/skills.sh` fails when a catalog connector has
no skill here, or a skill misses one of its connector's inputs.

| Skill | Use it when… |
|---|---|
| [`exasol-vs-postgresql`](exasol-vs-postgresql/SKILL.md) | Connecting PostgreSQL (self-hosted, RDS/Aurora, Azure) — psql discovery, a reader role, the RDS CA. |
| [`exasol-vs-mysql`](exasol-vs-mysql/SKILL.md) | Connecting MySQL or MariaDB — quoting lower-case names, `DESC NULLS LAST` for top-N. |
| [`exasol-vs-sqlserver`](exasol-vs-sqlserver/SKILL.md) | Connecting SQL Server, Azure SQL or RDS — a schema-scoped login, named instances, verified TLS. |
| [`exasol-vs-oracle`](exasol-vs-oracle/SKILL.md) | Connecting Oracle — service names (not SIDs), TCPS on 2484, the ORA- errors. |
| [`exasol-vs-snowflake`](exasol-vs-snowflake/SKILL.md) | Connecting a Snowflake schema — a service user, a programmatic access token, the network policy. |
| [`exasol-vs-bigquery`](exasol-vs-bigquery/SKILL.md) | Connecting a BigQuery dataset — a service account key, and who can read it in BucketFS. |
| [`exasol-vs-s3`](exasol-vs-s3/SKILL.md) | Querying JSON, CSV or Parquet files in S3 — an EDML mapping and a prefix-scoped IAM key. |
| [`exasol-vs-azure-blob`](exasol-vs-azure-blob/SKILL.md) | Querying the same in an Azure Blob Storage container — a read-and-list container SAS. |
| [`exasol-vs-databricks`](exasol-vs-databricks/SKILL.md) | Connecting a Unity Catalog schema through a SQL warehouse — a PAT, CAN USE, IP access lists. |
| [`exasol-vs-lakehouse`](exasol-vs-lakehouse/SKILL.md) | Reading Iceberg tables of an AWS Glue database from S3 — the Glue and S3 IAM policy. |
| [`exasol-vs-iceberg-rest`](exasol-vs-iceberg-rest/SKILL.md) | Reading Iceberg tables behind an Iceberg REST catalog (Beta) — a catalog token or storage keys. |
| [`exasol-vs-unity`](exasol-vs-unity/SKILL.md) | Reading a Unity Catalog schema from storage without a warehouse (Beta) — External Data Access. |
| [`exasol-vs-mongodb`](exasol-vs-mongodb/SKILL.md) | Connecting one MongoDB collection (Atlas or self-hosted) — the access list, child tables. |

**The wider Exasol ecosystem** — installed with the kit; it catalogs tools that are *not* part of it

| Skill | Use it when… |
|---|---|
| [`exasol-ecosystem`](exasol-ecosystem/SKILL.md) | Answering "is there an Exasol connector/driver/adapter for X" — which repo, which org, what support level, and which well-known projects are archived. |

**The marketplace** — opt-in add-ons

`exasol-marketplace` itself installs with the kit; the other seven skills below
are **installed with their add-on**, not with the kit: each declares
`addon: <id>` in its frontmatter, and the marketplace places it as part of
installing that add-on and removes it again when the add-on goes.
A skill is a set of triggers for an agent to match on, and matching them for a
tool that is not on the machine is worse than not shipping the skill at all.

| Skill | Use it when… |
|---|---|
| [`exasol-marketplace`](exasol-marketplace/SKILL.md) | Choosing, installing, updating or removing add-ons; explaining why one is not offered at all. |
| [`dbt-exasol`](dbt-exasol/SKILL.md) | Building SQL models with dbt against the local database; the generated profile, why `~/.dbt` is never touched, and why the command is `dbt-exasol` and not `dbt`. |
| [`notebook`](notebook/SKILL.md) | Notebooks connected to the local database: `exakit notebook`, the Exasol (Starter Kit) kernel, JupyterLab or Marimo, the `exakit.nb` helpers, the descriptor-driven persona notebooks (quickstarts, explore, train inside the database and log to MLflow, score a model trained anywhere), opt-in Langfuse tracing. |
| [`udf-devkit`](udf-devkit/SKILL.md) | Python and Rust UDFs on the local database: `exakit udf-setup` (the official container), `udf-use` (a tarball, or the kit's prebuilt one), `rust-udf` (a Rust scoring UDF), `model` (model files in the bucket), `mlflow` (the local MLflow server), `udf-build` from a pinned requirements file, `udf-file` into BucketFS; the restart every container install brings, and the smoke UDF that proves each. |
| [`dash-server`](dash-server/SKILL.md) | Building live dashboards the agent drives over an MCP control plane while the user opens a browser URL. |
| [`json-tables`](json-tables/SKILL.md) | Loading JSON into the database (exapump takes CSV and Parquet only); the prebuilt engine that means no Rust toolchain. |
| [`exasol-scheduler`](exasol-scheduler/SKILL.md) | Scheduling SQL jobs in SCHED.SCHED_TASKS; the scheduler_svc trust boundary, task chains, and why missed runs are never replayed. |
| [`exasol-vscode`](exasol-vscode/SKILL.md) | SQL editing and schema browsing inside VS Code; why the kit refuses to manage a copy the user installed themselves. |

**From the components' own repositories** — Exasol's skills, used as they are

Where a component ships skills of its own, the kit places those instead of
writing its own: copied unchanged at the version the kit installs, with one
line on top saying where they came from and that the `exakit` skill comes first
on this machine. [`upstream.json`](upstream.json) names each source, its pin,
and why the other skills in those repositories were not taken;
`python3 tools/sync_upstream_skills.py` copies them and writes
[`upstream.lock.json`](upstream.lock.json). Never edit a copy by hand —
`tests/skills.sh` compares every file with the lock and fails on a pin behind
the version the kit installs.

| Skill | From | Use it when… |
|---|---|---|
| [`exasol-mcp-server`](exasol-mcp-server/SKILL.md) | `exasol/mcp-server` | Using the MCP server's tools: exploring the database, debugging a query, BucketFS. |
| [`exasol-sql-dialect`](exasol-sql-dialect/SKILL.md) | `exasol/mcp-server` | Writing Exasol SQL that is correct the first time: syntax, types, functions, pitfalls. |
| [`exasol-system-tables`](exasol-system-tables/SKILL.md) | `exasol/mcp-server` | Reading system and statistics tables (`EXA_ALL_*`, `EXA_DBA_*`, …). |
| [`exasol-table-design`](exasol-table-design/SKILL.md) | `exasol/mcp-server` | `DISTRIBUTE BY`, `PARTITION BY`, data types, replication — designing tables for speed. |
| [`exasol-import-export`](exasol-import-export/SKILL.md) | `exasol/mcp-server` | SQL `IMPORT` / `EXPORT` — for data the database reaches itself; local files go through `exakit data-load` first. |
| [`exasol-udfs`](exasol-udfs/SKILL.md) | `exasol/mcp-server` | Writing `CREATE SCRIPT` UDFs; the containers come from `udf-devkit`. |
| [`exasol-database`](exasol-database/SKILL.md) | `exasol-labs/exasol-agent-skills` | exapump and Exasol SQL in depth: the statement grammar, reserved words, profiling, analytics. |
| [`exasol-pyexasol`](exasol-pyexasol/SKILL.md) | `exasol-labs/exasol-agent-skills` | The pyexasol API; this machine's interpreter, TLS setting and credentials are in the `exakit` skill. |
| [`exasol-bucketfs`](exasol-bucketfs/SKILL.md) | `exasol-labs/exasol-agent-skills` | Files in BucketFS with exapump. |
| [`exasol-dash`](exasol-dash/SKILL.md) | `exasol-labs/dash-server` | Writing the Dash app for a dashboard on dash-server. Placed with the dash-server add-on. |

The set is versioned as one component (`components.skills` in `versions.json`),
and it updates like one: when the maintainers change a skill and bump that
version, `exakit version` shows a `skills` row with the newer number and
`exakit update` fetches the new set from the kit repository and installs it —
no kit release involved. `exakit skills` reports when the copies in your
agent's folders are behind the advertised set.

Each skill is a directory containing a `SKILL.md`: `name` + `description`
frontmatter, then the instructions. A skill that belongs to a marketplace add-on
adds one more key, `addon: <add-on id>` — that is the whole wiring, and it is
what makes the skill travel with its add-on instead of with the kit. The agent always sees the name and
description, and loads the full body only when it decides the skill is relevant
(progressive disclosure). The `description`'s **"Triggers —"** list is how the
agent decides when to fire it — keep it accurate. A skill copied from a
component's repository keeps that repository's description as it is.

## Seeing what you have

```bash
exakit skills          # every skill, with a summary and whether it is installed
exakit skills --json   # the same, machine-readable
```

States are `installed` (in every discovery folder), `partial` (in some — a
half-finished install or a hand deletion), `needs-addon` (it belongs to a
marketplace add-on you have not installed; it arrives with the add-on, and
`skills-install` will not place it) and `available` (in none, and it should be).
The panel spells the third one `with <add-on id>` so you can see whose it is;
`--json` reports it as `"state":"needs-addon"` with an `addon` and a runnable
`remedy`. Only `partial` and `available` count as pending, so a healthy machine
with add-ons it never installed does not read as half-installed.

## How a skill reaches your agent

Skills auto-load only from an agent's discovery folders, **not** from this repo
path. The installer copies each skill into the standard per-user locations, and
`exakit skills` shows the result:

```bash
exakit skills
```

The per-user locations:

- **Claude Code** → `~/.claude/skills/<name>/` — **verified**: Claude Code reads
  this and picks the skills up on its next start.
- **Open-standard agents** → `~/.agents/skills/<name>/` — the shared
  **convention**. The kit writes it; whether a given tool reads it is that
  tool's business, and the kit has not verified each one. `exakit skills`
  reports that the file is in place, not that your agent read it. If your client
  shows no Exasol skills, check its own docs for where it looks — nothing in the
  kit depends on this path (see [AGENTS.md](../AGENTS.md)).

`exakit skills` only reports; it changes nothing, so it is safe to run any time.
The installer places the set, and `exakit skills` names the next command when one
is needed — `exakit update` to move to a **newer** set the maintainers have
published (it fetches the set first, then places it), or `exakit skills-install`
to put back a skill folder that has gone missing.

> **Chat-only clients (Claude, Cursor GUI over MCP):** these do not read
> filesystem skills the same way. There, the skill still works as guidance you
> paste in, and the query loop (Step 5) runs against the connected `exasol` MCP
> server. Filesystem auto-discovery is for terminal/CLI agents.

## Too many approval prompts?

An agent driving the kit runs many commands; by default each one asks for
approval. See [reducing-agent-prompts.md](reducing-agent-prompts.md) to
pre-approve the kit's **read-only** commands per agent (Claude Code, Codex,
Cursor) while keeping SQL execution and mutations gated — the split that keeps
the inspect-before-run trust model intact.

## Why this layout (and not a plugin marketplace)

The kit is a **first-touch, low-friction** experience — the goal is time-to-first
value, not a tooling catalog. A plugin-marketplace install would assume the user
already runs Claude Code / Codex with plugin habits and would add steps before
value. Instead the existing installer — the thing the user already runs — places
the skill where agents look. If versioned team distribution is ever needed, a
marketplace wrapper is additive and can be layered on later.

## Adding or editing a skill

Verify with:

```bash
bash tests/skills.sh    # frontmatter, registry, install/state, uninstall scope
```

1. Add or edit a folder under `skills/<skill-name>/SKILL.md`.
2. Keep the `name` / `description` (with `Triggers —`) accurate — that's how the
   agent decides when to fire it.
3. Reference only real kit commands and paths (`exakit …`, `exapump …`,
   `~/.exasol-starter-kit/kit/…`) — never invent commands, flags, or SQL.
4. If you add shared material for multiple skills, keep it once at this folder's
   level and reference it by relative path from each skill.
