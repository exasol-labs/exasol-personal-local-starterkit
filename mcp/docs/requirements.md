# Requirements

Status: Phase 1 approved baseline for subsequent phases.

## Objective

Define the requirements for a production-grade subsystem that discovers supported AI clients, configures them to use the Exasol MCP Server safely, validates connectivity, and manages its own generated runtime state without taking ownership of Exasol installation or MCP Server installation.

## Evidence Base

- Exasol docs: [Quick start with Exasol Personal](https://docs.exasol.com/db/latest/get_started/quick_start_guide.htm)
- Exasol docs: [Drivers and libraries](https://docs.exasol.com/db/latest/connect_exasol/drivers.htm)
- Exasol docs: [Connect AI assistants (MCP Server)](https://docs.exasol.com/db/latest/ai/ai_ask_db/connect-ai-assistants-mcp.htm)
- Exasol docs: [Security and guardrails](https://docs.exasol.com/db/latest/ai/ai_ask_db/security-and-guardrails.htm)
- Exasol docs: [Firewall and port settings](https://docs.exasol.com/db/latest/administration/on-premise/manage_network/system_network_settings.htm)
- Exasol docs: [Update considerations](https://docs.exasol.com/db/latest/administration/on-premise/upgrade/update_considerations.htm)
- Exasol GitHub: [exasol/mcp-server](https://github.com/exasol/mcp-server)
- MCP spec: [Transports](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)

## Scope

In scope:

- AI client discovery
- AI client adapter design
- Local client configuration generation
- Runtime manifest generation
- Connectivity validation
- Read-only database access setup guidance
- Repair of generated configuration drift
- Backup and restore of generated runtime assets
- Uninstall of generated runtime assets
- Upgrade compatibility strategy for client config changes

Out of scope:

- Exasol database installation
- Exasol Personal launcher flows
- Exasol MCP Server installation
- Exasol MCP Server source-code changes
- Credential vault product selection beyond documented extension points
- Multi-tenant access governance beyond the single-user starter-kit boundary

## Business And Technical Context

- Exasol documents MCP client connectivity for Claude and describes the MCP server as usable with Claude, Cursor, Windsurf, and similar assistants.
- Exasol states that the MCP server exposes metadata exploration and SQL execution capabilities.
- Exasol states that query restrictions are determined by the database user permissions, not by the MCP server itself.
- Exasol recommends a dedicated least-privilege user and gives a read-only example using `CREATE SESSION` plus `GRANT SELECT ON SCHEMA`.
- The MCP specification defines two standard transports: `stdio` and Streamable HTTP, and says clients should support `stdio` whenever possible.
- The MCP specification warns that HTTP deployments should validate `Origin`, prefer localhost for local operation, and implement proper authentication.
- The Exasol MCP Server README says the HTTP server host defaults to `0.0.0.0`, which increases exposure if used without controls.

## Constraints

- Documentation-first, phase-gated delivery.
- No mutable runtime artifacts inside the repository.
- Runtime home must be `~/.exasol-starter-kit/`.
- Cross-platform compatibility is required.
- Installer integration must be loose and contract-driven.
- Evidence-based engineering is mandatory.

## Functional Requirements

- `FR-001` The subsystem shall provide a stable public service boundary for `discover`, `install`, `configure`, `validate`, `repair`, `backup`, `restore`, `doctor`, `uninstall`, and `status`.
- `FR-002` The subsystem shall discover supported AI clients through client adapters rather than core hardcoding.
- `FR-003` The initial adapter roadmap shall cover Claude, Cursor, and Codex.
- `FR-004` The subsystem shall generate client-specific MCP configuration outside the repository under `~/.exasol-starter-kit/clients/`.
- `FR-005` The subsystem shall generate and maintain a runtime manifest outside the repository under `~/.exasol-starter-kit/manifest.json`.
- `FR-006` The subsystem shall validate that generated client configuration is syntactically valid before activation.
- `FR-007` The subsystem shall validate Exasol connectivity without performing write operations.
- `FR-008` The subsystem shall support repair of generated files when drift or corruption is detected.
- `FR-009` The subsystem shall back up generated runtime files before destructive repair, restore, upgrade, or uninstall operations.
- `FR-010` The subsystem shall restore a known-good generated runtime state from backup.
- `FR-011` The subsystem shall support uninstall of only the assets it owns.
- `FR-012` The subsystem shall preserve installer integration through explicit interfaces and must not assume ownership of upstream install steps.

## Security Requirements

- `SEC-001` The subsystem shall assume the Exasol MCP Server can execute whatever the configured database user is allowed to execute.
- `SEC-002` The subsystem shall require or strongly recommend a dedicated least-privilege Exasol database user for AI access.
- `SEC-003` The default access profile shall be read-only.
- `SEC-004` The subsystem shall never write plaintext credentials into repository-tracked files.
- `SEC-005` The subsystem shall apply restrictive file permissions to generated local configuration wherever the platform supports it.
- `SEC-006` The default deployment mode for personal use shall be local `stdio`.
- `SEC-007` Remote HTTP mode shall be treated as opt-in and higher risk.
- `SEC-008` Remote HTTP guidance shall require network restriction and TLS termination outside the Exasol MCP Server process.
- `SEC-009` The subsystem shall provide an auditability story for generated configuration and validation activity.

## Operational Requirements

- `OPS-001` All owned operations shall be idempotent where practical.
- `OPS-002` The subsystem shall maintain logs under `~/.exasol-starter-kit/logs/`.
- `OPS-003` The subsystem shall store generated artifacts, backups, cache, and client runtime state in dedicated subdirectories under `~/.exasol-starter-kit/`.
- `OPS-004` The subsystem shall support diagnostic or doctor mode for configuration, permission, and connectivity checks.
- `OPS-005` The subsystem shall support upgrade compatibility checks before mutating generated client configuration.
- `OPS-006` The subsystem shall preserve recoverability by backing up owned state before major changes.

## Quality Attributes

- `NFR-001` The design shall keep core logic independent from client adapter specifics.
- `NFR-002` The design shall be testable with mocks for filesystem, database, MCP server, network, runtime manifest, and backup engine.
- `NFR-003` The design shall support macOS, Linux, and Windows client configuration flows.
- `NFR-004` The design shall favor inspect-before-run behavior, including preview or dry-run outputs where feasible.
- `NFR-005` The design shall minimize future change cost when client config formats evolve.
- `NFR-006` The design shall be suitable for CI-driven automated testing.

## External Interface Requirements

- `INT-001` Upstream integration shall accept a clean handoff after Exasol, Exapump, MCP Server installation, and startup.
- `INT-002` Downstream client integrations shall be adapter-driven and version-aware.
- `INT-003` The subsystem shall not require repository-path-relative mutable files at runtime.
- `INT-004` The subsystem shall expose result objects rich enough for installer orchestration, diagnostics, and repair workflows.

## Phase 1 Acceptance Criteria

- Requirements are traceable to verified sources or marked assumptions.
- Scope boundaries are explicit.
- Security posture is explicit.
- Future architecture work has clear non-negotiable constraints.
- Known unknowns are captured in `assumptions.md` in this `docs/` folder.

## Open Questions Carried Forward

- Which client configuration files can be safely discovered automatically across all target operating systems?
- Which generated artifacts should be reversible versus ephemeral?
- What runtime manifest schema is sufficient without overcommitting too early?
- What backup retention and naming strategy best fits a local starter-kit experience?
