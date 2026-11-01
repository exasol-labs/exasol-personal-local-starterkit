# Persona and marketplace Python migration

Branch: `feat/persona-and-marketplace-ui`. This checklist tracks implementation and evidence. Check an item only when its behavior is wired into `exakit` and verified; a standalone Python prototype does not count.

## Scope and compatibility

- [ ] Keep the existing persona and marketplace selection wording, row order, keyboard controls, notebook child rows, and progress/activity placement while Textual renders them.
- [ ] Preserve every command, option, exit status, JSON shape, ownership receipt, and installed state used by the existing persona and marketplace paths on macOS, Linux, and Windows.
- [x] Leave database deployment, pre-persona installation, virtual schema, and external data source code outside this change. The platform entry-point edits are limited to persona and marketplace adapters.
- [x] Use the kit's uv-managed Python for persona/marketplace mutations after bootstrap; keep read-only queries able to use an existing interpreter without downloading Python. Add-on mutations, `persona add`, the initial persona controller and the Textual picker use uv with a cache under `EXAKIT_HOME`. Existing data/MCP commands remain platform services.
- [x] Keep root `versions.json` authoritative for advertised/update versions; use `marketplace/` defaults only as fallback and honor explicit overrides and the current version policy. Bash and PowerShell pass their validated active manifest to Python for individual, batch, Textual, and direct UDF commands. A Python context reads one snapshot for version and asset checksums; `tests/test_marketplace_runtime.py` covers a newer cached version and its matching checksum.
- [x] Read Notebook frontend and scikit-learn pins, MLflow server version, skill version, and Rust smoke overlay pins from that same active versions document. Focused tests use a changed cached document for Notebook, MLflow, and Rust.
- [x] Preserve the Notebook frontend aliases and skip defaults while moving its install logic to Python. Focused tests cover `jupyter`, semicolon-separated answers, and the legacy Jupyter/Marimo skip variables.
- [x] Keep the current MCP implementation and isolate add-on lifecycle behind `marketplace/service.py`; persona JSON names add-on IDs without host details. A future sidecar implementation remains a separate release task below.
- [x] Route the Linux installer's marketplace apply through the same Python controller already used by the macOS and Windows persona boundaries. The selected UI and pre-persona steps remain in place.
- [x] Make the Textual uv launcher and all five Python add-on virtual environments honor `EXAKIT_MANAGED_PYTHON_VERSION`, matching the shell and PowerShell adapters. The focused launcher and add-on suites pass.

## Definitions and state

- [x] Validate add-on definitions in `marketplace/catalog.json`, including unique IDs, `visible` boolean, fallback version, module identity, and add-on-specific choices. `tests/test_marketplace_ui.py` and `tests/test_marketplace_runtime.py` cover malformed definitions.
- [x] Require `backend: python` for every marketplace definition. The catalog can no longer add a new legacy script implementation; focused catalog, service, and runtime tests pass.
- [x] Validate persona JSON, including unique IDs, ordering, declared datasets, clients, services, add-ons, and `visible` boolean. `tests/personas.sh` and `tests/personas-ps.ps1` cover the old and new paths.
- [x] A definition with `visible: false` is unavailable for new selections, including a named `persona add` or `marketplace <id>`, while installed instances remain inspectable/updatable/removable. Selection and membership tests cover the toggle.
- [x] Adding a new persona JSON requires no change to picker or dispatcher code. Existing `persona list/show/plan/add` behavior remains stable in the persona suites.
- [x] Implement persona membership removal without deleting shared datasets, add-ons, or user-owned files; make repeated add/remove idempotent. Verified by `tests/test_persona_membership.py`, `tests/personas.sh`, and `tests/personas-ps.ps1`.
- [x] Make add-on registry and installed-state discovery read catalog JSON rather than two hard-coded shell/PowerShell lists. PowerShell retains only Notebook's fallback table-child hooks; `udf-devkit` uses the Python backend.
- [x] Use atomic, concurrent-safe manifest updates and retain the current receipt keys and owner values. The 24-writer test in `tests/test_marketplace_runtime.py` preserves every receipt.

## Textual and Python entry points

- [ ] Textual persona picker matches the current screen, including None and recorded/default selections. The actual Textual pilot now verifies selection and cancel; visual parity in a terminal remains.
- [ ] Textual marketplace picker matches the current screen, including Select All, Skip, unavailable rows, notebook frontends, and an activity line above progress. The actual Textual pilot verifies selection stays in the same app during Python apply, dynamic choices from catalog rows, activity above progress at 80/120 columns, and keyboard protection during install; visual parity in a real terminal remains.
- [x] Noninteractive env answers remain unattended and never open a UI; cancellation changes nothing. Verified by the selector and persona tests; the marketplace shell suite also checks scripted answers.
- [x] The seven add-on lifecycle operations enter `marketplace/service.py` through platform adapters. Direct Notebook, workflow, MLflow, Rust UDF, UDF file/model, and UDF setup/use/build commands also enter Python. `describe` still uses its small platform adapters and existing Python helpers.
- [x] Remove all seven old add-on `.sh`/`.ps1` implementation pairs after migrating production callers and compatibility coverage. The final UDF pair is removed; direct UDF/model checks now use Python and both public CLI entry points.
- [x] Remove the old dbt-exasol pair. Bash and PowerShell now discover it through the Python catalog and lifecycle hooks; the public catalog, adapter dry-run, connection validation, and compatibility suites pass.
- [x] Remove the old exasol-vscode pair. Public Bash/PowerShell commands already use Python hooks; compatibility and isolated end-to-end checks now call that backend. Python tests cover editor discovery, stdin isolation, WSL staging, digest selection and ownership.
- [x] Remove the old Exasol Scheduler pair. Public commands use Python hooks; pinned assets, archive validation, recovery and live task execution are verified in the current record.
- [x] Remove the old JSON Tables pair. The JSON file loader's readiness check now uses the Python add-on hook; the public marketplace already used it. Python tests cover release pins, platform selection, shim forwarding, authenticated lookup, API refusal, digest verification, ownership, and a missing Windows shim. The marketplace suite (348/0), agent checks (650/0), dry-run matrix (176/0), release contract (20/0), and Python suite (704 passed, 21 skipped), plus the latest focused tests, pass. Isolated macOS JSON ingest has passed; Windows checks remain a release gate.
- [x] Remove the old Dash Server pair. The Python add-on retains loopback port selection, launcher repair, UI and MCP health probes, and a single restart for an owned service whose UI is broken. Python discovery passed 712 tests (21 skipped), focused Dash tests 28/0, marketplace 276/0, agent operability 649/0, and the dry-run matrix 176/0. Isolated macOS service checks have passed; other native distributions remain release gates.
- [x] Remove the old Notebook pair and migrate its compatibility suites to Python/public CLI tests. Retain the full-kit uninstall preservation check in Bash. The shared lifecycle tests include store recovery, token masking, start/stop, port conflicts and missing frontends; Windows CI runs the same public commands under PowerShell 5.1 and 7. Real Mac Notebook kernels have passed; live Windows remains a release gate.
- [x] Prevent read-only Bash and PowerShell queries from bootstrapping a Python runtime during add-on hook discovery. Bash marks the command read-only before loading hooks; uv query calls use offline mode. A no-Python audit fixture covers both absent and preinstalled uv; agent audit passed 279/0.
- [x] Remove the obsolete `workflow`, `rust-udf`, and `mlflow` command wrapper pairs after replacing their direct-helper suites with public Bash/PowerShell CLI checks. The Python tests retain detailed behavior and fallback coverage; the MLflow Bash suite still tests a real local HTTP server.
- [x] Preserve public `exakit help`, `catalog`, `status`, `version`, `update`, `marketplace`, `uninstall`, and add-on-specific commands. The Python, marketplace shell, version, and persona suites pass; fresh-machine and other-platform checks remain separate below.
- [x] Move the post-persona apply/progress controller into Python. `installer_flow.py` owns initial persona decisions and recording; `persona_apply.py` sequences existing data/MCP/marketplace commands. `persona_services.py` shares service prerequisite checks. `apply.py` owns add-on installation and emits events to Textual or platform renderers. Duplicate shell/PowerShell apply loops are removed. Existing data/MCP screens keep their order.
- [x] Remove production CLI dependence on the old Notebook helper without changing its profiler behavior or picker layout. `describe` uses the recorded Notebook Python path; Bash and PowerShell fallback tables obtain child rows and selected-key normalization from Python metadata. Both `describe` command suites pass 106/0; the old Notebook pair and its direct-helper test suites have now been removed.

## Add-on ports

- [x] Dash Server: package, launcher, MCP connection, health, port ownership, start/stop, autostart, update, uninstall. Python tests and isolated macOS HTTP install pass.
- [x] dbt-exasol: adapter venv, private profile, secret-safe launcher, connection probe, ownership, update, uninstall. Python, compatibility and live Mac database connection checks pass.
- [x] Exasol Scheduler: verified binary, DB bootstrap/user, launcher, process and health, update, uninstall. Python tests and live Mac task execution pass; other-platform checks remain release gates.
- [x] Exasol for VS Code: editor detection, verified VSIX, WSL staging, external ownership, update, uninstall. Python tests and isolated macOS extension install pass; WSL remains a release gate.
- [x] JSON Tables: verified Rust engine and wheel, app control, launcher, validation, update, uninstall. Python tests and isolated macOS ingest pass.
- [x] Notebook: connector, JupyterLab/Marimo/Positron selection, stores/kernels, bundled notebooks, refresh, health, update, uninstall. Python tests, generated notebook parity and real Mac kernel execution pass; native UI and Windows checks remain release gates.
- [x] UDF Devkit: Python/Rust containers, hashes, MLflow/runtime support, validation/smoke, update, uninstall. Python, restart recovery and live Mac Python/Rust container smoke checks pass; other-platform checks remain release gates.
- [x] UDF file and model commands: Python BucketFS mapping, atomic file copy, model CRUD, provenance gate, receipt locking, and Bash/PowerShell entry-point tests. Verified by `tests/test_marketplace_udf_bucket.py` and `tests/test_marketplace_model_cli.py`.
- [x] UDF release asset selection and verified cache helper in Python; mirror, digest mismatch, invalid protocol, bundled Rust smoke asset, and database-version row selection tests pass in `tests/test_marketplace_udf_container.py`. The container lifecycle is routed through it.

## Verification and edge cases

- [x] `exakit help --json` and `catalog --json` work with no kit installed and without Textual downloaded; verified with a nonexistent `EXAKIT_HOME` and system Python. `marketplace --list --json` continues to require a kit installation under the existing CLI contract.
- [x] Malformed JSON, duplicate IDs, missing versions, unknown IDs, and invalid frontend selections fail before any install side effect. Catalog shape, duplicate ID, version block/line break, and frontend tests pass. The Python batch controller validates Notebook frontends for the entire selection before its first install; public Bash and PowerShell CLI fault-injection tests in a temporary checkout confirm invalid frontends, malformed JSON, a missing fallback version, empty CSV entries, and unknown CSV IDs leave the earlier selected Dash Server without a receipt. Named direct add-on checks cover unknown and disabled IDs.
- [x] `visible: false` preserves an installed receipt and keeps read-only lifecycle access; setting it back to `true` makes the same persona and add-on definitions selectable again. Covered by `tests/test_marketplace_ui.py`.
- [x] Named, CSV, `all`, `none`, and UI selections follow the same catalog eligibility rules. The two platform menu adapters agree on ten scripted cases, including hidden IDs; the Textual pilot verifies child choices and Select All. The shared parser rejects unknown/empty IDs before installation.
- [x] A reused external package or extension is never claimed, overwritten, updated, or uninstalled. Python ownership tests cover the seven add-ons; the shared install dispatcher also refuses an external receipt or a successful return without a new kit receipt.
- [x] Fault-injected partial downloads, bad digests, failed package/runtime setup and failed validation preserve retryable state. A real local process startup timeout removes its PID receipt, preserves an unrelated service record and succeeds on retry. Native distribution acceptance remains separate.
- [ ] Secrets stay out of command arguments, stdout, generated profiles, logs, and JSON responses.
- [x] Concurrent receipt writes do not lose data; updates do not change unrelated manifest keys. The 24-writer atomic manifest test and focused update tests pass.
- [ ] Install and uninstall reruns are idempotent; dry runs have no filesystem or manifest effects.
- [x] Run repeated native install/current-version update/preview/removal for dbt-exasol, JSON Tables, Dash Server, VS Code and Notebook in a disposable Mac kit home. All five passed through public CLI commands, preserving personal test files and the original kit manifest. Preview comparisons exclude CLI logs and the lock file; this does not close the complete lifecycle matrix below. The repeatable command is in `docs/ACCEPTANCE-REMAINING.md`.
- [x] Redact delegated passwords, tokens and API/secret keys from child-tool diagnostics before writing the shared marketplace log. Real subprocess regressions cover successful commands, failures and timeouts, inherited environment values, private log permissions and stdout protection.
- [x] Forward the active versions document to add-on `latest` and validation on Bash and PowerShell, under both manifest and latest policies. A cached-document regression reproduced both adapters selecting the older checkout version; it now passes. PowerShell's uv stderr diagnostics no longer become returned version values.
- [ ] Paths with spaces and WSL-mounted paths work; Windows wrappers quote arguments and do not leak credentials. The new `tests/test_marketplace_adapters.py` covers a kit path with spaces and dry-run safety on Bash and PowerShell; WSL and complete wrapper coverage remain.
- [x] Warm-machine macOS persona/add-on flows pass through the public CLI, including Scheduler recovery, dbt connection validation and Notebook/UDF execution. Bash and PowerShell compatibility checks pass locally. Fresh-machine and native Windows verification remain separate gates.
- [x] Run focused Python tests, shell/PowerShell compatibility tests, syntax checks, and a full test run on a clean staged snapshot. Commit the reviewed Python marketplace slice as `aaffaae` and push `feat/persona-and-marketplace-ui`.
- [x] Close the former [draft PR #8](https://github.com/ranjanm-chn/exasol-personal-local-starterkit-backup/pull/8) while implementation and release checks continue on `feat/persona-and-marketplace-ui`.
- [ ] Raise a new PR after the remaining implementation and agreed release checks are complete; present the result for review then.
- [x] Remove stale marketplace setup instructions and overlong historical comments from the touched Bash/PowerShell adapters. Keep comments that explain non-obvious safety gates and file formats. Bash and PowerShell parsers and `git diff --check` pass after cleanup.
- [x] Validate every selected add-on module once before the batch starts and restore the caller's activity-row setting after success or failure. The focused Python suite covers the failed-batch case.

## Launcher handoff and PR checks (rechecked 2026-11-01)

- [x] Check the staging PR stack against this checkout. #2 → #1 → #6 was the active chain when draft #8 was opened; #8 and #3 are now closed. The older heads are ancestors of this branch, and #6's head `d6ce9c7` is this branch's base; there is no PR commit to cherry-pick. #6's checks were red after only a few seconds. A sampled job had no log and its GitHub API record had zero steps, so the failure occurred before any test step; CI remains unresolved.
- [x] Audit the model setting rename across the PR stack and current checkout. The current reader in `notebook/package/exakit_nb/model_config.py`, examples, help, tests, and runbook use `EXAKIT_MODEL_ID`, `EXAKIT_PROVIDER_BASE_URL`, and `EXAKIT_PROVIDER_API_KEY`. PR #1 contains the former `EXAKIT_NB_MODEL` name, but no current source or help page reads or recommends the former `EXAKIT_NB_*` names; `CHANGELOG.md` records the migration. `LANGFUSE_HOST` remains a supported alias for `LANGFUSE_BASE_URL`.
- [x] Recheck [Exasol Personal v2.4.0-rc2](https://github.com/exasol/exasol-personal/releases/tag/v2.4.0-rc2), published 2026-10-30. It includes complete sidecar URLs, saved disabled definitions, readiness/enable wait, MCP restart, and the new `exasol mcp` commands. It is a prerelease; the latest stable release is still [v2.3.0](https://github.com/exasol/exasol-personal/releases/tag/v2.3.0), which root `versions.json` pins. Changing that core launcher pin is outside this branch. [#455](https://github.com/exasol/exasol-personal/pull/455) adds cloud BucketFS credentials for new cloud deployments; the local filesystem-backed UDF path in this branch does not use them.
- [x] Keep persona JSON keyed by capability/add-on IDs so host changes do not rewrite personas.
- [ ] When a supported launcher release is adopted, add a capability-gated sidecar host behind `marketplace/service.py`; preserve the existing MCP path until the new sidecar has proven health and a usable endpoint.
- [ ] For that host migration, consume the complete URL from [#459](https://github.com/exasol/exasol-personal/pull/459), distinguish saved disabled definitions from removal as in [#461](https://github.com/exasol/exasol-personal/pull/461), require `health=serving` and honor the enable wait in [#462](https://github.com/exasol/exasol-personal/pull/462), and account for MCP restart policy in [#470](https://github.com/exasol/exasol-personal/pull/470). Surface the macOS runner restart instruction from [#471](https://github.com/exasol/exasol-personal/pull/471). [#473](https://github.com/exasol/exasol-personal/pull/473) improves WSL Podman errors but also records an unresolved bridge-network issue on WSL 2.6; keep it in the later launcher installation work, outside this branch.
- [ ] Verify the first stable release containing those post-rc1 fixes and its `sidecar status --json` shape before switching any add-on or MCP service to it. The current upstream catalog sidecar is MCP; the seven kit add-ons still need their own supported deployment definitions before a host switch is possible.
- [x] Track upstream [#475](https://github.com/exasol/exasol-personal/pull/475): it merged 2026-10-30 and is included in rc2. `exasol mcp enable/status/disable/instructions` manages the upstream sidecar and prints client registration instructions. Its client entry is named `exasol-personal`, separate from this kit's `exasol` entry. Before any handoff, verify a stable release's actual JSON and retain the kit's enforced read-only database-user boundary.
- [x] Recheck upstream [#457](https://github.com/exasol/exasol-personal/pull/457) and [#367](https://github.com/exasol/exasol-personal/pull/367), both still open on the 2026-11-01 API recheck. Docker/Podman selection and launcher path migration affect core deployment discovery, UDF BucketFS paths, and update recovery. Review them with the core installer owner after release; do not copy their pre-persona install changes into this marketplace branch.

### Release edge-case checklist

- [x] Public CLI fixtures cover first add, second add, repeated add/apply and removal with shared-file preservation. Live Mac reapply/remove/restore also passed; a fresh-machine install remains a separate release gate.
- [x] Toggle persona/add-on `visible` false and back: model/service tests preserve installed receipts, block new selection and restore selection. The Bash/PowerShell selection matrix also excludes a hidden Notebook from `all` and named installs.
- [x] Malformed persona/catalog files, duplicate IDs, unknown IDs/frontends and missing required version/fallback fields fail before resource changes. Public CLI fault fixtures preserve the earlier selected add-on’s receipt; unavailable Rust asset metadata was also refused in the live Mac check.
- [x] Download interruption/retry, checksum mismatch, package/runtime failure, validation failure and service startup timeout/retry are covered at their actual lifecycle boundaries. The timeout case launches and cleans up a real local process.
- [ ] Install each add-on twice, update it at the current version and a newer version, preview uninstall, uninstall twice, and check kit/user/unknown ownership separately.
- [x] Public Bash/PowerShell CLI tests cover JSON success/refusal, redirected streams and paths with spaces. Python service/batch tests also keep progress on stderr and return one JSON object on stdout.
- [ ] Confirm secrets are absent from processes, emitted JSON, profiles, and logs; confirm kit-owned generated files are removed and user-owned files survive.
- [x] Verify macOS live Database + Notebook + UDF Python/Rust on the existing deployment; see the dated evidence above.
- [ ] Verify Windows PowerShell 5.1 and WSL paths on native machines, deferred by the user.

## Current verification record

### Latest checks (2026-11-01)

- Scheduler: repaired the legacy-to-Python runtime gap and made process identity independent of the checkout/install source path. Live `SELECT 1` tasks reached `SUCCEEDED`; cleanup left no task definitions. The service user has exactly `CREATE SESSION`. Repeated installed-CLI starts kept the same supervisor. A reusable check is in `tests/integration/scheduler_live.py`.
- dbt-exasol: the pinned installed version passed real database connection validation (`validated_by: connection`). VS Code remains user-owned and is excluded from kit updates/removal.
- Selection: Bash and PowerShell agree on named, CSV, `all`, `none` and hidden-ID fixtures. Windows CI is configured to run the new selection/ownership checks under both available PowerShell hosts. The actual Textual pilot passes eight checks, including the corrected Select All behavior for child choices. PTY and adapter checks now cover candidate menus/definitions beside an older installed kit.
- Ownership: 42 add-on/owner/operation cases refuse update/removal for user, unknown and untracked ownership, preserving receipts and personal files. Interrupted-download and local-process timeout checks prove cleanup and retry without changing another receipt.
- Native lifecycle: the five package/editor add-ons passed install twice, current-version update, preview and uninstall twice in an isolated home with spaces in its path. Generated runtimes/launchers were removed, personal test files survived and the existing kit manifest stayed unchanged. `tests/integration/marketplace_lifecycle_live.py` reproduces the checks; its fixture marks the borrowed database user-owned and isolates kernels, editor extensions, skills and login entries. Scheduler/UDF repeated lifecycle and actual newer-version upgrades remain pending.
- Credential logging: a new regression first reproduced a child tool echoing a delegated password/token into the shared log. Diagnostics are now filtered before persistence; success, failure and timeout regressions also cover Langfuse keys and private file permissions. This closes that logging gap, not the wider cross-platform privacy gate.
- Version discovery: fixed the marketplace compatibility failure where the active cached manifest advertised JSON Tables `v0.4.1` while Python reported the checkout's `v0.3.2`. Both adapters now forward the selected document for latest/validation; four adapter/policy cases pass without a network lookup. The PowerShell uv fallback keeps warnings on stderr. Windows CI includes the shared runtime and fixture-ownership checks.
- Compatibility: marketplace Bash 276/0 and agent operability 649/0 passed again after the active-version fix. Full Python discovery ran 778 tests without failures (22 skipped); the separate Textual run passed all eight UI tests. Focused adapters passed 18/0, shared runtime/privacy 19/0 and fixture ownership 1/0. Bash/PowerShell syntax, Windows workflow YAML and diff checks pass. The earlier persona Bash 87/0, persona PowerShell 36/0, 40-file PowerShell parse and zero-undefined-call audit remain the recorded checks for those unchanged paths.
- Upstream API recheck: latest stable remains [v2.3.0](https://github.com/exasol/exasol-personal/releases/tag/v2.3.0); #457 and #367 remain open. No core launcher or sidecar switch was made.

### Mac acceptance already completed

- The candidate reused the existing kit-owned database. Six Data Scientist and eight ML Engineer notebook runs passed across Pharma and Banking, including real Python/Rust UDF execution. Pharma used `CLASS_WEIGHT = None`; Banking used `balanced`. All 14 executed notebooks passed the output privacy scan.
- The connector’s unchanged `first_steps` connection cells passed after adding its required `docker-db` extra. JupyterLab and Marimo returned authenticated HTTP 200 responses; tokens were absent from server arguments and logs. The existing Jupyter session was preserved and the test Marimo server was stopped.
- Live persona reapply, membership removal and restoration preserved shared data/add-ons. The final persona plan had nothing pending. The manual runbook uses `EXAKIT_VERSION_POLICY=pinned` for the unreleased candidate because the published manifest lacks its Rust asset row.

### Remaining release gates

| Gate | Evidence still required |
|---|---|
| Native UI | Compare the existing and Textual screens in Terminal. Native Terminal UI automation is unavailable here; pilot/PTY results do not establish pixel parity. |
| Clean Mac install | Fresh-machine timing and first connected result; reused-database runs do not establish this. |
| Windows/Linux/WSL | Native install/service checks, Windows PowerShell 5.1 and mounted-path behavior. Windows verification is deferred by the user. |
| Hosted CI | Resolve the repository’s billing/spending-limit block and retain passing workflow URLs. Local checks do not establish a hosted pass. |
| Human acceptance | Share figure approval and the G1/G2/G3 practitioner gates in `docs/ACCEPTANCE-REMAINING.md`. |
| Sidecars | A supported stable launcher, add-on deployment definitions, endpoint/readiness contracts and the core owner’s handoff. |

The former draft PR #8 remains closed until the agreed release checks are complete.
The internal v0.3.0 Word record remains local and excluded from Git. The two
previously recorded PowerShell encoding findings in `setup/lib/pyexasol.ps1`
and `tests/workflow-command-ps.ps1` remain outside this persona/marketplace scope.
