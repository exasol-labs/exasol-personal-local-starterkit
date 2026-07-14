# Assumptions

Status: Phase 1 draft, awaiting review.

## Assumption Register

### A-001 Repository scaffold maturity

Assumption: The repository structure now exists as a scaffold, but most directories are still placeholders without implementation content or installer-owned assets.

Why this is an assumption: The structure has been created locally, but the broader repository history and parallel contributor assets are not yet present in this workspace.

Impact: Medium. Some architectural paths may need minor placement adjustments when additional repository content arrives.

Verification: Re-check directory ownership and neighboring assets before Phase 4 task breakdown.

### A-002 Installer handoff contract

Assumption: The installer team will provide a stable handoff after Exasol, Exapump, MCP Server installation, and runtime startup.

Why this is an assumption: The ownership split is specified, but the integration contract is not yet documented.

Impact: High. Architecture depends on clear upstream inputs and failure semantics.

Verification: Align with the installer owner before Phase 4 task breakdown.

### A-003 Primary deployment target

Assumption: The first-class target is a personal or single-user environment, with remote multi-user HTTP deployment considered a secondary mode.

Why this is an assumption: The project name and Exasol guidance point to personal usage, but no formal deployment matrix was supplied.

Impact: Medium. It affects defaults, UX, and security posture.

Verification: Confirm the deployment matrix during architecture review.

### A-004 Secret storage strategy

Assumption: Some target clients will require plaintext environment variables or config entries, so the subsystem must initially manage file permissions and backup exclusions rather than relying on a universal OS keychain abstraction.

Why this is an assumption: Exasol documents plaintext environment variables in client config, but does not define a cross-client secret-storage standard.

Impact: High. Secret handling is central to the design.

Verification: Validate per-client configuration capabilities during adapter design.

### A-005 Remote HTTP authentication gap

Assumption: The current Exasol MCP Server remote HTTP mode should be treated as lacking built-in HTTP-layer authentication suitable for open network exposure.

Why this is an assumption: Exasol docs explicitly say the remote HTTP server does not currently support HTTP-layer authentication; future versions may change this.

Impact: High. The architecture must plan compensating controls without depending on unsupported features.

Verification: Re-check Exasol MCP Server release documentation before implementation begins.

### A-006 Read-only grant model

Assumption: The documented read-only setup example is a valid baseline for this subsystem: dedicated user, `CREATE SESSION`, and `GRANT SELECT ON SCHEMA`.

Why this is an assumption: The example is documented, but schema patterns and object visibility requirements for richer discovery may vary by installation.

Impact: Medium. Some installations may need additional grants for metadata visibility or audit access.

Verification: Confirm minimum required grants against the Exasol MCP Server tool behavior during architecture.

### A-007 Upgrade responsibility boundary

Assumption: This subsystem is responsible for compatibility with changed client configuration formats, but not for upgrading the Exasol MCP Server package itself.

Why this is an assumption: The brief clearly assigns MCP Server installation elsewhere, but upgrade ownership details are not fully spelled out.

Impact: Medium.

Verification: Confirm upgrade boundary with the installer owner before Phase 4 task planning.
