---
name: local-agent-ready-starter
description: Use this to set up the Exasol Personal Local Starter Kit and run a first trusted, AI-assisted query against a local Exasol database — installing the local runtime, connecting an AI client over MCP, loading the sample data, and running the ask → inspect-SQL → run → validate → rerun loop. Triggers — "set up the Exasol starter kit", "install Exasol locally", "connect my AI to Exasol", "run my first query on my local database", "help me get started with the starter kit".
---

# Local Agent-Ready Starter

You are helping the user reach **first value**: a local Exasol database, an AI client
connected to it over MCP, sample data loaded, and one query answered **with the SQL
inspected before it ran**. The whole point of this kit is *AI speed with the user's own
verification* — never sacrifice the inspect-before-run discipline for speed.

Take it one step at a time, confirm each step worked before moving on, and prefer the
kit's own commands over improvising.

## Step 0 — Figure out two things first (always start here)

**A. Can you run shell commands?**
- **Yes** (you are in a terminal-capable agent such as Claude Code or Codex CLI): you can
  run `exakit` / `exapump` yourself. Drive the setup, showing the user each command and its
  output.
- **No** (you only have the read-only Exasol MCP tools — e.g. a chat-only client): you
  cannot install anything. Your job shrinks to guiding the *user* to run the commands, and
  taking over for the query loop (Step 5) once the MCP server is connected. Say this plainly
  so the user knows to run the setup commands themselves.

**B. Where is the user already?** If you have a shell, run:

```bash
exakit status      # is the kit installed and is the database running?
exakit mcp-doctor  # is an AI client connected over MCP?
```

Branch on the result — **do not blindly reinstall**:

| What you see | Go to |
|---|---|
| `exakit: command not found` | Step 1 (install) |
| installed, runtime **not** running | Step 2 (start + verify) |
| running, no MCP client configured | Step 3 (connect MCP) |
| running + MCP configured, no data | Step 4 (load data) |
| everything ready | Step 5 (first query) |
| **anything else** — a command errors, `mcp-doctor` reports problems, a half-finished install | Treat as *not ready*: re-run the installer (safe — it skips finished steps and retries failed ones), check `exakit logs`, then re-check `exakit status`. Do not improvise a fix. |

Re-running the installer is always safe — completed steps are skipped — so when in doubt,
verify rather than assume.

## Step 1 — Install the local runtime

One command installs and connects the database, `exapump` (data/SQL CLI), and the MCP server.

- **macOS / Linux / WSL:**
  ```bash
  curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | sh
  ```
- **Windows (PowerShell):**
  ```powershell
  irm https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.ps1 | iex
  ```

Inspect-before-run applies to setup too, not just SQL. Offer the user the kit's read-first
options before piping a remote script into a shell:
- `... | EXAKIT_PREFLIGHT=1 sh` — checks this machine's requirements and installs **nothing**.
- `... | EXAKIT_DRY_RUN=1 sh` — downloads the kit to `~/.exasol-starter-kit/kit` so the scripts
  can be read first; installs nothing until the user runs the setup themselves.

When **you** run the installer (no terminal is attached, so the install cannot prompt the
user), it silently takes safe defaults — it would load **every bundled dataset** and connect
**every AI client found on the machine that isn't connected yet** over MCP, without asking.
Instead, ask the user these questions first, then pass the answers so their choices are
honored — prefixed before `sh` on macOS/Linux/WSL, or set as `$env:` variables first in
PowerShell on Windows. Always use **names, not menu numbers** — numbers change between
releases:
- which MCP client(s) to connect → `EXAKIT_MCP_CLIENTS=claude` (`claude` = desktop app +
  Claude Code CLI; also `claude_desktop`, `claude_code`, `codex`, `cursor`, `copilot`,
  `gemini`, `opencode`, `continue`, `all`, comma-separated); or `EXAKIT_SKIP_MCP=1` to set
  MCP up later via `exakit mcp-setup`
- which data to load → `EXAKIT_DATASETS=tpch,weather` (bundled dataset ids; wins over
  `EXAKIT_LOAD_SAMPLE`), or `EXAKIT_LOAD_SAMPLE=1` (bundled sample) / `0` (skip data)
- on macOS, if a database is already running → `EXAKIT_REUSE_DB=1` (reuse) or `0` (deploy fresh)

Example: `curl -fsSL <install.sh URL> | EXAKIT_MCP_CLIENTS=claude EXAKIT_DATASETS=tpch sh` —
or on Windows: `$env:EXAKIT_MCP_CLIENTS = "claude"; $env:EXAKIT_DATASETS = "tpch"; irm <install.ps1 URL> | iex`.
(`EXAKIT_REUSE_DB` applies to the macOS native runtime only.)

Tell the user what to expect: a detection summary, an install plan, then numbered steps
ending in a connection panel — and the suggested first AI prompt is copied to the user's
clipboard automatically when a clipboard tool is available, ready to paste into their client.
**The first database deployment usually finishes in under 2 minutes on every
platform** (one-time). Do not treat a long-running macOS
deploy as a hang — it holds the foreground for a while. If you cannot keep a long foreground
command open, have the user run the install command themselves and tell you when the
connection panel appears; then poll `exakit status` and continue.

If a step fails, the installer says which one and how to fix it. Re-running resumes from the
failed step. Common fixes live in the [README troubleshooting table] and `exakit logs`.

## Step 2 — Verify it is alive

```bash
exakit status                                   # runtime: running
exakit info                                      # the connection panel
exapump sql -p starter-kit 'SELECT CURRENT_TIMESTAMP'
```

A returned timestamp means the local database works end to end. If `status` is not
`running`, `exakit start` brings it back on every platform — prefer it over re-running
the installer (a re-run with the kit in place is safe and skips the deploy, but `start`
is the direct tool for the job).

> Two names that look alike but are not the same thing — do not conflate or "correct" them:
> `starter-kit` is the **exapump connection profile** (`-p starter-kit`); each bundled dataset
> lives in its **own database schema** (`TPCH`, `ENERGY`, `WEATHER`), while `STARTER_KIT` is the
> default schema for data the user uploads themselves. Use each exactly as written.

## Step 3 — Connect the AI client over MCP

```bash
exakit mcp-setup
```

Tell the user that setup backs up and edits the selected client configs directly — it
presents a checkbox multi-select of every supported client (Claude Desktop, Claude Code,
Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Continue). Clients that are already
connected or not installed on this machine appear greyed out with the reason and cannot be
selected; **every selectable (pending) client is pre-selected**. The user restarts the
client afterward.

After setup, the client starts the MCP server named `exasol` on demand over stdio (it is not
a background service). Verify with `exakit mcp-doctor`.

The MCP login is a **dedicated, read-only database user** — it can read every schema in the
database but cannot write, and that read-only limit is enforced by the database, not by
trust. That is what makes the next steps safe.

## Step 4 — Load the sample data

So the user is not staring at an empty database, load the bundled TPC-H sample (customers,
orders, line items, parts, suppliers) into the `TPCH` schema:

```bash
exakit data-load
```

Safe to run any time; choose the bundled sample option to load it. Use `exakit data-load --force`
to reload the bundled sample directly. If it reports files as *pending*, the sample data has not shipped in this build —
the user can still continue with their own data:
`exapump upload yourfile.csv --table STARTER_KIT.MYTABLE -p starter-kit`.

## Step 5 — The first trusted query (the payoff, and the point)

Run the kit's core loop **once, end to end**. This is where the trust story is proven, so
hold the discipline even though it is tempting to just answer.

```text
ASK  ->  INSPECT (show the SQL first)  ->  RUN (read-only)  ->  VALIDATE (independently)  ->  RERUN
```

1. **Discover.** Ask the user's assistant to list schemas/tables and describe the
   `TPCH` tables first — ground in the *real* schema, do not guess column names.
2. **Ask, but show the SQL first.** For a question like *"which product category generated
   the most revenue?"*, present the SQL and a plain-English explanation **before executing**.
   Call out the judgment calls: what defines "revenue" (price × quantity? an amount column?),
   whether returns are subtracted, what is filtered out. Let the user correct the SQL before
   it runs.
3. **Run.** Only after the user approves the query *intent*. The MCP user is read-only, so the
   worst a query can do is read. If the database rejects it for a mechanical reason — a dialect
   quirk (Exasol uses `LIMIT n`, **not** `FETCH FIRST`/`TOP`), or an identifier that needs
   different casing — fix and re-run **without** re-asking; the approved intent hasn't changed.
4. **Validate independently.** Reproduce the number outside the assistant with the *same*
   approved SQL: `exapump sql -p starter-kit "<the approved SQL>"`. Matching numbers is the
   whole point — the AI's answer becomes the user's *verified* answer. **Caution:** the
   `starter-kit` exapump profile connects as the **admin** user, *not* the read-only MCP user —
   it is not sandboxed. Issue only the exact approved `SELECT` here; never DDL/DML through
   exapump. Reproducing the same SQL proves it reruns and connects; to also sanity-check
   *correctness*, vary one thing (a filter or grouping) and confirm the number moves the way
   you'd expect.
5. **Make it rerunnable.** Save the approved SQL to a file the user can rerun tomorrow
   (e.g. under `~/.exasol-starter-kit/workflows/`). Point to the walkthrough in
   `~/.exasol-starter-kit/kit/demo/first-revenue-analysis.md`.

## Non-negotiable guardrails

Follow these on every interaction, no exceptions:

- **Read-only only — and know which path is actually enforced.** Never CREATE, UPDATE, DELETE,
  DROP, or otherwise mutate data. Two access paths, two levels of protection:
  - **MCP tools** run as the dedicated read-only user — it can read every schema
    (`USE ANY SCHEMA` + `SELECT ANY TABLE`) but the database *enforces* read-only, so a
    mutation is rejected outright. This is the safe default path for querying.
  - **`exapump -p starter-kit`** connects as the **admin** user and is *not* restricted — the
    only thing stopping a destructive statement there is you. Use it solely for the approved
    `SELECT` in Step 5.4. Never route a write through it, and never use it to "work around"
    an MCP read-only rejection.
- **Show SQL before executing — approve once per query *intent*.** Present and explain the query,
  and run only after the user approves. This habit *is* the product. But do **not** re-prompt for
  mechanical re-runs of already-approved logic — fixing a dialect/syntax error, or a sanity-check
  variant of the same query — just say what changed and proceed. Re-ask only when the *meaning*
  changes (different tables, filters, or metric).
- **Validate through an independent path.** Encourage reproducing results with `exapump`
  rather than taking the assistant's number on faith.
- **Do not invent** schema names, column names, SQL syntax, file paths, or Exasol behavior.
  Discover the schema via MCP; if a fact is unverified, say so.

## When something goes wrong

- `exakit status` — is the runtime running?
- `exakit logs` — path to the latest log; every error message names its remedy.
- `exakit mcp-doctor` / `exakit mcp-repair` — MCP connectivity.
- Assistant can't see the database → confirm the runtime is running and the client was
  restarted after the MCP config change.
- Fuller guidance: `~/.exasol-starter-kit/kit/QUICKSTART.md` and the README troubleshooting
  table.

[README troubleshooting table]: https://github.com/exasol-labs/exasol-personal-local-starterkit#readme
