"""Reusable JSON-backed MCP client adapters."""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

from mcp.core.models import DeploymentMode, Finding, NextAction, Severity, ServerDefinition
from mcp.core.serialization import sha256_json
from mcp.runtime.environment import ExecutionEnvironment

from .base import (
    AdapterCapabilities,
    AdapterInspection,
    ClientAdapter,
    DetectionResult,
    LocationResult,
    RenderResult,
    json_config_is_kit_only,
)


class JsonConfigAdapter(ClientAdapter):
    """Shared behavior for JSON-based MCP config files."""

    def __init__(
        self,
        *,
        adapter_id_value: str,
        display_name_value: str,
        config_env_name: str,
        top_level_key: str,
        activation_message: str,
        default_location: str | None = None,
        workspace_relative_location: str | None = None,
        platforms: tuple[str, ...] = ("darwin", "linux", "win32"),
        programs: tuple[str, ...] = (),
        bundles: tuple[str, ...] = (),
    ) -> None:
        self._programs = programs
        self._bundles = bundles
        self._adapter_id_value = adapter_id_value
        self._display_name_value = display_name_value
        self._config_env_name = config_env_name
        self._top_level_key = top_level_key
        self._activation_message = activation_message
        self._default_location = default_location
        self._workspace_relative_location = workspace_relative_location
        self._platforms = platforms

    def adapter_id(self) -> str:
        return self._adapter_id_value

    def display_name(self) -> str:
        return self._display_name_value

    def describe_capabilities(self) -> AdapterCapabilities:
        return AdapterCapabilities(
            supports_stdio=True,
            supports_http=True,
            supports_managed_file=True,
            supports_patch_mode=True,
            supports_env_block=True,
            requires_restart=True,
            platforms=self._platforms,
        )

    def locate(self, environment: ExecutionEnvironment) -> LocationResult:
        override = environment.env.get(self._config_env_name)
        if override:
            return LocationResult(
                available=True,
                path=Path(override),
                evidence=[f"Config path overridden via {self._config_env_name}."],
            )
        if environment.os_name not in self._platforms:
            return LocationResult(
                available=False,
                path=None,
                evidence=[f"{self.display_name()} is not documented for this platform."],
            )
        if self._default_location is not None:
            return LocationResult(
                available=True,
                path=environment.home / self._default_location,
                evidence=["Using the documented user-level config location."],
            )
        if self._workspace_relative_location is not None:
            workspace_root = environment.cwd or Path.cwd()
            return LocationResult(
                available=True,
                path=workspace_root / self._workspace_relative_location,
                evidence=["Using the documented workspace-level config location."],
            )
        return LocationResult(
            available=False,
            path=None,
            evidence=["No supported config location was resolved."],
        )

    def detect(self, environment: ExecutionEnvironment) -> DetectionResult:
        return self.detect_from_evidence(
            environment,
            client_label=self._display_name_value,
            programs=self._programs,
            bundles=self._bundles,
            kit_only=lambda path: json_config_is_kit_only(path, self._top_level_key),
            override_env=self._config_env_name,
        )
    def inspect(self, path: Path, server_name: str) -> AdapterInspection:
        if not path.exists():
            return AdapterInspection(
                path=path,
                exists=False,
                document={self._top_level_key: {}},
                file_valid=True,
            )
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            return AdapterInspection(
                path=path,
                exists=True,
                document=None,
                file_valid=False,
                findings=[
                    Finding(
                        code="invalid_client_config",
                        severity=Severity.ERROR,
                        message=f"{self.display_name()} configuration is not valid JSON.",
                        scope={"path": str(path)},
                        evidence=[str(exc)],
                        recommended_action="Repair or restore the managed client configuration before applying changes.",
                        blocking=True,
                    )
                ],
            )
        if not isinstance(document, dict):
            return AdapterInspection(
                path=path,
                exists=True,
                document=None,
                file_valid=False,
                findings=[
                    Finding(
                        code="invalid_client_config",
                        severity=Severity.ERROR,
                        message=f"{self.display_name()} configuration must be a JSON object.",
                        scope={"path": str(path)},
                        recommended_action="Replace the file with a valid JSON object before continuing.",
                        blocking=True,
                    )
                ],
            )
        servers = document.get(self._top_level_key, {})
        if servers is None:
            servers = {}
        if not isinstance(servers, dict):
            return AdapterInspection(
                path=path,
                exists=True,
                document=document,
                file_valid=False,
                findings=[
                    Finding(
                        code="invalid_client_config",
                        severity=Severity.ERROR,
                        message=f"The '{self._top_level_key}' section must be a JSON object.",
                        scope={"path": str(path)},
                        recommended_action=f"Repair or remove the invalid '{self._top_level_key}' section.",
                        blocking=True,
                    )
                ],
            )
        managed_entry = servers.get(server_name)
        managed_hash = sha256_json(managed_entry) if managed_entry is not None else None
        return AdapterInspection(
            path=path,
            exists=True,
            document=document,
            file_valid=True,
            managed_entry=managed_entry,
            managed_hash=managed_hash,
            other_server_names=[name for name in servers.keys() if name != server_name],
        )

    def render(
        self, server_definition: ServerDefinition, inspection: AdapterInspection
    ) -> RenderResult:
        document = copy.deepcopy(inspection.document or {self._top_level_key: {}})
        servers = document.setdefault(self._top_level_key, {})
        entry = self._entry_for(server_definition)
        # Only a launched server has a command to mutate; a remote entry is a
        # URL and nothing else, so client-specific stdio keys do not apply.
        if server_definition.transport == DeploymentMode.STDIO:
            self._mutate_entry(entry)
        servers[server_definition.name] = entry
        return RenderResult(
            path=inspection.path,
            content=json.dumps(document, indent=2, sort_keys=True) + "\n",
            managed_hash=sha256_json(entry),
            entry_name=server_definition.name,
        )

    def render_removal(self, inspection: AdapterInspection, server_name: str) -> RenderResult:
        document = copy.deepcopy(inspection.document or {})
        servers = document.get(self._top_level_key)
        if isinstance(servers, dict):
            servers.pop(server_name, None)
            if not servers:
                document.pop(self._top_level_key, None)
        remove_file = not document
        content = None if remove_file else json.dumps(document, indent=2, sort_keys=True) + "\n"
        return RenderResult(
            path=inspection.path,
            content=content,
            managed_hash=None,
            entry_name=server_name,
            remove_file=remove_file,
        )

    def validate_render(self, rendered: RenderResult) -> list[Finding]:
        if rendered.remove_file:
            return []
        try:
            json.loads(rendered.content or "")
            return []
        except json.JSONDecodeError as exc:
            return [
                Finding(
                    code="invalid_render_output",
                    severity=Severity.ERROR,
                    message=f"Rendered {self.display_name()} configuration is not valid JSON.",
                    scope={"path": str(rendered.path)},
                    evidence=[str(exc)],
                    recommended_action="Inspect the rendered configuration before applying it.",
                    blocking=True,
                )
            ]

    def activation_instructions(self) -> list[NextAction]:
        return [NextAction(kind="restart_client", message=self._activation_message)]

    def _entry_for(self, server_definition: ServerDefinition) -> dict[str, Any]:
        """One server entry, in this client's shape.

        Cursor takes a remote server as a bare ``url``; it reads the transport
        from the endpoint rather than from a ``type`` key, so none is written.
        """
        if server_definition.transport == DeploymentMode.HTTP:
            if not server_definition.url:
                raise ValueError(f"{self.display_name()} HTTP rendering requires a url.")
            entry: dict[str, Any] = {"url": server_definition.url}
            if server_definition.headers:
                entry["headers"] = dict(server_definition.headers)
            return entry
        if not server_definition.command:
            raise ValueError(f"{self.display_name()} stdio rendering requires a command.")
        entry = {
            "command": server_definition.command,
            "args": list(server_definition.args),
        }
        if server_definition.env:
            entry["env"] = dict(server_definition.env)
        return entry

    def _mutate_entry(self, entry: dict[str, Any]) -> None:
        """Allow concrete adapters to add client-specific keys."""
