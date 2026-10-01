# Production Hardening

Status: active hardening contract, created from the 2026-07-07 review.

## Goal

Make update behavior boring, reversible where practical, and truthful across macOS, Linux and Windows x86_64 — the platforms Exasol Personal supports. The repo should not promise "latest by default" or "safe update" unless the matching platform path, manifest records, and tests support it.

## Update Contract

- Installs resolve current component versions by default.
- Environment overrides still win when a user or release process pins a version explicitly.
- Last-known-good fallback versions are used only when lookup fails or the version policy is not `latest`.
- The resolved desired versions are recorded in the manifest before component installation.
- Mutating updates must say whether they created a snapshot, kept user data in place, or require a manual backup.

## Recovery Contract

- Exasol Personal major upgrades remain explicit: plan, backup, then apply.
- A minor launcher update replaces the launcher only: the deployment and its data are left where they are, and the database is checked and restarted afterwards.
- A launcher update that crosses the 2.3 boundary rebuilds the deployment's VM guest on its first start. The wait is named before the update is taken, and the rebuild is recorded so it is announced once and not again.
- MCP package updates attempt a managed-state backup first and record the snapshot reference when one is available. This is best-effort because refreshing the MCP package and generated config bundle does not directly rewrite permanent client configs.

## Platform Parity

- Unix and Windows installers both use latest-by-default version resolution with fallback versions.
- Unix and Windows runtime update paths both record what they changed and probe the database afterwards rather than assuming it came back.
- Unix and Windows MCP update wrappers both expose the pre-update snapshot behavior.

## Test Contract

- `tests/dry-run-matrix.sh` guards routing, version fallback behavior, latest-resolution wiring, and update recoverability hooks.
- PowerShell files must parse successfully when `pwsh` is available.
- Python tests remain required before release sign-off; dry-run coverage is not a substitute for service-level tests.
