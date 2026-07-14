# Risk Analysis

Status: Phase 1 baseline.

## Initial Risk Register

| ID | Risk | Impact | Likelihood | Initial Mitigation Direction |
| --- | --- | --- | --- | --- |
| R-001 | AI client receives write-capable credentials and executes destructive SQL | High | Medium | Default to dedicated read-only user and validate grants before activation |
| R-002 | Plaintext client configuration leaks credentials | High | Medium | Keep configs outside repo, enforce restrictive permissions, exclude from backups where appropriate |
| R-003 | Remote HTTP mode is exposed without compensating controls | High | Medium | Default to `stdio`; require explicit hardening guidance for HTTP mode |
| R-004 | Client configuration formats change over time | Medium | High | Isolate adapters, version manifest data, add drift detection and repair |
| R-005 | Installer handoff is underspecified | High | Medium | Define explicit upstream contract during architecture |
| R-006 | Backup/restore overwrites healthy local state | Medium | Medium | Use manifest-aware backups, preview mode, and restore confirmations |
| R-007 | Repository structure differs from the brief | Medium | Medium | Treat current workspace gap as an assumption and validate before architecture is locked |
| R-008 | False validation success masks broken runtime state | Medium | Medium | Separate syntax validation, connectivity validation, and permission validation |
| R-009 | Platform update behavior drifts between Unix and Windows | High | Medium | Keep latest-version resolution and update-recovery hooks covered by shared dry-run/static guards |
| R-010 | Container update leaves Nano data intact but no runnable previous container | High | Low | Snapshot pre-update runtime metadata and recreate the previous image if the updated container fails readiness |
| R-011 | MCP package refresh obscures managed client-config recovery state | Medium | Medium | Attempt a managed MCP backup before update and record the snapshot reference when available |

## Review Note

This is a starter register. Detailed threat, failure-mode, and operational risk analysis belongs in Phase 2 and Phase 3 after component boundaries are defined.
