# MCP Subsystem

This directory contains the MCP access and client configuration subsystem for the Exasol Personal Local Starter Kit. End users drive it through `exakit mcp-setup`, `exakit mcp-doctor`, and the other `exakit mcp-*` commands — see the [root README](../README.md) and [QUICKSTART](../QUICKSTART.md). This page is the map for anyone reading the code.

## Structure

```text
mcp/
├── AGENT.md          # guardrails for AI agents working in this subsystem
├── QUICKSTART.md     # subsystem-level usage notes
├── docs/             # architecture, design, API contracts, security, QA
├── core/             # models, serialization, errors
├── adapters/         # one adapter per supported AI client
├── security/         # policy checks (loopback-only, stdio, credentials)
├── validator/        # five-stage post-setup validation
├── runtime/          # manifest, snapshots, fail-closed runtime loader
├── diagnostics/      # doctor report assembly
├── tests/            # unit + lifecycle coverage
└── README.md
```

## Current Implementation Scope

- Public orchestration entry point: [service.py](service.py)
- Client adapters (eight shipped): [claude_desktop.py](adapters/claude_desktop.py), [claude_code.py](adapters/claude_code.py), [cursor.py](adapters/cursor.py), [codex.py](adapters/codex.py), [vscode_copilot.py](adapters/vscode_copilot.py), [gemini_cli.py](adapters/gemini_cli.py), [opencode.py](adapters/opencode.py), [continue_dev.py](adapters/continue_dev.py)
- Runtime manifest and snapshots: [manifest.py](runtime/manifest.py), [snapshots.py](runtime/snapshots.py)
- Installed-runtime permanent client setup: [exakit.py](runtime/exakit.py), [cli.py](cli.py)

## Runtime Client Setup

When the starter kit runtime is already installed and its manifest contains the MCP connection details, the MCP package can configure any of the eight supported clients:

- Claude Desktop
- Claude Code (CLI)
- Codex
- Cursor
- VS Code (GitHub Copilot)
- Gemini CLI
- OpenCode
- Continue

The setup menu always shows the full list: clients that are installed but not yet connected are selectable and pre-selected; clients that are already connected or not installed appear greyed out with the reason. Discovery comes from each adapter's own detection (`discover-clients`).

See [architecture.md](docs/architecture.md) for the governing component boundaries.
