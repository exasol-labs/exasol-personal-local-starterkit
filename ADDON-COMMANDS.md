# Add-on commands, parameters and examples

The installed kit carries the reference for its own version. These forms work without installing an add-on or starting a service:

```sh
exakit --help udf-devkit
exakit help notebook
exakit udf-use --help
exakit model put --help
exakit help udf-devkit --json
exakit marketplace --list --json
```

Each add-on page now shows command syntax, positional arguments, options, defaults, valid values, examples and environment settings. Individual command pages also give their behavior and available exit codes. Flags belong to the command that lists them: for example, `--replace` belongs to `model put`, not `udf-use`. A requirements file is a positional argument, **not a `--requirements` flag**. Quote file paths containing spaces.

## Find each add-on's full reference

| Add-on | Help command | Main operation |
|---|---|---|
| Notebook | `exakit --help notebook` | JupyterLab, Marimo and Positron setup/open/check/stop |
| UDF devkit | `exakit --help udf-devkit` | Python/ML/Rust containers, model files, MLflow and Rust projects |
| Dash Server | `exakit --help dash-server` | Managed dashboard hosting and its MCP endpoint |
| JSON Tables | `exakit --help json-tables` | JSON/NDJSON loading and native ingest parameters |
| dbt-exasol | `exakit --help dbt-exasol` | dbt with the kit's private connection profile |
| Exasol Scheduler | `exakit --help exasol-scheduler` | SQL job service, schedule examples and logs |
| Exasol for VS Code | `exakit --help exasol-vscode` | Extension install/update and connection settings |

The add-on pages document the kit-managed interface. For a package's full version-specific native CLI, use its own help, for example `dbt-exasol run --help` or `exasol-json-tables ingest --help`. The Dash launcher and VS Code extension do not have extra kit-specific flags; use their listed lifecycle commands and settings.

## Install, update, inspect and remove

```sh
exakit marketplace notebook             # install one named add-on
exakit marketplace notebook json-tables # install only these IDs
exakit marketplace --list --json         # list only; installs nothing
exakit version --json                    # versions and component ownership
exakit update notebook                   # refresh a kit-owned add-on
exakit uninstall notebook --dry-run      # preview one add-on's removal
exakit uninstall notebook                # confirm removal of that add-on
```

Bare `marketplace` opens a chooser on a terminal and installs nothing without one. `--list`/`--json` are read-only and cannot be combined with installation IDs. An existing user-owned component stays user-owned and is preserved during update/removal. **`exakit uninstall --yes` without an add-on ID removes the full kit and a kit-owned database's data**; use a named add-on for selective removal.

Logs have separate listing and content forms:

```sh
exakit logs --json
exakit logs setup --lines 100 -f
exakit logs notebook --path
exakit logs udf-devkit-mlflow --lines 100
```

`--lines`/`-n` defaults to 200, `-f`/`--follow` continues until Ctrl+C, and `--path` prints the filename. `--json` lists targets; it does not return one target's contents.

## UDF devkit: choose the operation

**Container installation restarts the database.** The commands ask first on a terminal; `--yes` confirms it, and unattended container installation proceeds. Existing aliases can be checked without a reinstall unless explicitly forced.

```sh
exakit udf-use --list
exakit udf-setup --language python --json
exakit udf-use default --language python --yes --json
exakit udf-setup --language rust --yes --json
exakit udf-use ./custom.tar.gz --alias PYTHON3_CUSTOM --language python --yes
exakit udf-build ./requirements.txt --alias PYTHON3_CUSTOM --yes
exakit udf-file ./lookup.csv lookup/lookup.csv
```

- `udf-setup` prepares the official `PYTHON3` or pinned `RUST` container. `--force` reinstalls an existing container; it is not needed for an ordinary check.
- `udf-use default` chooses the verified matrix row for the database architecture/version: `PYTHON3_ML` for Python, `RUST` for Rust. `--alias` applies to a **custom archive**, not the pinned default. `--list` prints the launcher's human container listing; combining it with `--json` does not create a JSON listing.
- `udf-build` takes a real requirements file containing pinned lines such as `scikit-learn==1.9.0`. It needs Notebook, Docker or Podman and about 25 GB of free disk. A source build can take considerably longer than using a prebuilt container.
- `udf-file` takes a source file and an optional relative bucket path. Its default destination is the source filename; it prints the `/buckets/...` path to use inside a UDF.

The notebook Python and the Python running inside a database UDF are separate environments. Installing scikit-learn in the notebook does not install it in a UDF; the `PYTHON3_ML` runtime provides that database-side package set.

Models have their own arguments:

```sh
exakit model inspect ./churn.pkl --json
exakit model put ./churn.pkl --yes --json
exakit model list --json
exakit model prune --older-than 30 --json
exakit model template --json
```

Use `model put --yes` only when you trust the model's source: it confirms an unproven pickle/joblib file. `--replace` separately permits a different file with the same name. `model prune` is a preview until `--yes` is supplied; `model rm <name>` removes one recorded model. See the command's `--help` before either removal.

```sh
exakit mlflow start --port 5000 --json
exakit mlflow status --json
exakit mlflow replay --timeout 5 --json
exakit mlflow stop --disable
exakit rust-udf new score_model --coefficients ./coefficients.json
exakit rust-udf build score_model --json
exakit rust-udf deploy score_model --schema EXAKIT_SCORING --json
```

`mlflow --port` belongs to `start`; `--disable` belongs to `stop`. Replay also accepts `--tracking-uri`, `--tracking-dir` and a health-check `--timeout` (default 3 seconds). Rust `--coefficients` belongs to `new`, and `--schema` belongs to `deploy` (default `EXAKIT_SCORING`). These flows do not configure an external database source.

## Notebook and other add-ons

```sh
exakit notebook check
exakit notebook marimo --port 2720 --no-browser
exakit notebook stop marimo
exakit start dash-server
exakit status --json
exakit data-load ./events.json
dbt-exasol debug
dbt-exasol run --help
exakit start exasol-scheduler
exakit logs exasol-scheduler -f
exakit marketplace exasol-vscode
exakit info
```

Notebook ports must be 1024–65535. Defaults are JupyterLab 8888 and Marimo 2718; a running server keeps its current port, so stop it before moving it. Positron must already be installed. Dash Server's default is 5100; read the actual URL from `exakit status`. dbt needs a project with the kit's `exasol_starter_kit` profile. Scheduler jobs are rows in `SCHED.SCHED_TASKS`; its help page shows the SQL and cron/timezone format. VS Code connection settings are entered in the editor using `exakit info`.

Use environment settings before the command. For example:

```sh
EXAKIT_UDF_CONTAINERS_MIRROR=/path/to/verified-assets exakit udf-use default
```

On PowerShell:

```powershell
$env:EXAKIT_UDF_CONTAINERS_MIRROR = 'C:\verified-assets'
exakit udf-use default
Remove-Item Env:EXAKIT_UDF_CONTAINERS_MIRROR
```

Use the Environment section for each add-on's accepted variables and defaults. A local container mirror still has to match the pinned size and SHA-256.

## Why the first UDF installation took 667+ seconds

The completed Mac install log on 29 October 2026 records UDF devkit starting at **12:12:06 IST** and finishing at **12:23:24 IST**, about **11 minutes 18 seconds**:

| Work | Observed duration |
|---|---:|
| Official Python container installation and restart | 3m 51s |
| 842 MB ML container download and verification | 5m 37s |
| Prepare the isolated ML alias archive | 23s |
| ML container installation and restart | 1m 05s |
| Readiness, package checks and remaining setup | 22s |

The old **64%** was the ceiling of a time-based generic `installing` segment. It was not a measured download percentage and did not mean the installer had stopped. The row now reports distinct download, checksum, archive preparation, container installation, database restart and package-check stages. Percentages remain milestone estimates.

This run did not reuse a verified ML archive, so it downloaded the large file. Later runs reuse installed aliases and verified files under `$EXAKIT_HOME/cache/containers`; a clean uninstall removes the kit's cache. Keeping the cache or using a verified local mirror avoids that download. The MLflow service can be prepared separately after the add-on step when the ML Engineer persona finishes.

These timings are one observed run, not a promised installation duration. The help/progress update does not reinstall those containers or restart the database.
