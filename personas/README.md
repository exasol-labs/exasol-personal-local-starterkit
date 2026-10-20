# Personas

A persona is a named set of the answers the installer already takes from the
environment - which datasets to load, which AI clients to connect, which
marketplace add-ons to install. Pick one at install time:

```bash
curl -fsSL https://www.exasol.com/install/starter-kit.sh | EXAKIT_PERSONA=ml-engineer sh
```

or later, on an installed kit: `exakit persona apply ml-engineer`.

An answer you give yourself always wins for that one variable:
`EXAKIT_PERSONA=data-scientist EXAKIT_DATASETS=pharma_trials` loads only the
pharma dataset and keeps the persona's clients and add-ons.

| Persona | Datasets | AI clients | Add-ons |
|---|---|---|---|
| `data-scientist` | `pharma_trials`, `banking_complaints` | all detected | `notebook` |
| `ml-engineer` | `pharma_trials`, `banking_complaints` | all detected | `notebook`, `udf-devkit` |

## Adding a persona

One file, `personas/<id>.json`, and no code:

| Key | Value |
|---|---|
| `schema_version` | `1` |
| `id` | the file name without `.json` |
| `title`, `summary` | what `exakit persona list` shows |
| `datasets` | a list of bundled dataset ids, or `"all"` / `"none"` |
| `mcp_clients` | `"all"`, `"skip"`, or a list of client ids |
| `addons` | a list of marketplace add-on ids, or `"all"` / `"none"` |

No secrets and no machine paths: a persona names things, it never holds them.
`tests/personas.sh` validates every file against the datasets and add-ons this
kit ships.
