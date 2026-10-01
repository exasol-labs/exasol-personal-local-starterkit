# Operations

Status: Phase 3 baseline, aligned to the detailed design draft.

## Runtime Ownership

Owned mutable state belongs under:

- `~/.exasol-starter-kit/manifest.json`
- `~/.exasol-starter-kit/logs/`
- `~/.exasol-starter-kit/generated/`
- `~/.exasol-starter-kit/backups/`
- `~/.exasol-starter-kit/clients/`
- `~/.exasol-starter-kit/runtime/`
- `~/.exasol-starter-kit/cache/`

## Operational Expectations

- Re-running configuration should be safe.
- Repair should prefer non-destructive correction before replacement.
- Backup should run before restore, repair, uninstall, or upgrade-driven rewrites.
- Installs should resolve latest component versions by default, record the resolved desired versions, and fall back only when lookup fails or a non-latest policy is explicitly selected.
- Runtime updates should keep the deployment's data in place, and a major Exasol Personal upgrade should stay on its explicit plan/backup/apply path rather than being taken from a single confirmation.
- MCP package updates should attempt a managed-state snapshot before refreshing the package/config bundle and should surface whether that snapshot was created.
- Uninstall should remove only subsystem-owned artifacts.
- Doctor mode should separate environment checks from mutating actions.

## Open Questions For Later Phases

- Backup naming and retention policy
- Log format and verbosity model
- Manifest schema versioning strategy
- Recovery behavior after partially failed operations
