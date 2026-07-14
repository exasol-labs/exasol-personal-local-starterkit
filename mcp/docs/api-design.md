# API Design

Status: Phase 5 draft, awaiting approval before Phase 6 review and refinement.

## Purpose

Define the stable public API for the MCP access and client configuration subsystem so implementation can proceed without inventing request shapes, result shapes, operation semantics, or error contracts.

## Design Goals

- provide one coherent contract for upstream installer orchestration
- keep the public surface stable while allowing internal adapters to evolve
- make read-only and dry-run behavior explicit
- make failures structured, actionable, and machine-readable
- keep secrets out of API payloads wherever practical

## API Surface

The public subsystem API exposes these operations:

- `discover`
- `install`
- `configure`
- `validate`
- `repair`
- `backup`
- `restore`
- `doctor`
- `uninstall`
- `status`

## API Boundary Decisions

- The public API is command-oriented, not resource-oriented.
- Every operation returns a structured result object with findings and evidence.
- The API accepts references for credentials where possible rather than requiring raw secrets in every request.
- Mutating operations support dry-run semantics.
- The API does not expose client-specific file formats directly; those remain adapter internals.

## Common Type System

### `OperationName`

Allowed values:

- `discover`
- `install`
- `configure`
- `validate`
- `repair`
- `backup`
- `restore`
- `doctor`
- `uninstall`
- `status`

### `DeploymentMode`

Allowed values:

- `stdio`
- `http`

### `OperationStatus`

Allowed values:

- `success`
- `success_with_warnings`
- `no_change`
- `blocked`
- `failed_recoverable`
- `failed_terminal`

### `Severity`

Allowed values:

- `info`
- `warning`
- `error`
- `critical`

### `OwnershipState`

Allowed values:

- `managed`
- `observed`
- `conflicting`
- `orphaned`

## Common Request Envelope

All operations accept a request object that extends a shared base.

### `BaseRequest`

```json
{
  "request_id": "optional-correlation-id",
  "operation": "configure",
  "target_clients": ["claude_desktop", "cursor"],
  "deployment_mode": "stdio",
  "dry_run": true,
  "force": false,
  "runtime_root": "~/.exasol-starter-kit",
  "ownership_mode": "managed",
  "server_definition": {
    "name": "exasol",
    "transport": "stdio",
    "command": "exasol-mcp-server",
    "args": ["--profile", "starter-kit"],
    "env": {
      "EXASOL_DSN": "exa.example.internal:8563",
      "EXASOL_USER": "exa_readonly"
    }
  },
  "credential_reference": {
    "kind": "inline_env",
    "name": "EXA_PASSWORD"
  },
  "dsn_reference": {
    "kind": "literal",
    "value": "exa.example.internal:8563"
  }
}
```

### Base request fields

- `request_id`
  Optional caller correlation ID.
- `operation`
  One of the supported operation names.
- `target_clients`
  Explicit client targets or empty for auto-discovery.
- `deployment_mode`
  `stdio` by default, `http` only by explicit request.
- `dry_run`
  If true, compute and validate a plan without mutation.
- `force`
  Allows specific recoverable blockers to be overridden where policy permits.
- `runtime_root`
  Optional override for runtime-root location. Default remains `~/.exasol-starter-kit`.
- `ownership_mode`
  Initial allowed value is `managed`. Additional modes may be introduced later if justified.
- `server_definition`
  Required transport-specific instructions for how the target client should reach the MCP server.
- `credential_reference`
  Reference to credentials, not necessarily the raw secret itself.
- `dsn_reference`
  Reference or literal for Exasol connectivity.

## Common Result Envelope

All operations return a shared base result shape.

### `BaseResult`

```json
{
  "request_id": "optional-correlation-id",
  "operation": "configure",
  "status": "success_with_warnings",
  "summary": "Configured Claude and detected one unmanaged conflicting file for Cursor.",
  "findings": [],
  "changes": [],
  "artifacts": [],
  "backup_reference": null,
  "verification_evidence": [],
  "next_actions": []
}
```

### Base result fields

- `request_id`
  Echoed from the request when provided.
- `operation`
  The completed operation.
- `status`
  One of the public operation statuses.
- `summary`
  Short human-readable summary.
- `findings`
  Structured warnings, errors, and informational notes.
- `changes`
  Structured change records for planned or applied work.
- `artifacts`
  Managed or relevant observed artifacts involved in the operation.
- `backup_reference`
  Snapshot identifier or null.
- `verification_evidence`
  Evidence items showing what was checked.
- `next_actions`
  Actionable follow-up items for the caller.

## Supporting Public Types

### `CredentialReference`

Purpose:

- identify how the subsystem should obtain or pass credentials without standardizing a vault implementation prematurely

```json
{
  "kind": "inline_env",
  "name": "EXA_PASSWORD"
}
```

Allowed `kind` values:

- `literal`
- `inline_env`
- `process_env`
- `external_reference`

Design note:

- `literal` is allowed for API completeness but should be discouraged in higher-level UX.

### `ServerDefinition`

Purpose:

- supply the launch or endpoint details needed to render client configuration without coupling this subsystem to installer internals

`stdio` example:

```json
{
  "name": "exasol",
  "transport": "stdio",
  "command": "exasol-mcp-server",
  "args": ["--profile", "starter-kit"],
  "env": {
    "EXASOL_DSN": "exa.example.internal:8563",
    "EXASOL_USER": "exa_readonly"
  }
}
```

`http` example:

```json
{
  "name": "exasol",
  "transport": "http",
  "url": "http://127.0.0.1:8765/mcp",
  "headers": {
    "Authorization": "Bearer local-token"
  }
}
```

Fields:

- `transport`
  `stdio` or `http`
- `name`
  Optional stable server entry name. Defaults to `exasol`.
- `command`
  Required for `stdio`
- `args`
  Optional argument list for `stdio`
- `env`
  Optional environment block for `stdio`
- `url`
  Required for `http`
- `headers`
  Optional header map for `http`

### `DsnReference`

```json
{
  "kind": "literal",
  "value": "exa.example.internal:8563"
}
```

Allowed `kind` values:

- `literal`
- `named_profile`
- `external_reference`

### `Finding`

```json
{
  "code": "ownership_conflict",
  "severity": "warning",
  "message": "Existing client configuration is not owned by the subsystem.",
  "scope": {
    "client": "cursor",
    "path": "~/.config/example/path.json"
  },
  "evidence": [
    "manifest has no matching managed artifact"
  ],
  "recommended_action": "Run in inspect mode and choose patch-only handling."
}
```

Fields:

- `code`
- `severity`
- `message`
- `scope`
- `evidence`
- `recommended_action`

### `ChangeRecord`

```json
{
  "kind": "update",
  "path": "~/.exasol-starter-kit/clients/claude/exasol_db.json",
  "ownership_state": "managed",
  "applied": true,
  "reason": "refresh_config_render"
}
```

Fields:

- `kind`
  `create`, `update`, `remove`, `restore`, `noop`
- `path`
- `ownership_state`
- `applied`
- `reason`

### `ArtifactReference`

```json
{
  "artifact_id": "artifact-claude-config",
  "path": "~/.exasol-starter-kit/clients/claude/exasol_db.json",
  "kind": "client_config",
  "ownership_state": "managed",
  "client": "claude_desktop",
  "content_hash": "sha256:..."
}
```

### `VerificationEvidence`

```json
{
  "stage": "config_syntax",
  "status": "pass",
  "details": "Rendered JSON is syntactically valid.",
  "subject": "claude_desktop"
}
```

Fields:

- `stage`
- `status`
- `details`
- `subject`

### `NextAction`

```json
{
  "kind": "restart_client",
  "message": "Restart Claude to load the updated MCP configuration."
}
```

Fields:

- `kind`
- `message`

## Operation Contracts

### `discover`

Purpose:

- identify supported clients and report their locations and capabilities

Request additions:

```json
{
  "include_capabilities": true
}
```

Result-specific fields:

- `discovered_clients`
- `undetected_targets`

Behavior:

- never mutates local state
- may inspect filesystem and environment
- should return `no_change` or `success`

### `install`

Purpose:

- reserve the public slot for future installer-owned integration behavior without taking ownership of Exasol MCP Server installation today

Design constraint:

- implementation must remain no-op or explicitly delegated unless ownership changes in a future approved phase

Behavior:

- if unsupported in the current ownership boundary, return `blocked` with clear findings

### `configure`

Purpose:

- generate or update managed client configuration for the selected clients

Request additions:

```json
{
  "patch_mode_allowed": false,
  "create_snapshot": true,
  "validate_after_apply": true
}
```

Behavior:

- supports dry-run
- must snapshot before destructive mutation
- must validate after apply unless explicitly disabled by policy
- must fail fast if the request omits a transport-compatible `server_definition`

Success conditions:

- requested managed artifacts are updated or already compliant

### `validate`

Purpose:

- perform staged validation without mutating client configuration

Request additions:

```json
{
  "stages": [
    "environment",
    "config_syntax",
    "connectivity",
    "permission_posture",
    "manifest_consistency"
  ]
}
```

Behavior:

- read-only
- returns stage-specific evidence

### `repair`

Purpose:

- reconcile manifest-managed drift or corruption

Request additions:

```json
{
  "repair_strategy": "auto",
  "allow_restore": true
}
```

Allowed `repair_strategy` values:

- `auto`
- `rerender_only`
- `restore_only`
- `metadata_only`

Behavior:

- must snapshot before destructive repair
- must never silently take ownership of unmanaged artifacts

### `backup`

Purpose:

- create a snapshot of manifest-managed state

Request additions:

```json
{
  "snapshot_label": "pre-upgrade"
}
```

Result-specific fields:

- `snapshot_id`
- `snapshot_path`

### `restore`

Purpose:

- restore a previously captured snapshot

Request additions:

```json
{
  "snapshot_id": "required-snapshot-id",
  "snapshot_current_state_first": true
}
```

Behavior:

- snapshot current state before rollback by default
- verify restored state before returning success

### `doctor`

Purpose:

- run an operator-focused diagnostic sweep

Request additions:

```json
{
  "include_recommendations": true
}
```

Behavior:

- read-only
- should prioritize actionable findings over raw detail

### `uninstall`

Purpose:

- remove subsystem-managed artifacts only

Request additions:

```json
{
  "create_snapshot": true,
  "remove_runtime_cache": true
}
```

Behavior:

- must never delete non-managed client assets
- must snapshot before destructive removal unless explicitly disabled by policy

### `status`

Purpose:

- return the current managed-state summary

Behavior:

- read-only
- should summarize managed artifacts, last validation, active warnings, and last snapshot

## Public Error Contract

The public API reports errors through structured findings and status values rather than exceptions alone.

### Public error codes

- `invalid_request`
- `unsupported_operation`
- `environment_missing`
- `client_not_found`
- `ownership_conflict`
- `security_block`
- `validation_failed`
- `connectivity_failed`
- `manifest_corrupt`
- `snapshot_not_found`
- `restore_failed`
- `unsupported_install_scope`

### Error mapping rules

- request-shape violations map to `failed_terminal`
- unmet but fixable preconditions map to `blocked`
- post-mutation validation failures map to `failed_recoverable`
- harmless drift observations may still produce `success_with_warnings`

## Dry-Run Semantics

Dry-run is valid for:

- `configure`
- `repair`
- `backup`
- `restore`
- `uninstall`

Dry-run guarantees:

- no filesystem mutation
- no manifest mutation
- no snapshot creation
- full planning and risk evaluation

Dry-run outputs:

- planned changes
- blockers
- predicted snapshot requirement
- expected verification stages

## Idempotence Contract

- `discover`, `validate`, `doctor`, and `status` are read-only by contract
- repeated `configure` on already compliant state should produce `no_change` or `success`
- repeated `backup` always creates a new snapshot unless policy later introduces deduplication
- repeated `uninstall` after clean removal should return `no_change`

## Security Contract

- the public API must never emit raw credential values in results
- `http` deployment mode must trigger explicit risk findings
- permission posture checks are part of public validation evidence, not hidden internals

## Versioning Strategy

### Public API version

The subsystem should expose a public contract version independent from implementation version.

Initial value:

- `api_version: "1"`

### Versioning rules

- additive non-breaking fields may extend existing request and result objects
- field removal or meaning changes require a new API version
- manifest schema version and API version are tracked separately

## Examples

### Example: `discover`

```json
{
  "request_id": "req-1",
  "operation": "discover",
  "target_clients": [],
  "deployment_mode": "stdio",
  "dry_run": true
}
```

### Example: `configure`

```json
{
  "request_id": "req-2",
  "operation": "configure",
  "target_clients": ["claude_desktop"],
  "deployment_mode": "stdio",
  "dry_run": false,
  "create_snapshot": true,
  "validate_after_apply": true,
  "credential_reference": {
    "kind": "process_env",
    "name": "EXA_PASSWORD"
  },
  "dsn_reference": {
    "kind": "literal",
    "value": "exa.example.internal:8563"
  }
}
```

### Example: `status`

```json
{
  "request_id": "req-3",
  "operation": "status",
  "target_clients": [],
  "deployment_mode": "stdio",
  "dry_run": true
}
```

## Open Items For Phase 6 Review

- confirm whether `install` remains a reserved operation or becomes explicitly unsupported in the first implementation
- confirm whether `ownership_mode` should remain single-valued in version `1`
- confirm whether `literal` credential references should be allowed in low-level API callers
- confirm whether snapshot labels need stronger structure than free text

## Exit Criteria

- Every public operation has a defined request and result contract.
- Common types are explicit enough for implementation and tests.
- Error and dry-run semantics are defined.
- The installer-facing integration boundary is clearer than it was at the end of Phase 4.
