# Decisions

Status: ADR set through Phase 5.

## ADR-0001 Documentation-first, gated delivery

### Context

The project brief requires phased execution and forbids implementation before architecture and design approval.

### Decision

This project will use approval gates between requirements, architecture, design, task breakdown, API design, implementation, testing, integration, and final review.

### Consequences

- Slower start, lower rework risk
- Documentation becomes the governing artifact
- Implementation must stop if design drift appears

## ADR-0002 Mutable runtime state lives outside the repository

### Context

The brief explicitly requires mutable artifacts under `~/.exasol-starter-kit/`.

### Decision

Generated client configs, manifests, logs, cache, and backups will be treated as runtime assets owned outside the repository.

### Consequences

- Safer commits and reviews
- Clear ownership boundary for uninstall and backup
- Requires explicit manifesting and backup strategy

## ADR-0003 Least-privilege Exasol user is mandatory by default

### Context

Exasol documents that the MCP server does not enforce query restrictions; the database user permissions control what the assistant can do.

### Decision

The subsystem will assume and optimize for a dedicated, read-only Exasol database user as the secure default.

### Consequences

- Stronger protection against destructive AI-issued SQL
- Some advanced workflows may require explicit opt-in elevation later
- Validation and repair logic must preserve least privilege

## ADR-0004 Local `stdio` is the default transport mode

### Context

The MCP specification recommends `stdio` support wherever possible, and Exasol recommends local mode for individual use. Remote HTTP adds network exposure and Exasol documents no built-in HTTP-layer authentication in the current server.

### Decision

Use local `stdio` as the default personal-starter-kit mode. Treat remote HTTP as an explicit advanced mode with stronger operational controls.

### Consequences

- Lower default exposure
- Cleaner single-user onboarding
- Remote HTTP requires network controls, TLS termination, and additional review

## ADR-0005 Hexagonal architecture with adapter isolation

### Context

The subsystem must support multiple AI clients whose configuration formats can change independently, while preserving stable core behavior and a clean installer boundary.

### Decision

Use a hexagonal architecture with:

- core domain and policy logic in `mcp/core/`
- client-specific adapters in `mcp/adapters/`
- infrastructure concerns separated into runtime, validator, diagnostics, and security modules

### Consequences

- Easier client expansion and testing
- Lower blast radius when client configuration formats change
- Slightly more upfront interface design work

## ADR-0006 Manifest-first runtime ownership

### Context

The subsystem owns generated runtime state outside the repository and must support repair, backup, restore, uninstall, and upgrade compatibility.

### Decision

Every owned runtime artifact will be tracked through a manifest-first model rooted at `~/.exasol-starter-kit/manifest.json`.

### Consequences

- Stronger ownership boundaries
- Safer backup, restore, repair, and uninstall behavior
- Requires careful schema versioning in later phases

## ADR-0007 Inspect-plan-apply operational flow

### Context

The brief emphasizes inspect-before-run behavior, idempotence, and secure defaults.

### Decision

Mutating operations will follow an `inspect -> plan -> apply -> verify -> record` pattern whenever feasible.

### Consequences

- Better operator trust and recoverability
- Clearer diagnostics and dry-run behavior
- Slightly more orchestration complexity than direct-write flows

## ADR-0008 Command-oriented public API

### Context

The subsystem is triggered by installer orchestration and lifecycle actions such as configure, validate, repair, restore, and uninstall rather than by long-lived resource CRUD operations.

### Decision

Expose a command-oriented public API with explicit operation names and structured request and result envelopes.

### Consequences

- Better fit for installer orchestration
- Easier expression of dry-run, validation, and lifecycle operations
- Less natural fit for generic REST-style resource modeling

## ADR-0009 Structured results over implicit exceptions

### Context

The subsystem needs machine-readable outcomes with warnings, evidence, backup references, and next actions even when an operation is partially successful or recoverably failed.

### Decision

Use structured operation results with status, findings, changes, artifacts, verification evidence, and next actions as the primary public outcome contract.

### Consequences

- Better operator and installer visibility
- Clearer recoverable-versus-terminal failure semantics
- Slightly more verbose result handling for callers

## ADR-0010 Latest-by-default with explicit recovery signals

### Context

The README promises latest-version installs and version-aware updates, but the Windows setup path previously initialized shared component versions from pinned defaults while Unix resolved latest versions first.

### Decision

All first-install paths use latest-by-default component resolution with explicit fallback versions, and update paths must surface their recovery behavior before mutation.

### Consequences

- Windows and Unix installs follow the same version policy.
- Offline installs remain deterministic through fallback versions.
- Update wrappers must keep manifest records and snapshot/restore messages honest, even when a snapshot is best-effort rather than a full data backup.
