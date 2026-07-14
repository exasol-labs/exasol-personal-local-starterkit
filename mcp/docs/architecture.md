# Architecture

Status: Phase 2 approved baseline for Phase 3 detailed design.

## Architecture Goals

- Keep the security model explicit and least-privilege by default
- Decouple core behavior from fast-changing AI client configuration formats
- Preserve a clean installer handoff
- Keep runtime ownership manifest-driven and recoverable
- Support inspection, validation, repair, backup, restore, and uninstall without implementation guesswork

## Architectural Drivers

- Exasol MCP access is only as safe as the configured database user permissions
- Client configuration formats vary by product and can change independently
- Runtime artifacts must live outside the repository
- Remote HTTP mode is materially riskier than local `stdio`
- Cross-platform behavior matters for path handling and local client discovery

## System Context

### Upstream

- Exasol is installed and reachable
- Exapump is installed
- Exasol MCP Server is installed
- Base runtime startup is handled elsewhere

### This subsystem

- discovers supported AI clients
- generates or updates client configuration
- validates configuration and connectivity
- records runtime ownership in a manifest
- repairs, backs up, restores, uninstalls, and reports status

### Downstream

- local AI clients such as Claude, Cursor, and Codex
- local runtime state under `~/.exasol-starter-kit/`

## High-Level Architecture

The subsystem uses a hexagonal architecture with a small set of application services coordinating policy-rich domain logic and adapter-driven infrastructure.

### Layers

- `Application layer`
  Coordinates use cases such as discover, configure, validate, repair, backup, and uninstall.
- `Domain/core layer`
  Holds policies, ownership rules, runtime manifest rules, operation planning, and validation semantics.
- `Adapter layer`
  Encapsulates client-specific discovery and configuration logic.
- `Infrastructure layer`
  Handles filesystem, process execution, environment inspection, logging, backups, and connectivity probes.

## Repository Mapping

```text
mcp/
├── core/          # domain models, use-case orchestration, policies, contracts
├── adapters/      # client adapters and adapter registry
├── security/      # permission checks, secret handling policies, safety guards
├── validator/     # config validation, connectivity validation, grant validation
├── runtime/       # manifest, state repository, backup/restore coordination
├── templates/     # client config templates and renderers
├── diagnostics/   # doctor/status/reporting services
├── tests/         # subsystem-focused tests
└── README.md
```

## Core Components

### 1. Service Facade

Purpose:

- provide the stable public API
- normalize results for installer integration

Planned operations:

- `discover()`
- `install()`
- `configure()`
- `validate()`
- `repair()`
- `backup()`
- `restore()`
- `doctor()`
- `uninstall()`
- `status()`

Design choice:

- keep the public surface stable even if internals evolve

Trade-off:

- requires disciplined contract versioning early

### 2. Client Adapter Registry

Purpose:

- enumerate supported clients
- resolve the correct adapter for each discovered client

Responsibilities:

- register adapters by client identity
- expose discovery probes
- expose adapter capability metadata

Design choice:

- adapter registry instead of `if/else` client logic in the core

Trade-off:

- slightly more structure up front
- much lower future maintenance cost

### 3. Configuration Planner

Purpose:

- turn desired state into an explicit plan before mutation

Responsibilities:

- compare requested state against discovered state
- identify files to create, update, back up, or leave untouched
- determine whether credentials, DSN, or mode changes affect risk posture

Design choice:

- inspect-plan-apply flow instead of direct writes

Trade-off:

- more orchestration
- better safety and clearer repair paths

### 4. Runtime Manifest Service

Purpose:

- track every runtime artifact owned by the subsystem

Responsibilities:

- record generated files, their hashes, ownership metadata, timestamps, and schema version
- support drift detection
- support targeted backup, restore, and uninstall

Design choice:

- manifest-first ownership model

Trade-off:

- manifest management overhead
- safer lifecycle operations

### 5. Validation Engine

Purpose:

- ensure configuration is safe and functional before marking success

Validation stages:

- syntax validation of generated client config
- environment validation of required binaries or client presence
- connectivity validation to Exasol without write operations
- permission posture validation against the desired read-only baseline

Design choice:

- multi-stage validation instead of a single health check

Trade-off:

- more detailed result model
- far better failure diagnosis

### 6. Repair Engine

Purpose:

- correct owned drift or corruption without broad destructive behavior

Responsibilities:

- detect manifest drift
- detect invalid client config owned by this subsystem
- restore from backup or re-render known-good configuration

Design choice:

- repair only owned assets

Trade-off:

- avoids damaging user-managed client configuration
- may leave non-owned problems for manual resolution

### 7. Backup And Restore Engine

Purpose:

- preserve recoverability across repair, upgrade, and uninstall flows

Responsibilities:

- take manifest-scoped backups
- label snapshots with operation intent and timestamp
- restore the latest selected valid snapshot

Design choice:

- backup by manifest ownership, not by whole home-directory copy

Trade-off:

- requires ownership precision
- avoids overreaching into unrelated local state

### 8. Diagnostics And Doctor Service

Purpose:

- expose operator-readable status and actionable diagnostics

Responsibilities:

- report discovered clients
- report active configuration mode
- report missing prerequisites
- report drift and permission issues
- report upgrade risks

## Client Adapter Architecture

Every client adapter must implement the same conceptual contract.

### Adapter Responsibilities

- identify whether the client is installed
- locate relevant config files or config roots
- describe supported transport modes
- render the client-specific MCP configuration payload
- validate rendered output format
- describe activation requirements such as restart behavior

### Adapter Non-Responsibilities

- deciding global security policy
- deciding credential policy
- deciding manifest ownership rules
- making direct database authorization decisions

### Why this design

- client config formats change faster than core policy
- new clients should not require rewriting core orchestration

### Alternatives considered

- single shared renderer with client flags
- client logic embedded inside command handlers

Why rejected:

- both approaches make future client changes riskier and harder to test

## Runtime State Architecture

All mutable state is outside the repository under `~/.exasol-starter-kit/`.

### Planned Layout

```text
~/.exasol-starter-kit/
├── manifest.json
├── logs/
├── generated/
├── backups/
├── clients/
├── runtime/
└── cache/
```

### Ownership Rules

- only subsystem-owned artifacts go into the manifest
- direct edits to user-owned files are avoided unless explicitly imported into managed ownership
- uninstall removes only manifest-owned artifacts

## Public API Shape

This architecture keeps the previously approved public operations and adds a shared result model.

### Common Result Shape

Each operation should eventually return:

- operation name
- status
- summary
- findings
- changed artifacts
- backup reference if one was created
- next actions

### Why this design

- the installer needs machine-readable outcomes
- diagnostics need richer context than exit code only

## Security Architecture

### Trust Boundaries

- boundary 1: installer handoff into this subsystem
- boundary 2: local runtime state and client config files
- boundary 3: AI client launching the MCP server
- boundary 4: MCP server connecting to Exasol
- boundary 5: optional remote HTTP exposure

### Security Baseline

- default to `stdio`
- assume plaintext client config may be necessary
- enforce restrictive local permissions where supported
- require dedicated least-privilege Exasol credentials
- treat remote HTTP as advanced and opt-in

### Inference from sources

Because Exasol documents that the MCP server does not enforce read-only behavior, the architecture places access control responsibility on credential selection and validation rather than on the server process.

## Operational Flow

### Configure flow

1. discover clients and environment
2. inspect current state
3. plan changes
4. back up affected owned state
5. render configuration
6. validate syntax and connectivity
7. record manifest changes
8. return activation instructions or status

### Repair flow

1. inspect manifest and owned files
2. classify drift or corruption
3. choose non-destructive fix or restore path
4. verify repaired state
5. update manifest

### Uninstall flow

1. inspect manifest
2. back up owned state
3. remove owned artifacts only
4. verify removal
5. emit final status

## Cross-Platform Strategy

### Platform-agnostic core

- keep policy, planning, manifest, and validation semantics platform-neutral

### Platform-specific edges

- filesystem paths
- permission application
- client discovery heuristics
- client restart guidance

### Why this design

- keeps the majority of logic unit-testable
- isolates platform variance to a smaller surface area

## Upgrade Compatibility Strategy

### Architectural stance

- client configuration formats are expected to drift over time
- adapter capability metadata should include format or strategy versioning
- manifest records should include the adapter version or renderer version used

### Why this design

- enables targeted repair and upgrade re-rendering
- limits unnecessary rewrites

## Alternatives Considered

### Alternative 1: Monolithic command implementation

Pros:

- faster first implementation

Cons:

- weak separation of concerns
- hard to add clients safely
- difficult to test

Decision:

- rejected

### Alternative 2: Repository-local runtime files

Pros:

- easy to inspect during development

Cons:

- unsafe to commit
- poor fit for end-user local state
- violates the project brief

Decision:

- rejected

### Alternative 3: HTTP-first architecture

Pros:

- one remote server could serve multiple clients

Cons:

- significantly larger attack surface
- Exasol docs note missing HTTP-layer auth in the current server
- worse default fit for a personal starter kit

Decision:

- rejected as the default

## Risks And Architectural Responses

- Write-capable credentials: addressed by least-privilege baseline and permission validation
- Client config drift: addressed by adapters plus manifest-aware repair
- Plaintext secrets on disk: addressed by runtime ownership, permissions, and backup scope control
- Remote exposure: addressed by `stdio` default and explicit HTTP hardening path
- Partial failure during mutation: addressed by inspect-plan-apply plus backup-first behavior

## Open Questions Carried Into Later Phases

- Which clients can support managed ownership cleanly versus patch-only behavior?
- What is the minimum manifest schema that still supports safe restore and uninstall?
- Should there be an explicit import step for user-managed existing config blocks?
- How should secret redaction appear in status, doctor, and log output?
