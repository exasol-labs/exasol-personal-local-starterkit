"""GitHub Copilot adapter."""

from __future__ import annotations

import copy
import json
import shutil
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
)


class VSCodeCopilotAdapter(ClientAdapter):
    """Adapter for GitHub Copilot agent mode in VS Code.

    VS Code reads user-scope (global) MCP servers from ``mcp.json`` in the
    user profile directory — available in every workspace. The format is
    ``{"servers": {<name>: {"type": "stdio", "command": ..., "args": [...],
    "env": {...}}}}`` (note ``servers``, not ``mcpServers``).
    """

    _CONFIG_ENV_NAME = "VSCODE_MCP_CONFIG_PATH"

    def adapter_id(self) -> str:
        return "vscode_copilot"

    def display_name(self) -> str:
        return "GitHub Copilot"

    def describe_capabilities(self) -> AdapterCapabilities:
        return AdapterCapabilities(
            supports_stdio=True,
            supports_http=False,
            supports_managed_file=True,
            supports_patch_mode=True,
            supports_env_block=True,
            requires_restart=True,
            platforms=("darwin", "linux", "win32"),
        )

    def _user_dir(self, environment: ExecutionEnvironment) -> Path | None:
        if environment.os_name == "darwin":
            return environment.home / "Library/Application Support/Code/User"
        if environment.os_name == "win32":
            appdata = environment.env.get("APPDATA")
            return Path(appdata) / "Code" / "User" if appdata else None
        return environment.home / ".config/Code/User"

    def locate(self, environment: ExecutionEnvironment) -> LocationResult:
        override = environment.env.get(self._CONFIG_ENV_NAME)
        if override:
            return LocationResult(
                available=True,
                path=Path(override),
                evidence=[f"Config path overridden via {self._CONFIG_ENV_NAME}."],
            )
        user_dir = self._user_dir(environment)
        if user_dir is None:
            return LocationResult(
                available=False,
                path=None,
                evidence=["%APPDATA% is not set, so the VS Code user profile could not be determined."],
            )
        return LocationResult(
            available=True,
            path=user_dir / "mcp.json",
            evidence=["Using the VS Code user-scope (global) MCP config location."],
        )

    def detect(self, environment: ExecutionEnvironment) -> DetectionResult:
        location = self.locate(environment)
        evidence = list(location.evidence)
        if not location.available or location.path is None:
            return DetectionResult(
                detected=False,
                confidence="none",
                location=location,
                evidence=evidence,
            )
        if location.path.exists():
            evidence.append("Config file exists.")
            return DetectionResult(
                detected=True,
                confidence="high",
                location=location,
                evidence=evidence,
            )
        if location.path.parent.exists() or shutil.which("code"):
            evidence.append("VS Code is installed but has no global MCP config yet.")
            return DetectionResult(
                detected=True,
                confidence="medium",
                location=location,
                evidence=evidence,
            )
        evidence.append("No VS Code evidence was found.")
        return DetectionResult(
            detected=False,
            confidence="low",
            location=location,
            evidence=evidence,
        )

    def inspect(self, path: Path, server_name: str) -> AdapterInspection:
        if not path.exists():
            return AdapterInspection(
                path=path,
                exists=False,
                document={"servers": {}},
                file_valid=True,
            )
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            finding = Finding(
                code="invalid_client_config",
                severity=Severity.ERROR,
                message="VS Code MCP configuration is not valid JSON.",
                scope={"path": str(path)},
                evidence=[str(exc)],
                recommended_action="Repair or restore the managed client configuration before applying changes.",
                blocking=True,
            )
            return AdapterInspection(
                path=path,
                exists=True,
                document=None,
                file_valid=False,
                findings=[finding],
            )
        if not isinstance(document, dict):
            finding = Finding(
                code="invalid_client_config",
                severity=Severity.ERROR,
                message="VS Code MCP configuration must be a JSON object.",
                scope={"path": str(path)},
                recommended_action="Replace the file with a valid JSON object before continuing.",
                blocking=True,
            )
            return AdapterInspection(
                path=path,
                exists=True,
                document=None,
                file_valid=False,
                findings=[finding],
            )
        servers = document.get("servers", {})
        if servers is None:
            servers = {}
        if not isinstance(servers, dict):
            finding = Finding(
                code="invalid_client_config",
                severity=Severity.ERROR,
                message="The 'servers' section must be a JSON object.",
                scope={"path": str(path)},
                recommended_action="Repair or remove the invalid 'servers' section.",
                blocking=True,
            )
            return AdapterInspection(
                path=path,
                exists=True,
                document=document,
                file_valid=False,
                findings=[finding],
            )
        managed_entry = servers.get(server_name)
        managed_hash = sha256_json(managed_entry) if managed_entry is not None else None
        other_server_names = [name for name in servers.keys() if name != server_name]
        return AdapterInspection(
            path=path,
            exists=True,
            document=document,
            file_valid=True,
            managed_entry=managed_entry,
            managed_hash=managed_hash,
            other_server_names=other_server_names,
        )

    def render(
        self, server_definition: ServerDefinition, inspection: AdapterInspection
    ) -> RenderResult:
        if server_definition.transport != DeploymentMode.STDIO:
            raise ValueError("VS Code rendering currently supports stdio only.")
        if not server_definition.command:
            raise ValueError("VS Code stdio rendering requires a command.")
        document = copy.deepcopy(inspection.document or {"servers": {}})
        servers = document.setdefault("servers", {})
        entry: dict[str, Any] = {
            "type": "stdio",
            "command": server_definition.command,
            "args": list(server_definition.args),
        }
        if server_definition.env:
            entry["env"] = dict(server_definition.env)
        servers[server_definition.name] = entry
        content = json.dumps(document, indent=2, sort_keys=True) + "\n"
        return RenderResult(
            path=inspection.path,
            content=content,
            managed_hash=sha256_json(entry),
            entry_name=server_definition.name,
        )

    def render_removal(self, inspection: AdapterInspection, server_name: str) -> RenderResult:
        document = copy.deepcopy(inspection.document or {})
        servers = document.get("servers")
        if isinstance(servers, dict):
            servers.pop(server_name, None)
            if not servers:
                document.pop("servers", None)
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
                    message="Rendered VS Code MCP configuration is not valid JSON.",
                    scope={"path": str(rendered.path)},
                    evidence=[str(exc)],
                    recommended_action="Inspect the rendered configuration before applying it.",
                    blocking=True,
                )
            ]

    def activation_instructions(self) -> list[NextAction]:
        return [
            NextAction(
                kind="restart_client",
                message="Reload VS Code, then use Copilot Chat in Agent mode (the exasol tools appear under the tools icon).",
            )
        ]
