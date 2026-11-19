# Persona marketplace development

`marketplace/catalog.json` is the ordered add-on catalog. Each row has an ID,
a `github` block naming the repository, a `visible` switch, a fallback version,
and a backend. A row never has a `label`: the name comes from GitHub. Set `visible` to `false`
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
module under `marketplace/addons/`.
Python add-on environments use `EXAKIT_MANAGED_PYTHON_VERSION` when set, matching
the Textual launcher; the kit defaults to Python 3.12.

The installer keeps its database, exapump, MCP, and pyexasol stages. At the
persona boundary, it calls `marketplace/launch.py` for an interactive Textual
choice, drawn exactly as the shell's checkbox menu and add-on table (same
characters, the terminal's own colours, no Textual chrome; a click ticks a
row, Enter moves on, the wheel scrolls the terminal). Add-on lifecycle operations call `marketplace/service.py`. Public
`persona add` sequences the existing data/MCP/marketplace commands in
`persona_apply.py`. `apply.py` owns the marketplace installation sequence,
while Textual displays its activity and progress in the table's Status
column, the same bar the data-load table shows.
`installer_flow.py` decides the initial question, dataset/add-on defaults and
membership receipt. Platform adapters invoke the existing data UI in response.
`persona_services.py` checks service prerequisites and starts the same services
for initial installs and later persona additions. Platform code retains only
the existing data/MCP calls and terminal rendering adapters. Python add-ons
share receipt locking, logging, download, and process helpers in `runtime.py`
and `process.py`. `kit_telemetry.py` keeps Exasol's usage telemetry off
(`EXASOL_TELEMETRY_DISABLE`, unless the user set it): `runtime.py` applies it on
import, and each `*_launcher.py` applies it to its service's environment.

`service.py` is the host boundary for a later Exasol Personal sidecar backend.
The current add-ons remain local services until a supported launcher release
provides their sidecar definitions and readiness contract.

To add a persona, copy a JSON file into `personas/`, give it a unique ID and
`order`, and set `visible: true`. See `personas/README.md` for the fields. No picker
code needs changing.
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

Every add-on's lifecycle operations use the Python service; the install's
persona step uses `installer_flow.py` and `exakit persona add` uses
`persona_apply.py`. The add-on shell/PowerShell implementation pairs have been
removed.
