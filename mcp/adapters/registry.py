"""Adapter registry."""

from __future__ import annotations

from mcp.core.errors import MCPSubsystemError

from .base import ClientAdapter
from .claude_code import ClaudeCodeAdapter
from .claude_desktop import ClaudeDesktopAdapter
from .codex import CodexAdapter
from .continue_dev import ContinueAdapter
from .cursor import CursorAdapter
from .gemini_cli import GeminiCliAdapter
from .opencode import OpenCodeAdapter
from .vscode_copilot import VSCodeCopilotAdapter


class AdapterRegistry:
    """Lookup table for supported adapters."""

    def __init__(self, adapters: list[ClientAdapter] | None = None) -> None:
        self._adapters = {
            adapter.adapter_id(): adapter
            for adapter in (
                adapters
                or [
                    ClaudeDesktopAdapter(),
                    ClaudeCodeAdapter(),
                    CursorAdapter(),
                    CodexAdapter(),
                    VSCodeCopilotAdapter(),
                    GeminiCliAdapter(),
                    OpenCodeAdapter(),
                    ContinueAdapter(),
                ]
            )
        }

    def all(self) -> list[ClientAdapter]:
        return list(self._adapters.values())

    def get(self, adapter_id: str) -> ClientAdapter:
        try:
            return self._adapters[adapter_id]
        except KeyError as exc:
            raise MCPSubsystemError(
                "client_not_found", f"Unsupported client adapter '{adapter_id}'."
            ) from exc
