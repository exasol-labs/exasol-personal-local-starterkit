# Personas

A persona is a named set of the answers the installer already takes from the
environment - which datasets to load, which AI clients to connect, which
marketplace add-ons to offer. The rules live in one Python service,
`setup/lib/persona_service.py`, which the shell and PowerShell installers both
call; the screens are the kit's own menus.

The kit ships the two personas of the requirements document (TDD/BRD v0.3,
P-1), both on the two reference datasets, Pharma and Banking:

| Persona | Datasets | AI clients | Add-ons | First notebook |
|---|---|---|---|---|
| `data-scientist` (AI Scientist) | `pharma_trials`, `banking_complaints` | all detected | `notebook` | `data-scientist/00_quickstart.ipynb` |
| `ml-engineer` (ML Engineer) | `pharma_trials`, `banking_complaints` | all detected | `notebook`, `udf-devkit` | `ml-engineer/00_quickstart.ipynb` |

Pick one with `EXAKIT_PERSONA` on the install command:

```bash
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_PERSONA=data-scientist sh
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_PERSONA=ml-engineer sh
```

**On a terminal without `EXAKIT_PERSONA`** the install asks, after the parts
everyone needs (the database, exapump, the AI bridge):

1. *What will you use this machine for?* - AI Scientist, ML Engineer (one or
   both), or None - just the kit, which is ticked to begin with.
2. *Data to load* - sample datasets, your own file or folder, or an external
   source (shown, coming soon). The samples come next, a For column naming the
   persona each is for, and the picked personas' datasets ticked. With None,
   the kit's own samples are ticked: TPC-H, energy, weather.
3. At the end, *Add-ons for your personas* - only their add-ons, ticked; Enter
   installs them, Skip backs out. The rest of the marketplace is one command
   away: `exakit marketplace`.

Nothing is loaded or installed without that screen. Without a terminal and
without `EXAKIT_PERSONA`, the kit installs on its own with TPC-H, energy and
weather, as before.

On an installed kit: `exakit persona list`, `exakit persona show <id>`,
`exakit persona apply <id>` (asks first; `--yes` for a script; without a
terminal it changes nothing without `--yes`) and `exakit persona plan [<id>]
[--json]`, which shows what a persona brings and what of it is still pending -
after an `EXAKIT_PERSONA` install, nothing (AC-P1.1).

An answer you give yourself always wins for that one variable:
`EXAKIT_PERSONA=data-scientist EXAKIT_DATASETS=banking_complaints` loads only
the Banking dataset and keeps the persona's clients and add-ons. Several
personas together load each dataset and offer each add-on once; one naming
`all` wins.

## Adding a persona

One file, `personas/<id>.json`, and no code in the installers (two lines in `tests/personas.sh` and `tests/personas-ps.ps1` list the shipped personas and must name it). Try it first, in a sandbox that changes
nothing (`examples/analyst.json` is a ready-made one to start from):

```bash
bash tools/try_persona.sh personas/examples/analyst.json          # the checks, the question, the answers, the data table
bash tools/try_persona.sh personas/examples/analyst.json --ask    # ...then the install question, live
```

The keys:

| Key | Value |
|---|---|
| `schema_version` | `1` |
| `id` | the file name without `.json` |
| `title`, `summary` | what `exakit persona list` and the install question show |
| `picker` | `true` to offer it in the install question |
| `default` | `true` to tick it there to begin with (neither shipped persona does: None is ticked) |
| `order` | where the question lists it (lowest first) |
| `datasets` | a list of bundled dataset ids, or `"all"` / `"none"` |
| `mcp_clients` | `"all"`, `"skip"`, or a list of client ids |
| `addons` | a list of marketplace add-on ids, or `"all"` / `"none"` |
| `notebook_tools` | optional: which notebook tools to tick, e.g. `["jupyterlab", "marimo"]` |
| `first_prompt` | optional: what to do first, shown by `exakit persona show` (the shipped ones open their quickstart notebook) |

No secrets and no machine paths: a persona names things, it never holds them.
`tests/personas.sh` validates every file against the datasets and add-ons this
kit ships; `tests/personas-ps.ps1` checks the PowerShell side reads them the
same way.
