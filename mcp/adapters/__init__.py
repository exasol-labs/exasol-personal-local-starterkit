"""Client adapter implementations."""

from .claude_code import ClaudeCodeAdapter
from .claude_desktop import ClaudeDesktopAdapter
from .codex import CodexAdapter
from .continue_dev import ContinueAdapter
from .cursor import CursorAdapter
from .gemini_cli import GeminiCliAdapter
from .opencode import OpenCodeAdapter
from .registry import AdapterRegistry
from .vscode_copilot import VSCodeCopilotAdapter

__all__ = [
    "AdapterRegistry",
    "ClaudeCodeAdapter",
    "ClaudeDesktopAdapter",
    "CodexAdapter",
    "ContinueAdapter",
    "CursorAdapter",
    "GeminiCliAdapter",
    "OpenCodeAdapter",
    "VSCodeCopilotAdapter",
]
