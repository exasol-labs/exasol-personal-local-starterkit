# Add-ons and downloads (/security/add-ons-and-downloads)



The kit pins what it downloads. Each pin is a version in `versions.json`, and where the kit can check the file, a SHA-256 digest. The download is checked before anything is unpacked, and a file that fails the check is removed.

## What is pinned, and how [#what-is-pinned-and-how]

Every pin is in `versions.json` at the root of the repository. The kit reads the copy that shipped with it, not a copy fetched from the network. Each module says so in a comment, for example "The kit copy's own pin, never the fetched document (SEC-13)" in `setup/lib/exapump.sh`.

| Item                                  | Version pinned | SHA-256 pinned                             | Where the check is                                                                                                                               |
| ------------------------------------- | -------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Semantic Views (`semantic-views`)     | Yes            | Yes, for the archive                       | `_download()` and `_unpack()` in `marketplace/addons/semantic_views.py`                                                                          |
| Exasol Scheduler (`exasol-scheduler`) | Yes            | Yes, per platform                          | `_download()` in `marketplace/addons/exasol_scheduler.py`                                                                                        |
| Exasol for VS Code (`exasol-vscode`)  | Yes            | Yes, for the VSIX                          | `install()` in `marketplace/addons/exasol_vscode.py`, after the download                                                                         |
| JSON Tables (`json-tables`)           | Yes            | Yes, for the wheel and the platform assets | `_asset()` in `marketplace/addons/json_tables.py`                                                                                                |
| UDF devkit (`udf-devkit`)             | Yes            | Yes, for each container, with its size     | `verify()` and `fetch()` in `marketplace/udf_container.py`                                                                                       |
| exapump                               | Yes            | Yes, per platform                          | `exapump_expected_sha256()` in `setup/lib/exapump.sh`                                                                                            |
| uv                                    | Yes            | Yes, per platform                          | `exakit_uv_pinned_sha256()` and `exakit_uv_install_pinned()` in `setup/lib/common.sh`; `Install-ExakitUvPinned` in `setup/lib/exakit-common.ps1` |
| Dash Server (`dash-server`)           | Yes            | No                                         | Installed with `uv pip install` of the pinned release URL, in `marketplace/addons/dash_server.py`                                                |
| dbt-exasol, pyexasol, notebook        | Yes            | No                                         | Version only, in `versions.json`                                                                                                                 |

## The order of checks [#the-order-of-checks]

For the archive-based add-ons, the code follows the same order. Semantic Views is the clearest example:

1. `_expected_digest()` takes the digest from the kit's own pin, when the version matches. Otherwise it reads the release's `.sha256` file.
2. `_download()` streams the archive to disk and computes its SHA-256 as it writes. It compares the digest with the expected one. On a mismatch it raises `Checksum mismatch` and deletes the archive.
3. Only then does `_unpack()` run. It refuses any archive entry whose resolved path is outside the destination folder (`the Semantic Views archive holds a path outside its folder`). It also requires `tools/install.py` and at least one `build/install/*.sql` file.

The UDF containers follow the same pattern. `fetch()` in `marketplace/udf_container.py` downloads to a temporary `.part` file, and `verify()` checks the size and the SHA-256 before the file is moved into the cache. A cached file is verified again when it is used, and removed if it fails. The mirror setting, `EXAKIT_UDF_CONTAINERS_MIRROR`, changes where the file comes from, not whether it is checked.

Downloads must use `https://`. `_https()` in `marketplace/addons/semantic_views.py` refuses any other scheme and refuses a redirect that leaves HTTPS. The UDF path checks the redirect the same way.

## Where a digest comes from when the pin does not match [#where-a-digest-comes-from-when-the-pin-does-not-match]

A pin is used only when the requested version is the pinned one. For other versions, the code can take the digest from the release itself:

* Semantic Views reads the release's own `.sha256` file.
* Exasol Scheduler's `_digest()` reads the release's `.sha256` file, and then the release API.
* exapump's `exapump_expected_sha256()` falls back to a digest in the release API.

These digests come from the same host as the file. They confirm that the download matches what that release says. They do not confirm that the release is one the kit's maintainers reviewed. Only the `versions.json` pin does that.

## Escape hatches [#escape-hatches]

Three add-ons can install without a checksum when you set an environment variable to `1`. Without the variable, a missing checksum is refused.

| Add-on             | Variable                                   | What it does                                                                                   | Where                                                     |
| ------------------ | ------------------------------------------ | ---------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| Exasol for VS Code | `EXAKIT_ALLOW_UNVERIFIED_EXASOL_VSCODE`    | Installs the VSIX with no digest                                                               | `marketplace/addons/exasol_vscode.py`                     |
| Exasol Scheduler   | `EXAKIT_ALLOW_UNVERIFIED_EXASOL_SCHEDULER` | Installs the archive with no digest                                                            | `_download()` in `marketplace/addons/exasol_scheduler.py` |
| JSON Tables        | `EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES`      | Installs the asset with no digest. The error message says "a maintainer may explicitly set" it | `_asset()` in `marketplace/addons/json_tables.py`         |

Do not set these for a normal install. A setting left in your shell applies to every later install.

## Skills are copied byte for byte [#skills-are-copied-byte-for-byte]

The AI skills the kit ships from other repositories are copies of upstream files. The list is in `skills/upstream.json`, with the repository, a pinned commit or tag, and the path. `tools/sync_upstream_skills.py` writes `skills/upstream.lock.json`, which records a commit and a SHA-256 for every file, and each copy's license file. The script's `--check` mode fails when a copy differs from the lock, or when a pin falls behind the version the kit installs. The repository's notes say the copies are never edited by hand, and `tests/skills.sh` checks them against the lock.

## Add-ons the kit did not install [#add-ons-the-kit-did-not-install]

The kit leaves an installation it did not make alone:

* `system_present()` in `marketplace/addons/dash_server.py` treats a `dash-server` command on your PATH as managed outside the kit when the kit has no receipt for it. The kit never installs over it, updates it or removes it.
* `marketplace/addons/exasol_vscode.py` says: "A user-installed extension remains the user's installation." It is listed as managed outside the kit and never offered again.

## Removing an add-on [#removing-an-add-on]

```bash
exakit uninstall dash-server --dry-run    # print what would be removed, change nothing
exakit uninstall dash-server --yes        # remove that one add-on
exakit uninstall --dry-run                # the full plan
```

`setup/help/exakit.json` says `--dry-run` "previews the full plan and changes nothing". The full uninstall keeps uv and the PATH line in your shell profile, because uv may be used by other tools and the profile line is shared (the comment above `exakit_uninstall_run()` in `setup/lib/common.sh`).

## Logs [#logs]

Each add-on's output goes to `logs/marketplace.log` in the kit home, created at mode 600. `run_logged()` in `marketplace/runtime.py` replaces the values of any environment variable whose name ends in `PASSWORD`, `TOKEN`, `_KEY` or `SECRET` before the output is written.

## Limits [#limits]

* Dash Server, dbt-exasol, pyexasol and the notebook package are pinned by version only. The kit checks no digest for them.
* Three add-ons have an escape hatch that installs without a digest.
* Digests taken from a release, rather than from `versions.json`, check the download against that release only.
* The checks are SHA-256 digests. The add-on modules in `marketplace/` contain no signature verification.
