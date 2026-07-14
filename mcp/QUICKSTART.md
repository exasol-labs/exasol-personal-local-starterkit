# Quickstart

This subsystem now has a working Python implementation plus lifecycle tests.

## Current Status

- Shipped adapters (eight): Claude Desktop, Claude Code (CLI), Codex, Cursor, VS Code (GitHub Copilot), Gemini CLI, OpenCode, Continue
- Permanent runtime client setup works for all eight
- Supported operations: discover, configure, validate, repair, backup, restore, doctor, uninstall, status
- Explicitly blocked operation: install
- Runtime files are generated under the request-specific runtime root, defaulting to `~/.exasol-starter-kit`

## Read In Order

1. [AGENT.md](AGENT.md)
2. [requirements.md](docs/requirements.md)
3. [architecture.md](docs/architecture.md)
4. [design.md](docs/design.md)
5. [api-design.md](docs/api-design.md)
6. [service.py](service.py)
7. [test_service.py](tests/test_service.py)

## Test Command

```bash
python3 -m unittest discover -s mcp/tests -v
```

## Lifecycle Commands

The installed user-facing wrapper now exposes the managed MCP lifecycle directly:

```bash
exakit mcp-setup
exakit mcp-status
exakit mcp-validate
exakit mcp-doctor
exakit mcp-repair
exakit mcp-remove
exakit mcp-restore
```
