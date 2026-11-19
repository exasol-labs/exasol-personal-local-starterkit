# Personas

A persona is a named set of the answers the installer already takes from the
environment - which datasets to load, which AI clients to connect, which
marketplace add-ons to offer. The rules live in one Python service,
`setup/lib/persona_service.py`, which the shell and PowerShell installers both
call.

This release ships one persona, **General** (`general.json`): the kit's two
sample datasets (`retail_sales`, `bank_transaction`) and every AI client the
machine has. Every install applies it without asking
(`marketplace/installer_flow.py`), so a fresh install ticks those two datasets
in the *Data to load* table. Nothing is loaded or installed without that
table; without a terminal the install loads them on its own.

| Persona | Datasets | AI clients | Add-ons |
|---|---|---|---|
| `general` (General) | `retail_sales`, `bank_transaction` | all detected | - |

An answer you give yourself always wins for that one variable:
`EXAKIT_PERSONA=general EXAKIT_DATASETS=retail_sales` loads only the retail
dataset and keeps the persona's AI clients.

On an installed kit `exakit persona list`, `show <id>`, `plan [<id>] [--json]`,
`add <id>` and `remove <id>` work on these files (the command is hidden from
`exakit help` in this release).

## The file

One file, `personas/<id>.json`, and no code in the installers:

| Key | Value |
|---|---|
| `schema_version` | `1` |
| `id` | the file name without `.json` |
| `title`, `summary` | what `exakit persona list` shows |
| `picker` | `true` to offer it in the persona question |
| `visible` | `true` to offer new selections; `false` hides it and refuses a new named add, while preserving the definition and an existing installation |
| `default` | `true` to tick it to begin with (General does) |
| `order` | where the question lists it (lowest first) |
| `datasets` | a list of bundled dataset ids, or `"all"` / `"none"` |
| `mcp_clients` | `"all"`, `"skip"`, or a list of client ids |
| `addons` | a list of marketplace add-on ids, or `"all"` / `"none"` |
| `addon_reasons` | optional: `{"<add-on id>": "one line, at most 90 characters"}` - what each add-on does for the persona, shown in place of the add-on repository's About while its add-ons are offered |
| `first_prompt` | optional: what to do first, shown by `exakit persona show` |

No secrets and no machine paths: a persona names things, it never holds them.
`tests/personas.sh` validates every file against the datasets and add-ons this
kit ships; `tests/personas-ps.ps1` checks the PowerShell side reads them the
same way.
