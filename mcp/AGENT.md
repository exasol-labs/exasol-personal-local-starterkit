# AGENT.md

## Project Vision

Build a production-grade MCP access and client configuration subsystem for the Exasol Personal Local Starter Kit that is secure by default, maintainable for years, and ready to integrate with the installer without tight coupling.

## Scope

This project starts after:

- Exasol installation
- Exapump installation
- MCP Server installation
- Runtime startup

This project owns:

- Secure MCP access
- Read-only database access
- Least-privilege enforcement
- AI client discovery
- AI client configuration
- Connectivity validation
- Runtime manifest management
- Repair
- Backup
- Restore
- Uninstall
- Upgrade compatibility

This project does not own:

- Exasol deployment
- Exapump deployment
- MCP Server installation
- Base runtime startup orchestration

## Source Of Truth

Use this precedence order:

1. Official Exasol documentation and official Exasol GitHub repositories
2. Official Model Context Protocol specification
3. Approved repository documentation in this project
4. Explicit user instructions
5. Marked assumptions

If a fact is not verified, label it `ASSUMPTION` and include how it should be verified later.

## Phase Gate Rules

Work in this exact order:

1. Requirements Analysis
2. Architecture
3. Detailed Design
4. Task Breakdown
5. API Design
6. Review and refinement
7. Implementation
8. Testing
9. Integration
10. Final Review

Hard rules:

- No implementation before architecture and design are approved.
- No silent phase skipping.
- Stop after each phase and wait for approval.
- If implementation reveals an architectural inconsistency, return to design documents first.

## Architecture Rules

- Keep mutable runtime state outside the repository under `~/.exasol-starter-kit/`.
- Keep repository content deterministic, reviewable, and safe to commit.
- Separate core business logic from client-specific adapter logic.
- Never hardcode client-specific behavior into the core domain.
- Prefer composition, dependency injection, and testable interfaces.
- Preserve clean integration boundaries with the existing installer.
- Default to local `stdio` MCP usage for single-user flows unless a documented reason requires HTTP.
- Treat remote HTTP mode as higher risk and require compensating controls.

## Security Rules

- Secure by default beats convenience by default.
- Use a dedicated least-privilege Exasol database user for AI access.
- Never assume the MCP server enforces read-only behavior; the database account must enforce it.
- Never commit generated client configs or plaintext credentials.
- Restrict local file permissions for client configuration files and runtime secrets.
- Any remote HTTP exposure must be explicitly documented, network-restricted, and TLS-protected.
- Prefer inspect-before-run, dry-run, and validation steps before writing client configuration.

## Documentation Rules

- Documentation is part of the product, not project exhaust.
- Every significant decision must state rationale, alternatives, trade-offs, risks, and evidence.
- Use ADR style in `docs/decisions.md`.
- Keep requirements traceable to sources.
- Keep assumptions explicit and review them at each phase gate.

## Coding Standards

- Favor small interfaces and testable modules.
- Prefer explicit types and structured error handling.
- Avoid global mutable state.
- Keep adapters thin and core logic reusable.
- Make installers and repair flows idempotent.

## Testing Standards

- Design tests before implementation.
- Mock filesystem, database, MCP server, AI clients, network, runtime manifest, and backup engine.
- Cover unit, contract, integration, and upgrade-compatibility scenarios.
- Require cross-platform validation for macOS, Linux, and Windows configuration behavior.

## Review Checklist

- Are all claims backed by official sources or marked assumptions?
- Does the design preserve least privilege?
- Is mutable state outside the repository?
- Are client adapters isolated from core logic?
- Is the installer integration boundary clean?
- Are backup, restore, repair, and uninstall flows defined?
- Are upgrade and drift scenarios addressed?
- Are tests planned for happy path, failure path, and recovery path?

## Definition Of Done

- The current phase documents are internally consistent.
- Open questions are explicit.
- Risks are surfaced, not hidden.
- Evidence links are recorded.
- No implementation begins before approval for the implementation phase.

## No Hallucination Policy

- Never invent Exasol APIs, SQL syntax, paths, client config locations, or MCP behavior.
- If a source is missing or ambiguous, say so.
- When inferring from evidence, state that it is an inference.
