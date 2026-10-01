# Agent guide: Exasol Personal Local Starter Kit

This repo installs a complete local analytics stack with one command: an Exasol database on the user's machine, the `exapump` data/SQL CLI, an MCP server with a dedicated read-only database user, and the `pyexasol` Python driver. If a user asks you to "install this repo", this file is your runbook.

## The contract in 20 lines

Everything below expands on this. If you read nothing else, this is enough to install, verify and recover.

```bash
# 1. Install, unattended, in the background; answer choices with env vars (names, never menu numbers).
#    nohup, not a bare &: your shell tool's timeout would otherwise reap the installer mid-step.
EXAKIT_DATASETS=tpch,energy,weather EXAKIT_MCP_CLIENTS=all EXAKIT_MARKETPLACE_ADDONS=none \
  nohup sh -c 'curl -fsSL https://www.exasol.com/install/starter-kit.sh | sh' \
  </dev/null >~/exakit-install.log 2>&1 &
# 2. Put the CLI on PATH once — a bare non-interactive shell does not have ~/.local/bin.
export PATH="$HOME/.local/bin:$PATH"      # Windows/Git Bash: the command is exakit.cmd
# 3. Poll until it answers running (exit 0). While it installs: status "installing", install_step, exit 3.
exakit status --json
# 4. Prove it end to end, then discover the data from the system tables.
exakit sql --json 'SELECT CURRENT_TIMESTAMP'
exakit sql --json "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROW_COUNT FROM SYS.EXA_ALL_TABLES WHERE TABLE_SCHEMA NOT LIKE 'SYS%'"
```

- **Exit codes.** `0` running / healthy · `2` bad input (unknown command or option, a refused statement; nothing is recorded) · `3` database not running, or still installing · `4` not installed · `5` a command you did not confirm (`exakit repair-runtime`, which is destructive, and `exakit migrate docker-nano`, which stops the database for the copy).
- **Every state query** (`status`, `info`, `version`, `mcp-status`, `mcp-doctor`, all with `--json`) carries `installed`, `status` and `remedy`. **`remedy` is a command you can run verbatim, or `null`** — never a sentence. The explanation, when there is one, is in `remedy_hint` (and `remedy_hints`, keyed like `remedies`); read it, do not execute it.
- **`exakit sql` names its remedy first, on stdout**, as a line starting with `! `, ahead of the engine's text. Every other refusal — unknown command, unknown option, no install — goes to **stderr**, with the exit code carrying the meaning: capture both streams. If you are guessing, read `exakit status --json` again.
- **Two connections.** `exakit sql` and `exapump` are the **admin** user. The MCP server is the **read-only** user, enforced by the database. Never route a write around the MCP user.
- **Never print a password.** They live in `~/.exasol-starter-kit/credentials/` and inside each AI client's MCP config.
- **Your own MCP tools appear only after your client restarts.** Use `exakit sql` in the session that ran the install.
- Step 2's `export PATH` is the once-per-shell fix for a bare `PATH`; in a shell that has not had it, call the binary by absolute path (`~/.local/bin/exakit`) instead. Where a command takes `--json` (the state queries, `sql`, `skills`, `catalog`, `logs`, `help`), the answer is one object on stdout and nothing else there.
- **Only the five state queries report on this machine.** `catalog`, `help`, `logs`, `skills` and `sql` answer with their own shapes and are never a liveness probe — the first four exit `0` on a machine with nothing installed at all, because they report on the kit's own contents.

## Install (one command)

macOS / Linux / WSL:

```bash
curl https://www.exasol.com/install/starter-kit.sh | sh
```

Windows (PowerShell):

```powershell
irm https://www.exasol.com/install/starter-kit.ps1 | iex
```

The installer is **fully unattended-safe**. With no TTY attached (the normal case for an agent shell) every question takes a safe default: all bundled datasets are loaded, and every AI client that is installed on the machine but not yet connected gets an MCP config. Nothing ever hangs waiting for input.

Two things the unattended path does that are easy to miss. **A closed stdin is not enough to be headless:** when a controlling terminal exists (an agent launched from a user's shell), the installer reattaches its menus to `/dev/tty` so a human can still answer; pre-answer with the env vars below and it never waits. **`exakit marketplace` without a terminal installs nothing** — browsing is never an install. To look, run `exakit marketplace --list` (`--json` for a machine-readable answer); to install, name ids (`exakit marketplace dash-server`) or set `EXAKIT_MARKETPLACE_ADDONS` to an ids csv, `all`, or `none`.

One caveat when driving a **WSL** install from the Windows side (`wsl.exe -- bash -c "curl ... | sh"`): wsl.exe can attach a console that looks interactive but never delivers keypresses, so menus render and block. Either run the command detached (`setsid sh -c '...' < /dev/null` on Linux/WSL; `setsid` does **not** exist on macOS, where `nohup sh -c '...' </dev/null &` is the equivalent) or pre-answer everything with the env vars below.

## Answer the install's choices via environment variables

Flags do not travel through a pipe, so choices are env vars. They work on all platforms; on Windows set them with `$env:` before `irm ... | iex`. **Always use client and dataset names, never menu numbers.** Numbers are display order and change between releases.

| Variable | Effect |
|---|---|
| `EXAKIT_MCP_CLIENTS=claude,cursor` | Which MCP clients to configure, by name: `claude` (= desktop app **and** Claude Code CLI), `claude_desktop`, `claude_code`, `codex`, `cursor`, `vscode_copilot` (also `copilot`), `gemini_cli` (also `gemini`), `opencode`, `continue`, `all`, `skip`. **`all` means every client detected on this machine**, the same set the interactive menu offers — it never writes a config (and the password inside it) for a tool that is not installed. "Detected" means the client's own program or app is present, or a config file with the client's own settings; a config that holds only the kit's entries is the kit's own work and does not count. A client named explicitly is configured whether or not it is installed |
| `EXAKIT_SKIP_MCP=1` | Skip MCP client setup entirely (run `exakit mcp-setup` later) |
| `EXAKIT_DATASETS=tpch,weather` | Which bundled datasets to load, by id: `tpch`, `energy`, `weather`. Takes precedence over `EXAKIT_LOAD_SAMPLE` |
| `EXAKIT_LOAD_SAMPLE=0\|1` | `0` skip data loading, `1` load the bundled sample (tpch) |
| `EXAKIT_DATA_FILE=/abs/path/data.json` | Load this local CSV / Parquet / JSON file (skips the data menu; also works standalone: `EXAKIT_DATA_FILE=... exakit data-load`) |
| `EXAKIT_DATA_TABLE=SCHEMA.TABLE` | Target table for `EXAKIT_DATA_FILE` (default `STARTER_KIT.<FILENAME>`; a nested JSON file fans out to `<TABLE>_*` tables) |
| `EXAKIT_MARKETPLACE_ADDONS=dash-server` | Answer the closing marketplace offer: ids csv, `all`, or `none`. Unset, a non-interactive install skips the offer with a hint |
| `EXAKIT_LEGACY_DATA=migrate\|skip` | What to do with the database of an installation made by an OLDER kit (one that put it in a container). `migrate` copies every non-system table into the new deployment; `skip` sets the new one up empty and leaves the old one alone. **Neither deletes the old container or its data volume** — both stop it, because it holds the port the new deployment needs, and the removal command is printed. Unset in an unattended run means **skip**. Asked at most ONCE per machine: a fresh machine, one that has already crossed, and one whose container is gone all pass through silently. The kit's own bundled sample data, when unchanged in the old database, is left out of the copy (the install loads it itself). A skipped copy can be made later with `exakit migrate docker-nano`; `status --json` names that container under `legacy_database` with `copied: false` until it is |
| `EXAKIT_LEGACY_PASSWORD=...` | The old container database's password for a scripted `exakit migrate docker-nano`, when it is not on file. `--password-file <path>` is preferred; there is deliberately no `--password` option, because argv is readable by every process |
| `EXAKIT_REUSE_DB=0\|1` | Adopt an existing database (`1`, the default) or decline the adoption (`0`). Declining is harmless on its own: a running database makes the install stop with guidance, and a stopped deployment is only ever deleted with the separate `EXAKIT_REPLACE_DB=1` consent below |
| `EXAKIT_REPLACE_DB=1` | macOS only: consent to **delete a stopped Exasol deployment and its data** and deploy fresh. Without it, `EXAKIT_REUSE_DB=0` (or answering no) stops the install with guidance instead of destroying anything. `exakit repair-runtime` sets it itself after asking its own destructive question |
| `EXAKIT_PODMAN_SELFHEAL=1` | Consent, for a run with no terminal, to the one system change the kit can make to get Podman working. On Linux and WSL: add your missing rootless subuid/subgid range with `sudo` (this needs passwordless sudo when nothing can type the password). On Windows: switch Podman Desktop's default machine to rootless, which restarts it (containers made under the rootful machine are no longer visible, not deleted). With a terminal the kit asks instead; without this variable an unattended install skips the fix and prints the command to run. |
| `EXAKIT_PREFLIGHT=1` | Check machine requirements only, installs nothing. Both installers: `... \| EXAKIT_PREFLIGHT=1 sh`, or `$env:EXAKIT_PREFLIGHT = '1'` before `irm ... \| iex` |
| `EXAKIT_DRY_RUN=1` | Download the kit into a temporary folder for inspection; installs nothing and changes nothing under `EXAKIT_HOME` |
| `EXAKIT_LOCAL_KIT=/path/to/checkout` | Install from a local checkout instead of downloading — on every platform, including Windows (`$env:EXAKIT_LOCAL_KIT = 'C:\path\to\checkout'`), where the checkout must contain `setup\exakit.ps1` or the installer refuses it by name. On WSL this is the only supported way to install from a Windows-side clone: pass the `/mnt/c/...` path |
| `EXAKIT_DB_PORT=8564` | Alternate DB port (Linux and Windows container path only). Set it once, for the install: the kit records it and every later `exakit start` reuses it |

Version and update behaviour (all optional, sensible defaults):

| Variable | Effect |
|---|---|
| `EXAKIT_VERSION_POLICY=manifest\|latest\|pinned` | Where versions come from. `manifest` (default) installs the tested set the maintainers publish in `versions.json`; `latest` resolves each component from its own upstream; anything else (`pinned`) uses the kit's built-in fallbacks and touches no network |
| `EXAKIT_VERSIONS_URL=...` | Where that document is fetched from (must be `https://`). Defaults to the kit repository's `versions.json` on `main` |
| `EXAKIT_VERSIONS_TTL=86400` | Seconds before the cached copy is refreshed. `0` fetches every time |
| `EXAKIT_<COMPONENT>_VERSION=...` | Pin one component by hand: `EXAKIT_EXAPUMP_VERSION`, `EXAKIT_MCP_VERSION`, `EXAKIT_PYEXASOL_VERSION`, `EXAKIT_PERSONAL_VERSION`. Outranks the manifest, on install **and** on update |
| `EXAKIT_CONFIRM_RUNTIME_UPDATE=1` | Pre-answer "yes, you may stop the database and recreate the container". Covers both entry points: it skips the confirmation in `exakit update`, and it opts an unattended `exakit update` into the runtime change it would otherwise defer (`exakit update --yes` does the same for one run). `=0` is a deliberate "no" and outranks the prompt |
| `EXAKIT_NO_UPDATE_NOTICE=1` | Never print the pending-update notice after other commands. Unset, the notice appears after **every** command while any update is pending |
| `EXAKIT_NOTICE_INTERVAL=86400` | Throttle that notice to at most one per this many seconds (`86400` = once a day). Default `0`: every command |

Example:

```bash
curl -fsSL .../install.sh | EXAKIT_MCP_CLIENTS=claude EXAKIT_DATASETS=tpch sh
```

## Troubleshooting and advanced overrides

None of these are needed on a normal machine, and none are set by default. They exist because when one of them is the answer, nothing else is.

| Variable | Effect |
|---|---|
| `EXAKIT_HOME=/abs/path` | Where the kit keeps everything — state, credentials, logs, the kit copy (default `~/.exasol-starter-kit`). The only fix for a redirected, cloud-synced (OneDrive) or UNC home directory. Set it for the install **and** keep it set for later `exakit` commands (on Windows as a user environment variable, not just in one shell): the CLI reads it each time and otherwise looks in the default location |
| `EXAKIT_PERSONAL_READY_TIMEOUT=600` | Seconds to wait for the database to report ready (default `150`). Raise it on a slow or heavily loaded machine. Setting it also **overrides** the rebuild budget below, so one value covers both waits |
| `EXAKIT_PERSONAL_REBUILD_TIMEOUT=1200` | Seconds to wait when the first start after a launcher update rebuilds the deployment's VM guest (default `900` — fifteen minutes, and the longest wait the kit has). Used only when `EXAKIT_PERSONAL_READY_TIMEOUT` is unset. **Without a terminal both waits print a progress line to stderr every 30 s** naming the elapsed time, the ceiling and the variable that raises it — so a long wait is distinguishable from a hang. Do not loop on `exakit start` to find out; read that line |
| `EXAKIT_EXAPUMP_READY_TIMEOUT=300` | Seconds to wait for a freshly installed exapump to become runnable (default `180`). Windows Defender and endpoint-security agents hold a newly written unsigned binary while they scan it, and every call meanwhile fails with `Access is denied`; only that error is waited for |
| `EXAKIT_UPLOAD_RETRIES=0` | How many more attempts a data-file upload gets when the database's import connection is cut mid-transfer (`ETL-5105 ... transfer closed with outstanding read data remaining`; default `2`, `0` disables). Retried one file at a time, logged, never shown; a malformed file or a refused login is never retried |
| `EXAKIT_INSTALL_PODMAN=0` | Linux and WSL only: do **not** install Podman when it is missing. The default is to install it — the database runs through Podman, so the kit runs one package-manager command through `sudo` (apt, dnf, yum, zypper, pacman or apk) between the launcher step and the database step, and on Debian/Ubuntu brings `uidmap` with it. The command's output goes to the logfile behind a spinner, and a password is asked for only when `sudo` actually wants one. Set this to `0` for a run where package installs are somebody else's job: the database step is then recorded as not finished and prints the command instead |
| `EXAKIT_PERSONAL_MIN_RAM_GB=4` | RAM floor for the deployment (default `8`) |
| `EXAKIT_PERSONAL_MIN_DISK_GB=10` | Free-disk floor at the home directory, where the deployment lives (default `20`) |
| `EXAKIT_PERSONAL_REAP_MIN_AGE=0` | Seconds a matching runner process must have been alive before the kit will treat it as an abandoned orphan and kill it (default `180`). A deployment that is still coming up carries the same process name as a stranded one, so the kit waits out the start budget before reaping; `0` restores the old reap-by-name-alone behaviour. **Do not set it to `0` to get past a busy port** — killing a runner that is mid-start leaves the launcher `interrupted`, and the only documented cure for that is `exakit repair-runtime`, which deletes the database |
| `EXAKIT_FORCE=1` | Install even though a RAM or free-disk check failed, or could not read the number at all. It lowers no requirement — the deploy can still fail on the real limit |
| `EXAKIT_AUTO_ROLLBACK=1` | On a failed install, undo the failed step's changes without asking. The question defaults to no, so an unattended run otherwise keeps partial progress and resumes on the next run (sh installer only) |
| `EXAKIT_NO_FANCY=1` | ANSI-free, glyph-free output everywhere — no colour, no spinner, no box drawing. What a non-TTY agent wants when it captures a screen; `NO_COLOR=1` is honoured too. `EXAKIT_HELP_PLAIN=1` does the same for `exakit help` / `exakit catalog` alone |
| `EXAKIT_CONFIRM_RUNTIME_REPAIR=1` | Pre-answer `exakit repair-runtime`'s confirmation. **This DESTROYS the database and its data** (bundled datasets are reloaded afterwards; anything the user loaded is not). Without it, and with no terminal, the command changes nothing and exits `5`. Ask the user before setting it — the same rule as `--yes` |
| `EXAKIT_MCP_READONLY_SCHEMAS=STARTER_KIT` | The **default schema** the read-only MCP connection opens on (default `STARTER_KIT`); the first name wins if you pass several. **This is not a security boundary and does not narrow one.** The read-only user is granted `USE ANY SCHEMA` + `SELECT ANY TABLE`, so it can already read every schema and table in the database — present and future — whatever this is set to. What makes it read-only is the absence of any write or DDL privilege (see the MCP privilege note below), not this list |
| `EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1`<br>`EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES=1`<br>`EXAKIT_ALLOW_UNVERIFIED_EXASOL_VSCODE=1`<br>`EXAKIT_ALLOW_UNVERIFIED_EXASOL_SCHEDULER=1` | Install a downloaded binary **without verifying its checksum**. They exist for a maintainer debugging a publishing fault, on a machine they own. **Never set one in an unattended run**, and never as a way past a failed verification — a checksum that does not match is the check working |

## Timing: read this before you run it

- The first install deploys a database, **usually in under 2 minutes** on every platform.
- Your shell tool may **time out before the deploy finishes**. That is not a failure. Run the install in the background (or with a raised timeout), then poll:

```bash
exakit status        # until it reports running
```

  The `exakit` command is put in place in the first seconds of the install, so the poll works from the start: while the installer runs, `exakit status --json` answers `"status": "installing"` with `install_step` and `steps_completed`, exit code 3; `running` with exit 0 means installed and healthy. An installer that died is **not** "installing": its lock names a dead process, so `status` answers with `installing: false`, `install_step` still set, and `remedies.install` naming the re-run — never keep polling past that. The `status` word there is whatever the database is: `stopped` or `running` if one was deployed before the installer stopped, and `no database` if it never got that far (there, `remedy` is the installer's own command — `exakit start` has nothing to start, and `exakit start` in that state fails identically every time). `command not found` therefore means the install has not started (or `~/.local/bin` is not on your `PATH`, see below), not that it is still running.

- **Re-running the installer is safe and resumes.** Completed steps are skipped, failed steps retry. When in doubt, re-run rather than diagnose.
- An existing database is **adopted**, running or stopped. Only a database that cannot start is replaced, and the installer announces it. To restart a stopped database, prefer `exakit start` over re-installing.
- **A database that cannot be started at all is a distinct state, and it has its own command.** After a crash (SIGKILL, a hard power loss) the launcher can mark the deployment `interrupted`, after which every `exakit start` fails the same way. `exakit status` reports `interrupted` rather than `stopped` and names `exakit repair-runtime` as the remedy; `status --json` puts that same command in `remedies.database`. **Do not loop on `exakit start`, and do not expect a plain installer re-run to fix it** — `repair-runtime` rebuilds the deployment, which **destroys its data** (bundled datasets are reloaded afterwards; anything the user loaded themselves is not). Ask the user before running it, and pass `--yes` (or `EXAKIT_CONFIRM_RUNTIME_REPAIR=1`) only once they have agreed. **Without that consent it changes nothing and exits `5`** — so a `repair-runtime` that answers `5` has not repaired anything, and re-polling `status` will report `interrupted` again.

## Verify the install

```bash
exakit status                                     # Status: running
exakit info                                       # connection panel
exakit sql 'SELECT CURRENT_TIMESTAMP'             # end-to-end proof
```

A returned timestamp means the database works. MCP health: `exakit mcp-doctor` (reports `success` plus a per-client state map: connected, available, not installed — and it now starts the configured server and completes an MCP handshake, so `connected` means the client can actually reach it, not merely that the config entry parses; `--json` also carries `mcp_privileges`, the system privileges the read-only user reports about itself — exactly `CREATE SESSION`, `SELECT ANY TABLE`, `USE ANY SCHEMA` — so the boundary is proven without touching a password file). It also **repairs** drift it finds — a deleted entry, a loosened file mode — and re-checks; `mcp-doctor --json` only reports, and its `remedy` names the repairing form. `exakit mcp-setup` takes no options (exit 2 if given one): name clients with `EXAKIT_MCP_CLIENTS=...`, and a client whose file no longer holds the kit's `exasol` entry is offered again (an add-on's entry alone does not count). `exakit mcp-remove <client>` takes the kit's entries out of a client that is gone from the machine, which is what doctor's `managed_client_missing` remedy names. Doctor repairs the warnings it can act on too (a loosened file mode), and an add-on endpoint is only ever written into clients that are connected: detected, with the `exasol` entry present.

**You cannot use the MCP tools in the session that installed them.** An MCP client reads its server list at startup, so the client running this install — including you — has no `exasol` tools until it restarts. That is expected and is not a fault to diagnose. For the rest of *this* session use `exakit sql` (below); verify the MCP path next session, or ask the user to restart their client.

### Running SQL

`exakit sql '<statement>'` is the path to prefer: it is the only one that turns a raw engine error into a remedy (connection refused → `exakit start`; `FETCH FIRST`/`TOP` → `LIMIT`; object not found → describe it first). The remedy is printed **first, on stdout**, as a line starting with `! `, ahead of the engine's own text. It refuses anything that is not a single read statement unless you pass `--write`; a first word it does not recognise at all (`SELCT`) is reported as a typo, not as a write. A saved statement reruns with `exakit sql --file <path>` or `exakit sql < file`; comment lines and a trailing `;` are dropped, so the files under `~/.exasol-starter-kit/workflows/` run as saved. `--json` returns one object (`{"ok": true, "rows": [...], "row_count": n}` or `{"ok": false, "error": ..., "remedy": ...}`) with nothing else on stdout.

Without MCP tools — always the case in the session that ran the install — discover what data exists from the system tables, which the engine answers in well under a second (through `exakit sql` budget about a second per statement on Windows — process start and TLS — so fold introspection into as few statements as you can): `SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROW_COUNT FROM SYS.EXA_ALL_TABLES WHERE TABLE_SCHEMA NOT LIKE 'SYS%'` lists every table, `SYS.EXA_ALL_COLUMNS` (filter on `COLUMN_SCHEMA`) gives columns and types, and the table and column comments (`TABLE_COMMENT`, `COLUMN_COMMENT`) are the dictionary for every bundled dataset; the kit copy's `data/data-dictionary.md` (`~/.exasol-starter-kit/kit/data/data-dictionary.md`) adds the narrative and the join map.

It is **not** a sandbox — it connects as the admin user, exactly like `exapump sql -p starter-kit`. The enforced read-only boundary is the MCP user and nothing else.

## Updates

The kit installs a **tested set** of versions published by the maintainers, not the newest of each component. Two commands cover everything:

```bash
exakit version           # installed vs advertised, one row per component
exakit update            # apply what is waiting: kit scripts, exapump, MCP server, pyexasol — and, after asking, the database
```

What an agent needs to know:

- `exakit update` takes **seconds** for the quick components. A pending **database** update stops the database, so it is applied only for an answer the run was actually given: on a terminal the user is asked (`Stop the database and update the runtime now? [y/N]`), and on yes the command does the whole sequence itself — stop, update, restart, report.
- **An agent-driven run has no terminal, so the database update is never started on its own.** It is deferred with the exact command (`exakit update`). Opt in deliberately with `exakit update --yes` or `EXAKIT_CONFIRM_RUNTIME_UPDATE=1`, and expect the database to be down for a minute or two. Ask the user first — the database is theirs, and other things may be connected to it.
- The runtime update keeps your data: the container is recreated over the same data volume and the previous image is put back if the new one does not come up. There is no data backup step because nothing deletes data. The one exception is an Exasol Personal **major** upgrade, which is a real data migration: `exakit update` reports it, never starts it, and points at the Exasol Personal migration guidance for that version.
- Nothing here can hang. Version resolution degrades to a cached copy, then to the copy that shipped with the kit; no command fails because an update check could not reach the network.
- `exakit version` is the one command that reports versions: one row per component and add-on, each with what is installed and whether something newer is advertised. There is no separate `update-check` — it was merged into `version`.
- In `exakit version --json`, every row in `components` carries **`addon`**: `true` for an optional tool from the marketplace, `false` for a part of the kit itself. Branch on it before you act on `status` — an add-on that reads `available` was never installed and nothing is wrong, while a kit component that reads `missing` is a gap `remedy` will close. Each row's `status` is one of `current`, `ahead`, `unsupported`, `unknown`, `available`, `blocked_on_kit`, `missing`, `update_available`, and `remedy` is the command for it or `null`.
- If the advertised version is **older** than the installed one, nothing is offered and nothing is applied: `exakit version --json` reports that row's `status` as **`ahead`** (the human table prints it as `none` — the JSON token is the one to branch on), and asking for that component by name succeeds and does nothing. The kit has no downgrade path, by any route or override. To withdraw a faulty release, publish a higher version.
- A component that reports `not installed` (most often `pyexasol`, whose install step is deliberately non-fatal) is repaired by the same command: `exakit update`.

## Marketplace add-ons (optional)

Optional tools live behind `exakit marketplace`, never in the install flow. Interactively it is a checkbox menu (Space selects, Enter installs); without a terminal it installs nothing. An agent looks with `exakit marketplace --list` (`--json` for scripts), installs by naming ids or answering with the environment, and removes one add-on with `exakit uninstall <id> --yes`:

```bash
exakit marketplace --list                                  # read-only: every add-on and its state
exakit marketplace --json                                  # the same, machine-readable
exakit marketplace dash-server                             # install exactly this one
EXAKIT_MARKETPLACE_ADDONS=dash-server exakit marketplace   # ids csv, or all / none
exakit uninstall json-tables --yes                         # remove one add-on, nothing else
```

- **dash-server** — agent-operated Dash hosting: build live dashboards on the local database through its MCP control plane (`http://127.0.0.1:5100/mcp`; start it with `dash-server`). Once it is installed, `exakit mcp-setup` registers that control plane as an MCP server named `dash-server` for Cursor, Claude Code, Codex, GitHub Copilot, Gemini CLI, OpenCode and Continue — Claude Desktop is the one client left out, as a note rather than a warning, because its config file has no shape for a remote server (the app takes those through its own Connectors settings) — so after the client restarts you drive it with tools rather than raw HTTP.
- **dbt-exasol** — run dbt models against the local database. The kit writes its own `profiles.yml` under `~/.exasol-starter-kit/dbt` and points dbt at it with `DBT_PROFILES_DIR`; your own `~/.dbt/profiles.yml` is never read or written. Driven with `dbt-exasol`, not `dbt`, so a dbt you already have on PATH is never shadowed.
- **exasol-scheduler** — run SQL on a schedule, recorded in `SCHED.SCHED_TASKS`.
- **exasol-vscode** — the Exasol extension for VS Code (SQL editing and schema browsing); installed into VS Code itself, so a copy the user already has from the VS Code Marketplace is respected and never touched.
- **json-tables** — ingest, query and reshape JSON-shaped data (`exasol-json-tables ingest --input <file.json>`). `exapump` loads CSV and Parquet only, so `exakit data-load` installs this add-on silently when handed a `.json` file and finishes the load itself — it asks nothing beyond the schema and table every file kind is asked for. Supported on macOS (Apple silicon), Linux, WSL and Windows x86_64; Windows ARM64 and Intel Macs have no prebuilt engine and are not offered. The ingest engine ships **prebuilt**, from an immutable per-version release the kit's own CI publishes — never tell a user to install Rust.
- **exasol-scheduler** — SQL jobs on a schedule, defined and audited in a table (`SCHED.SCHED_TASKS` / `SCHED_HISTORY`). Runs as a dedicated `scheduler_svc` database user, never the admin — `SCHED_TASKS` is a code-execution surface, so the read-only MCP user can see it but not write it: create tasks with `exakit sql --write`, and grant `SCHEDULER_SVC` access to the schemas your jobs touch. Missed occurrences are never replayed (a laptop asleep at 02:00 does not run the 02:00 job on wake), one instance per task table is enforced, and the kit's launcher supervises the engine itself. Supported everywhere the kit runs except Windows ARM64.
- Once installed, an add-on updates through the normal flow — `exakit update` covers it along with everything else. Add-ons that were never picked are never touched, and one already on the system outside the kit is respected, not managed.
- An interactive install ends with the same offer once everything ran; `EXAKIT_MARKETPLACE_ADDONS` pre-answers it (see the install answers table above).
- Add-ons that run as services (dash-server) are managed like the database: `exakit status` shows `running` / `stopped`, `exakit start` and `exakit stop` cover the database and every service together, and `exakit autostart` decides whether they come back after a reboot (it asks; `EXAKIT_AUTOSTART_CHANGE=1|0` pre-answers) (on by default from a fresh install — launchd on macOS, systemd --user on Linux, a Startup entry on Windows).
- dash-server serves on `http://127.0.0.1:5100` by default. If something else holds that port the install moves to the next free one and records it; change it deliberately with `EXAKIT_DASH_SERVER_PORT=<port> exakit update`. `exakit status` distinguishes "stopped" from "the port is held by another process".
- `exakit logs` lists every log the kit can show (installer run, each add-on service, and what the boot entries wrote at login) with size and last-updated; `exakit logs <target>` tails one, `-f` follows it, `--path` prints just the path for piping.
- After a restart, nothing needs a human if autostart is on — on macOS, Linux and Windows. On a headless Linux box a systemd **user** unit only runs while you have a session, so the kit enables lingering for your user when it can (`loginctl enable-linger`); where that is refused it says so and names the command an admin has to run.
- Building a NEW add-on for the marketplace is a development task, not an install step: the walkthrough with skeleton code is [MARKETPLACE.md](MARKETPLACE.md).

## Recipe: install → local JSON file → live dashboard, in one unattended run

The whole flow — fresh machine to a dashboard URL — needs no human and no client restart. Every step below is the non-interactive path; do not substitute interactive menus for any of them.

1. **Install with both add-ons pre-answered**, in the background (see Timing above), then poll `exakit status` until `running`:

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | \
  EXAKIT_MCP_CLIENTS=claude EXAKIT_LOAD_SAMPLE=0 EXAKIT_MARKETPLACE_ADDONS=dash-server,json-tables sh
```

2. **Load the JSON file directly.** `exakit data-load` loads a file unattended with `EXAKIT_DATA_FILE=<file> EXAKIT_DATA_TABLE=<SCHEMA.TABLE>` — but this recipe still calls the add-on's CLI, because `ingest-and-wrap` additionally installs the queryable wrapper views the dashboard uses: it shreds the file, imports it, and creates those views in one command (admin credentials, because it creates schemas):

```bash
exasol-json-tables ingest-and-wrap --input <file.json> --dsn 127.0.0.1:8563 \
  --user sys --password "$(cat ~/.exasol-starter-kit/credentials/personal_sys_password)" \
  --name <workflow_name> --no-tls --if-exists replace --json
```

The `--json` summary names the source schema it created (`EJT_<NAME>_SRC`). Explore it with read-only SQL; every ingested column is a string, so `CAST(... AS DOUBLE)` numerics before aggregating.

3. **Build the dashboard through dash-server's MCP control plane** — plain JSON-RPC over HTTP to `http://127.0.0.1:5100/mcp` (read the real URL from `exakit status --json`, key `urls["dash-server"]`; the port alone is `exakit info --json`'s `components.dash_server.port`). The install just registered this endpoint with your clients as an MCP server named `dash-server`, but a client only reads its server list at startup, so the session that ran the install does not have those tools yet. Inside this run, call the endpoint over HTTP; from the next session, use the registered tools instead:

```bash
curl -s -X POST http://127.0.0.1:5100/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"<tool>","arguments":{...}}}'
```

   Call four tools in order: `exasol_profile_create_local` (bind the **read-only** user — `user: mcp_readonly`, `secret_value` from `~/.exasol-starter-kit/credentials/mcp_readonly_password`, `tls_verify: false`; dashboards read, they never need `sys`), `exasol_profile_validate`, `app_scaffold_from_schema` (point it at the ingested schema/table; it introspects the columns and builds the app itself), then `app_run_healthcheck`.

   **Then make it presentable — the scaffold alone is a bare ops template.** One `app_put_files` + `app_deploy_draft` pass turns it into a dashboard a human would demo:

   - Push `assets/theme.css`, copied **verbatim** from the local kit copy at `~/.exasol-starter-kit/kit/templates/dash-theme.css` — KPI cards, chart cards, tab styling and a colorblind-validated chart palette (`#2a78d6` / `#eb6834` / `#1baf7a`), so no run invents its own CSS.
   - In `app.py`, pass `assets_folder=str(Path(__file__).parent / "assets")` to the `Dash(...)` constructor. The host imports the module dynamically, so Dash's default assets lookup resolves outside the artifact and the theme is **silently never linked** without this.
   - Replace the scaffold's placeholder business SQL with real aggregates of the ingested measures — a KPI summary row (totals, counts, a margin), a monthly trend, and one or two categorical breakdowns — and lay the page out business-first: KPI row on top, charts in `chart-card` divs inside a `chart-grid`, the scaffold's system tabs after. Format money and counts in the KPI values; keep chart series on the palette above and never a dual-axis chart.

4. **Report the browser URL** (`http://127.0.0.1:<port>/apps/<app-name>`) only after the healthcheck's `data_layer` and `sql_smoke` probes pass — a `200` from the page alone does not prove the dashboard can query.

## Where things live

- State, credentials, logs: `~/.exasol-starter-kit/` (logs under `logs/`). Installer and `exakit` messages name their remedy — check there before improvising. Raw database/driver errors (through MCP tools or `exapump` directly) do NOT; translate the common ones with the table below.
- Kit source copy (read any script): `~/.exasol-starter-kit/kit/`
- CLI binaries: `~/.local/bin/` (`exakit`, `exapump`, `exasol` on macOS, and `dash-server` once that add-on is installed). **That directory is not on a bare non-interactive `PATH`** (a clean `sh -c` sees roughly `/usr/local/bin:/bin:/usr/bin`), so `exakit: command not found` does **not** mean "not installed" — test `~/.local/bin/exakit` before concluding anything, and either call it by absolute path or `export PATH="$HOME/.local/bin:$PATH"` first. **On Windows the command is `exakit.cmd`** (in `%USERPROFILE%\.local\bin`): PowerShell resolves bare `exakit`, but Git Bash — Claude Code's shell on Windows — does not, and `~/.local/bin/exakit` does not exist there; call `~/.local/bin/exakit.cmd` by that name.
- Saved queries: `~/.exasol-starter-kit/workflows/` — created by the install, and where the skill's "make it rerunnable" step puts approved SQL.
- **Never print, echo or paste a database password — and it is not only in `~/.exasol-starter-kit/credentials/`.** The MCP setup writes `EXA_PASSWORD` **in clear text** into each AI client's own config (`~/.claude.json`, `~/.codex/config.toml`, and the rest — `exakit mcp-status` lists them). Those are files agents read routinely while debugging MCP, so treat them the same as the credential files: read them if you must, never reproduce them in your output, a commit, an issue, or a support thread. Redact the `env` block before showing a client config to anyone.

## After the install

The installer already placed the agent skills where CLI agents look (`~/.claude/skills`, `~/.agents/skills`), so future sessions can drive the full ask, inspect SQL, run, validate loop. Nothing to run:

```bash
exakit skills             # what this kit carries, whether each is placed, and the next command if one is needed (--json too)
```

The skill set is a versioned component: `exakit version` and `exakit info` show its installed and advertised versions, and `exakit update` fetches a newer set the maintainers advertise and places it, without a kit release. If a placed skill has gone missing, `exakit skills` says so and names the repair.

There is one skill per thing you have to operate, so only the relevant one loads: `local-agent-ready-starter` (setup and the first query), `exasol-runtime`, `exasol-exapump`, `exasol-mcp`, `exasol-pyexasol`, `exakit-lifecycle` (updating, logs, credentials, uninstall), `exasol-ecosystem` (tools beyond this kit), and one per marketplace add-on (`exasol-marketplace`, `dash-server`, `dbt-exasol`, `exasol-scheduler`, `json-tables`, `exasol-vscode`). Full index: [skills/README.md](skills/README.md).

Then see `skills/local-agent-ready-starter/SKILL.md` for the full query-loop discipline. **If your harness loads this file but not filesystem skills, these are the rules that must not drop out:**

### Guardrails (also in SKILL.md — inlined here so they survive a skill-less harness)

- **The loop is ASK → INSPECT → RUN → VALIDATE → RERUN.** Show the user the SQL *before* running it; validate results independently (a second query, a count, a spot check) before presenting conclusions.
- **Two connections, two trust levels.** The MCP tools run as a dedicated **read-only** database user — reads everywhere, writes rejected *by the database*. `exapump -p starter-kit` connects as the **admin** user and is **not sandboxed**: it can create, drop and delete. Never treat an exapump success as proof something is safe for the MCP path, and never reach for exapump to "work around" an MCP rejection.
- **Prove the boundary, don't assert it:** `SELECT PRIVILEGE FROM SYS.EXA_USER_SYS_PRIVS` as the MCP user returns exactly `CREATE SESSION`, `SELECT ANY TABLE`, `USE ANY SCHEMA`.
- **Never print or log** a database password. They are in `~/.exasol-starter-kit/credentials/` **and in clear text inside each AI client's MCP config** (`~/.claude.json` and friends) — redact the `env` block before showing one of those to anyone.

### Common database errors → remedy (raw engine messages carry none)

| You see | It means | Do |
|---|---|---|
| `Connection refused` (exapump: `Failed to connect to 127.0.0.1:8563`) | The database is not running | `exakit start`, then confirm with `exakit status` (exit 0 = running, 3 = stopped) |
| MCP tool: `A database error occurred. Please try again later or contact your administrator` | The MCP server masks the engine text; nine times in ten the database is not running | `exakit status --json` and follow its `remedy` (`exakit start`); the server cannot tell you more |
| `TLS error: tls handshake eof` | The port is open but no database completes a handshake behind it: most often the database is still booting behind its published port (under rootless Podman the port is pasta's from the moment the container starts, a minute before the database answers); otherwise something that is not Exasol holds the port | Wait a minute and retry; `exakit status` then says `running`, or reports `conflict` and names the process — stop it, then `exakit start` |
| `syntax error, unexpected FETCH_` — or, for `SELECT TOP n`, `unexpected UNSIGNED_INTEGER_` | Exasol does not page with `FETCH FIRST` / `TOP` | Rewrite with `LIMIT <n>` (optionally `OFFSET`) |
| MCP tool: `The query is invalid or not a SELECT statement` for a statement that IS a `SELECT` | The server's gate refused it before the engine saw it: `TOP`, a second statement, or a leading comment | Rewrite with `LIMIT`, one statement, no leading `--` line |
| `object <NAME> not found` | Wrong name or missing schema qualifier | `describe_exasol_table_or_view` (MCP) or `DESCRIBE <schema>.<table>`, then fix the query |
| `object <NAME> not found` on a table you loaded from a file | File columns keep the file's exact spelling and case, quoted: `"visits"`, not `VISITS` | `DESCRIBE STARTER_KIT.<table>`, then quote the column names as shown |

`exakit sql --json` returns the same faults as data: `{"ok": false, "error": "<engine text>", "remedy": "..."}` on failure and `{"ok": true, "rows": [...]}` on success, so nothing above has to be pattern-matched off a screen.

### Scripted state checks

- `exakit status --json`: `platform` (`macos` | `linux` | `wsl` | `windows` — **branch on this before you run a remedy on WSL**) and `wsl_version` (`1` | `2`, null elsewhere); `running`, `datasets_loaded` (**verified against the database**, not the manifest; `datasets_source` says which of the two answered), `services` (state per add-on service id), `urls` (the address of each service that has one — this is where dash-server's URL comes from), `steps_completed`, `steps_missing`, `remedies` (component to the exact repair **command**, runnable as written) and `remedy_hints` (the prose for the same keys; an install step that never finished is in both, so a session picking up after a crash sees `remedies.mcp: "exakit mcp-setup"`), `last_failure` and `last_failure_at`. **On WSL, not every `remedies` value is runnable in your shell**: some are actions on the Windows host (a `%USERPROFILE%\.wslconfig` edit, `wsl --shutdown` from PowerShell, a `/etc/wsl.conf` line plus a distro restart). `platform` is how you know to read the `remedy_hints` sentence and escalate to the user instead of executing it. `legacy_database` appears only on a machine where the installer found an older kit's container database: `container`, `engine`, `choice`, `copied`, `restored_tables`, `sample_left_out`, and `command` — `exakit migrate docker-nano` while the data is not copied, else null.
- `exakit info --json`: the install record. `exakit mcp-doctor --json`: per-client MCP state under `details.clients` (`connected`, `needs_attention`, `configured_client_missing`, `not_set_up`, `not_installed`); its `remedy` is null unless a WARNING or ERROR names one, and `--json` only reports where the plain command also repairs.
- `exakit catalog --json`: every supported command (a handful of internal upgrade paths are marked hidden and are not for you to call). `exakit logs --json`: every log target and its path. `exakit help <id> --json`: a component's page. All rendered from `setup/help/*.json`, so read these rather than scraping the decorated screen.
- `exakit preflight`: re-runs the installer's machine-requirement checks (RAM, free disk, the container engine or the macOS runtime, the database port) against an installed kit and changes nothing — the same checks `EXAKIT_PREFLIGHT=1` runs before an install.

### Exit codes, precisely

- `status`, `info --json`, `mcp-doctor`: `0` running · `3` database not running (also `3` with `"status": "installing"` while the installer runs) · `4` not installed. The code **is** the answer.
- A kit that is not where `exakit` looks (no install, or `EXAKIT_HOME` pointing elsewhere) answers `4`, with the same JSON shape when `--json` is given.
- `version` and `mcp-status`: `0` ok · `4` not installed. They report on versions and configs, which a stopped database does not change; do not read database health off them.
- Bad input exits `2` and records nothing: an unknown subcommand, an unknown option to **any** command, a statement `exakit sql` refuses (`--json` answers `{"ok": false, "error": ..., "rejected": true}`), an unsupported data file. `last_failure` is only for a step of your install that did not finish — and no query writes it, however it fails.
- `exakit repair-runtime` exits `5` when the destructive confirmation was **not** given (the default with no terminal): nothing was changed. `0` there means the database really was rebuilt. `--json` says the same thing as `{"ok": false, "status": "declined", "changed": false, "remedy": "exakit repair-runtime --yes"}`.
- `exakit migrate docker-nano` copies an older kit's container database into the running deployment: `0` done (or nothing of the user's to copy — the kit's own sample data is left out), `1` the copy did not finish (the copies are kept; the next run restores a waiting copy first), `3` no deployment to copy into, `5` not confirmed (`--yes` pre-answers it; without a terminal the default is no). `--json` answers `{"ok", "status": done|nothing|declined|failed|partial, "copied_out", "restored", "left_alone", "failed", "sample_left_out", "reason", "remedy"}`. It **stops the database** while the tables are copied out when the container publishes the same port, and starts it again — say so before running it on someone's behalf.
- **The five state queries are `status`, `info`, `version`, `mcp-status` and `mcp-doctor`.** They are the only commands that report on THIS MACHINE, they agree with each other on `installed` and on the `status` vocabulary, and **one shape covers all of them** — but only `status`, `info` and `mcp-doctor` carry database health in their exit code; `version` and `mcp-status` keep their own `0/4` codes exactly as the exit-code list above says, so never read liveness off those two: `installed`, `status`, `remedy` in every state, so a parser branches without first working out which shape it received. `status` is drawn from a fixed vocabulary, and which vocabulary depends on what the command reports on.

**Liveness** — `status`, `info`, `mcp-doctor`: `running`, `stopped` (the database is not running; this is what exit 3 means, and all three commands use this one word for it — `info` and `mcp-doctor` also carry `"database": "not running"` for callers written against their older shape), `installing`, `interrupted`, `conflict`, `no database` (the kit is installed, no database is deployed yet), `not installed` (no install record at all), `unknown` (the kit could not read its own record — the `remedy` says how to repair it).

**Outcomes** — the commands that *do* something rather than report: `repair-runtime --json` answers `{"ok", "status", "changed", "remedy", ...}` where `status` is `repaired` (it ran), `declined` (you did not confirm — exit 5, `changed` false) or `failed` (it ran and did not finish); the MCP operations (`mcp-status`, `mcp-doctor`, `mcp-setup`, `mcp-remove`) answer `{"installed", "status", "remedy", ...}` where `status` is one of **`success`**, **`success_with_warnings`**, **`no_change`**, **`blocked`**, **`failed_recoverable`** (the operation did not complete but `exakit mcp-doctor` can repair it — the commonest non-success answer) or **`failed_terminal`**; plus `error` on the narrow path where the operation produced no result at all. Two of the five state queries therefore answer from THIS set, not from the liveness set — branch on the command you ran. These carry `ok` and/or `changed`, which no state query does — that pair is how you tell an outcome from a report. Never read liveness from one.

**Currency** — `version`, `skills`: `current` (nothing to update, `remedy`/`next` is null), `update_pending` (something is behind, and the command that fixes it is given), or — `skills` only — `missing` (the skill set is not on this machine at all; `next` is `exakit skills-install`). These commands report on versions, not on the database, so they never emit a liveness word — and a parser must not read database health off them. `mcp-status` reports per-client configuration state and carries its own shape.
- **The other `--json` commands are documents and results, not state.** None of them carries `installed`, and none carries a *liveness* `status` — read database health from `exakit status --json` and nowhere else: `sql --json` is `{"ok", "rows"|"error", "remedy", "remedy_hint"}` — `remedy` stays a runnable command or null, the sentence lives in `remedy_hint`; `catalog --json` and `help --json` are `{"schema_version", "count", "commands", "documents"}`; `logs --json` is `{"count", "targets"}`; `skills --json` is `{"skills", "installed_version", "advertised_version", "status", "next"}` — its `status` is a **currency** verdict (below), not a liveness one, and `next` is the command that resolves it or null. All four of the latter report on the kit's own contents, so they answer exit `0` even with nothing installed. **Never use one as a liveness probe — use `exakit status --json`.**

### Discovering the data and the commands

- Table and column comments ship with every bundled dataset: `SYS.EXA_ALL_TABLES` (`TABLE_COMMENT`) and `SYS.EXA_ALL_COLUMNS` (`COLUMN_COMMENT`, filter by `COLUMN_SCHEMA` / `COLUMN_TABLE`). Sub-100 ms, and it returns units, value domains and FK targets, not just types. The kit copy's `data/data-dictionary.md` says the same in prose.
- `exakit catalog` lists every supported command (searchable: `exakit catalog logs`). `exakit <component> --help` prints a component's page: what it is, how to start it, its commands, environment variables and troubleshooting table. Components: `exapump`, `mcp`, `pyexasol`, `personal`, `dash-server`, `json-tables`, `exasol-vscode`. Every command answers `--help`.

### Fewer approval prompts

`skills/reducing-agent-prompts.md` is the per-agent guide: which read-only commands are safe to allow without a prompt, and why `exakit sql`, `exapump` and every mutating command deliberately keep asking. The installer applies that allowlist to Claude Code's settings itself (and `exakit uninstall` removes exactly those entries again); other agents follow the doc.

## Uninstall

```bash
exakit uninstall --yes    # database + data, MCP configs, skills, binaries
```
