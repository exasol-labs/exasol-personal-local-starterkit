# Version bump proposal: exapump 0.14.1, personal 2.5.0, uv 0.13.9

Written by the `versions-bump` workflow on 2026-11-20 03:32 UTC from `main` at 4d198cf6b3d5. This branch is a proposal: nothing reaches users until a pull request from it is reviewed and merged.

| Component | Was | Now | Upstream release | Digests | Min kit |
|---|---|---|---|---|---|
| `exapump` | 0.14.0 | **0.14.1** | [v0.14.1](https://github.com/exasol-labs/exapump/releases/tag/v0.14.1) | 5 of 5 recomputed | - |
| `personal` | 2.4.0 | **2.5.0** | [v2.5.0](https://github.com/exasol/exasol-personal/releases/tag/v2.5.0) | 5 of 5 recomputed | - |
| `uv` | 0.13.8 | **0.13.9** | [0.13.9](https://github.com/astral-sh/uv/releases/tag/0.13.9) | 5 of 5 recomputed | - |

## exapump 0.14.0 -> 0.14.1

- linux-aarch64 needs glibc 2.28 (an older system runs it through the kit's container shim)
- linux-x86_64 needs glibc 2.28 (an older system runs it through the kit's container shim)
- checked: downloaded linux-aarch64, linux-x86_64, macos-aarch64, macos-x86_64, windows-x86_64 and hashed each

## personal 2.4.0 -> 2.5.0

- checked: newest stable release of exasol/exasol-personal on GitHub
- checked: downloaded the launcher for linux-arm64, linux-x86_64, macos-arm64, macos-x86_64, windows-x86_64 from https://x-up.s3.eu-west-1.amazonaws.com/releases/exasol-personal and hashed it

## uv 0.13.8 -> 0.13.9

- min_version stays 0.13.4 (a security floor, never moved by this bot)
- ACTION: the offline tables exakit_uv_pinned_sha256 (common.sh) and Get-ExakitUvPinnedSha256 (exakit-common.ps1) still name 0.13.8; update them on this branch or uv-digest-verify fails
- checked: downloaded astral's 5 archives and hashed each

## Files changed beside versions.json

- `setup/lib/common.sh`
- `setup/lib/exakit-common.ps1`
- `setup/lib/runtime-personal.ps1`

## What this workflow checked before pushing

- looked up the newest stable release of every advertised component at its own upstream (GitHub releases, PyPI); release candidates, betas, yanked and draft releases are skipped
- downloaded every asset whose digest is pinned and hashed it here; no digest is copied from a release page
- a component whose assets could not all be fetched (or measured) was left alone, never advertised with stale pins
- measured each Linux scheduler engine's glibc floor from its ELF version references
- resolved a bumped MCP version's launcher image on Docker Hub (both Linux architectures)
- moved the fallback constants that must equal the manifest (the COUPLED table)
- wrote versions.json only after proving it canonical (python -m json.tool)

## What CI checks on this branch

The bump workflow starts `versions` and `windows-ps51` on this branch itself (a push made with the workflow token starts no workflow). Their runs: https://github.com/exasol-labs/exasol-personal-local-starterkit/actions?query=branch%3Achore%2Fversions-bump

- validate: canonical versions.json, schema, the MCP constant
- personal-s3-digest-verify, digest-verify, uv-digest-verify: every pinned asset downloaded and hashed
- upstream-exists: each advertised version is published (PyPI not yanked, GitHub tags, vsix digest)
- component-smoke on linux x86_64 and arm64, macOS arm64 and x86_64, Windows: each changed component downloaded, verified and run there (`--version`, `--help`, a clean-venv install and import)
- the shell, PowerShell 5.1 and Python suites, including the fallback constants (tests/versions-manifest.sh)

## Open the pull request

GitHub Actions may not open pull requests in this repository, so open it by hand:

    git fetch origin chore/versions-bump
    gh pr create -R exasol-labs/exasol-personal-local-starterkit --base main --head chore/versions-bump --title 'Bump advertised versions: exapump 0.14.1, personal 2.5.0, uv 0.13.9' --body-file <(git show origin/chore/versions-bump:.github/versions-bump-report.md)

or in the browser: https://github.com/exasol-labs/exasol-personal-local-starterkit/compare/main...chore/versions-bump?expand=1

This file (`.github/versions-bump-report.md`) only describes this proposal and is replaced by the next one; it is a commit of its own, so it can be dropped from the pull request: `git rm .github/versions-bump-report.md`.

## Before merging

- [ ] The offline uv tables (`exakit_uv_pinned_sha256`, `Get-ExakitUvPinnedSha256`) name uv 0.13.9 for every platform.
- [ ] Severity is `normal` on everything above. Raise it to `recommended` or `critical` only if people need to know now.
- [ ] These versions were tested **together**, not just individually. The Tagged column is a tested set.
- [ ] `kit.version` is untouched, which is correct unless kit scripts changed too.
- [ ] `versions` and `windows-ps51` are green on this branch (component-smoke ran every changed component on each OS).
