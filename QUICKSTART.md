# Quickstart: zero to your first AI-assisted query

Goal: a local Exasol database on your machine, an AI assistant connected to it, and your first question answered with the SQL visible and rerunnable.

## 1. Check your machine (optional, 10 seconds)

**macOS / Linux / WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

**Windows (PowerShell):** there is no `sh` there, and `curl` is an alias for `Invoke-WebRequest`, so set the variable first and use the PowerShell installer:

```powershell
$env:EXAKIT_PREFLIGHT = '1'
irm https://www.exasol.com/install/starter-kit.ps1 | iex
```

## 2. Install everything (one command)

**macOS / Linux / WSL:**

```bash
curl https://www.exasol.com/install/starter-kit.sh | sh
```

**Windows (PowerShell):**

```powershell
irm https://www.exasol.com/install/starter-kit.ps1 | iex
```

You will see a short plan, then numbered steps: database, data, AI setup. The database is usually up in under 2 minutes. The install ends with a connection panel, and a first prompt for your AI client is copied to your clipboard.

## 3. Verify it is alive

```bash
exakit status     # Status: running
exakit info       # the connection panel, any time you need it
```

## 4. Connect your AI assistant

The installer already did this. To run it again, or after installing a new AI client:

```bash
exakit mcp-setup
```

A checkbox menu shows every supported client: Claude, Codex, Cursor, Gemini CLI, GitHub Copilot, OpenCode, Continue. The ones on your machine are pre-selected. The ones you do not have appear greyed out. Existing configs are backed up before any change.

After setup, restart the client and look for an MCP server named `exasol`.

**Optional: let your AI agent do all of this.** The installer placed the agent skills; say **"setup starter kit"** in a fresh agent session. It checks state, connects, loads data, and runs the first query with the SQL shown before execution. Details: [skills/README.md](skills/README.md).

## 5. Ask your first question

Sample data is already loaded. To load more, or your own CSV, Parquet or JSON file:

```bash
exakit data-load
```

Then ask your assistant something like:

> *"Use the exasol MCP server connected to my local Exasol database. List the available schemas and tables first. Then answer my questions with read-only SQL only, and show me the SQL before you run it."*
> *"Show me total revenue by product category."*

The assistant is read-only by design. It can discover schemas and run SELECT queries, nothing else. Ask it to show the SQL first, inspect, then approve.

## Everyday commands

```bash
exakit status              # health at a glance
exakit info                # connection details
exakit stop                # stop the database (your data is kept)
exakit start               # bring it back
exakit mcp-doctor          # AI connection health check
exakit version             # what is installed vs what the maintainers advertise
exakit update              # apply the updates that are waiting
exakit uninstall           # remove everything the kit installed
```

The quick updates take seconds and no downtime. When a **database** update is
waiting, `exakit update` asks — `Stop the database and update the runtime now?
[y/N]` — and on `y` it stops the database, updates it, brings it back up and says
so. On `n` nothing is stopped and `exakit update` applies it later. Your
data is kept either way. Full detail:
[Staying up to date](README.md#staying-up-to-date).

Re-running the installer is safe. It skips what is done and repairs what is not.

## If something goes wrong

| Symptom | Fix |
|---|---|
| I already had the starter kit, with the database in a container | Re-run the install command. It recognises the old installation before touching anything and asks whether to bring your data across: **Migrate my data** copies every non-system table into the new database, **Skip and continue** sets the new one up empty. Neither deletes the old container or its data — both stop it (it holds the port the new database needs) and print the command that removes it when you want it gone. The kit's own sample data (TPC-H, energy, weather), when unchanged, is left out of the copy: the install loads it itself |
| I skipped that, or my container was never offered | `exakit migrate docker-nano` — the same copy, later, into the running database. It remembers the container the installer saw; name another with `--container`, `--engine docker\|podman`, `--dsn HOST:PORT`, and give the password with `--password-file` or at the prompt (never on the command line). Both databases want port 8563, so yours is stopped for the copy out and started again before the copy in. Nothing in the container is changed or removed |
| "Podman is installed but not running" | macOS/Windows: `podman machine start`. Linux: there is no machine to start — check `grep $(id -un) /etc/subuid /etc/subgid` first. Then re-run |
| "Port 8563 is already in use" | The launcher selects the deployment's port itself and the kit reads it back — an existing Exasol on the port is adopted; anything else is reported with the process named. Stop that app and re-run |
| Setup failed mid-way | Re-run the same install command. It resumes from the failed step |
| Assistant cannot see the database | `exakit status`, then restart the AI client |
| Anything else | `exakit logs` has the full story. Every error message names its remedy |
