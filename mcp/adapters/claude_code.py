"""Claude Code (CLI) adapter."""

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


class ClaudeCodeAdapter(ClientAdapter):
    """Adapter for the Claude Code CLI user-scope config (~/.claude.json).

    Claude Code reads user-scope MCP servers from the top-level ``mcpServers``
    key of ``~/.claude.json``. Unlike the desktop config, that file also holds
    unrelated CLI state (account, project history, feature flags), so this
    adapter only ever touches the ``mcpServers`` entry it manages and never
    deletes the file on removal.
    """

    _CONFIG_ENV_NAME = "CLAUDE_CODE_CONFIG_PATH"

    def adapter_id(self) -> str:
        return "claude_code"

    def display_name(self) -> str:
        return "Claude Code (CLI)"

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

    def locate(self, environment: ExecutionEnvironment) -> LocationResult:
        override = environment.env.get(self._CONFIG_ENV_NAME)
        if override:
            return LocationResult(
                available=True,
                path=Path(override),
                evidence=[f"Config path overridden via {self._CONFIG_ENV_NAME}."],
            )
        return LocationResult(
            available=True,
            path=environment.home / ".claude.json",
            evidence=["Using the Claude Code user-scope config location (~/.claude.json)."],
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
        if shutil.which("claude") or (environment.home / ".claude").exists():
            evidence.append("The Claude Code CLI is installed but has no user config yet.")
            return DetectionResult(
                detected=True,
                confidence="medium",
                location=location,
                evidence=evidence,
            )
        evidence.append("No Claude Code CLI evidence was found.")
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
                document={},
                file_valid=True,
            )
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            finding = Finding(
                code="invalid_client_config",
                severity=Severity.ERROR,
                message="Claude Code configuration is not valid JSON.",
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
                message="Claude Code configuration must be a JSON object.",
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
        mcp_servers = document.get("mcpServers", {})
        if mcp_servers is None:
            mcp_servers = {}
        if not isinstance(mcp_servers, dict):
            finding = Finding(
                code="invalid_client_config",
                severity=Severity.ERROR,
                message="The 'mcpServers' section must be a JSON object.",
                scope={"path": str(path)},
                recommended_action="Repair or remove the invalid 'mcpServers' section.",
                blocking=True,
            )
            return AdapterInspection(
                path=path,
                exists=True,
                document=document,
                file_valid=False,
                findings=[finding],
            )
        managed_entry = mcp_servers.get(server_name)
        managed_hash = sha256_json(managed_entry) if managed_entry is not None else None
        other_server_names = [name for name in mcp_servers.keys() if name != server_name]
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
            raise ValueError("Claude Code rendering currently supports stdio only.")
        if not server_definition.command:
            raise ValueError("Claude Code stdio rendering requires a command.")
        document = copy.deepcopy(inspection.document or {})
        mcp_servers = document.setdefault("mcpServers", {})
        entry: dict[str, Any] = {
            "command": server_definition.command,
            "args": list(server_definition.args),
        }
        if server_definition.env:
            entry["env"] = dict(server_definition.env)
        mcp_servers[server_definition.name] = entry
        # No sort_keys: ~/.claude.json is the CLI's own state file, so the
        # managed edit is kept minimally invasive (insertion-order preserved).
        content = json.dumps(document, indent=2) + "\n"
        return RenderResult(
            path=inspection.path,
            content=content,
            managed_hash=sha256_json(entry),
            entry_name=server_definition.name,
        )

    def render_removal(self, inspection: AdapterInspection, server_name: str) -> RenderResult:
        document = copy.deepcopy(inspection.document or {})
        mcp_servers = document.get("mcpServers")
        if isinstance(mcp_servers, dict):
            mcp_servers.pop(server_name, None)
            if not mcp_servers:
                document.pop("mcpServers", None)
        # Never delete ~/.claude.json: it holds unrelated Claude Code CLI state
        # (and even when empty, the CLI expects to own the file's lifecycle).
        content = json.dumps(document, indent=2) + "\n"
        return RenderResult(
            path=inspection.path,
            content=content,
            managed_hash=None,
            entry_name=server_name,
            remove_file=False,
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
                    message="Rendered Claude Code configuration is not valid JSON.",
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
                message="Start a new Claude Code session (or run /mcp in an existing one) to load the updated MCP configuration.",
            )
        ]
