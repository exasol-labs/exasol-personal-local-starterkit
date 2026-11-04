---
name: exasol-marketplace
description: Browse, install and remove the starter kit's optional add-ons through exakit marketplace — dash-server (agent-built dashboards), notebook (JupyterLab, Marimo), udf-devkit (Python and Rust UDFs, MLflow), Exasol for VS Code (editor extension), JSON Tables (JSON ingestion), Exasol Scheduler (SQL jobs on a schedule) and dbt-exasol (dbt models) — including the read-only listing, installing by id without a terminal, why an add-on may not be offered at all, and how installed add-ons join the normal update and uninstall flows. Triggers — "what optional tools can I add", "exakit marketplace", "install an add-on", "add dashboards to my kit", "add dbt to my kit", "schedule a query", "run this nightly", "install the scheduler", "why is an add-on not listed", "remove an add-on", "update my add-ons", "add a persona to my kit".
---

# The marketplace — optional add-ons

The marketplace is where the kit keeps **optional tools**: worth having next to
the database, not worth lengthening the install for. The install adds them only
when a persona (`EXAKIT_PERSONA`) or `EXAKIT_MARKETPLACE_ADDONS` asks for them;
afterwards use `exakit marketplace` or `exakit persona add <id>`. On a terminal,
`exakit persona add` with no id asks the install's persona question with this
kit's personas ticked and adds the ones newly ticked; without a terminal it
names the command to run and exits 2.

```bash
exakit marketplace       # browse: Space selects, Enter installs
```

Without a terminal, a bare `exakit marketplace` installs **nothing**. Drive it
like this instead:

```bash
exakit marketplace --list          # read-only: every add-on and its state
exakit marketplace --list --json   # the same, for scripts: id, status, installed, version, repo, docs, name, url, about
exakit marketplace dbt-exasol      # install exactly this one (ids, space-separated)
EXAKIT_MARKETPLACE_ADDONS=dash-server exakit marketplace   # ids csv, or all / none
```

Look with `--list` first: it never installs anything, downloads nothing and
writes nothing.

The same variable pre-answers the one-question offer that follows a successful
interactive install ("Do you want to add optional tools?").

## What is on offer

| Id | What it gives the user | Skill with the detail |
|---|---|---|
| `dash-server` | Agent-built live dashboards on the local database, driven through its own MCP control plane | `dash-server` |
| `notebook` | JupyterLab or Marimo connected to the local database, with the kit's persona notebooks | `notebook` |
| `udf-devkit` | Python and Rust UDF containers, training inside the database, a local MLflow server | `udf-devkit` |
| `exasol-vscode` | Exasol SQL editing and schema browsing inside VS Code | `exasol-vscode` |
| `json-tables` | Ingest, query and reshape JSON-shaped data; the engine ships prebuilt, no Rust toolchain | `json-tables` |
| `exasol-scheduler` | SQL jobs on a cron schedule, defined and audited as rows in a table | `exasol-scheduler` |
| `dbt-exasol` | Build, test and document SQL models on the local database with dbt | `dbt-exasol` |

On screen each row shows the add-on repository's name on GitHub, with the id
beside it when the two differ: `exasol-json-tables (json-tables)`,
`notebook-connector (notebook)`. The id is what you type. The name, link and
About come from GitHub only while installing and while `exakit update` shows
updates; every other screen uses the cached copy, and a failed lookup falls back
to the kit's own copy.

Each has its own skill, placed when the add-on is installed. Load that one
when the user wants to *use* the tool; this skill is about choosing and
managing them.

## Why an add-on might not appear

Two independent filters run before anything is listed, and both are deliberate:

**Applicability.** An add-on that extends software the user does not have, or
that has no build for this machine, is not offered for install: the menu has no
row for it, while `exakit marketplace --list` still shows it as not applicable
with the reason. `exasol-vscode` is only offered on a machine that has VS Code,
notebook not on Linux Arm. Naming it anyway explains why, instead of failing
deep in an installer:

```bash
EXAKIT_MARKETPLACE_ADDONS=exasol-vscode exakit marketplace
# -> explains VS Code was not found, rather than half-installing
```

**Presence.** An add-on already on the machine is never advertised again:

- installed *by the kit* → shown as `installed (vX)`
- already on the system *outside* the kit → shown as `already on this system —
  the kit leaves it alone`

That second case is a promise: **the kit never updates or uninstalls what it
did not install.** When everything is present, the offer disappears entirely.

So "it is not in the list" almost always means *already there* or *not
applicable* — check before concluding something is broken.

## After installing

An installed add-on becomes a **full component** of the kit:

```bash
exakit version                     # its version, and whether a newer one is advertised
exakit update dash-server          # update one add-on
exakit update dash-server dbt-exasol   # or several, each once
exakit update                      # covers every INSTALLED add-on
```

Add-ons you never picked are never touched by `exakit update`.

Add-ons that **run as a service** (`dash-server`, `exasol-scheduler`, and udf-devkit's MLflow server) are managed like the
database itself:

```bash
exakit status        # shows running / stopped per service
exakit start         # database AND every installed service
exakit stop
exakit stop <id>     # one add-on service only; exakit start <id> needs the database up
exakit autostart     # asks, then flips it; EXAKIT_AUTOSTART_CHANGE=1 pre-answers
exakit logs          # each service's log is listed
```

## Removing one

```bash
exakit uninstall dash-server --dry-run   # what removing just this one would do
exakit uninstall dash-server --yes       # remove just this add-on; the rest of the kit stays
exakit uninstall                         # interactive: Skip (safe default), the add-ons as a
                                         # group, each add-on on its own, or EVERYTHING
```

Each add-on is individually selectable, the plan is shown back as a summary,
and a typed gate confirms. `exakit uninstall --dry-run` previews the full plan
without touching anything — prefer it when you are unsure. A full uninstall
keeps the user's work: notebooks, the kit MLflow server's runs and models, and
Dash dashboards stay in the kit home unless `EXAKIT_UNINSTALL_NOTEBOOKS=remove`.

Pin a specific version at install or update time with the per-add-on variable,
e.g. `EXAKIT_DASH_SERVER_VERSION=<version>`.

## Guardrails

- **Install add-ons through the marketplace or a persona, nothing else.** During
  a kit install that means `EXAKIT_PERSONA` or `EXAKIT_MARKETPLACE_ADDONS`;
  afterwards `exakit marketplace <id>` or `exakit persona add <id>`. Do not
  shortcut it by calling module functions directly.
- **Never manage a copy the kit did not install.** If an add-on shows as
  "already on this system", leave it alone; do not update or remove it.
- **Prefer `--dry-run` before any uninstall**, and never run
  `exakit uninstall --yes` (the scripted *full* teardown) unless the user asked
  for exactly that.
- **Adding a NEW add-on to the marketplace is development work, not an install
  step.** The walkthrough with skeleton code lives in the kit's
  `MARKETPLACE.md`; do not improvise a module.
