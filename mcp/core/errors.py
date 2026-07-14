"""Subsystem-specific exceptions."""

from __future__ import annotations


class MCPSubsystemError(Exception):
    """Base exception for recoverable subsystem failures."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class BlockingOperationError(MCPSubsystemError):
    """Raised when an operation is blocked before mutation."""
