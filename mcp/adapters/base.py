"""Adapter contracts for supported MCP clients."""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
import json
import os
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

    def locate_for_server(
        self, environment: ExecutionEnvironment, server_name: str
    ) -> LocationResult:
        """Where THIS server's configuration lives for this client.

        Every client but one keeps all of its MCP servers in a single file, so
        the default ignores the name. Continue is the exception: it loads one
        block file per server, and a second server written into the first
        server's file would replace it.
        """
        del server_name
        return self.locate(environment)

    @abstractmethod
    def detect(self, environment: ExecutionEnvironment) -> DetectionResult:
        raise NotImplementedError

    def detect_from_evidence(
        self,
        environment: ExecutionEnvironment,
        *,
        client_label: str,
        programs: Iterable[str] = (),
        bundles: Iterable[str] = (),
        client_dir: Callable[[ExecutionEnvironment, Path], Path] | None = None,
        kit_only: Callable[[Path], bool] | None = None,
        kit_paths: Callable[[Path], set[Path]] | None = None,
        override_env: str | None = None,
    ) -> DetectionResult:
        """Is the client on this machine? Evidence of the CLIENT, not of a file.

        Detection used to be "the config file exists, or its directory does".
        The kit writes that file itself, so once it had configured a client the
        client counted as installed forever -- including four clients that were
        never on the machine, whose configs (password inside) a mis-scoped
        EXAKIT_MCP_CLIENTS=all had created. The rule is now, in order:

        1. An explicit config-path override is the caller vouching for the
           client (tests, a portable install): the old file/directory rule.
        2. The client's program on PATH, or its app bundle: installed.
        3. A config file that holds anything beyond the kit's own entries:
           the user's own settings, so the client is installed.
        4. A config that holds ONLY the kit's entries is the kit's own work and
           proves nothing; the client's directory still counts if it holds
           other files of the client's (settings, extensions, history).
        5. Otherwise: not installed.
        """
        location = self.locate(environment)
        evidence = list(location.evidence)
        if not location.available or location.path is None:
            return DetectionResult(False, "none", location, evidence)
        path = location.path
        config_exists = path.exists()
        if override_env and environment.env.get(override_env):
            if config_exists:
                evidence.append("Config file exists (path overridden).")
                return DetectionResult(True, "high", location, evidence)
            if path.parent.exists():
                evidence.append("Config directory exists (path overridden).")
                return DetectionResult(True, "medium", location, evidence)
            evidence.append("No local config evidence was found.")
            return DetectionResult(False, "low", location, evidence)
        program = program_on_path(environment, programs) if programs else None
        bundle = app_bundle_present(environment, bundles) if bundles else None
        if program or bundle:
            evidence.append(f"{client_label} is installed ({program or bundle}).")
            return DetectionResult(True, "high" if config_exists else "medium", location, evidence)
        if config_exists:
            if kit_only is not None and kit_only(path):
                evidence.append("The only config here is the one this kit wrote; that is not evidence of the client.")
            else:
                evidence.append("Config file exists with the client's own settings.")
                return DetectionResult(True, "high", location, evidence)
        root = client_dir(environment, path) if client_dir else path.parent
        owned = kit_paths(path) if kit_paths else {path}
        if root.exists() and dir_has_foreign_content(root, owned):
            evidence.append(f"{root} holds the client's own files.")
            return DetectionResult(True, "medium", location, evidence)
        evidence.append(f"No {client_label} evidence was found (no program on PATH, no config of its own).")
        return DetectionResult(False, "low", location, evidence)

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


# Servers this kit writes. A config that holds nothing else was written by the
# kit, so it is not evidence that the client is installed.
KIT_MANAGED_SERVER_NAMES = frozenset({"exasol", "dash-server"})


def program_on_path(environment: ExecutionEnvironment, names: Iterable[str]) -> str | None:
    """The first of ``names`` found as an executable on the environment's PATH."""
    exts = [""] + ([".exe", ".cmd", ".bat"] if environment.os_name == "win32" else [])
    for directory in environment.env.get("PATH", "").split(os.pathsep):
        if not directory:
            continue
        for name in names:
            for ext in exts:
                candidate = Path(directory) / f"{name}{ext}"
                try:
                    if candidate.is_file() and os.access(candidate, os.X_OK):
                        return str(candidate)
                except OSError:
                    continue
    return None


def app_bundle_present(environment: ExecutionEnvironment, names: Iterable[str]) -> str | None:
    """The first ``<name>.app`` under /Applications or ~/Applications (macOS only).

    EXAKIT_MCP_APP_ROOTS (os.pathsep-separated) replaces the two default roots:
    a sandboxed run must not read the real /Applications as its own.
    """
    if environment.os_name != "darwin":
        return None
    override = environment.env.get("EXAKIT_MCP_APP_ROOTS")
    if override is not None:
        roots = [Path(part) for part in override.split(os.pathsep) if part]
    else:
        roots = [Path("/Applications"), environment.home / "Applications"]
    for name in names:
        for root in roots:
            bundle = root / f"{name}.app"
            try:
                if bundle.is_dir():
                    return str(bundle)
            except OSError:
                continue
    return None


def json_config_is_kit_only(path: Path, servers_key: str, ignore_keys: Iterable[str] = ()) -> bool:
    """True when the JSON document carries nothing but kit-managed server entries.

    Anything else -- another top-level key, a server the kit did not write, or
    a file that does not parse -- counts as the user's own and is evidence.
    """
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    if not isinstance(document, dict):
        return False
    ignored = set(ignore_keys)
    for key in document:
        if key != servers_key and key not in ignored:
            return False
    servers = document.get(servers_key) or {}
    if not isinstance(servers, dict):
        return False
    return set(servers) <= KIT_MANAGED_SERVER_NAMES


def dir_has_foreign_content(root: Path, kit_paths: set[Path], depth: int = 2) -> bool:
    """Any file under ``root`` (to ``depth`` levels) that the kit did not write."""
    owned = set()
    for owned_path in kit_paths:
        try:
            owned.add(owned_path.resolve())
        except OSError:
            owned.add(owned_path)

    def walk(directory: Path, level: int) -> bool:
        try:
            entries = list(directory.iterdir())
        except OSError:
            return False
        for entry in entries:
            try:
                resolved = entry.resolve()
            except OSError:
                resolved = entry
            if entry.is_file() and resolved not in owned:
                return True
            if entry.is_dir() and level < depth and walk(entry, level + 1):
                return True
        return False

    return walk(root, 1)
