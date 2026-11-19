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
  (e.g. `EXAKIT_MCP_CLIENTS=claude,codex`, `EXAKIT_DATASETS=retail_sales`).
- Never print or log database passwords; they live in files under
  `~/.exasol-starter-kit/credentials/` and scripts read them from there.

Working on the code in this repo:

- Shell must stay **bash 3.2** compatible (macOS default); PowerShell must
  stay **5.1** compatible (no ternary, no `??`).
- **Adding an optional tool (marketplace add-on)?** Follow
  [MARKETPLACE.md](MARKETPLACE.md) — it is the full walkthrough. An add-on is
  Python; it has no shell or PowerShell code of its own. The short version: a
  `marketplace/catalog.json` row (`id`, a `github` block naming the
  repository, `backend: "python"`, `visible`, `default_version`; never a
  `label`), whose `url`, `name` and `about` `python3 tools/addon_github.py`
  fills from GitHub; the module `marketplace/addons/<id_with_underscores>.py`
  with its lifecycle functions (`dash_server.py` is the reference for a
  service), which `marketplace/metadata.py` turns into the hooks both shells
  call; a `components.<id>` block in versions.json; and a
  `setup/help/<id>.json` page (`kind: "addon"`) carrying `role` + `docs`.
  Then the guards that name every add-on: the id list in
  `tests/marketplace.sh`, the `expected` components in
  `.github/workflows/versions.yml`, and a mention in AGENTS.md
  (`tests/agents-rosters.sh`); `tests/test_addon_help.py` fails without the
  help page. Test the module in a `tests/test_marketplace_*.py`. The add-on's
  **name, link and description are never typed into this repo** — they are
  that repository's on GitHub: looked up only while installing and showing
  updates, cached, and the catalog's copy is the answer whenever a lookup
  fails. The one exception: an add-on the kit builds itself, with no
  repository of its own, whose `github` block names the upstream it is built
  on — its row's `kit_about` is the one line the kit writes in place of that
  upstream's About. Never add per-add-on case arms to the shell libraries —
  the generic registry handles registered add-ons, and `tests/marketplace.sh`
  fails on hand-wired ones.
- **Which add-ons an install adds by itself.** Exactly two, Dash Server and
  JSON Tables: `EXAKIT_AUTO_ADDONS` in `setup/lib/common.sh`,
  `$script:ExakitAutoAddons` in `exakit-common.ps1`. They install with no
  question, side by side, through `marketplace/apply.py`, and the install's
  add-ons table shows their progress. On macOS and Linux, with a terminal and
  the drawn table, they start earlier, in the background, while the data
  questions are on screen (`exakit_addons_early_begin`; `EXAKIT_ADDONS_EARLY=0`
  turns that off, documented in AGENTS.md); the table is then
  drawn at once, and each of their rows turns "Auto installed" once that
  add-on is in (one the early run did not get in is installed in the table).
  The Windows installer has no early run: its table installs the two at once.
  Without a terminal the two install at the add-ons step and nothing else is
  offered. One of the two is skipped when it does not apply on this machine
  (its module's `applicable_reason` says why: JSON Tables on Intel macOS, on
  Windows ARM64, or on a Linux whose glibc is older than its engine needs),
  when the kit already has it, or when it is on the machine outside the kit.
  Both are skipped when the database never installed, and in an installer
  run that `exakit update` started. A set `EXAKIT_MARKETPLACE_ADDONS` is the
  whole answer: exactly the ids it names install, and `none` installs
  neither. Every other add-on installs only when someone picks it in the
  add-ons table or names it (`exakit marketplace <id>`,
  `EXAKIT_MARKETPLACE_ADDONS`); `exakit data-load` also adds JSON Tables for
  a `.json` file. A setup script never calls an add-on's install itself: add
  an id to the auto list in both twins, or leave the add-on to the
  marketplace.
- **Adding an AI skill?** Create `skills/<name>/SKILL.md` with `name` +
  `description` frontmatter (the description ends with a `Triggers —` list —
  that is how an agent decides to load it) and add a row to
  `skills/README.md`. That is the whole change: the registry is the
  filesystem, so no shell code names a skill. `tests/skills.sh` fails if one
  is ever hardcoded into `common.sh` or `exakit.ps1`. Bump
  `components.skills.version` in versions.json in the same PR: that bump is
  what makes `exakit update` on every installed kit fetch the new set from
  `main` — no kit release is needed for a skills change.
- **A component already ships a skill?** Use it rather than writing one: add it to
  `skills/upstream.json` (repository, pinned ref, path; `addon:` when it belongs
  to an add-on) and run `python3 tools/sync_upstream_skills.py`. The copies are
  byte for byte plus a provenance line; never edit them by hand —
  `tests/skills.sh` checks them against `skills/upstream.lock.json` and fails
  when a pin falls behind the version the kit installs. The kit's own rules
  for every task live in one master skill, `skills/exakit/SKILL.md`.
- `setup/lib/ui.sh` and `setup/lib/ui.ps1` are close twins of the shared
  visual layer (banner, palette, status glyphs, spinner, progress, panels):
  when you change a function that exists in both, mirror it in the other,
  including the wordmark bytes. They are not a strict 1:1 map — some helpers
  live in different files on each side (e.g. step rendering), so not every
  function has a peer.
- Do not add AI attribution to commits, PRs, code, or docs.
