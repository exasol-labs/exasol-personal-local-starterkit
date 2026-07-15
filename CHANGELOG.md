# Changelog

## 0.1.0

- First public release of the Exasol Personal Local Starter Kit.
- Feat: one-command installers for macOS (native Exasol Personal), Linux/WSL, and Windows (Exasol Nano container): `install.sh` and `install.ps1`, unattended-safe, with resume on re-run and a check-only preflight mode (`EXAKIT_PREFLIGHT=1`).
- Feat: the `exakit` lifecycle CLI: `status`, `info`, `start`/`stop`, `data-load`, MCP setup and maintenance (`mcp-setup`, `mcp-doctor`, `mcp-repair`, `mcp-remove`, `mcp-restore`), `logs`, `catalog`, and a guarded `uninstall`.
- Feat: MCP integration with a dedicated read-only database login, validated during setup and re-validated by `exakit mcp-doctor`. Supported clients: Claude (desktop and Claude Code), Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Continue.
- Feat: three bundled sample datasets (TPC-H retail, smart-meter energy, daily city weather), loaded and verified during install, each in its own schema.
- Feat: the `local-agent-ready-starter` agent skill, so a coding agent can drive the full setup and the inspect-before-run query loop.
- Docs: end-user README, QUICKSTART, per-OS quickstarts, an AGENTS.md runbook, data dictionary, example questions, and a guided first workflow.
- Verified: full test and evaluation runs on macOS (native), Windows (Docker Desktop), and WSL (Podman): 82/82 read-only security probes passed, byte-exact dataset counts on every platform, idempotent re-runs, clean uninstall.
