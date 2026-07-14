# Agent guide: Exasol Personal Local Starter Kit

This repo installs a complete local analytics stack with one command: an Exasol database on the user's machine, the `exapump` data/SQL CLI, an MCP server with a dedicated read-only database user, and the `pyexasol` Python driver. If a user asks you to "install this repo", this file is your runbook.

## Install (one command)

macOS / Linux / WSL:

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.ps1 | iex
```

The installer is **fully unattended-safe**. With no TTY attached (the normal case for an agent shell) every question takes a safe default: all bundled datasets are loaded, and every AI client that is installed on the machine but not yet connected gets an MCP config. Nothing ever hangs waiting for input.

One caveat when driving a **WSL** install from the Windows side (`wsl.exe -- bash -c "curl ... | sh"`): wsl.exe can attach a console that looks interactive but never delivers keypresses, so menus render and block. Either run the command detached (`setsid sh -c '...' < /dev/null`) or pre-answer everything with the env vars below.

## Answer the install's choices via environment variables

Flags do not travel through a pipe, so choices are env vars. They work on all platforms; on Windows set them with `$env:` before `irm ... | iex`. **Always use client and dataset names, never menu numbers.** Numbers are display order and change between releases.

| Variable | Effect |
|---|---|
| `EXAKIT_MCP_CLIENTS=claude,cursor` | Which MCP clients to configure, by name: `claude` (= desktop app **and** Claude Code CLI), `claude_desktop`, `claude_code`, `codex`, `cursor`, `vscode_copilot` (also `copilot`), `gemini_cli` (also `gemini`), `opencode`, `continue`, `all`, `skip` |
| `EXAKIT_SKIP_MCP=1` | Skip MCP client setup entirely (run `exakit mcp-setup` later) |
| `EXAKIT_DATASETS=tpch,weather` | Which bundled datasets to load, by id: `tpch`, `energy`, `weather`. Takes precedence over `EXAKIT_LOAD_SAMPLE` |
| `EXAKIT_LOAD_SAMPLE=0\|1` | `0` skip data loading, `1` load the bundled sample (tpch) |
| `EXAKIT_REUSE_DB=0\|1` | macOS: adopt an existing database (`1`, the default) or destroy it and deploy fresh (`0`) |
| `EXAKIT_PREFLIGHT=1` | Check machine requirements only, installs nothing (sh installer only) |
| `EXAKIT_DRY_RUN=1` | Download the kit for inspection, installs nothing |
| `EXAKIT_DB_PORT=8564` | Alternate DB port (Linux and Windows container path only) |

Example:

```bash
curl -fsSL .../install.sh | EXAKIT_MCP_CLIENTS=claude EXAKIT_DATASETS=tpch sh
```

## Timing: read this before you run it

- The first install deploys a database, **usually in under 2 minutes** on every platform.
- Your shell tool may **time out before the deploy finishes**. That is not a failure. Run the install in the background (or with a raised timeout), then poll:

```bash
exakit status        # until it reports running
```

- **Re-running the installer is safe and resumes.** Completed steps are skipped, failed steps retry. When in doubt, re-run rather than diagnose.
- An existing database is **adopted**, running or stopped. Only a database that cannot start is replaced, and the installer announces it. To restart a stopped database, prefer `exakit start` over re-installing.

## Verify the install

```bash
exakit status                                     # Status: running
exakit info                                       # connection panel
exapump sql -p starter-kit 'SELECT CURRENT_TIMESTAMP'   # end-to-end proof
```

A returned timestamp means the database works. MCP health: `exakit mcp-doctor` (reports `success` plus a per-client state map: connected, available, not installed).

## Where things live

- State, credentials, logs: `~/.exasol-starter-kit/` (logs under `logs/`; every error message names its remedy, check there before improvising)
- Kit source copy (read any script): `~/.exasol-starter-kit/kit/`
- CLI binaries: `~/.local/bin/` (`exakit`, `exapump`, and `exasol` on macOS)
- Never print or log the password files under `~/.exasol-starter-kit/credentials/`

## After the install

Install the agent skill so future sessions can drive the full ask, inspect SQL, run, validate loop:

```bash
exakit skills-install
```

Then see `skills/local-agent-ready-starter/SKILL.md` for the query-loop discipline (read-only MCP user, show SQL before running it).

## Uninstall

```bash
exakit uninstall --yes    # database + data, MCP configs, skills, binaries
```
