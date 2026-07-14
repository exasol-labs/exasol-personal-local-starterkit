# Design

Status: Phase 3 approved baseline for Phase 4 task breakdown.

## Design Goals

- Translate the approved architecture into implementation-ready module boundaries
- Keep client-specific behavior isolated behind stable contracts
- Make owned runtime state explicit, reversible, and auditable
- Preserve inspect-before-run behavior across all mutating operations
- Avoid committing to unverified client path details until adapter evidence is gathered

## Design Scope

This document defines:

- internal module contracts
- runtime manifest design
- adapter lifecycle and responsibilities
- operation flows for discover, configure, validate, repair, backup, restore, uninstall, doctor, and status
- result and error models

This document does not define:

- implementation task ordering
- concrete source-code filenames
- exact client configuration paths that are not yet verified

## Design Principles

- Core logic must remain platform-agnostic where possible
- Client adapters must be replaceable and independently testable
- All mutating operations must be manifest-aware
- Validation must be explicit about what was and was not verified
- Any unverified client path or client config rule remains an `ASSUMPTION`

## Module Design

### `mcp/core/`

Purpose:

- contain policy, domain models, and use-case orchestration

Planned subdomains:

- `operations`
  Defines orchestrators for `discover`, `configure`, `validate`, `repair`, `backup`, `restore`, `doctor`, `uninstall`, and `status`.
- `planning`
  Computes desired versus actual state and emits operation plans.
- `ownership`
  Determines whether an artifact is managed, external, conflicting, or unknown.
- `results`
  Defines common result, finding, and change-record structures.
- `errors`
  Defines subsystem error categories and mapping rules.

Key rule:

- `mcp/core/` must not know client-specific file formats.

### `mcp/adapters/`

Purpose:

- contain one adapter per supported AI client plus an adapter registry

Expected adapter categories:

- `desktop_mcp_clients`
  Claude, Cursor, Codex
- `editor_embedded_clients`
  VS Code, GitHub Copilot when applicable

Design note:

- Some products may share reusable mechanics, but shared code must stay in adapter support utilities rather than moving into core policy.

### `mcp/security/`

Purpose:

- enforce local safety rules before and after mutation

Responsibilities:

- secret redaction
- file permission policy
- deployment-mode risk checks
- read-only grant posture checks
- unsafe-operation blockers

### `mcp/validator/`

Purpose:

- perform explicit validation stages

Validators:

- config syntax validator
- environment validator
- connectivity validator
- permission posture validator
- manifest consistency validator

### `mcp/runtime/`

Purpose:

- manage owned runtime state under `~/.exasol-starter-kit/`

Responsibilities:

- manifest repository
- backup repository
- artifact hashing
- snapshot metadata
- restore coordination

### `mcp/templates/`

Purpose:

- store reusable configuration renderers and safe patch templates

Design note:

- Templates are rendering inputs, not ownership records.

### `mcp/diagnostics/`

Purpose:

- produce human-readable and machine-readable diagnostic reports

Outputs:

- doctor report
- status report
- drift report
- upgrade readiness report

## Core Data Model

### OperationRequest

Represents the caller’s intent.

Fields:

- `operation`
- `target_clients`
- `deployment_mode`
- `server_definition`
- `credential_reference`
- `dsn_reference`
- `ownership_mode`
- `dry_run`
- `force`
- `backup_policy`

Design note:

- the request can hold references rather than raw secrets
- whether upstream resolves those references remains an `ASSUMPTION`
- rendering also requires explicit MCP server launch or endpoint details, so `server_definition` is part of the core request contract

### OperationPlan

Represents the planned state transition before mutation.

Fields:

- `operation`
- `discovered_clients`
- `owned_artifacts`
- `planned_changes`
- `preconditions`
- `risk_flags`
- `backup_required`
- `verification_steps`

### OperationResult

Represents the final outcome.

Fields:

- `operation`
- `status`
- `summary`
- `findings`
- `changes`
- `artifacts`
- `backup_reference`
- `verification_evidence`
- `next_actions`

### Finding

Fields:

- `code`
- `severity`
- `message`
- `scope`
- `evidence`
- `recommended_action`

### ArtifactRecord

Represents an owned or observed artifact.

Fields:

- `path`
- `kind`
- `ownership_state`
- `hash`
- `last_seen_at`
- `source_adapter`
- `manifest_version`

## Runtime Manifest Design

### Purpose

The manifest is the authoritative record of all artifacts owned by this subsystem.

### Location

- `~/.exasol-starter-kit/manifest.json`

### Draft Schema

```json
{
  "schema_version": "1",
  "runtime_root": "~/.exasol-starter-kit",
  "created_at": "2026-07-02T00:00:00Z",
  "updated_at": "2026-07-02T00:00:00Z",
  "subsystem_version": "draft",
  "artifacts": [
    {
      "artifact_id": "uuid-or-stable-id",
      "path": "~/.exasol-starter-kit/clients/claude/exasol_db.json",
      "kind": "client_config",
      "client": "claude_desktop",
      "adapter_version": "draft",
      "ownership_state": "managed",
      "content_hash": "sha256:...",
      "permissions": "0600",
      "created_at": "2026-07-02T00:00:00Z",
      "updated_at": "2026-07-02T00:00:00Z",
      "backup_policy": "snapshot_before_change"
    }
  ],
  "snapshots": [
    {
      "snapshot_id": "uuid",
      "created_at": "2026-07-02T00:00:00Z",
      "operation": "configure",
      "artifact_ids": ["uuid-or-stable-id"]
    }
  ]
}
```

### Manifest Invariants

- every managed artifact must have one manifest record
- unmanaged artifacts must never be silently added as managed
- restore and uninstall must act only on manifest-managed artifacts
- content hash must be recomputed after successful mutation

### Ownership States

- `managed`
  created or fully managed by this subsystem
- `observed`
  discovered but not owned
- `conflicting`
  collides with managed intent and needs operator review
- `orphaned`
  was previously managed but can no longer be reconciled cleanly

## Adapter Contract Design

### ClientAdapter Contract

Each adapter must provide the following conceptual methods:

- `adapter_id()`
- `display_name()`
- `detect(environment) -> DetectionResult`
- `locate(environment) -> LocationResult`
- `describe_capabilities() -> AdapterCapabilities`
- `inspect(current_state) -> AdapterInspection`
- `render(desired_state) -> RenderResult`
- `validate_render(rendered_output) -> ValidationResult`
- `activation_instructions() -> ActivationGuidance`

### AdapterCapabilities

Fields:

- `supports_stdio`
- `supports_http`
- `supports_managed_file`
- `supports_patch_mode`
- `supports_env_block`
- `requires_restart`
- `platforms`

### Important Assumption

Exact config file locations for every target client are not yet verified from primary sources. The design therefore requires a `locate()` step instead of embedding fixed paths in core logic.

## Discovery Design

### Goal

Find supported clients without mutating their state.

### Inputs

- operating system context
- optional client allowlist

### Steps

1. Load adapter registry
2. Run adapter detection probes
3. Record discovered clients and confidence
4. Emit findings for unsupported or ambiguous clients

### Output

- `DiscoverResult` with detected clients, locations, and capability summaries

## Configure Flow Design

### Goal

Create or update managed client configuration for Exasol MCP access.

### Steps

1. Discover candidate clients
2. Resolve requested client targets
3. Inspect current client state
4. Classify ownership of related artifacts
5. Build a configuration plan
6. Run preflight checks
7. Create snapshot if mutation is planned
8. Render client-specific config or patch
9. Apply mutation
10. Run syntax and connectivity validation
11. Update manifest and logs
12. Return activation guidance

### Preconditions

- Exasol DSN is available
- credential source is available
- adapter can locate a supported configuration target

### Failure Handling

- if preflight fails, do not mutate
- if apply fails after backup, return recoverable failure with snapshot reference
- if validation fails after apply, mark state degraded and recommend repair or restore

## Validation Design

### Validation Stages

1. `environment`
   Confirm client presence, executable presence, and runtime-root accessibility.
2. `config_syntax`
   Confirm generated configuration shape for the specific adapter.
3. `connectivity`
   Confirm Exasol connection works without write operations.
4. `permission_posture`
   Confirm the effective posture is consistent with read-only expectations where requested.
5. `manifest_consistency`
   Confirm manifest records match filesystem state for managed artifacts.

### Validation Results

- `pass`
- `pass_with_warnings`
- `fail_recoverable`
- `fail_blocking`

## Repair Design

### Goal

Fix manifest-managed state without damaging user-managed assets.

### Repair Triggers

- manifest mismatch
- syntax-invalid managed config
- missing managed artifact
- permission drift
- stale adapter format version

### Repair Strategies

- recompute and update metadata only
- re-render managed config from desired state
- restore from the latest valid snapshot
- quarantine conflicting managed artifact and stop for review

### Repair Rules

- never overwrite observed or conflicting user-managed assets silently
- always snapshot before destructive repair
- always verify after repair

## Backup And Restore Design

### Backup Scope

- manifest-managed files only
- relevant manifest snapshot metadata

### Snapshot Layout Draft

```text
~/.exasol-starter-kit/backups/
└── <snapshot-id>/
    ├── snapshot.json
    └── artifacts/
```

### Snapshot Metadata

- `snapshot_id`
- `created_at`
- `operation`
- `artifact_ids`
- `manifest_hash`
- `notes`

### Restore Flow

1. select snapshot
2. validate snapshot integrity
3. compare current managed state
4. snapshot current state before rollback
5. restore artifact contents and permissions
6. verify restored state
7. update manifest timestamps and hashes

## Uninstall Design

### Goal

Remove only subsystem-owned artifacts.

### Steps

1. load manifest
2. classify managed artifacts
3. snapshot current state
4. remove managed artifacts
5. prune empty owned runtime directories if safe
6. mark manifest entries removed or archive manifest
7. return completion report

### Rule

- uninstall must not remove unrelated client config or user-owned folders

## Doctor And Status Design

### Doctor

Focus:

- prerequisites
- unsafe deployment mode
- config drift
- missing binaries
- permission drift
- connectivity issues

### Status

Focus:

- discovered clients
- managed artifacts
- last successful validation
- active warnings
- last snapshot reference

## Secret Handling Design

### Design stance

- treat secrets as external inputs to rendering, not as loggable values
- redact secrets in findings, logs, and manifest
- store only what the chosen client format requires

### Assumption

Whether specific clients can reference OS-native secret stores remains unverified and must stay outside the core design until adapter evidence is gathered.

## Logging Design

### Goals

- support diagnostics without leaking credentials
- support recovery decisions
- support upgrade analysis

### Log Categories

- discovery
- planning
- mutation
- validation
- repair
- backup_restore
- uninstall

### Rule

- logs may include artifact paths and adapter IDs
- logs must not include raw passwords

## Error Model Design

### Error Categories

- `input_error`
- `environment_error`
- `adapter_error`
- `render_error`
- `validation_error`
- `manifest_error`
- `backup_error`
- `restore_error`
- `ownership_conflict`
- `security_block`

### Error Semantics

- errors must distinguish blocking versus recoverable conditions
- every blocking result should include a recommended next action
- recoverable results should include backup references when relevant

## Cross-Platform Design Notes

- path resolution belongs in adapters or filesystem utilities, not in core policy
- permission enforcement must degrade gracefully on platforms without POSIX-style modes
- restart guidance remains adapter-specific

## Testability Design Hooks

To support the approved testing strategy, the design requires injectable interfaces for:

- filesystem access
- hashing
- time source
- environment lookup
- process execution
- Exasol connectivity probes
- manifest repository
- snapshot repository

## Open Items For Phase 4

- confirm upstream request and result object exact field names
- verify client-specific config locations and patch strategies from primary sources
- decide whether manifest entries need explicit desired-state records in addition to observed artifact metadata
- decide whether uninstall archives the manifest or deletes it after final snapshot

## Exit Criteria

- The design is specific enough to implement without inventing behavior.
- Manifest structure is defined well enough for Phase 4 task breakdown.
- Adapter contract is explicit enough to parallelize client support later.
- Operation flows are clear for configure, validate, repair, backup, restore, and uninstall.
