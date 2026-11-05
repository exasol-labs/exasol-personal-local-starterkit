---
name: exakit-discovery
description: Find out what THIS starter kit has and can do — its commands and their exact options, the personas, the add-ons and how to install, update or remove each, the datasets, the skills, the services and the current state — by asking the kit itself in JSON instead of guessing. Use it before answering any question about the kit's commands, parameters, personas or add-ons, and whenever unsure whether something exists. Triggers — "what can this kit do", "which personas does this kit have", "what add-ons are available", "which datasets does the kit have", "what options does exakit X take", "how do I install/remove/update an add-on", "is there a command for", "what is installed on this machine", "what parameters does", "list everything the starter kit offers".
---

# Discovery — ask the kit, never guess

Every fact an agent needs about this kit is answered by the kit itself, in JSON,
read-only. **Answer from those answers.** A command, option, persona, add-on or
dataset that the kit does not report does not exist here — say so instead of
inventing one. These commands never install anything and never change the
machine; run as many as the question needs.

The command is `exakit` (on Windows `exakit.cmd`). A non-interactive shell often
has no `~/.local/bin` on `PATH`: call `~/.local/bin/exakit` if the bare name is
not found.

## Where each answer lives

| Question | Ask | What to read |
|---|---|---|
| Which commands exist, with which options? | `exakit catalog --json` | `commands[]`: `invocation`, `usage`, `options`, `parameters`, `examples`, `help_command`. Search with `exakit catalog <word> --json`. Entries with `hidden: true` are not for normal use. |
| Exactly how does one command or add-on work? | `exakit help <command> --json`, `exakit help <add-on id> --json` | A command: its `commands` entry, with `environment` (the variables it reads) and `exit_codes`. An add-on: `role`, `platforms`, `environment`, and `management` — the exact `install`, `update`, `uninstall`, `uninstall_preview`, `help` commands for it. |
| Which personas are there, and what does each bring? | `exakit persona list --json` | `personas[]`: `id`, `title`, `summary`, `datasets`, `addons`, `mcp_clients`, `notebooks[]` (`jupyter`, `marimo` paths), `start_here`, `recorded`, and `services` / `udf_language` where the persona sets them; and `recorded` — the personas this kit was set up as. One: `exakit persona show <id> --json`. |
| What of a persona is still missing here? | `exakit persona plan [<id>] --json` | `datasets.loaded/pending`, `addons.installed/pending`, `nothing_pending`. |
| Which add-ons exist, and which are installed? | `exakit marketplace --list --json` | `addons[]`: `id`, `status`, `installed`, `ownership`, `version`, `reason` (why one is not offered here), `repo`, `docs`, `name`, `url`, `about`. |
| What is running, what data is loaded? | `exakit status --json` | `status` (`running`, `stopped`, `installing`, `not installed`, …), `datasets_loaded`, `services`, `remedy`. Exit code: 0 running, 3 database stopped, 4 not installed. |
| Which versions are installed and advertised? | `exakit version --json` | one row per component and add-on. |
| Which AI skills are placed, which wait for an add-on? | `exakit skills --json` | `skills[]`: `name`, `state` (`installed`, `needs-addon`, `missing`, …), `addon`, `remedy`. |
| Which AI clients are connected over MCP? | `exakit mcp-status --json` | per-client state; `remedy` names the next command. |
| Where are the logs? | `exakit logs --json` | every log target and its path. |
| What does a bundled dataset contain? | `exakit help data-load --json`, then the data dictionary | The dictionary is `~/.exasol-starter-kit/kit/data/data-dictionary.md`: every bundled dataset's schema, tables, columns and meaning. What is in the database right now: `exakit sql "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROW_COUNT FROM SYS.EXA_ALL_TABLES WHERE TABLE_SCHEMA NOT LIKE 'SYS%'" --json`. |
| What changed in this version? | `exakit whats-new` | release notes for the kit version on disk. |

Every answer above carries `remedy` (or a `management` command) where there is a
next step — use that exact command rather than composing one.

## How to answer from it

1. **Run the query first, then answer.** "Which add-ons can I install?" is
   `exakit marketplace --list --json`; "how do I remove dbt?" is
   `exakit help dbt-exasol --json` → `management.uninstall_preview`, then
   `management.uninstall`.
2. **Quote names exactly as returned.** Ids (`data-scientist`, `dbt-exasol`,
   `esophageal_posts`) are what commands take; titles are what people read.
3. **Options come from `usage` / `options` only.** If a flag is not in
   `exakit catalog --json` for that command, it does not exist; `exakit
   <command> --help` prints the same page.
4. **Exit codes are per command — read them, do not assume them.** The
   commands that define their own list it under `exit_codes` in
   `exakit help <command> --json` (`status`, `persona`, `data-load`,
   `mcp-doctor`, `udf-setup`, `udf-use`, `repair-runtime`, `migrate`, …).
   The common pattern is `0` done, `2` bad input (nothing changed), `3` the
   database is not running, `4` no kit installed, `5` not confirmed or
   declined — but a code's meaning is what that command's `exit_codes` says.
   A non-zero exit prints the command that fixes it; relay that line.
5. **Changing things is the user's call.** The read-only queries above are
   always safe. Before an install, update or removal, say what will happen;
   for removal run the preview (`exakit uninstall <id> --dry-run`) first.

## The other skills

This skill finds things; the others operate them: `exakit-personas`
(personas), `exasol-marketplace` (add-ons), `exakit-lifecycle` (updates,
logs, uninstall), `exasol-runtime` (the database), `exasol-mcp` (AI clients),
`exasol-exapump` (SQL and loading files), and one skill per installed add-on.
