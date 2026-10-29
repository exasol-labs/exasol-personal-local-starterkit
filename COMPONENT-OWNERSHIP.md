# Component ownership and reuse

The kit reuses compatible tools it finds instead of reinstalling them. It configures its own connections and keeps its credentials and helper environments beneath `EXAKIT_HOME` (normally `~/.exasol-starter-kit`). A reused component stays yours.

| Owner | Install / configure | Update | Uninstall |
|---|---|---|---|
| `kit` | Created by this kit; keep it on a repeat install | Managed by the kit | Removed when selected |
| `user` | Reuse and configure; preserve the existing installation | Update with its original tool | Preserved |
| `unknown` | Older shared installation without an ownership record | Preserved until provenance is known | Preserved |

`exakit version` shows an **Owner** column. `exakit version --json` and `exakit marketplace --list --json` include `ownership` and `installed_by_kit` for each component. An available, uninstalled add-on has `ownership: null`. A reused version row has `status: "external"` and no automatic update command.

The ownership flag is recorded in the kit's `manifest.json`; no extra install option is needed. The Exasol launcher (`components.personal`) and the database deployment (`runtime`) have separate receipts, because installing a launcher does not make an existing database belong to the kit. Exapump and pyexasol have their own receipts. New marketplace installs are recorded separately too. Repeat reuse keeps a kit receipt only when its recorded path matches.

If an existing user-owned tool is broken or incompatible, the installer explains what needs repair and leaves it in place. It does not replace that tool to make setup succeed. The installer's internal force flag does not override ownership.

New binary receipts include a SHA-256 digest. If a user replaces the executable at the same path, the old receipt no longer permits the kit to update or remove that replacement.

The kit's exapump connection profile now lives at `~/.exasol-starter-kit/exapump/config.toml`. Its commands pass that profile through `EXAPUMP_CONFIG`; the user's `~/.exapump` store is preserved. Prefer `exakit sql` for kit queries. For a direct exapump invocation on macOS/Linux:

```sh
EXAPUMP_CONFIG="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}/exapump/config.toml" \
  exapump sql -p starter-kit 'SELECT CURRENT_TIMESTAMP'
```

On PowerShell:

```powershell
$kitHome = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME '.exasol-starter-kit' }
$env:EXAPUMP_CONFIG = Join-Path $kitHome 'exapump/config.toml'
exapump sql -p starter-kit 'SELECT CURRENT_TIMESTAMP'
```

A working pyexasol in the Python already on your PATH can be reused without installing packages into that Python. Notebook Connector and notebook dependencies still use the kit's separate notebook environment, so notebook setup can add its tested packages without changing your Python installation.

Full uninstall removes kit-owned resources and kit configuration. It preserves reused binaries, shared exapump profiles, reused database data, and explicitly recorded user component paths even when they are beneath the kit home. Legacy private package environments recorded under the kit home retain their existing kit-managed lifecycle; legacy shared binaries and databases without receipts are treated as unknown and kept. Review `exakit uninstall --dry-run` before removal.

These changes are local source work until published. Use the local checkout command in [the Mac runbook](MANUAL-RUNBOOK.md) when testing this version. PowerShell behavior has automated fixture coverage; live Windows verification is deferred.
