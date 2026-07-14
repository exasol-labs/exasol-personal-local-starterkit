# Integration

Status: Phase 5 refined baseline aligned to the API design draft.

## Upstream Boundary

Owned by another developer:

- Exasol installation
- Exapump installation
- MCP Server installation
- Runtime startup

This subsystem begins after those steps succeed.

## Required Upstream Inputs

- Exasol endpoint or DSN
- Database user guidance or credential handoff mechanism
- MCP Server availability
- Target operating system context
- Requested AI clients to configure

## Handoff Contract

The API design assumes the installer or upstream orchestration will hand this subsystem a request object containing:

- `request_id`
- `operation`
- `target_clients`
- `deployment_mode`
- `dry_run`
- `force`
- `runtime_root`
- `ownership_mode`
- `server_definition`
- `credential_reference`
- `dsn_reference`

See [api-design.md](api-design.md) for the full request schema.

## Result Contract

The subsystem should return structured results containing:

- `request_id`
- `operation`
- `status`
- `summary`
- `findings`
- `changes`
- `artifacts`
- `backup_reference`
- `verification_evidence`
- `next_actions`

See [api-design.md](api-design.md) for the full result schema.

## Downstream Responsibilities

- Discover supported clients
- Generate client config
- Validate runtime state
- Manage manifest, repair, backup, restore, uninstall

## Integration Principles

- No tight coupling to installer internals
- No dependence on repository-local mutable files
- Clear machine-readable result objects for status and failure reporting
- Idempotent re-entry after partial success or failure

## Open Items For Later Phases

- Confirm whether credentials are passed directly or resolved indirectly
- Confirm whether upstream will orchestrate backups globally or leave them local to this subsystem
- Confirm how partial failures should be surfaced in installer UX
- Confirm which upstream component is authoritative for populating `server_definition` across `stdio` and HTTP deployment modes
