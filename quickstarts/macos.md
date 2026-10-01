# Quickstart: macOS

This guide takes you from a bare Mac to a local Exasol database with an AI assistant connected. On macOS the database runs in a lightweight VM that Exasol Personal manages for you, so there is nothing to install or configure first.

## What you need

- macOS on Apple Silicon or Intel. One optional add-on, JSON Tables, runs on
  Apple Silicon only; everything else runs on both.
- 8 GB+ RAM, ~20 GB free disk

The install runs unattended, and the database is usually up in under 2 minutes. The steps after it (sample data, the AI bridge and the Python driver) take longer.

To check your Mac before you start (this installs nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

You don't need Python on your Mac. The installer brings its own.

## Install

```bash
curl https://www.exasol.com/install/starter-kit.sh | sh
```

What happens, in order:

1. The installer checks your Mac (chip, memory, disk) and shows the plan
2. The database is deployed and started
3. exapump (the data tool) is installed and tested
4. The sample data is loaded and verified
5. The AI bridge is set up with a read-only database login, and your AI clients are connected
6. You get a connection panel with the details you need

You can interrupt and re-run the install at any point. Completed steps are skipped.

## Verify

```bash
exakit status
```

## Load data

The installer loads the sample data for you. To load more datasets or your own files later, open the menu again:

```bash
exakit data-load
```

## Connect your AI assistant

The installer does this too. To run it again, use `exakit mcp-setup`. The [QUICKSTART](../QUICKSTART.md) has the details.

After setup, restart the AI client and look for an MCP server named `exasol`.

Then try the [example questions](../data/example-questions.md).

## Keeping it current

```bash
exakit version         # installed vs the versions the maintainers advertise
exakit update          # the quick ones in seconds, then it asks before touching the database
exakit update --yes    # unattended: applies a waiting database update without asking
```

When a database update is waiting, `exakit update` asks `Stop the database and update the
runtime now? [y/N]`, and `y` runs the whole sequence for you. A major Exasol
Personal version never starts that way. It is a data migration, so it goes
through the backup-gated route, one step at a time:

```bash
exakit update runtime --plan     # what the migration involves, changes nothing
exakit update runtime --backup   # take the backup the migration is gated on
exakit update runtime --apply    # perform the migration
```

For the full detail, see [Staying up to date](../README.md#staying-up-to-date).

## macOS notes

| Issue | Fix |
|---|---|
| "This machine is not compatible: Exasol Personal needs at least 8 GB RAM" | Exasol Personal needs 8 GB RAM and 20 GB free disk. The installer stops instead of leaving a half-finished install |
| `python3` triggers a developer-tools popup | Dismiss it. `/usr/bin/python3` is only a stub until Xcode's command line tools are installed, and the installer brings its own Python and carries on. You don't need to re-run anything |
| `~/.local/bin` not on PATH warning | Add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc`. If you switched your login shell to bash, add it to `~/.bash_profile` instead, because macOS terminals never read `~/.bashrc` |
| Company-managed Mac blocks virtualization | Use a machine you control |
| `exakit start` keeps failing after a crash or hard power-off | `exakit status` says `interrupted`. The launcher cannot restart that deployment, so rebuild it with `exakit repair-runtime`. **This deletes the database content.** The bundled sample data is reloaded, but anything you loaded yourself is not |
| On an Intel Mac, `exakit data-load` will not take a `.json` file | The JSON Tables add-on is published for Apple silicon only. Everything else in the kit runs on both. Convert the file to CSV or Parquet, or load it from an Apple silicon Mac |
| Where did everything go? | Commands: `~/.local/bin` · kit state and credentials: `~/.exasol-starter-kit` · the database itself (deployment, data, `secrets.json`): `~/.exasol/personal/deployments/default` |

You can stop and start the database at any time with `exakit stop` and `exakit start`. Your data is kept.

To remove everything, run `exakit uninstall`.
