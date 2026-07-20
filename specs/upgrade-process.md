# Upgrade Process and Kit Versioning

Specification, draft for team review.

| | |
|---|---|
| Status | Draft |
| Owner | Krishna |
| Date | 2026-07-17 |
| Applies to | starter kit 0.1.0 and later |
| Implementation | Phased, after this spec is approved (section 12) |

## 1. Purpose and scope

The starter kit installs five moving parts: the Exasol runtime (Personal on macOS, Nano container on Linux/Windows), exapump, the MCP server, pyexasol, and the exakit CLI itself. This spec defines a supported upgrade experience for all of them: users can always see the versions they run and the versions available, and can upgrade each part to its latest release without breaking their local installation. Database content and credentials must survive every upgrade.

In scope: the versioning scheme for the kit itself, the `exakit update-check` and `exakit update` command surface, per-component upgrade mechanics, safety guarantees, downgrade policy, failure handling, platform parity, the implementation plan, and the verification plan.

Out of scope: the Kit 1 to Kit 2 feature-tier upgrade (`kit_level`, `upgrade/upgrade-kit2.sh`), and upgrades of host-level dependencies the kit does not own (Docker, Podman, uv).

## 2. Definitions

Terms from `CONTEXT.md` are used with their existing meanings: **Component**, **Desired Version** (`desired.*` manifest keys), **Snapshot** (a recoverability record, metadata), **Backup** (a restorable copy of data), **Runtime**. This spec adds:

- **Kit Version**: the semver in the `VERSION` file at the kit root. The kit's identity for comparisons.
- **Provenance**: where the installed kit came from, recorded in manifest `kit.source` (`repo@ref`, `local:<path>`, `checkout:<path>`).
- **Dev Install**: an install whose provenance ref is not a release tag (for example `@main`, `local:`, `checkout:`).
- **Migration Pending**: a recorded state meaning the runtime launcher was upgraded across a major version but the user's data migration is not yet verified.
- **Receipt**: the per-component result lines printed after an update run (`component: A -> B` or `component: current (A)`).
- **Pins**: the per-release file naming the component versions tested together. The default source for install-time version resolution.

## 3. Current state and gaps

The kit already ships most of an update system, in both shells:

- `exakit update-check [target]` prints a four-column table (Component, Installed, Latest, Action): `exakit_print_update_check` at `setup/lib/common.sh:922`, `Invoke-CmdUpdateCheck` at `setup/exakit.ps1:359`. Installed versions come from the manifest. Latest versions come from GitHub releases (tag with `v` stripped), PyPI JSON, and Docker Hub tags with architecture filtering.
- `exakit update [target]` exists with per-component updaters. Bash has kit self-update (`exakit_update_self`, `common.sh:954`): staged tarball download, required-file validation, backup of the old kit dir, atomic swap, manifest rewrite. Nano has a volume-preserving container update with automatic image-level rollback (`nano_update`, `runtime-nano.sh:437`; `Update-Nano`, `nano.ps1:365`). Personal has a guarded major-upgrade path `--plan/--backup/--apply` (`personal_update`, `runtime-personal.sh:477`) where the backup is a tarball of the deployment directory and data migration is deliberately manual.
- Reusable safety helpers exist: MCP config snapshots plus `exakit mcp-restore` (both shells), Nano metadata snapshots, the Personal deployment tarball, and `backups.<op>.latest` manifest keys.

Thirteen verified gaps make this unsupportable today. Each is resolved by the section referenced.

| # | Gap | Where | Resolved by |
|---|---|---|---|
| 1 | Updaters compare versions with plain string inequality while update-check compares semver-aware, so updates can silently downgrade (a `@main` or pre-release install would be replaced by an older release) | `common.sh:958`, `runtime-nano.sh:442`, `runtime-personal.sh:492`, PS updaters | 8 |
| 2 | The kit cannot version itself: no `VERSION` file exists (0.1.0 appears only in `CHANGELOG.md`), fresh installs record `kit.source=repo@main` and display `main`, script installs display `unknown` | `install.sh:117`, `common.sh:895` | 4.1 |
| 3 | `install.ps1` never records the install ref, so the Windows kit row is always `unknown` | `install.ps1:46-59` vs `install.sh:117-125` | 4.3, 11 |
| 4 | Kit self-update is missing on PowerShell (warning stub only), and `install.ps1` keeps no backup of the old kit dir | `exakit.ps1:394` | 6.1, 11 |
| 5 | pyexasol has no update target at all (installed and displayed, never updated) | `common.sh:913` | 6.4 |
| 6 | The Nano "snapshot" is metadata only, with no data-level protection, and rollback is a best-effort old-image restart that only warns on failure | `runtime-nano.sh:487` | 5.4, 6.5 |
| 7 | Personal `--apply` leaves `runtime.version` stale by design, so the same major upgrade shows as pending forever with no explanation | `runtime-personal.sh:527` | 9 |
| 8 | `update all` runs self-update first, then keeps executing old in-memory code for the remaining components | `common.sh:915` | 5.3 |
| 9 | Latest versions are resolved repeatedly (once for the table, again per updater) | `common.sh:1055` | 5.2 |
| 10 | `exakit.ps1` redefines the Docker-tag helper without architecture filtering, overriding the arch-aware library copy, so ARM Windows update paths can select amd64 tags | `exakit.ps1:299` vs `exakit-common.ps1:675` | 11 |
| 11 | `update mcp` leaves AI client configs pinned to the old version until a manual `mcp-setup` | `mcp.sh:133` | 6.3 |
| 12 | exapump updates beyond the pinned version depend on the release API digest and die otherwise | `exapump.sh:123-138` | 6.2, 14 |
| 13 | No integration test exercises a real update, and none verifies data survival | `tests/dry-run-matrix.sh` | 13 |

## 4. Versioning scheme

### 4.1 Kit version

A `VERSION` file at the kit root holds a bare semver (for example `0.2.0`). It is the single source of truth for the kit's own version.

- The installed version is read live from `~/.exasol-starter-kit/kit/VERSION`, falling back to manifest `kit.version`, then to parsing `kit.source`. Reading the file live means the value can never go stale: re-running the installer refreshes the kit directory and the file travels with it, so `local:` and `checkout:` installs also get a real version.
- Both installers and self-update record `kit.version` in the manifest.
- The self-update required-files validation (`common.sh:980`) gains `VERSION`, so a release tarball missing it fails before the swap.
- Semver rules for a script kit: MAJOR for breaking CLI or state-format changes (manifest schema, kit home layout), MINOR for new commands or features, PATCH for fixes and docs.
- Release checklist, in lockstep: move `## Unreleased` items in `CHANGELOG.md` into a new `## X.Y.Z` section, bump `VERSION` to match, tag `vX.Y.Z` on that commit, publish the GitHub release with the section bullets as notes. A read-only `tests/release-consistency.sh` asserts `VERSION` equals the topmost changelog heading and, when HEAD is exactly on a tag, that the tag equals `v$(cat VERSION)`.
- `kit_level` stays a feature tier (1 or 2), never compared against versions and never shown in the update table.

### 4.2 Component version sources

| Component | Installed version source | Latest version source | Manifest keys written on update |
|---|---|---|---|
| exakit (kit) | `kit/VERSION` live, fallback `kit.version` | GitHub releases of the kit repo | `kit.version`, `kit.source` |
| exapump | `components.exapump.version` | GitHub releases `exasol-labs/exapump` | `components.exapump.*`, `desired.exapump` |
| MCP server | `components.mcp_server.version` | PyPI `exasol-mcp-server` | `components.mcp_server.*`, `desired.mcp` |
| pyexasol | `components.pyexasol.version`, verified by a live venv probe | PyPI `pyexasol` | `components.pyexasol.*`, `desired.pyexasol` |
| Nano runtime | tag of `runtime.image` | Docker Hub `exasol/nano` tags, arch-filtered | `runtime.image`, `desired.runtime.nano`, `backups.nano_update.latest` |
| Personal runtime | `runtime.version` | GitHub releases `exasol/exasol-personal` | `runtime.launcher_version`, `desired.runtime.personal`, `backups.personal_upgrade.*` (`runtime.version` only after verified migration, section 9) |

### 4.3 Provenance and dev installs

`kit.source` keeps answering "where did this kit come from" and is never used as a version. Display combines identity and provenance: `Installed: 0.2.0` for a release install, `0.2.0 (main)` for a dev install.

A Dev Install is detected when the provenance ref is not `X.Y.Z` or `vX.Y.Z`. For dev installs, update-check shows Action `dev install` instead of an update suggestion, and `exakit update exakit` refuses with an explanation. `--force` is the deliberate opt-in to move a dev install onto the release channel.

`install.ps1` records provenance exactly like `install.sh` does today (repo@ref or local path), closing gap 3.

### 4.4 Pinned release sets

Each release ships a Pins file next to `VERSION`, naming the component versions tested together: exapump, MCP server, pyexasol, the Nano tag, and the Personal version. Both installers resolve component versions from the Pins by default, so every install of the same release produces identical bits on any machine, any day. The existing env overrides (`EXAKIT_EXAPUMP_VERSION`, `EXAKIT_NANO_TAG`, and friends) and `EXAKIT_VERSION_POLICY=latest` opt out per component or wholesale.

The Pins are also the downgrade mechanism: installing an older release (`EXAKIT_REF=vX.Y.Z`) applies that release's Pins, so moving back is as deterministic as moving forward. `exakit update` targets the latest release's Pins for components, falling back to per-component latest lookups when the Pins cannot be fetched.

## 5. Command surface and UX

### 5.1 `exakit update-check [target]`

Read-only, no confirmation, exits 0. The existing four-column table stays the single display primitive, with these changes: a `pyexasol` row, the fixed exakit Installed cell (4.1), the `dev install` Action (4.3), and the `migration pending` Action (9). All latest versions are resolved once per run and reused.

```
  Your components: current vs available
  -------------------------------------
Component    Installed          Latest             Action
exakit       0.1.0              0.2.0              exakit update exakit
nano         2026.2.0-nano.2    2026.3.0-nano.1    exakit update runtime
exapump      0.11.2             0.12.0             exakit update exapump
mcp          1.10.1             1.11.0             exakit update mcp
pyexasol     2.2.2              2.2.2              current
```

### 5.2 `exakit update [target]`

Flow: print the table for the target, then prompt `Apply these updates? [y/N]`, then apply, then print the Receipt. Latest versions resolved once and passed to the updaters (gap 9).

- `--yes` (or `EXAKIT_ASSUME_YES=1`) skips the prompt.
- No TTY and no `--yes`: print the table plus `Re-run with --yes to apply.` and exit 0, behaving as a check. This keeps unattended pipelines safe by default.

### 5.3 `exakit update` and `exakit update all`

With no target (or `all`), the run covers everything: tools first (`exapump -> mcp -> pyexasol`), then the database runtime behind its own gate, then kit self-update last.

- The tools apply after the first confirmation.
- The runtime never rides along silently. Inside the run it prints its full plan (section 5.4), offers the backup, and asks its own separate confirmation. Answering No leaves the runtime untouched and the run continues to self-update.
- Unattended (`--yes` or no TTY): the tools apply, the runtime step is skipped, and the run ends with the advisory `The database runtime has an update available. Apply it with: exakit update runtime --yes`. The runtime updates unattended only when it is the explicit target.
- Self-update runs last so one consistent code version orchestrates the entire run (gap 8). There is no re-exec: bash 3.2 and PowerShell 5.1 make in-place re-exec fragile. After self-update: `exakit was updated to X.Y.Z. The new version takes effect on the next command.` If a broken updater must be replaced first, run `exakit update exakit` alone, then re-run `exakit update`.

### 5.4 `exakit update runtime`

The guarded path, shared mental model for both runtimes: plan, optional or required backup, explicit confirm, apply, verify.

Nano flow:

1. Plan: from-tag and to-tag, `the container is recreated, the data volume '<name>' is kept`, the volume's estimated size, and a downtime warning.
2. Automatic Backup: a real data-level Backup of the volume is created before anything changes, using the already-present old image and an entrypoint override (`docker run --rm --entrypoint tar -v <vol>:/exa:ro -v <backups>:/out <old-image> czf /out/<stamp>-<from>-to-<to>.tar.gz -C / exa`). No question is asked. The user is never the safety mechanism. `--no-backup` is the explicit opt-out for constrained disks or throwaway installs.
3. Confirm, then: pull new image, stop and remove the container, recreate on the same volume, wait until ready.
4. On failure: automatic restart on the old image (existing behavior), stated honestly as best-effort (10). `exakit update runtime --restore <archive>` recreates the volume from a Backup and restarts on the recorded previous image.
5. The existing metadata JSON stays and is called a Snapshot. The tarball is a Backup. The two are never conflated in messages (gap 6).

Personal flow: same-major updates get the confirm prompt, an automatic deployment Backup, and the launcher reinstall. Major updates keep the staged `--plan`, `--backup`, `--apply` commands unchanged, and `--apply` now records Migration Pending (section 9) instead of leaving silent stale state.

### 5.5 Flags and environment

| Control | Meaning |
|---|---|
| `--yes` / `EXAKIT_ASSUME_YES=1` | Skip the confirm prompt (runtime plan output still prints in full) |
| `--force` / `EXAKIT_ALLOW_DOWNGRADE=1` | Permit a non-newer target: downgrade, dev-install replacement, indeterminate comparison |
| `--no-backup` | Skip the automatic pre-update data Backup (the only opt-out, backups are otherwise always created) |
| `--plan` / `--backup` / `--apply` / `--complete` | Personal staged major upgrade, plus migration verification |
| `--restore <archive>` | Recreate the Nano volume from a Backup |
| No TTY, no `--yes` | Table plus hint, exit 0, nothing applied |

## 6. Per-component upgrade paths

### 6.1 exakit (kit self-update)

Mechanism (bash, existing, `common.sh:954`): download the release tarball, stage to temp, validate required files (now including `VERSION`), back up `~/.exasol-starter-kit/kit` to `kit.backup-<timestamp>`, swap, reinstall the `exakit` binary, rewrite `kit.source` and `kit.version`. Restore the backup on any failure. New: PowerShell gains the twin `Update-ExakitSelf` with identical staging and backup semantics, and `install.ps1` keeps a backup of the old kit dir when re-downloading (gap 4). Never touches the database, credentials, or MCP state.

### 6.2 exapump

Re-download from the GitHub release with SHA-256 verification (pinned digest or release-API digest), smoke test, profile refresh, manifest write. Unverified binaries stay refuse-by-default (`EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1` is the documented escape hatch), with a clearer message that names the failed verification source (gap 12, decision in 14).

### 6.3 MCP server

Existing: snapshot client configs, re-prime `exasol-mcp-server@<version>` via uvx, validate. New: after a successful update, offer to refresh the managed client configs immediately (perform it under `--yes`), using the snapshot plus `exakit mcp-restore` as the safety net, so clients do not stay pinned to the old version (gap 11).

### 6.4 pyexasol (new target)

Upgrade the package inside the managed venv, then an import-and-version smoke test as the same read-only user flow used at install, then manifest write. Appears in the table and in `all` (gap 5).

### 6.5 Nano runtime

As 5.4. Validation before swap: image pulled successfully. Rollback: automatic old-image restart on failed start or readiness timeout, plus the new Backup and `--restore` for data-level recovery. Honest limit, stated in output and docs: if the new image migrated the on-disk format, the old image may not start against the migrated volume, which is exactly why the Backup is created automatically before the change.

### 6.6 Personal runtime

Existing staged flow. The Backup is a tarball of the whole deployment directory (runtime plus data). `--apply` reinstalls the launcher only and never claims the data migration happened: it records Migration Pending. Windows: Personal remains report-only (no Personal runtime on Windows).

## 7. Safety invariants

Normative rules every implementation change must keep true:

1. Database content and credentials survive every update. Only `exakit uninstall` deletes data.
2. The runtime is never changed without its own explicit confirmation, and never in an unattended run unless it is the explicit target. A runtime change always prints its plan first.
3. No silent downgrade. Applying requires a definite "newer" verdict from the shared comparison. Anything else requires `--force` and prints a downgrade banner.
4. Kit self-update is staged: validate, back up, swap, restore on failure.
5. Every mutating update records a Snapshot or Backup and its manifest handle (`backups.<op>.latest`) before mutating.
6. Every update run is logged to the existing log directory, and the Receipt states exactly what changed.
7. Both shells behave identically for every command in this spec (section 11).

## 8. Downgrade and pinning policy

The shared comparison (`exakit_version_newer` and its PS twin) is the only comparison used anywhere. Verdicts:

| Verdict | update-check Action | `exakit update` behavior |
|---|---|---|
| latest newer than installed | `exakit update <component>` | proceeds after confirm |
| equal | `current` | no-op, `component: current (A)` |
| installed newer, or indeterminate | `inspect` | refuses without `--force`, explains why |
| dev install (kit only) | `dev install` | refuses without `--force` |

The bash no-Python fallback comparison is indeterminate beyond majors: display may say `inspect`, updaters must refuse without `--force`. Installs are pinned by default (4.4). `exakit update` moves components to the latest release's Pins, and `--force` remains the only path to downgrades or off-train versions.

## 9. Migration-pending lifecycle

New manifest state, set by Personal `--apply`:

```
runtime.migration = { pending: true, from: "2.1.0", to: "3.0.0", backup: "<path>", created_at: "<ts>" }
```

- update-check shows the personal row's Action as `migration pending (2.1.0 -> 3.0.0): exakit update runtime --complete`, distinct from "update available". `exakit status` prints one warning line while pending.
- `exakit update runtime --complete` verifies rather than trusts: it queries the running database's actual version through the existing SQL plumbing and only when it matches `migration.to` sets `runtime.version = to` and clears the state. `--complete --force` is the manual override when verification cannot run.
- A fresh reinstall of the runtime also clears the state.

## 10. Failure handling and rollback

| Component | Failure leaves | Automatic recovery | Manual recovery |
|---|---|---|---|
| exakit self | old kit restored from staged backup | yes, restore-on-failure | `kit.backup-<ts>` directory |
| exapump | old binary untouched until verified download | n/a, install is atomic replace | re-run `exakit update exapump` |
| MCP server | old package still resolvable, configs snapshotted | validation gate before configs change | `exakit mcp-restore` |
| pyexasol | venv rolled back by re-running the installer step | smoke test gate | re-run update |
| Nano | container recreated on old image, same volume | yes, best-effort image rollback | `--restore <archive>` from the Backup |
| Personal | launcher backup tarball recorded | none, staged flow only | untar the deployment Backup |

Rollback failures are errors, not warnings, and name the manual recovery path.

## 11. Platform parity

bash 3.2 and PowerShell 5.1 twins stay mirrored. The parity fills this spec requires:

| bash | PowerShell | Status |
|---|---|---|
| `exakit_update_self` | `Update-ExakitSelf` | new on PS (gap 4) |
| `install.sh` provenance recording | `install.ps1` provenance recording | new on PS (gap 3) |
| pyexasol updater | pyexasol updater | new on both (gap 5) |
| arch-filtered Docker tag lookup | remove the arch-blind override in `exakit.ps1:299` | fix on PS (gap 10) |
| Nano Backup and `--restore` | same via `Update-Nano` additions | new on both |
| confirm and Receipt flow | same | new on both |

## 12. Implementation plan

Each phase leaves the kit releasable and maps to `## Unreleased` changelog bullets.

Phase 1, correctness and parity: (1) shared semver gate in every updater, interim `EXAKIT_ALLOW_DOWNGRADE` (gap 1); (2) remove the arch-blind Docker-tag override (gap 10); (3) `install.ps1` provenance recording (gap 3); (4) single latest-resolution pass per run (gap 9); (5) clearer exapump digest failure message (gap 12).

Phase 2, kit versioning and pins: (6) `VERSION` file, live read, manifest `kit.version`, self-update file check (gap 2), plus the Pins file with default-pinned install resolution in both installers (4.4); (7) release checklist plus `tests/release-consistency.sh`, `## Unreleased` section in the changelog; (8) `Update-ExakitSelf` and installer kit-dir backup on PS (gap 4); (9) dev-install detection, marker, and exemption.

Phase 3, UX and guarded runtime: (10) table-confirm-apply-receipt flow with `--yes` and no-TTY behavior; (11) the combined `update` flow with the gated runtime step, self-update last, and the unattended advisory (gap 8); (12) pyexasol target in both shells (gap 5); (13) full downgrade policy with `--force` (gap 1); (14) Nano plan, automatic Backup with `--no-backup` opt-out, `--restore`, components targeting the latest release's Pins (gap 6); (15) migration-pending state and `--complete` (gap 7); (16) MCP client-config refresh after update (gap 11).

Phase 4, tests and docs: (17) integration update tests and dry-run-matrix extensions (gap 13); (18) README "Keeping the kit up to date" in end-user voice, AGENTS.md runbook entry, QUICKSTART note.

## 13. Verification

Automated, per platform:

- Tool upgrade round-trip: fresh install pinned to n-1 releases (`EXAKIT_REF=v0.1.0`, component version pins), load sample data, record dataset row counts and credential file hashes, run `exakit update all --yes`, assert manifest versions bumped, table shows all current, kit backup exists, row counts byte-identical, credential hashes unchanged, `exakit mcp-doctor` passes.
- Runtime upgrade with data survival (Nano): install at an old tag, create a marker table, `exakit update runtime --backup --yes`, assert new tag running, marker rows intact, Backup archive lists `/exa`, Snapshot recorded.
- Downgrade guard: seed a manifest version newer than latest, assert every updater refuses non-zero without `--force` and proceeds with the banner under `--force`.
- Self-update: from a v0.1.0 install, `exakit update exakit --yes`, assert kit dir replaced, backup sibling present, `VERSION` and `kit.version` match, next `exakit` invocation works.
- No-TTY: `exakit update all < /dev/null` applies nothing, exits 0, prints the hint. `exakit update --yes` without a TTY applies the tools, skips the runtime, and prints the runtime advisory.
- Release consistency: `tests/release-consistency.sh` on every push and tag.

Manual release gate, mirroring the kit's T&E discipline, on macOS Personal, Windows Docker Desktop, and WSL Podman: fresh old-version install, data load, `update all`, `update runtime`, then verify data, credentials, MCP client configs, and an all-current table. Personal additionally walks a simulated major with plan, backup, apply, and `--complete`. Results recorded in the release notes.

## 14. Risks and open questions for review

1. Nano tag semantics: is the Docker Hub tag scheme strict semver, and does a major tag change imply an on-disk format change? The backup-default heuristic depends on this. Fallback: always default Yes.
2. Resolved during review: the runtime Backup is automatic on every update, never a question to the user. `--no-backup` is the only opt-out.
3. Personal majors stay vendor-manual. Confirm the database-version metadata query used by `--complete` works across Personal versions.
4. GitHub API rate limits (60/hour unauthenticated) can blank the Latest column. Single-pass resolution plus honoring `GITHUB_TOKEN` mitigates. Is a short-lived cache worth it, or over-engineering?
5. exapump digest trust: keep refuse-by-default with the env escape hatch, or maintain a pinned sha256 list per kit release (couples kit releases to exapump releases)? Recommendation: the former.
6. Dev-install `--force` on a `local:` install replaces a developer's working copy under the kit home. Acceptable, or refuse outright for `local:`?
7. Windows self-replacement: `Update-ExakitSelf` rewrites scripts that may back the running process. Self-last ordering avoids sourcing new files mid-run. Needs an explicit test.
8. tar availability inside the Nano image for the entrypoint-override Backup. Verify once; the busybox fallback adds a network dependency.
9. On machines where the Python bootstrap failed, version comparison is indeterminate beyond majors, making updates force-only. Recommendation: accept, safety over convenience.
