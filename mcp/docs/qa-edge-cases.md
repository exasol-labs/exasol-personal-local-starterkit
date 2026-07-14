# MCP QA Edge Cases

Status: Expanded QA matrix for the implemented MCP scope.

## Purpose

This document captures the edge cases and failure paths that should be tested for the production-facing MCP flow.

It covers:

- install-time MCP preparation
- dedicated read-only MCP credentials
- permanent client configuration
- lifecycle CRUD for managed MCP artifacts
- validation, repair, backup, restore, and uninstall
- security, drift, and recoverability

## Test Areas

### 1. Runtime And Bootstrap Edge Cases

- `python3` present: MCP flow should use system Python directly.
- `python3` missing but `uv` present: MCP flow should still succeed.
- `python3` missing and `uv` missing: MCP flow should bootstrap `uv`.
- `python3` missing and `uv` bootstrap fails: installer should stop with a clear error.
- `curl` and `wget` both unavailable during `uv` bootstrap: MCP setup should fail clearly.
- `~/.local/bin` not on `PATH`: setup should still complete, but should warn.
- runtime manifest missing: MCP commands should fail with a precise manifest error.
- runtime manifest corrupted: setup should quarantine and rebuild where supported.

### 2. Dedicated MCP Read-Only User Edge Cases

- no `components.mcp_server.connection` block: MCP export and runtime commands must fail closed.
- MCP connection present but `validated` is false: runtime commands must fail closed.
- MCP connection user equals runtime admin user: runtime commands must fail closed.
- MCP password file missing or empty: runtime commands must fail closed.
- read-only user exists already: setup should reuse and refresh safely.
- read-only user missing `CREATE SESSION`: setup should fail.
- read-only user has extra system privileges: setup should fail.
- read-only user missing `SELECT` on the allowed schema: setup should fail.
- read-only user has object privileges broader than `SELECT`: setup should fail.
- read-only user can successfully create a table: setup should fail immediately.

### 3. Client Setup Edge Cases

#### Permanent setup

- configure one client only
- configure multiple clients
- rerun configure on already-managed clients
- client config file does not exist yet
- client config directory exists but file does not
- client config already contains unmanaged servers
- managed entry already exists and matches expected content
- managed entry already exists but has drifted

### 4. Config File Corruption Edge Cases

- Claude config contains invalid JSON
- Cursor config contains invalid JSON
- Codex config contains invalid TOML
- top-level config object exists but wrong shape
- server section exists but wrong type
- config contains unrelated unmanaged entries that must be preserved

Expected behavior:

- validation should report precise findings
- configure should block on unsafe corruption
- repair should restore managed content without deleting unrelated unmanaged entries

### 5. Lifecycle CRUD Edge Cases

- `mcp-doctor` (status view) with no managed artifacts
- `mcp-doctor` (status view) with one managed artifact
- `mcp-doctor` (status view) with multiple managed artifacts
- `mcp-doctor` (validation) on healthy managed state
- `mcp-doctor` (validation) with invalid DSN literal
- `mcp-doctor` (validation) with TCP connectivity failure
- `mcp-repair` when nothing is wrong
- `mcp-repair` when managed config drift exists
- `mcp-remove` for one selected client
- `mcp-remove` for all managed clients
- `mcp-remove` when there is nothing to remove
- `mcp-restore` with latest snapshot
- `mcp-restore` with explicit snapshot id
- `mcp-restore` with no snapshot available
- `mcp-doctor` with healthy state
- `mcp-doctor` with drift and warnings

### 6. Snapshot And Recoverability Edge Cases

- configure should create a snapshot before destructive mutation
- repair should snapshot before mutation
- uninstall should snapshot before removing managed state
- restore should recover the last known-good config
- restore should preserve file permissions after recovery
- restore should fail cleanly when snapshot id is invalid
- manifest should keep a coherent snapshot history after multiple operations

### 7. Security Policy Edge Cases

- `stdio` request missing command must block
- HTTP request targeting non-loopback host must block
- deployment mode mismatch must block
- literal credential reference must warn
- managed config permissions drift from `0600` should be detected

### 8. Cross-Platform And Path Edge Cases

- Claude path on macOS
- Claude path on Windows via env override
- Cursor path override
- Codex path override
- workspace cwd missing for workspace-relative consumers
- nested directories requiring creation
- existing file owned by user but unreadable by process

### 9. User Experience Edge Cases

- user skips MCP setup during install and runs it later
- user reruns permanent setup after client config drift
- user changes selected clients on rerun
- user asks to remove only one client from previously configured set
- summary output should remain readable when operation partially succeeds
- restart guidance should only reference the selected supported clients

### 10. Manual End-To-End QA Scenarios

- clean macOS machine with no Python
- clean WSL machine with no Python
- existing runtime, first MCP setup
- existing runtime, damaged client config, then repair
- existing runtime, remove MCP config, then restore it
- existing runtime, read-only user manually broadened, then rerun validation

## Automated Coverage Added

The automated suite now explicitly covers:

- strict runtime-loader failures for missing, unvalidated, incomplete, or non-isolated MCP connections
- CLI failure paths for missing validated connection and restore-without-snapshot
- security-policy blocks for unsafe HTTP targets and invalid stdio requests
- lifecycle command coverage for setup, status, validate, and remove

## Remaining Manual-Only Coverage

Some behaviors still require real-environment QA because they are not reliable to simulate fully in the test sandbox:

- live Exasol privilege checks through `exapump`
- live `uv` bootstrap and missing-Python fallback
- real client restart behavior
- real filesystem permission behavior on each target OS
- PowerShell / native Windows parity
