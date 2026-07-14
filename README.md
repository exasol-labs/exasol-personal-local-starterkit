<div align="center">

<picture>
  <source srcset="static/Exasol_Logo_2025_Bright.svg" media="(prefers-color-scheme: dark)">
  <img src="static/Exasol_Logo_2025_Dark.svg" alt="Exasol Logo" width="300">
</picture>

# Exasol Personal Local Starter Kit

### The Analytics Database for Agentic AI. Free for Personal Use.

**One command. No cloud account. No license key.**

[![Documentation](https://img.shields.io/badge/docs-exasol.com-blue)](https://docs.exasol.com/db/latest/home.htm)
[![Community](https://img.shields.io/badge/community-exasol-green)](https://community.exasol.com)
[![Quickstart](https://img.shields.io/badge/first%20query-under%202%20min-orange)](QUICKSTART.md)

**macOS / Linux / WSL**

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | sh
```

**Windows (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.ps1 | iex
```

**Prefer to let your AI do it?** Paste this into Claude Code, Codex, or any coding agent:

<div align="left">

```text
Install the Exasol starter kit from https://github.com/exasol-labs/exasol-personal-local-starterkit
```

</div>

</div>

---

## What is this?

You already use AI. The hard part is trusting it with your data. This kit gives you a complete, private AI-ready analytics setup that runs **entirely on your machine**. See every SQL statement before it runs, verify every answer yourself, and rerun the whole thing tomorrow.

**One command installs four things and connects them:**

| | Component | What it does for you |
|---|---|---|
| 🤖 | **MCP server** | Lets Claude, Cursor, or other supported MCP clients query your database with a dedicated read-only login |
| 🗄️ | **Exasol&nbsp;Personal&nbsp;Local** | A full in-memory analytics database, running locally |
| ⚡ | **exapump** | Load CSV/Parquet files and run SQL from your terminal |
| 🐍 | **pyexasol** | The official Exasol Python driver, ready in its own environment |

At the end: connection details on screen, a managed runtime state under `~/.exasol-starter-kit/`, and guided MCP setup for supported clients. Time to first query: **under 2 minutes**.

## Key features

- 🪶 **No prerequisites to manage.** No Python, Homebrew, or Rust needed.
- ⚡ **Ready in under 2 minutes.** One command installs and connects the whole stack.
- 🔒 **Read-only AI.** Your assistant can read everything and change nothing. The database enforces it.
- 🤖 **Support for multiple AI clients.** Claude, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Continue.
- 📊 **Sample data included.** Three sample datasets, loaded and verified for you.
- ♻️ **Safe to re-run.** Re-runs skip what is already done.

## 🚀 Local Agent-Ready Starter

*Install, connect an AI assistant, ask your first question.*

### Will it run on my machine?

| Your machine | Minimum Requirements | That's all |
|---|---|---|
| **macOS** | 8 GB+ RAM, ~20 GB disk | The database runs natively |
| **Linux / WSL** | Docker or Podman (running), 4 GB+ RAM | Container runtime required |
| **Windows** | Docker Desktop (running), 4 GB+ RAM | Native Windows uses the PowerShell installer |

Not sure? Check first. It installs **nothing**:

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

Step-by-step guides: [QUICKSTART](QUICKSTART.md) · [macOS](quickstarts/macos.md) · [WSL](quickstarts/windows-wsl.md) · [Windows + Docker](quickstarts/windows-docker.md)

### Installing: what to expect

The installer detects your OS and hardware, shows its plan, then installs everything: the database, exapump, the MCP server, pyexasol, and your AI client connections. The flow is the same on macOS, Linux, WSL, and Windows PowerShell. The database is usually up in **under 2 minutes**.

At the end you get a connection panel with everything you need, and a first prompt for your AI client is on your clipboard.

Installing from a script or an AI agent? See [AGENTS.md](AGENTS.md).

## Connect your AI assistant

```bash
exakit mcp-setup
```

A checkbox multi-select (↑/↓ to move, **Space** to toggle, **Enter** to confirm) over **Claude**, **Codex**, **Cursor**, **GitHub Copilot**, **Gemini CLI**, **OpenCode**, **Continue**, and **Skip for now**. The list is **dynamic**: clients already connected, or not installed on this machine, aren't offered. If everything found is already connected, the command says so and exits.

The command validates the MCP connection, prints where the config lives, and gives you a first prompt to try, copied to your clipboard when a clipboard tool is available. When it can detect the local MCP launcher path, it writes that exact path into client configs instead of assuming `uvx` is on every app's PATH, for more reliable setup across macOS, Linux, and Windows.

The installer runs this step for you automatically. `exakit mcp-setup` re-runs it any time.

Health check any time: `exakit mcp-doctor`.

## Let an AI assistant drive the kit (the skill)

The kit ships an **AI skill**, a `SKILL.md` recipe that teaches an agent (Claude Code, Codex, Cursor, or any tool that reads the open skill standard) to run the whole flow for you: check status, connect MCP, load data, and hold the inspect-before-run query loop.

```bash
exakit skills-install
```

This copies the skill into each agent's discovery folder (`~/.claude/skills/`, `~/.agents/skills/`). In a **fresh** agent session, say **"setup starter kit"** and it takes over. See [`skills/README.md`](skills/README.md) for how it works, and [`skills/reducing-agent-prompts.md`](skills/reducing-agent-prompts.md) if the agent asks for approval too often.

## The workflow this kit teaches

```
ASK -> INSPECT -> RUN -> VALIDATE -> RERUN
```

Ask your assistant: *"Which product category generated the most revenue? Show me the SQL before you run it."*

## Sample data included

The kit ships **three bundled datasets**, each in its own schema, so your AI client sees them instantly:

| Dataset | What it is | Schema |
|---|---|---|
| **TPC-H retail** | The standard wholesale/retail model: customers, orders, line items, parts, suppliers (~175k rows, ~21 MB) | `TPCH` |
| **Smart&#8209;meter&nbsp;energy&nbsp;readings** | A ~108k-row time series ([data/datasets/energy](data/datasets/energy)) | `ENERGY` |
| **Daily&nbsp;city&nbsp;weather&nbsp;history** | ~11k rows ([data/datasets/weather](data/datasets/weather)) | `WEATHER` |

Run `exakit data-load` for the same checkbox menu as the installer. It lists every bundled dataset **not yet loaded** (checked against the live database, not a flag), a **local CSV or Parquet file** option, and Cancel. Once everything bundled is loaded, only the local-file and Cancel options remain. `exakit data-load --force` reloads the bundled sample data. One-liner alternative:

```bash
exapump upload yourfile.csv --table STARTER_KIT.MYTABLE -p starter-kit
```

Your uploads go to the `STARTER_KIT` schema by default.

**More detail:**

- [data/README.md](data/README.md): what's included and how to regenerate at a different size
- [data/data-dictionary.md](data/data-dictionary.md): every table and column, with types, keys, and the revenue formula
- [data/example-questions.md](data/example-questions.md): 14 ready-to-ask questions with validated reference SQL

## More ways to connect

- **GUI**: [DBeaver](https://dbeaver.io/download/). New Connection, Exasol, host `127.0.0.1`, port `8563`, user `sys`.
  - `exakit info` shows where the password lives.
- **Python**: pyexasol comes preinstalled in its own environment.
- **Terminal**: `exapump interactive -p starter-kit` opens a SQL shell.

Run `exakit guide` for the full walkthrough.

## Everyday commands

```bash
exakit status          # is everything running?
exakit info            # connection details
exakit start           # start the database
exakit stop            # stop it (your data is kept)
exakit data-load       # load more data
exakit mcp-setup       # connect AI clients
exakit mcp-doctor      # AI connection health check
exakit update-check    # updates available?
exakit help            # every command
```

Something failed mid-install? Re-run the install command. It picks up where it left off.

## Safety and operations

- **Dedicated read-only MCP login.** The kit provisions and validates a least-privilege database user before any MCP flow proceeds.
- **Local TLS handled for MCP clients.** Generated MCP client configs set `EXA_SSL_CERT_VALIDATION=no` only for the local self-signed `127.0.0.1` runtime. Use trusted CA validation for real remote databases.
- **No preinstalled Python required.** Uses `python3` when present, otherwise bootstraps a managed runtime through `uv`.
- **Repo stays pure source.** Runtime state, logs, credentials, backups, and generated configs live under `~/.exasol-starter-kit/`, never in this repo.
- **Everything is inspectable.** Install scripts, MCP configs, backups, and logs remain available on disk.
- **Local only.** The database listens on `127.0.0.1` only, passwords live in local files and are never shown on screen, and AI client configs are backed up before every change.
- **Reversible lifecycle.** `exakit` manages the kit end to end: `status`, `start`/`stop`, `data-load`, MCP setup and maintenance (`mcp-setup`, `mcp-doctor`, `mcp-repair`, `mcp-remove`, `mcp-restore`), `logs`, and a guarded `uninstall`. Run `exakit help` (or `exakit catalog`) to see every command.

## Quick answers

| Question | Answer |
|---|---|
| Do&nbsp;I&nbsp;need&nbsp;Rust&nbsp;/&nbsp;Python&nbsp;/&nbsp;Homebrew? | **No.** The installer brings everything it needs. |
| Does&nbsp;it&nbsp;cost&nbsp;anything? | No. Exasol Personal Local is free. |
| What&nbsp;makes&nbsp;this&nbsp;"for&nbsp;Agentic&nbsp;AI"? | An MCP server ships in the box with a dedicated read-only login, so Claude, Cursor, and other MCP clients can query your data directly, with every SQL statement inspectable before it runs. |
| What&nbsp;sample&nbsp;data&nbsp;is&nbsp;included? | Three bundled datasets: TPC-H retail, smart-meter energy, daily weather, each in its own schema. See the [data dictionary](data/data-dictionary.md). |
| Can&nbsp;I&nbsp;load&nbsp;my&nbsp;own&nbsp;data? | Yes. `exakit data-load` has a local CSV or Parquet option, and `exapump upload` works from the terminal. |
| Docker&nbsp;installed&nbsp;but&nbsp;not&nbsp;running? | Start Docker Desktop, run the install command again. |
| Docker Desktop runs on Windows<br>but WSL can't see it? | Docker Desktop → Settings → Resources → **WSL integration** → enable your distro → Apply & restart (the installer detects and flags this too). |
| `exakit` not recognized after<br>a Windows install? | Re-run the install command. It adds `~\.local\bin` to your user PATH and repairs the command automatically. |
| Port&nbsp;8563&nbsp;already&nbsp;taken? | `EXAKIT_DB_PORT=8564` before the install command. |
| Behind&nbsp;a&nbsp;corporate&nbsp;proxy? | `export HTTPS_PROXY=...` and re-run. |
| Where's&nbsp;the&nbsp;deep-dive&nbsp;for&nbsp;my&nbsp;OS? | [macOS](quickstarts/macos.md) · [WSL](quickstarts/windows-wsl.md) · [Windows + Docker](quickstarts/windows-docker.md) |
| Step-by-step&nbsp;to&nbsp;the&nbsp;first&nbsp;query? | [QUICKSTART](QUICKSTART.md) → [First workflow](demo/first-revenue-analysis.md) |
| How&nbsp;do&nbsp;I&nbsp;remove&nbsp;everything? | `exakit uninstall` |

---

<div align="center">

**Start locally. Connect AI safely. Inspect the SQL. Validate the output.**

*Questions or issues: open an issue in this repository.*

Part of the [Exasol](https://www.exasol.com) ecosystem · [Exasol Personal](https://github.com/exasol/exasol-personal) · [exapump](https://github.com/exasol-labs/exapump) · [MCP server](https://github.com/exasol/mcp-server) · [pyexasol](https://github.com/exasol/pyexasol)

</div>
