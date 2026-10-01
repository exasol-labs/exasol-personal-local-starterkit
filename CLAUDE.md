# Claude Code notes for this repo

**Installing the kit?** Follow [AGENTS.md](AGENTS.md) — it is the full agent
runbook (install command, env-var answers, verification, uninstall).

Claude-Code-specific tips:

- The macOS first install deploys a database — **usually in under 2 minutes**.
  Run the install command
  **in the background** and poll `exakit status` until it reports running — do
  not treat a long-running or timed-out foreground call as a failure.
  Re-running the installer is safe; it resumes.
- Answer install choices with env vars using **names, not menu numbers**
  (e.g. `EXAKIT_MCP_CLIENTS=claude,codex`, `EXAKIT_DATASETS=tpch`).
- Never print or log database passwords; they live in files under
  `~/.exasol-starter-kit/credentials/` and scripts read them from there.

Working on the code in this repo:

- Shell must stay **bash 3.2** compatible (macOS default); PowerShell must
  stay **5.1** compatible (no ternary, no `??`).
- **Adding an optional tool (marketplace add-on)?** Follow
  [MARKETPLACE.md](MARKETPLACE.md) — it is the full walkthrough with skeleton
  code. The short version: a `setup/lib/<id>.sh` + `.ps1` module pair
  (dash-server is the reference implementation), a `components.<id>` block in
  versions.json, one registry line each side
  (`exakit_marketplace_addons` in common.sh, `Get-ExakitMarketplaceAddons` in
  exakit-common.ps1), and a `setup/help/<id>.json` carrying `repo` + `tagline`,
  plus the two CI-guard entries. The add-on's one-line **description is never
  typed into this repo** — it is that repository's GitHub About, fetched and
  cached (`exakit_marketplace_addon_description`), with the tagline as the
  offline answer. Never add per-add-on case
  arms to the registry functions — the generic arms handle registered add-ons,
  and `tests/marketplace.sh` fails on hand-wired ones. Never install an
  add-on from the setup scripts; the marketplace and its closing offer are
  the only install paths.
- **Adding an AI skill?** Create `skills/<name>/SKILL.md` with `name` +
  `description` frontmatter (the description ends with a `Triggers —` list —
  that is how an agent decides to load it) and add a row to
  `skills/README.md`. That is the whole change: the registry is the
  filesystem, so no shell code names a skill. `tests/skills.sh` fails if one
  is ever hardcoded into `common.sh` or `exakit.ps1`. Bump
  `components.skills.version` in versions.json in the same PR: that bump is
  what makes `exakit update` on every installed kit fetch the new set from
  `main` — no kit release is needed for a skills change.
- `setup/lib/ui.sh` and `setup/lib/ui.ps1` are close twins of the shared
  visual layer (banner, palette, status glyphs, spinner, progress, panels):
  when you change a function that exists in both, mirror it in the other,
  including the wordmark bytes. They are not a strict 1:1 map — some helpers
  live in different files on each side (e.g. step rendering), so not every
  function has a peer.
- Do not add AI attribution to commits, PRs, code, or docs.
