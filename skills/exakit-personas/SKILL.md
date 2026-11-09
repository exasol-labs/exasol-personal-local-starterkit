---
name: exakit-personas
description: Work with the starter kit's personas — named bundles of datasets, AI clients, add-ons and services such as Data Scientist, ML Engineer and General — listing them, showing what one brings, seeing what is still pending, adding one to an installed kit, removing one, choosing one at install time, and defining a new one as a file. Use it whenever the user talks about what the machine is for, a role, or a persona. Triggers — "what personas are there", "set the kit up for data science", "add the ML engineer persona", "I am a data scientist", "what does a persona install", "what is still missing for my persona", "remove a persona", "switch persona", "make my own persona", "EXAKIT_PERSONA".
---

# Personas

A persona is a named set of the answers the installer already takes: which
datasets to load, which AI clients to connect, which marketplace add-ons to
install, which services to start. It installs nothing on its own — adding one
runs the same data load, MCP setup and marketplace steps the install runs.

**Never describe a persona from memory.** Its contents are files in the kit and
change between versions; read them:

```bash
exakit persona list --json           # every persona, what each brings, which this kit was set up as
exakit persona show <id> --json      # one persona: datasets, addons, mcp_clients, services, notebooks, start_here
exakit persona plan --json           # the recorded personas: what is loaded/installed, what is still pending
exakit persona plan <id> --json      # the same for a persona not added yet
```

`persona list --json` returns `personas[]` (`id`, `title`, `summary`,
`datasets`, `addons`, `mcp_clients`, `notebooks[]`, `start_here`, `recorded`,
plus `services`, `notebook_tools` and `udf_language` on the personas that set
them) and `recorded` (the ids this kit was set up as).
`persona plan --json` returns `datasets.loaded`, `datasets.pending`,
`addons.installed`, `addons.pending` and `nothing_pending`. The text forms
(`exakit persona list`, `show <id>`, `plan`) print the same for a person.

The kit currently ships `data-scientist`, `ml-engineer` and `general`; check
`persona list --json` before relying on that.

## Adding a persona to an installed kit

```bash
exakit persona add ml-engineer                 # one
exakit persona add data-scientist,ml-engineer  # several, joined by a comma
exakit persona add                             # on a terminal only: the install's persona question
```

It joins the personas named to the recorded ones and brings in what is not here
yet — the sample data, the AI clients, the add-ons — with no question, in three
steps (sample data, AI clients, add-ons). What is already here is named and not
redone. A part that fails does not stop the others; the closing line names the
command that retries it. `apply` is the old name; `--yes` is accepted and
changes nothing.

Exit codes: `0` done or nothing to do · `1` a part did not finish (its retry is
printed) · `2` an unknown persona or option, or `persona add` with no id and no
terminal (name the persona) · `4` no kit installed.

Without a terminal (an agent's shell) always name the persona: the bare
`exakit persona add` only asks on a terminal.

## Removing a persona

```bash
exakit persona remove ml-engineer
```

It takes the persona off the kit's record and **keeps everything it brought** —
datasets, add-ons, notebooks. Removing those is a separate, explicit step:
`exakit uninstall <add-on id> --dry-run`, then without `--dry-run`. Services
the persona started at login keep starting until their add-on is removed; the
removal says so.

## Choosing at install time

```bash
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_PERSONA=data-scientist sh
```

`EXAKIT_PERSONA` takes one id or several joined by a comma. On a terminal
without it, the installer asks; without a terminal and without it, the kit
installs with the General samples. An unknown persona is refused before
anything is installed.

**Your own answer replaces the persona's for that one variable** — it does not
add to it. `EXAKIT_PERSONA=data-scientist EXAKIT_MARKETPLACE_ADDONS=dbt-exasol`
installs dbt-exasol and *not* the persona's add-ons; to keep them and add one,
name them all, or add the extra one afterwards with `exakit marketplace
dbt-exasol`. `persona plan` then shows what of the persona is still pending.

## Where to start after adding one

`start_here` in `persona show <id> --json` is the persona's first step (the
The ML Engineer is disabled for now (`"visible": false` in its file: kept, not offered, refused by
name); never offer or add it, and say so if the user asks for it. Data Scientist and ML Engineer open their quickstart notebook with `exakit
notebook`); the install's closing line prints it too. The persona's notebooks
are `notebooks[]` in the same answer.

## Defining a new persona

A persona is one file, `personas/<id>.json`, in the kit copy
(`~/.exasol-starter-kit/kit/personas/`), and no code. Its keys — `id`, `title`,
`summary`, `picker`, `visible`, `default`, `order`, `datasets`,
`mcp_clients`, `addons`, `notebook_tools`, `services`, `udf_language`,
`first_prompt` — are documented in `personas/README.md` beside it; read that
file for the allowed values instead of guessing them. A file the kit cannot
read is left out of `exakit persona list` (the others still work), and naming
it — `exakit persona show <id>` or `add <id>` — is refused with exit `2` and
says what is wrong with it. A kit update
replaces the kit copy, so keep your own persona file elsewhere as well.
