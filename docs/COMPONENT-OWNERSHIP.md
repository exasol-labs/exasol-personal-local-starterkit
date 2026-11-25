# Component ownership and reuse

The kit reuses compatible tools it finds instead of reinstalling them. It configures its own connections and keeps its credentials and helper environments beneath `EXAKIT_HOME` (normally `~/.exasol-starter-kit`). A reused component stays yours.

| Owner | Install / configure | Update | Uninstall |
|---|---|---|---|
| `kit` | Created by this kit; keep it on a repeat install | Managed by the kit | Removed when selected |
| `user` | Reuse and configure; preserve the existing installation | Update with its original tool | Preserved |
| `unknown` | Older shared installation without an ownership record | Preserved until provenance is known | Preserved |

`exakit version` shows an **Owner** column. `exakit version --json` and `exakit marketplace --list --json` include `ownership` and `installed_by_kit` for each component. An available, uninstalled add-on has `ownership: null`. A reused version row has `status: "external"` and no automatic update command.

The ownership flag is recorded in the kit's `manifest.json`; no extra install option is needed. The Exasol launcher (`components.personal`) and the database deployment (`runtime`) have separate receipts, because installing a launcher does not make an existing database belong to the kit. Exapump and pyexasol have their own receipts. New marketplace installs are recorded separately too. Repeat reuse keeps a kit receipt only when its recorded path matches. The kit runs its own Exasol launcher, from its own folder, and never replaces, moves or deletes a launcher of yours.

## The database

The kit's database is always the Exasol Personal deployment `starter-kit-local`. It is `kit` when the kit deployed it. It is `user` when it is a database of yours that you picked in the install's question, or one that kit 0.3.0 was allowed to use. Your other databases are never the kit's.

| What the kit does | `kit` database | `user` database |
|---|---|---|
| Use it (the read-only MCP user, the sample data) | yes | yes |
| Rename it to `starter-kit-local` | made with that name | yes, when you pick it, or by the update from 0.3.0 |
| Stop, start and restart it, lift its 20-session limit, update it | yes | yes |
| Delete it (uninstall) | yes, with its data | never |
| Rebuild it from empty (`exakit repair-runtime`) | yes, its data is lost | yes, its data is lost, and it stays `user` |

An uninstall keeps a `user` database as `starter-kit-local` and drops only the logins the kit created inside it: the users `MCP_READONLY` and the Scheduler's `SCHEDULER_SVC`, and the roles `SEMANTIC_USER` and the preprocessor's, each kept when a user of yours holds it. A login you named for the kit, or one you had before, is kept, and the uninstall prints its `DROP USER` statement. A schema that a dropped login or role owns is kept: it goes to `SYS` first, and `exakit uninstall --dry-run` names each one. Your connections are kept, and the uninstall lists each one with its `DROP CONNECTION` statement. The kit's own launcher is removed unless another deployment still uses it and no launcher of yours on Exasol Personal 2.5 or newer can open it. It is then kept as `~/.local/bin/exasol` (Windows: `%USERPROFILE%\.local\bin\exasol.exe`) when nothing is there, else in the kit folder.

If an existing user-owned tool is broken or incompatible, the installer explains what needs repair and leaves it in place. It does not replace that tool to make setup succeed. The installer's internal force flag does not override ownership.

New binary receipts include a SHA-256 digest. If a user replaces the executable at the same path, the old receipt no longer permits the kit to update or remove that replacement.

The kit's exapump connection profile now lives at `~/.exasol-starter-kit/exapump/config.toml`. Its commands pass that profile through `EXAPUMP_CONFIG`; the user's `~/.exapump` store is preserved. Prefer `exakit sql` for kit queries. For a direct exapump invocation on macOS/Linux:

```sh
EXAPUMP_CONFIG="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}/exapump/config.toml" \
  exapump sql -p starter-kit 'SELECT CURRENT_DATE'
```

On PowerShell:

```powershell
$kitHome = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME '.exasol-starter-kit' }
$env:EXAPUMP_CONFIG = Join-Path $kitHome 'exapump/config.toml'
exapump sql -p starter-kit 'SELECT CURRENT_DATE'
```

A working pyexasol in the Python already on your PATH can be reused without installing packages into that Python.

Full uninstall removes kit-owned resources and kit configuration. It preserves reused binaries, shared exapump profiles, a `user` database and its data (see The database above), and explicitly recorded user component paths even when they are beneath the kit home. Legacy private package environments recorded under the kit home retain their existing kit-managed lifecycle; legacy shared binaries and databases without receipts are treated as unknown and kept. Review `exakit uninstall --dry-run` before removal.
