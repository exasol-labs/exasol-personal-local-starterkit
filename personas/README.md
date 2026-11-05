# Personas

A persona is a named set of the answers the installer already takes from the
environment - which datasets to load, which AI clients to connect, which
marketplace add-ons to offer. The rules live in one Python service,
`setup/lib/persona_service.py`, which the shell and PowerShell installers both
call. The interactive persona and marketplace choices use the Textual screen
in `marketplace/ui.py`, drawn exactly as the kit's own checkbox menu and table,
in the terminal's colours: a click ticks or unticks a row, Enter moves on, and
the scroll wheel still scrolls the terminal. The shell menus remain the
recovery path and take clicks the same way.

The kit ships the two BRD persona baselines, both on Walmart weekly sales and Amazon sales,
each downloaded from the kit's `datasets` release only when it is loaded,
and General, the kit's own samples, bundled with the kit and loaded offline:

| Persona | Datasets | AI clients | Add-ons | First notebook |
|---|---|---|---|---|
| `data-scientist` (Data Scientist) | `walmart_sales`, `amazon_sales` | all detected | `dash-server`, `notebook` | `data-scientist/00_quickstart.ipynb` |
| `ml-engineer` (ML Engineer) | `walmart_sales`, `amazon_sales` | all detected | `notebook`, `udf-devkit` | `ml-engineer/00_quickstart.ipynb` |
| `general` (General) | `tpch`, `energy`, `weather` | all detected | - | - |

General is ticked to begin with and combines with the others like any persona:
tick all three to load every dataset and get every persona's add-ons.

The Data Scientist gets Dash Server first, then the notebook: the notebooks' Share step
publishes a dashboard there, querying as the kit's read-only user. The ML Engineer persona
also starts local MLflow and installs the selected UDF runtime. JSON Tables stays available
separately: `exakit marketplace json-tables` adds CLI JSON ingestion (the notebook own-file
loader handles flat JSON without it). To select the extended bundle during install, set
`EXAKIT_MARKETPLACE_ADDONS=dash-server,notebook,json-tables` for Data Scientist,
or `EXAKIT_MARKETPLACE_ADDONS=notebook,json-tables,udf-devkit` for ML Engineer.

Pick one with `EXAKIT_PERSONA` on the install command:

```bash
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_PERSONA=data-scientist sh
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_PERSONA=ml-engineer sh
```

**On a terminal without `EXAKIT_PERSONA`** the install asks, after the parts
everyone needs (the database, exapump, the AI bridge):

1. *What will you use this machine for?* - Data Scientist, ML Engineer and
   General, as many as you like; General is ticked to begin with.
2. *Data to load* - one table: **Sample datasets** is the parent row with the
   datasets under it (a For column names the persona each is for, and the
   picked personas' datasets are ticked), then your own file or folder, an
   external source (shown, coming soon) and Skip. Enter starts the load in the
   same table. With General, the kit's own samples are ticked: TPC-H, energy,
   weather.
3. *Add-ons for your personas* - only their add-ons, ticked; Enter installs
   them, Skip backs out. The notebook add-on's tools (JupyterLab and
   Marimo) are child rows under its row in the same table, each saying what
   will become of it, ticked as `notebook_tools` says (both otherwise);
   untick one there. Then the connection panel and "Your starter kit is
   ready to use" close the install. The rest of the marketplace is one command
   away: `exakit marketplace`. (General brings no add-ons, so with General alone
   the marketplace offer comes after the panel.)

Nothing is loaded or installed without that screen. Without a terminal and
without `EXAKIT_PERSONA`, the kit installs on its own with TPC-H, energy and
weather, as before.

On an installed kit: `exakit persona list`, `exakit persona show <id>`,
`exakit persona add <id>` and `exakit persona plan [<id>] [--json]`, which
shows what a persona brings and what of it is still pending - after an
`EXAKIT_PERSONA` install, nothing (AC-P1.1).

`exakit persona add ml-engineer` on a kit set up as Data Scientist makes it both:
the record becomes `data-scientist,ml-engineer`, and what the two bring that is
not here yet comes in - nothing is asked. Three steps, headed like the
installer's (*Step 1/3 Sample data*, *2/3 AI clients*, *3/3 Add-ons*), each
showing the installer's own table with its defaults ticked and filling it in as
it works; what is already here is named in one line instead (*Already loaded:
Amazon sales*). Without a terminal the same happens in plain lines.
A part that fails does not stop the others; the closing line says *Persona
added: Data Scientist + ML Engineer*, or names each part that did not finish and
the command that retries it (exit 1). `apply` is the same command, and `--yes`
is accepted.

`exakit persona remove data-scientist` removes only that membership from the
kit record. It leaves datasets, notebooks, add-ons and their ownership receipts
in place because another persona or the user may still use them. Repeating the
command changes nothing. Use the add-on uninstall command separately if you
want to remove a kit-owned component.

An answer you give yourself always wins for that one variable:
`EXAKIT_PERSONA=data-scientist EXAKIT_DATASETS=walmart_sales` loads only
the Walmart dataset and keeps the persona's clients and add-ons. Several
personas together load each dataset and offer each add-on once; one naming
`all` wins.

## Adding a persona

One file, `personas/<id>.json`, and no code in the installers. The new entry appears at the position given by `order` when `visible` and `picker` are true. Try it first, in a sandbox that changes
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
| `visible` | `true` to offer new selections; `false` hides it and refuses a new named add, while preserving the definition and an existing installation |
| `default` | `true` to tick it there to begin with (General does) |
| `order` | where the question lists it (lowest first) |
| `datasets` | a list of bundled dataset ids, or `"all"` / `"none"` |
| `mcp_clients` | `"all"`, `"skip"`, or a list of client ids |
| `addons` | a list of marketplace add-on ids, or `"all"` / `"none"` |
| `notebook_tools` | optional: which notebook tools to tick, e.g. `["jupyterlab", "marimo"]` |
| `services` | optional: kit services the persona starts at login, e.g. `["mlflow"]` (ML Engineer) |
| `udf_language` | optional: `python` or `rust`, the UDF language udf-devkit sets up first (sets `EXAKIT_UDF_LANGUAGE`) |
| `first_prompt` | optional: what to do first, shown by `exakit persona show` (the shipped ones open their quickstart notebook) |

No secrets and no machine paths: a persona names things, it never holds them.
`tests/personas.sh` validates every file against the datasets and add-ons this
kit ships; `tests/personas-ps.ps1` checks the PowerShell side reads them the
same way.
