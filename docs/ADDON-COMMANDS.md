# Add-on commands, parameters and examples

The installed kit carries the reference for its own version. These forms work without installing an add-on or starting a service:

```sh
exakit --help json-tables
exakit help dash-server
exakit uninstall --help
exakit help json-tables --json
exakit marketplace --list --json
```

Each add-on page shows command syntax, positional arguments, options, defaults, valid values, examples and environment settings. Individual command pages also give their behavior and available exit codes. Flags belong to the command that lists them. Quote file paths containing spaces.

## The same discovery flow for every add-on

Use the same words on macOS, Linux and PowerShell (Windows uses the `exakit.cmd` launcher). Substitute a registered add-on ID for `dash-server`:

```sh
exakit marketplace --list --json
exakit help dash-server
exakit --help dash-server
exakit help dash-server --json
exakit marketplace dash-server
exakit update dash-server
exakit uninstall dash-server --dry-run
```

The human help forms show the same page. Adding `--json` to any of them returns the same document, including a `management` object with install, help, JSON help, update, uninstall preview and uninstall commands. Reading help never installs an add-on. A page describes the shipped interface; use `marketplace --list --json` or `version --json` to discover what is installed and who owns it.

Agents should discover commands before invoking them:

```sh
exakit catalog --json
exakit help uninstall --json
exakit help "exakit uninstall" --json
exakit uninstall --help --json
exakit help exasol-json-tables ingest --json
```

Each catalog row includes an exact `invocation`, `usage`, `source`, `hidden` flag and runnable `help_command`; documented parameters, defaults, choices, examples, warnings and exit codes accompany it. Existing field names remain compatible with schema version 1. Internal repair commands remain marked `hidden` and are not for normal agent use.

Command help resolves command names and their documented children. It does not search descriptions or silently substitute a parent for an unknown action. Unknown help returns exit **2**; JSON carries `ok: false`, an empty `commands` array and the remedy `exakit catalog --json`. Use `exakit catalog <text> --json` for a keyword search. A command family can return several rows; an exact leaf command returns its own row. The input spelling is retained in `search`, so compare the `commands` array when comparing equivalent spellings.

Native tools that forward arguments, such as dbt, point to their own installed-version help. A documented add-on ID does not imply that it is an executable subcommand: install through `marketplace`, then use the operations listed in its page.

## Find each add-on's full reference

| Add-on | Help command | Main operation |
|---|---|---|
| Dash Server | `exakit --help dash-server` | Managed dashboard hosting and its MCP endpoint |
| JSON Tables | `exakit --help json-tables` | JSON/NDJSON loading and native ingest parameters |
| Semantic Views | `exakit --help semantic-views` | The database-native semantic layer, installed into the local database |
| dbt-exasol | `exakit --help dbt-exasol` | dbt with the kit's private connection profile |
| Exasol Scheduler | `exakit --help exasol-scheduler` | SQL job service, schedule examples and logs |
| Exasol for VS Code | `exakit --help exasol-vscode` | Extension install/update and connection settings |

The add-on pages document the kit-managed interface. For a package's full version-specific native CLI, use its own help, for example `dbt-exasol run --help` or `exasol-json-tables ingest --help`. The Dash launcher and VS Code extension do not have extra kit-specific flags; use their listed lifecycle commands and settings.

## Install, update, inspect and remove

```sh
exakit marketplace dash-server               # install one named add-on
exakit marketplace dash-server json-tables   # install only these IDs
exakit marketplace --list --json             # list only; installs nothing
exakit version --json                        # versions and component ownership
exakit update dash-server                    # refresh a kit-owned add-on
exakit uninstall dash-server --dry-run       # preview one add-on's removal
exakit uninstall dash-server                 # confirm removal of that add-on
```

Bare `marketplace` opens a chooser on a terminal and installs nothing without one. `--list`/`--json` are read-only and cannot be combined with installation IDs. An existing user-owned component stays user-owned and is preserved during update/removal. **`exakit uninstall --yes` without an add-on ID removes the full kit and a kit-owned database's data**; use a named add-on for selective removal.

Logs have separate listing and content forms:

```sh
exakit logs --json
exakit logs setup --lines 100 -f
exakit logs dash-server --path
exakit logs exasol-scheduler --lines 100
```

`--lines`/`-n` defaults to 200, `-f`/`--follow` continues until Ctrl+C, and `--path` prints the filename. `--json` lists targets; it does not return one target's contents.
