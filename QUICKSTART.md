# Quickstart: zero to your first AI-assisted query

Goal: a local Exasol database on your machine, an AI assistant connected to it, and your first question answered with the SQL visible and rerunnable.

## 1. Check your machine (optional, 10 seconds)

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

## 2. Install everything (one command)

**macOS / Linux / WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | sh
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.ps1 | iex
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

**Optional: let your AI agent do all of this.** Run `exakit skills-install`, then say **"setup starter kit"** in a fresh agent session. It checks state, connects, loads data, and runs the first query with the SQL shown before execution. Details: [skills/README.md](skills/README.md).

## 5. Ask your first question

Sample data is already loaded. To load more, or your own CSV or Parquet file:

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
exakit uninstall           # remove everything the kit installed
```

Re-running the installer is safe. It skips what is done and repairs what is not.

## If something goes wrong

| Symptom | Fix |
|---|---|
| "Docker is installed but not running" | Start Docker Desktop or `podman machine start`, then re-run |
| "Port 8563 is already in use" | Stop the other app, or re-run with `EXAKIT_DB_PORT=8564` (Linux and Windows) |
| Setup failed mid-way | Re-run the same install command. It resumes from the failed step |
| Assistant cannot see the database | `exakit status`, then restart the AI client |
| Anything else | `exakit logs` has the full story. Every error message names its remedy |
