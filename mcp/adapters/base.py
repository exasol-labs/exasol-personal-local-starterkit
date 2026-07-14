"""Adapter contracts for supported MCP clients."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from mcp.core.models import Finding, NextAction, ServerDefinition
from mcp.runtime.environment import ExecutionEnvironment


@dataclass
class AdapterCapabilities:
    supports_stdio: bool
    supports_http: bool
    supports_managed_file: bool
    supports_patch_mode: bool
    supports_env_block: bool
    requires_restart: bool
    platforms: tuple[str, ...]


@dataclass
class LocationResult:
    available: bool
    path: Path | None
    evidence: list[str] = field(default_factory=list)


@dataclass
class DetectionResult:
    detected: bool
    confidence: str
    location: LocationResult
    evidence: list[str] = field(default_factory=list)


@dataclass
class AdapterInspection:
    path: Path
    exists: bool
    document: dict[str, Any] | None
    file_valid: bool
    findings: list[Finding] = field(default_factory=list)
    managed_entry: dict[str, Any] | None = None
    managed_hash: str | None = None
    other_server_names: list[str] = field(default_factory=list)


@dataclass
class RenderResult:
    path: Path
    content: str | None
    managed_hash: str | None
    entry_name: str
    remove_file: bool = False


class ClientAdapter(ABC):
    """Abstract adapter for one client integration."""

    @abstractmethod
    def adapter_id(self) -> str:
        raise NotImplementedError

    @abstractmethod
    def display_name(self) -> str:
        raise NotImplementedError

    @abstractmethod
    def describe_capabilities(self) -> AdapterCapabilities:
        raise NotImplementedError

    @abstractmethod
    def locate(self, environment: ExecutionEnvironment) -> LocationResult:
        raise NotImplementedError

    @abstractmethod
    def detect(self, environment: ExecutionEnvironment) -> DetectionResult:
        raise NotImplementedError

    @abstractmethod
    def inspect(self, path: Path, server_name: str) -> AdapterInspection:
        raise NotImplementedError

    @abstractmethod
    def render(
        self, server_definition: ServerDefinition, inspection: AdapterInspection
    ) -> RenderResult:
        raise NotImplementedError

    @abstractmethod
    def render_removal(self, inspection: AdapterInspection, server_name: str) -> RenderResult:
        raise NotImplementedError

    @abstractmethod
    def validate_render(self, rendered: RenderResult) -> list[Finding]:
        raise NotImplementedError

    @abstractmethod
    def activation_instructions(self) -> list[NextAction]:
        raise NotImplementedError
