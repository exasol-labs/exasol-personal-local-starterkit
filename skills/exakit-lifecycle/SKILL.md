---
name: exakit-lifecycle
description: Operate the starter kit itself with exakit — checking which versions are installed and what changed, updating the kit and its components, reading the logs, discovering the command surface, finding the credential files the kit wrote, and uninstalling safely by previewing with --dry-run before anything is removed. Triggers — "update my starter kit", "is there a newer version of the kit", "what changed in this version", "what can exakit do", "list the exakit commands", "where are the logs", "exakit logs", "what is my Exasol password", "where is my connection string", "uninstall the starter kit", "remove Exasol from my machine", "what did the kit install", "where did the kit put things".
---

# The kit itself — versions, updates, logs, credentials, removal

This skill is about **exakit as a product you maintain**, not about the
database it deploys. For starting, stopping or diagnosing the database use
`exasol-runtime`; for SQL use `exasol-exapump`; for AI clients use `exasol-mcp`;
for add-ons use `exasol-marketplace`.

Every command below is read-only unless this page says otherwise. On Windows the
binary is `exakit.cmd`; everywhere else it is `exakit`. A non-interactive shell
usually has no `~/.local/bin` on `PATH`, so call it by absolute path
(`~/.local/bin/exakit …`) if the bare name is not found.

## Where everything lives

| What | Path |
|---|---|
| Kit state (the install record, logs, cache) | `~/.exasol-starter-kit/` |
| The install record | `~/.exasol-starter-kit/manifest.json` |
| Passwords, one file per credential | `~/.exasol-starter-kit/credentials/` |
| Logs | `~/.exasol-starter-kit/logs/` |
| The kit copy the CLI runs from | `~/.exasol-starter-kit/kit/` |
| Saved, rerunnable SQL | `~/.exasol-starter-kit/workflows/` |
| The CLIs (`exakit`, `exapump`) | `~/.local/bin/` |

## What is installed, and what is newer

```bash
exakit version          # one row per component: installed, and what is advertised
exakit version --json   # the same rows as one object
exakit whats-new        # the card for the version you have
exakit whats-new 0.2.0  # or for a named one
```

`exakit version` is the answer to "what did the kit install" and to "is there a
newer version". It reads a cached versions document — it does not decide to
upgrade anything.

## Applying updates

```bash
exakit update           # everything that is waiting
exakit update skills    # or one target
exakit update --yes     # pre-answer the one question it can ask
```

Targets are `all`, `runtime`, `exakit`, `exapump`, `mcp`, `pyexasol`, `skills`,
any installed add-on id, and the runtime name `personal`. An unknown
target is refused with exit 2 and changes nothing.

The quick components apply in seconds. A **database** change is different: it
stops the database, so it is applied only for an answer the run was actually
given — on a terminal you are asked, and an unattended run defers it and prints
the exact command to apply it later. Data is kept either way.

A newer **skill set** published by the maintainers arrives through
`exakit update` as well; no kit release is involved. `exakit skills` reports
when the copies in your agent's folders are behind the advertised set.

## An installation from an older kit

Older kits could put the database in a **container**. This kit deploys Exasol
Personal and nothing else, so such an installation has a database nothing here
can drive. `exakit status` names it plainly — `Runtime  nano · from an older
kit, not managed here` — and `exakit update` on it cannot help: the crossing is
a **re-run of the installer**.

The installer recognises it before touching anything and asks **once** — and
only when there is really something to move: a container that is gone, a
machine that has already crossed, and a resumed attempt at the same install all
pass through in silence. When it does ask, there are two exclusive answers:

- **Migrate my data** — every non-system table is copied out while the old
  database is still running, then restored into the new deployment at the end
  of the run. Each table is recreated from the source's own column types first,
  so nothing is type-inferred. A text column that held an empty string arrives
  as NULL; that is stated before the copy starts.
- **Skip and continue** — the new database is set up empty; the old one keeps
  its data.

`EXAKIT_LEGACY_DATA=migrate` or `=skip` pre-answers it. **Unset in an
unattended run means skip** — so an agent that wants the copy has to ask for
it, which is the point.

Two things hold on both answers: the old container is **stopped** (it holds the
port the new deployment needs), and it is **never removed**. Its data volume
stays, and the command that deletes it is printed rather than run. A table the
fresh install already created is left alone rather than appended to, and named
in the summary.

**The kit's own sample data is not "my data".** A bundled dataset (TPC-H,
energy, weather) found in the old database with the same tables and row counts
as the kit ships is left out of the copy and named as such — the install loads
it itself, and `exakit data-load` puts it back any time. A sample table the
user has changed travels with the rest. `status --json` records what was left
out under `legacy_database.sample_left_out`.

### After the install: `exakit migrate docker-nano`

The same copy, later, for a machine that answered **skip** (or was never
asked, in an unattended run) and for a container the installer never saw —
made by hand with `docker run exasol/nano`, or by the upstream kit. `exakit
status` names such a container as `Old database … not copied`, and
`status --json` carries it as `legacy_database` with `copied: false` and
`command: "exakit migrate docker-nano"`.

```bash
exakit migrate docker-nano                                    # the container the installer remembered
exakit migrate docker-nano --container exasol-nano --engine docker
exakit migrate docker-nano --password-file ~/nano_sys_password --yes
exakit migrate docker-nano --json --yes                       # one object: ok, status, copied_out, restored, left_alone, failed, sample_left_out, reason, remedy
```

What is not named comes from the record the installer kept, then the old
install's own record, then the machine (which engine knows the container, which
port it publishes), then an older kit's defaults (`exasol-nano`, user `sys`).
**The password never goes on the command line**: `--password-file`, or
`EXAKIT_LEGACY_PASSWORD` for a scripted run, or the prompt on a terminal.

Both databases want port 8563. When the container publishes the deployment's
port, the deployment is **stopped for the copy out and started again before the
copy in**; a container on another port costs no downtime. The container ends as
it began, except that one holding the deployment's port stays stopped. Nothing
in it is changed or removed.

Exit codes: `0` done, or nothing of the user's to copy · `1` the copy did not
finish (the reason and where the copies are kept are printed; the next run
restores a waiting copy first) · `2` bad input · `3` no deployment to copy into
· `4` not installed · `5` not confirmed (`--yes` pre-answers it).

## Reading the logs

```bash
exakit logs                     # every log target, with size and last-updated
exakit logs --json              # the same list, machine-readable
exakit logs setup               # one target (setup = the installer run)
exakit logs setup -f            # follow it live
exakit logs setup --lines 200   # the last N lines
exakit logs dash-server --path  # just the path, for piping
```

`--json` lists the targets; it does not apply to one target's contents. One
target at a time. Targets cover the installer run, the database container, each
add-on service, and what the boot entries wrote at login.

## Discovering the command surface

```bash
exakit help              # the grouped overview
exakit help <command>    # one command's page
exakit catalog           # every exakit, exapump and exasol command
exakit catalog mcp       # searchable
exakit catalog --json    # the whole surface as one object
exakit guide             # how to connect: AI clients, SQL clients, Python
```

Prefer `exakit catalog --json` over guessing a flag. If a command or flag is not
in that output, it does not exist — do not invent one.

## Credentials and connection details

```bash
exakit info          # DSN, admin and MCP users, which file holds each password
exakit info --json   # the install record verbatim on stdout, nothing else
```

`exakit info` prints the **paths** of the password files, not the passwords.
The files live in `~/.exasol-starter-kit/credentials/`.

- **Never print, echo or log a credential file.** Read it into a command when a
  command needs it; do not put it in a transcript, a commit or a chat message.
- The admin password and the read-only MCP password are different files. The
  MCP user is the one AI clients use, and the database enforces its read-only
  scope; the admin one is not sandboxed.
- If a password file is missing, do not mint one by hand — `exakit mcp-doctor`
  repairs the MCP login, and re-running the installer rebuilds what it can.

## Uninstalling — preview first, always

`exakit uninstall` is the one destructive command here. A full uninstall removes
the database **and its data**, the managed AI-client configs, the skills the kit
placed and the binaries.

```bash
exakit uninstall --dry-run        # the full plan; changes nothing
exakit uninstall                  # interactive: Skip, one add-on, or EVERYTHING
exakit uninstall json-tables --yes  # one add-on only; the rest is untouched
exakit uninstall --yes            # no prompts — only with explicit consent
```

- **Run `--dry-run` first and show the user the plan.** It is free and it is the
  only way to see what would go.
- **Never pass `--yes` on your own initiative.** The interactive flow has a
  confirmation summary and a typed gate for a reason; `--yes` removes both.
- Removing one add-on is `exakit uninstall <addon-id>` — reach for that before
  anything wider when the user only wants one tool gone.
- Uninstall does not remove `uv`/`uvx` (shared tools) and it does not edit the
  `PATH` line in the shell profile. That line is tagged with the kit's name, so
  the user can delete it themselves.

## Guardrails

- **Read before you write.** `version`, `whats-new`, `logs`, `catalog`, `help`,
  `guide`, `info` and `status` change nothing — use them to establish the facts
  before proposing `update` or `uninstall`.
- **Never remove anything the user did not ask to remove**, and never widen the
  scope of a removal the user narrowed.
- **Do not invent commands, flags or paths.** Everything on this page is in
  `exakit catalog --json`; check there rather than guessing.
- **Do not drive the kit's parts underneath it** (editing `manifest.json` by
  hand, deleting containers, moving `~/.exasol-starter-kit/`). The manifest is
  how `status`, `version` and a re-run of the installer know the truth.
