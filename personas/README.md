# Personas

A persona is a named set of the answers the installer already takes from the
environment - which datasets to load, which AI clients to connect, which
marketplace add-ons to offer. The rules live in one Python service,
`setup/lib/persona_service.py`, which the shell and PowerShell installers both
call; the screens are the kit's own menus.

**On a terminal** the install asks, after the parts everyone needs (the
database, exapump, the AI bridge):

1. *What will you use this machine for?* - tick one persona or several
   (General is ticked to begin with).
2. *Data to load* - sample datasets, your own file or folder, or an external
   source (coming soon). The samples come next, each named with the personas
   it is for, and the personas' own datasets ticked.
3. At the end, *Add-ons for your personas* - only their add-ons, ticked;
   Enter installs them, Skip backs out. The rest of the marketplace is one
   command away: `exakit marketplace`.

Nothing is loaded or installed without that screen. **Without a terminal**,
name the personas instead and their answers are taken as given:

```bash
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_PERSONA=ml-engineer sh
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_PERSONA=general,data-scientist sh
```

or later, on an installed kit: `exakit persona apply ml-engineer`.

An answer you give yourself always wins for that one variable:
`EXAKIT_PERSONA=data-scientist EXAKIT_DATASETS=fda_recalls` loads only the
FDA dataset and keeps the persona's clients and add-ons. Several personas
together load each dataset and offer each add-on once; one naming `all` wins.

| Persona | Datasets | AI clients | Add-ons |
|---|---|---|---|
| `general` | `tpch`, `energy`, `weather` | all detected | none |
| `data-scientist` (AI / Data Scientist) | `fda_recalls`, `banking_complaints` | all detected | `notebook`, `dash-server`, `json-tables` |
| `ml-engineer` | `bank_marketing`, `pharma_trials` | all detected | `notebook`, `udf-devkit` |

## Adding a persona

One file, `personas/<id>.json`, and no code. Try it first, in a sandbox that changes
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
| `default` | `true` to tick it there to begin with (General does) |
| `order` | where the question lists it (lowest first) |
| `datasets` | a list of bundled dataset ids, or `"all"` / `"none"` |
| `mcp_clients` | `"all"`, `"skip"`, or a list of client ids |
| `addons` | a list of marketplace add-on ids, or `"all"` / `"none"` |
| `notebook_tools` | optional: which notebook tools to tick, e.g. `["jupyterlab", "marimo"]` |

No secrets and no machine paths: a persona names things, it never holds them.
`tests/personas.sh` validates every file against the datasets and add-ons this
kit ships; `tests/personas-ps.ps1` checks the PowerShell side reads them the
same way.
