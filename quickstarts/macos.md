# Quickstart: macOS

Gets you from a bare Mac to a local Exasol database with an AI assistant connected. On macOS the database runs natively. No Docker needed.

## What you need

- macOS on Apple Silicon or Intel
- 8 GB+ RAM, ~20 GB free disk

The install runs unattended and usually finishes in **under 2 minutes**.

Check before you start (installs nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

No Python on your Mac? That is fine. The installer brings its own.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | sh
```

What happens, in order:

1. Your Mac is checked (chip, memory, disk) and the plan is shown
2. The database is deployed and started
3. exapump (the data tool) is installed and tested
4. The sample data is loaded and verified
5. The AI bridge is set up with a read-only database login, and your AI clients are connected
6. You get a connection panel with everything you need

Safe to interrupt and re-run at any point. Completed steps are skipped.

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

After setup, restart the AI client and look for an MCP server named `exasol`.

Then continue with the [first workflow](../demo/first-revenue-analysis.md).

## macOS notes

| Issue | Fix |
|---|---|
| "This machine does not meet the requirements" | Exasol Personal needs 8 GB RAM. The installer stops rather than half-installing |
| `python3` triggers a developer-tools popup | Accept it, then re-run |
| `~/.local/bin` not on PATH warning | Add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` |
| Company-managed Mac blocks virtualization | Use a machine you control |
| Where did everything go? | Commands: `~/.local/bin` · state and passwords: `~/.exasol-starter-kit` |

Stop and start any time with `exakit stop` and `exakit start`. Your data is kept.

Remove everything: `exakit uninstall`.
