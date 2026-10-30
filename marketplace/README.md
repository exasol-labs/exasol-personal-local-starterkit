# Persona marketplace development

`marketplace/catalog.json` is the ordered add-on catalog. Each row has an ID,
label, `visible` switch, fallback version, and backend. Set `visible` to `false`
to hide an add-on from new choices without deleting its definition or installed
receipts. Set it back to `true` to offer it again. A persona has the same
switch in `personas/<id>.json`. Existing installations remain inspectable,
updatable, and removable while hidden.

Root `versions.json` remains the advertised and update version source. The
catalog's `default_version` is only the offline fallback. The version bump
workflow and JSON Tables packaging workflow update both together.
The platform adapters pass their validated active versions document to Python,
so a cached version and its asset checksums stay paired.
`marketplace/defaults.env` pins the Textual UI runtime. Package and artifact
requirements belong in each add-on's Python
module under `marketplace/addons/`; the MLflow server version is pinned under
`components.udf-devkit.mlflow_server` in `versions.json`.
Python add-on environments use `EXAKIT_MANAGED_PYTHON_VERSION` when set, matching
the Textual launcher; the kit defaults to Python 3.12.

The installer keeps its database, exapump, MCP, and pyexasol stages. At the
persona boundary, it calls `marketplace/launch.py` for an interactive Textual
choice. Add-on lifecycle operations call `marketplace/service.py`. Public
`persona add` sequences the existing data/MCP/marketplace commands in
`persona_apply.py`. `apply.py` owns the marketplace installation sequence,
while Textual displays its activity and progress in the selection screen.
The initial installer persona/data flow and platform progress renderers still
have small shell and PowerShell adapters; further consolidation is tracked in
`tasks.md`. Python add-ons share receipt locking, logging, download, and
process helpers in `runtime.py` and `process.py`.

`service.py` is the host boundary for a later Exasol Personal sidecar backend.
The current add-ons remain local services until a supported launcher release
provides their sidecar definitions and readiness contract.

To add a persona, copy a JSON file into `personas/`, give it a unique ID and
`order`, and set `visible: true`. See `personas/README.md` for the fields and
`tools/try_persona.sh` for a local preview. No picker code needs changing.
Setting `visible: false` in a release hides the choice for new installations;
after the release, an existing installation picks up the changed definition
with `exakit update exakit`. A local checkout reads the JSON on its next
persona or marketplace command.

To add a Python add-on, add one catalog row and a module named
`marketplace/addons/<id_with_underscores>.py`. Implement the operations the
add-on supports (`install`, `validate`, `update`, `uninstall`, and any service
or discovery hooks). `metadata.py` exposes only functions the module actually
implements, so the platform adapters need no new hook entry. Add the tested
version and artifact pins to root `versions.json` and include an ownership and
failure test. Keep credentials in files or child process environment; never
put them in command arguments or the catalog.

Notebook and UDF Devkit lifecycle operations use the Python service. The
direct `notebook`, `workflow`, `mlflow`, `rust-udf`, `udf-file`, `model`, `udf-setup`, `udf-use`, and `udf-build`
commands use Python entry points in this directory. `udf_container.py` selects
and verifies the pinned release assets. The public CLI still loads Notebook's
platform helper for `describe`; the workflow, Rust UDF, and MLflow command
wrappers and the dbt-exasol, Exasol for VS Code, Exasol Scheduler, and JSON Tables script pairs have been removed.
Other legacy add-on script pairs remain until their compatibility checks use
the Python backend; that cleanup is tracked in `tasks.md`.
