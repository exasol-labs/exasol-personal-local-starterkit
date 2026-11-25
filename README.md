<div align="center">

<picture>
  <source srcset="static/Exasol_Logo_2025_Bright.svg" media="(prefers-color-scheme: dark)">
  <img src="static/Exasol_Logo_2025_Dark.svg" alt="Exasol Logo" width="300">
</picture>

# Exasol Personal Local Starter Kit

### The Analytics Database for Agentic AI. Free for Personal Use.

**Install it with one command. You don't need a cloud account or a license key.**

[![Documentation](https://img.shields.io/badge/docs-exasol.com-blue)](https://docs.exasol.com/db/latest/home.htm)
[![Community](https://img.shields.io/badge/community-exasol-green)](https://community.exasol.com)
[![Quickstart](https://img.shields.io/badge/database%20ready-~5%20min-orange)](QUICKSTART.md)

**macOS / Linux / WSL**

```bash
curl https://www.exasol.com/install/starter-kit.sh | sh
```

**Windows (PowerShell)**

```powershell
irm https://www.exasol.com/install/starter-kit.ps1 | iex
```

To have an AI agent do the install, paste this into Claude Code, Codex or any other coding agent:

<div align="left">

```text
Install the Exasol starter kit from https://github.com/exasol-labs/exasol-personal-local-starterkit
```

</div>

</div>

---

## Overview

This kit sets up an analytics database on your own machine and connects your AI assistant to it. Everything runs locally, so your data stays with you. You see every SQL statement before it runs and can check each answer yourself.

The install command sets up five components and connects them:

| Component | What it does |
|---|---|
| [MCP server](https://github.com/exasol/mcp-server) | Let Claude, Cursor or other supported MCP clients query your database through a dedicated read-only login. One server runs beside the database at `http://127.0.0.1:4896/mcp`, or on the next free port, and every AI client uses that URL |
| [Exasol&nbsp;Personal&nbsp;Local](https://github.com/exasol/exasol-personal) | An in-memory analytics database that runs on your machine |
| [exapump](https://github.com/exasol-labs/exapump) | Loads CSV and Parquet files and runs SQL from your terminal |
| [pyexasol](https://github.com/exasol/pyexasol) | The official Exasol Python driver, installed in its own environment |
| [SQL&nbsp;preprocessor&nbsp;framework](https://github.com/exasol-labs/preprocessor-framework) | Lets add-ons such as Semantic Views and JSON Tables extend SQL in every session, with no setup per session |

It also gives your AI agent a skill for each part of the kit and for each Federation connector. They work in Claude Code, Codex, Cursor and any tool that reads the open skill standard, and an agent loads one only when the task needs it.

## What's new

### Federation: query your other data

Query data where it lives, straight from your local Exasol. `exakit connect` turns a remote source into a virtual schema, `VS_<NAME>`, that you join with your local tables in plain SQL. Nothing is copied.

**What you can connect (11 connectors)**

- **Cloud warehouses:** Snowflake, Databricks, BigQuery
- **Databases:** PostgreSQL, MySQL, Oracle, SQL Server, MongoDB
- **Cloud storage:** Amazon S3, Azure Blob Storage
- **Lakehouse catalogs:** Iceberg and Delta tables
  - Open Iceberg REST catalogs, such as Apache Polaris and Lakekeeper
  - Unity Catalog
  - AWS Glue
  - A plain Parquet folder on S3 or Azure

**How to connect**

1. On the source, create a read-only user and allow your computer's IP.
2. Run `exakit connect` and pick the source.
3. Talk to your data: ask your AI client in plain words, for example "Which customers in VS_SALES ordered the most?". Or query it yourself: `exakit sql "SELECT * FROM VS_SALES.ORDERS LIMIT 10"`.

Two commands are all you need: **`exakit connect`** adds a source, and **`exakit source`** shows your sources and everything you can do with them next.

**Need help?**

- Type `?` and press Enter at any question to see that source's guide (not at the hidden password or connection-string prompt).
- `exakit connect --help` opens the guide for every connector.
- The [Federation guide](docs/virtual-schemas/README.md) has a page for each connector.

### Add-ons through `exakit marketplace`

The base install stays small. When you want more, you pick an add-on by the outcome you want, and the kit installs it, checks that it works, and keeps it current with `exakit update`. Dash Server and JSON Tables come with the install (on Windows, from the add-ons table at the end). The install ends with one table of the other add-ons, and `exakit marketplace` opens the same list at any time.

| Add-on | What you get |
|---|---|
| [dash-server](https://github.com/exasol-labs/dash-server) | A result shared as a live dashboard. Your AI builds it from a query on the local database, and you open it in the browser |
| [Exasol&nbsp;for&nbsp;VS&nbsp;Code](https://github.com/exasol-labs/exasol-vscode) | SQL editing and schema browsing next to the rest of your project, inside your editor |
| [JSON&nbsp;Tables](https://github.com/exasol-labs/exasol-json-tables) | JSON files, nested ones included, turned into tables you can query |
| [Exasol&nbsp;Scheduler](https://github.com/exasol-labs/exasol-scheduler) | SQL that runs on a timetable inside the database. The jobs are rows in a table |
| [dbt-exasol](https://github.com/exasol/dbt-exasol) | Repeatable SQL models built, tested and documented with dbt against the local database |
| [Semantic&nbsp;Views](https://github.com/exasol-labs/exasol-semantic-views) | Metrics and dimensions defined once in the database, then queried in Semantic SQL from any client |


### JSON support

`exakit data-load` now takes JSON files, including nested documents, and loads them as regular tables. The load goes through the JSON Tables add-on, which comes with the install. JSON paths then work in plain SQL.

### Bulk upload

Point `exakit data-load` at a folder and every CSV, Parquet or JSON file in it becomes one table, named after the file. The folder is read at its top level only. Uploads land in the `STARTER_KIT` schema by default.

## Minimum requirements

Every platform runs the same database, Exasol Personal, set up by the same launcher.

| Machine | Minimum | Notes |
|---|---|---|
| **[macOS](quickstarts/macos.md)** | 8 GB+ RAM, 20 GB free disk | Runs in a lightweight managed VM. Nothing to install first |
| **[Linux](quickstarts/linux.md)** | Docker Engine 29+ or Podman (rootless is fine), 8 GB+ RAM, 20 GB free disk | A new install runs on Docker when a usable one is found, otherwise on Podman. If neither is there, the installer installs Podman without stopping to ask. It uses `sudo`, so expect a password prompt |
| **[Windows](quickstarts/windows.md)** | 8 GB+ RAM, 20 GB free disk | Uses [Docker Desktop](quickstarts/windows.md#docker-or-podman) when it is running, otherwise Podman, which the launcher offers to install. We recommend installing Docker and having it running when you install the starter kit. Windows arm64 is not supported<br>**WSL**: run the same command inside a WSL2 distro. |
| All platforms | Python 3.11+ |  |

If Podman blocks the install, see the [Podman troubleshooting guide](quickstarts/podman.md).


## Upgrade path for the starter kit

From 0.3.0, run `exakit update`. On Windows, run it again when it says so. It restarts the database once, renames it to `starter-kit-local`, and moves the kit to 0.3.1 and Exasol Personal to 2.5.0. Your data, the port, your connected sources and your AI clients stay as they are. The database folder moves to the 2.5 launcher's own folder, which `exakit info --json` names, and that move cannot be undone.

0.3.0 is a major upgrade. From 0.2.5 or earlier, run `exakit update` twice. The first run installs the 0.3.0 kit, and the second run updates its parts. Re-running the install command from the top of this page once does the same job.

Coming from an older kit, such as 0.1.0, or want a clean start with everything new? Uninstall and install fresh: run `exakit uninstall`, then the install command from the top of this page. An uninstall removes the kit's own database and its data, so save anything you want to keep first.

### Windows notes

- On Windows, `exakit update` from 0.2.5 or earlier may wrongly say "Everything is already current" when one of GitHub's addresses does not answer. Then run `irm https://www.exasol.com/install/starter-kit.ps1 | iex` once instead.
- On Windows with Podman, WSL 2.7 or newer is recommended for Exasol Personal 2.4 and later: if `exakit start` then fails with an nftables error, run `wsl --update`.

## Connect your AI client and ask

```bash
exakit mcp-setup
```

The install connects every AI client it finds on your machine, without asking. Run `exakit mcp-setup` any time to add a client. It lists Claude, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode and Continue, greys out the ones already connected or not installed, writes the config for the ones you pick and checks the connection. `exakit mcp-doctor` checks it again later.

Two sample datasets are loaded for you: retail sales in `RETAIL_SALES` and bank transactions in `BANK_TRANSACTION`. The [data dictionary](data/data-dictionary.md) describes them, and [data/example-questions.md](data/example-questions.md) has 21 questions with reference SQL.

Try it: *"Which product category generated the most revenue? Show me the SQL before you run it."*

## Everyday commands

```bash
exakit status          # is everything running?
exakit info            # connection details
exakit start           # start the database
exakit stop            # stop it (your data is kept)
exakit data-load       # load more data
exakit mcp-setup       # connect AI clients
exakit mcp-doctor      # AI connection health check
exakit connect         # query another database or bucket (Federation)
exakit source          # manage your connected sources: list, check, refresh, reauth, remove
exakit version         # what is installed, and what is newer
exakit update          # apply what is pending (a database update restarts the database)
exakit marketplace     # optional add-ons (dashboards & more)
exakit whats-new       # what changed in this version
exakit help            # the commands it offers
```

## More ways to connect

- GUI: [DBeaver](https://dbeaver.io/download/) or [DbVisualizer](https://www.dbvis.com/download/). Create a new Exasol connection with host `127.0.0.1`, the port `exakit info` shows (`8563`, or the next free port when another Exasol uses it) and user `sys`.
  - `exakit info` shows where the password is stored.
- Python: pyexasol is preinstalled in its own environment.
- Terminal: `exapump interactive -p starter-kit` opens a SQL shell.

Run `exakit guide` for the full walkthrough.

## Staying up to date

The maintainers publish one recommended set of versions. Compare your install against it:

```bash
exakit version
```

`exakit update` applies what is pending. Most updates take seconds and need no downtime. A database update stops the database for a minute or two, and `exakit update` restarts it for you.

<!-- ## See it in action

The whole flow, from install to the first query: -->

<!-- https://github.com/user-attachments/assets/77916db0-d273-4720-8d59-1aedac95d5e8 -->

## FAQ

| Question | Answer |
|---|---|
| What&nbsp;do&nbsp;I&nbsp;need&nbsp;installed&nbsp;first? | Python 3.11+. You don't need Rust or Homebrew. |
| Can&nbsp;I&nbsp;use&nbsp;Docker&nbsp;instead<br>of&nbsp;Podman? | Yes, from kit 0.2.4 (Exasol Personal 2.4). A new install on Linux, WSL or Windows runs on Docker Engine 29 or newer when its daemon is running and set to Linux containers, otherwise on Podman. If Docker is installed but stopped, the installer asks once: start it and press Enter, or type `p` for Podman. The kit never installs or starts Docker. |
| What&nbsp;if&nbsp;I&nbsp;don't&nbsp;have<br>Podman&nbsp;Desktop&nbsp;on&nbsp;Windows? | The Exasol launcher offers to install Podman at the database step through Windows Package Manager, which may ask for administrator approval once. If that fails, see the [Podman troubleshooting guide](quickstarts/podman.md). |
| Podman&nbsp;on&nbsp;Windows:&nbsp;installed<br>but&nbsp;unable&nbsp;to&nbsp;connect? | Run `podman info` and check whether the machine is running. The [connection troubleshooting steps](quickstarts/podman.md#windows-connection-failures) explain how to get it working. |
| Podman&nbsp;on&nbsp;WSL:&nbsp;"nft&nbsp;did<br>not&nbsp;return&nbsp;successfully"? | Exasol Personal 2.4 and later need WSL 2.7 or newer for Podman, because its network needs nftables in the WSL kernel. The kit checks before a fresh Podman deploy, and an `exakit start` that fails with this error after an update names the same fix: `wsl --update`, then `wsl --shutdown`. See [WSL 2.7 and nftables](quickstarts/podman.md#wsl-27-and-nftables). Docker is not affected. |
| Does&nbsp;it&nbsp;cost&nbsp;anything? | No. Exasol Personal Local is free of charge, but it is not open source: the database ships under the [Exasol Personal End User License Agreement](https://www.exasol.com/terms-and-conditions/#h-exasol-personal-end-user-license-agreement), and this kit's scripts are [MIT](LICENSE). |
| Can&nbsp;I&nbsp;load&nbsp;my&nbsp;own&nbsp;data? | Yes. `exakit data-load` takes CSV, Parquet or JSON files, or a folder of them, and `exapump upload` works from the terminal. |
| How&nbsp;can&nbsp;I&nbsp;learn&nbsp;more&nbsp;about<br>an&nbsp;`exakit`&nbsp;command? | Run `exakit help <command>`. For example, `exakit help marketplace`. |
| The&nbsp;install&nbsp;failed<br>partway&nbsp;through? | Re-run the install command. It skips what is already done and picks up where it left off. |
| `exakit`&nbsp;not&nbsp;recognized<br>after&nbsp;a&nbsp;Windows&nbsp;install? | Re-run the install command. It adds `~\.local\bin` to your user PATH and fixes the command. |
| Port&nbsp;8563&nbsp;already&nbsp;taken? | The kit gives its database the next free port, whether another Exasol or another program holds 8563. `exakit info` shows the port your database uses. If Exasol's own runner from an interrupted install still holds the kit's port, the installer waits for it and clears it. One it cannot clear is named with the command that frees the port (`kill <pid>`). If another program later takes your database's port, `exakit start` names it: stop that program and run `exakit start` again. |
| Behind&nbsp;a&nbsp;corporate&nbsp;proxy? | Set `HTTPS_PROXY` before installing so the kit can download through your proxy. Use `export HTTPS_PROXY=http://proxy.example.com:8080` on macOS and Linux, or `$env:HTTPS_PROXY = 'http://proxy.example.com:8080'` in PowerShell. For proxies that require a login, the Windows installer uses your signed-in Windows account. Podman image pulls may need separate proxy and certificate settings inside its machine. See the [Podman troubleshooting guide](quickstarts/podman.md). |
| Installing&nbsp;over&nbsp;a&nbsp;database<br>I&nbsp;already&nbsp;have? | The kit's database is its own deployment, `starter-kit-local`, on its own port next to yours. If you have Exasol Personal 2.5 with databases, the installer asks once: a new database (press Enter) or one of yours, which is renamed to `starter-kit-local` and keeps its data. With 2.4 on macOS or Linux, your databases are left alone (Windows: see the [Windows notes](quickstarts/windows.md#windows-notes)). `exakit uninstall` never deletes a database of yours, and `exakit repair-runtime` rebuilds one only after your yes. |
| I&nbsp;already&nbsp;have&nbsp;the&nbsp;kit.<br>How&nbsp;do&nbsp;I&nbsp;get&nbsp;this&nbsp;version? | From 0.3.0, run `exakit update`. On Windows, run it again when it says so. From 0.2.5 or earlier, run it twice, or re-run the install command once. See [Upgrade](#upgrade-path-for-the-starter-kit). |
| Windows,&nbsp;0.2.5&nbsp;or&nbsp;earlier:<br>update&nbsp;says&nbsp;everything<br>is&nbsp;current? | `exakit update` from 0.2.5 or earlier may wrongly say "Everything is already current" when one of GitHub's addresses does not answer. Then run `irm https://www.exasol.com/install/starter-kit.ps1 \| iex` once instead. |
| Does&nbsp;Federation&nbsp;copy&nbsp;my&nbsp;data? | No. A connected source stays where it is. Each query reads only what it needs from the source. |
| How&nbsp;do&nbsp;I&nbsp;remove&nbsp;everything? | Run `exakit uninstall`. |

---

<div align="center">

*Questions or problems? Open an issue in this repository, or write to plg.connect@exasol.com.*

This kit is community supported. Its own scripts are licensed under [MIT](LICENSE). The Exasol database it installs is a separate product under Exasol's own licence terms. The kit is part of [Exasol Labs](https://github.com/exasol-labs/).

More Exasol projects are on [GitHub](https://github.com/exasol).

</div>
