# Quickstart: WSL

Gets you from Windows to a local Exasol database with an AI assistant connected, using **WSL (Windows Subsystem for Linux)**. Prefer staying in PowerShell? Use the [Windows Docker quickstart](windows-docker.md) instead.

## What you need

- Windows 10/11 with **WSL 2** and a Linux distro (Ubuntu is fine):
  ```powershell
  wsl --install        # from an admin PowerShell, if you do not have WSL yet
  ```
- **Docker available inside WSL**. Easiest via Docker Desktop with WSL integration turned on (Docker Desktop, Settings, Resources, WSL integration, enable your distro). Podman works too.
- 4 GB+ RAM, ~10 GB free disk

Check from a WSL terminal (installs nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

Every ✗ line tells you what to fix. The usual one is Docker Desktop not running or WSL integration not enabled.

## Install (inside the WSL terminal)

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | sh
```

What happens, in order:

1. WSL is detected and the plan is shown
2. The database container is pulled and started, reachable only from your machine
3. The database is ready, usually in under 2 minutes
4. exapump (the data tool) is installed, the sample data is loaded and verified
5. The AI bridge is set up with a read-only database login, and your AI clients are connected
6. You get a connection panel with everything you need

## Verify

```bash
exakit status
```

## Load data

The installer loads the sample data for you. Open the menu again any time, for more datasets or your own files:

```bash
exakit data-load
```

## Connect your AI assistant

The installer does this too. To run it again: `exakit mcp-setup`. Details in the [QUICKSTART](../QUICKSTART.md).

Windows apps can reach the database directly at `127.0.0.1:8563`. If you configure a Windows desktop app from inside WSL, make sure its config uses a launcher command Windows can run. Two options:

- Install `uv` on Windows and use the path from `(Get-Command uvx).Source` as the command
- Or keep the same settings and wrap the launch as `wsl uvx exasol-mcp-server@<version>`

Then continue with the [first workflow](../demo/first-revenue-analysis.md).

## WSL notes

| Issue | Fix |
|---|---|
| "No container runtime found" inside WSL | Start Docker Desktop on Windows and enable WSL integration for your distro, then re-run |
| Docker works in PowerShell but not in WSL | Same fix: WSL integration is per distro (Settings, Resources, WSL integration) |
| Port 8563 busy on the Windows side | Something on Windows holds it. Stop it, or re-run with `EXAKIT_DB_PORT=8564` |
| Database state after `wsl --shutdown` | Safe. Your data is kept. `exakit start` brings it back |
| WSL clock drift after laptop sleep | If TLS or downloads act strange: `sudo hwclock -s` |

Remove everything: `exakit uninstall` inside WSL.
