# Quickstart: Windows with Docker Desktop

Gets you from Windows to a local Exasol database, staying entirely in **PowerShell**. No WSL terminal needed. (More comfortable in a Linux shell? Use the [WSL quickstart](windows-wsl.md).)

## What you need

- Windows 10/11
- **Docker Desktop, installed and running** ([get it here](https://docs.docker.com/desktop/setup/install/windows-install/))
- 4 GB+ RAM, ~10 GB free disk

## Install (regular PowerShell, no admin needed)

```powershell
irm https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.ps1 | iex
```

What happens, in order:

1. Your machine is checked and the plan is shown
2. Docker is verified. If Docker Desktop is not running, you are told exactly that
3. The database container is pulled and started, reachable only from your machine
4. exapump (the data tool) is installed, the sample data is loaded and verified
5. The AI bridge is set up with a read-only database login, and your AI clients are connected
6. You get a connection panel with everything you need

Want to look before it runs? `$env:EXAKIT_DRY_RUN = "1"` first. It downloads and plans, installs nothing.

## Verify

```powershell
exakit status                                       # Status: running
```

Any SQL client (DBeaver etc.) connects with host `127.0.0.1`, port `8563`, user `sys`. The password location is shown by `exakit info`.

## Load data

The installer loads the sample data for you. Open the menu again any time, for more datasets or your own files:

```powershell
exakit data-load
```

## Connect your AI assistant

The installer does this too. To run it again: `exakit mcp-setup`. Details in the [QUICKSTART](../QUICKSTART.md).

Restart your AI client, then continue with the [first workflow](../demo/first-revenue-analysis.md).

## Windows notes

| Issue | Fix |
|---|---|
| "Docker is installed but not running" | Start Docker Desktop, wait for the whale icon to settle, re-run |
| "Port 8563 is already in use" | Stop the other application, or set `$env:EXAKIT_DB_PORT = "8564"` and re-run |
| Script execution policy complaints | The installer affects only its own script. Nothing system-wide is changed |
| Corporate proxy | Set `$env:HTTPS_PROXY` before running |
| After a reboot | `exakit start` brings the database back with all data intact |
| Windows on ARM | The database and Python driver install. exapump needs an x86_64 Windows machine |

Remove everything: `exakit uninstall`.
