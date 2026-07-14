# Production Hardening

Status: active hardening contract, created from the 2026-07-07 review.

## Goal

Make update behavior boring, reversible where practical, and truthful across macOS, Linux, WSL, and Windows. The repo should not promise "latest by default" or "safe update" unless the matching platform path, manifest records, and tests support it.

## Update Contract

- Installs resolve current component versions by default.
- Environment overrides still win when a user or release process pins a version explicitly.
- Last-known-good fallback versions are used only when lookup fails or the version policy is not `latest`.
- The resolved desired versions are recorded in the manifest before component installation.
- Mutating updates must say whether they created a snapshot, kept user data in place, or require a manual backup.

## Recovery Contract

- Exasol Personal major upgrades remain explicit: plan, backup, then apply.
- Exasol Nano updates keep the Docker or Podman data volume and create a pre-update runtime snapshot record before replacing the container.
- If an updated Nano container fails to start or become ready, the updater attempts to recreate the previous container image against the same volume.
- MCP package updates attempt a managed-state backup first and record the snapshot reference when one is available. This is best-effort because refreshing the MCP package and generated config bundle does not directly rewrite permanent client configs.

## Platform Parity

- Unix and Windows installers both use latest-by-default version resolution with fallback versions.
- Unix and Windows Nano update paths both create pre-update snapshot metadata and attempt previous-image restore on startup failure.
- Unix and Windows MCP update wrappers both expose the pre-update snapshot behavior.

## Test Contract

- `tests/dry-run-matrix.sh` guards routing, version fallback behavior, latest-resolution wiring, and update recoverability hooks.
- PowerShell files must parse successfully when `pwsh` is available.
- Python tests remain required before release sign-off; dry-run coverage is not a substitute for service-level tests.
