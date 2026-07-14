# Security

Status: Phase 3 refined baseline aligned to the detailed design draft.

## Security Objectives

- Prevent destructive database access by default
- Prevent accidental credential disclosure
- Minimize network exposure
- Preserve auditability and recoverability

## Verified Security Facts

- Exasol states that the MCP server itself does not enforce query restrictions; the database user permissions control what is allowed.
- Exasol recommends a dedicated least-privilege database user and documents a read-only example.
- Exasol documents that credentials in client config are plaintext on disk.
- Exasol documents that the current remote HTTP server does not provide HTTP-layer authentication.
- The MCP spec says local HTTP deployments should bind to localhost and implement authentication, and that clients should support `stdio` where possible.

## Security Baseline

- Default to local `stdio`
- Use dedicated read-only database credentials
- Store generated configs outside the repository
- Apply restrictive file permissions
- Back up owned state before destructive changes
- Require explicit opt-in for remote HTTP mode

## Trust Boundaries

- Upstream installer to subsystem
- Subsystem to local client configuration files
- Client process to MCP server process
- MCP server to Exasol database
- Optional remote HTTP entrypoint to MCP server

## Control Strategy

### Credential controls

- Dedicated AI-access user
- Read-only grants by default
- No repository-stored plaintext secrets
- Secret redaction in logs and diagnostics

### File controls

- Restrictive permissions on generated client config where supported
- Manifest ownership for all generated assets
- Backup-first before destructive operations

### Network controls

- Prefer local `stdio`
- Treat HTTP mode as advanced
- Require binding and access restrictions for HTTP mode
- Require external TLS termination guidance for HTTP mode

## Architectural Security Decision

The subsystem does not rely on the MCP server to enforce read-only behavior. It relies on Exasol permissions plus local validation and safe defaults.

## Open Security Design Questions

- Which credentials, if any, can be externalized to OS-native secret stores per client?
- What minimum permission checks should validation enforce before activation?
- How should backup encryption be handled for owned runtime state, if at all?
