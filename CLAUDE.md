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
- `setup/lib/ui.sh` and `setup/lib/ui.ps1` are close twins of the shared
  visual layer (banner, palette, status glyphs, spinner, progress, panels):
  when you change a function that exists in both, mirror it in the other,
  including the wordmark bytes. They are not a strict 1:1 map — some helpers
  live in different files on each side (e.g. step rendering and the Nano
  credential self-repair), so not every function has a peer.
- Do not add AI attribution to commits, PRs, code, or docs.
