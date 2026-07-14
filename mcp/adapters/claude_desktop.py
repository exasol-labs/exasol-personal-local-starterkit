"""Claude adapter."""

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
)


class ClaudeDesktopAdapter(ClientAdapter):
    """Adapter for the officially documented Claude config file."""

    _CONFIG_ENV_NAME = "CLAUDE_DESKTOP_CONFIG_PATH"

    def adapter_id(self) -> str:
        return "claude_desktop"

    def display_name(self) -> str:
        return "Claude"

    def describe_capabilities(self) -> AdapterCapabilities:
        return AdapterCapabilities(
            supports_stdio=True,
            supports_http=False,
            supports_managed_file=True,
            supports_patch_mode=True,
            supports_env_block=True,
            requires_restart=True,
            platforms=("darwin", "win32"),
        )

    def locate(self, environment: ExecutionEnvironment) -> LocationResult:
        override = environment.env.get(self._CONFIG_ENV_NAME)
        if override:
            return LocationResult(
                available=True,
                path=Path(override),
                evidence=[f"Config path overridden via {self._CONFIG_ENV_NAME}."],
            )
        if environment.os_name == "darwin":
            path = environment.home / "Library/Application Support/Claude/claude_desktop_config.json"
            return LocationResult(
                available=True,
                path=path,
                evidence=[
                    "Using the official macOS Claude config location.",
                ],
            )
        if environment.os_name == "win32":
            return self._locate_windows(environment)
        return LocationResult(
            available=False,
            path=None,
            evidence=["Claude local config is only documented for macOS and Windows."],
        )

    def _locate_windows(self, environment: ExecutionEnvironment) -> LocationResult:
        # Two Claude builds exist on Windows and they read different
        # files:
        #   * The direct-download (.exe) build reads %APPDATA%\Claude\...
        #   * The Microsoft Store (MSIX) build is filesystem-virtualized: when
        #     IT writes %APPDATA%\Claude the OS redirects the write into its
        #     package sandbox at
        #     %LOCALAPPDATA%\Packages\Claude_<publisher>\LocalCache\Roaming\Claude.
        #     That redirect only applies to the packaged process itself - an
        #     external writer like this installer hits the REAL %APPDATA%\Claude,
        #     which the Store app never reads. So on a Store install we must
        #     target the package's LocalCache path explicitly or the server
        #     silently never appears in the app.
        candidates: list[Path] = []
        local_appdata = environment.env.get("LOCALAPPDATA")
        if local_appdata:
            packages = Path(local_appdata) / "Packages"
            try:
                # glob only yields package dirs that actually exist, so a match
                # here is strong evidence the Store build is installed. The
                # publisher hash is not hardcoded in case it ever changes.
                packaged = sorted(packages.glob("Claude_*"))
            except OSError:
                packaged = []
            for pkg in packaged:
                candidates.append(
                    pkg / "LocalCache" / "Roaming" / "Claude" / "claude_desktop_config.json"
                )
        appdata = environment.env.get("APPDATA")
        if appdata:
            candidates.append(Path(appdata) / "Claude" / "claude_desktop_config.json")

        if not candidates:
            return LocationResult(
                available=False,
                path=None,
                evidence=[
                    "Neither %LOCALAPPDATA% nor %APPDATA% is set, so the Claude "
                    "Desktop config location could not be determined.",
                ],
            )

        # Prefer a location that already has a config file, then one whose
        # directory exists, else the first candidate (packaged before standard,
        # so a Store install wins over the never-read %APPDATA% path).
        chosen = next((c for c in candidates if c.exists()), None)
        if chosen is None:
            chosen = next((c for c in candidates if c.parent.exists()), None)
        if chosen is None:
            chosen = candidates[0]

        is_packaged = "Packages" in chosen.parts
        evidence = [
            "Using the Microsoft Store (packaged) Claude config location."
            if is_packaged
            else "Using the official Windows Claude config location."
        ]
        return LocationResult(available=True, path=chosen, evidence=evidence)

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
        if location.path.parent.exists():
            evidence.append("Config directory exists.")
            return DetectionResult(
                detected=True,
                confidence="medium",
                location=location,
                evidence=evidence,
            )
        evidence.append("No local config evidence was found.")
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
                document={"mcpServers": {}},
                file_valid=True,
            )
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            finding = Finding(
                code="invalid_client_config",
                severity=Severity.ERROR,
                message="Claude configuration is not valid JSON.",
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
                message="Claude configuration must be a JSON object.",
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
            raise ValueError("Claude rendering currently supports stdio only.")
        if not server_definition.command:
            raise ValueError("Claude stdio rendering requires a command.")
        document = copy.deepcopy(inspection.document or {"mcpServers": {}})
        mcp_servers = document.setdefault("mcpServers", {})
        entry: dict[str, Any] = {
            "command": server_definition.command,
            "args": list(server_definition.args),
        }
        if server_definition.env:
            entry["env"] = dict(server_definition.env)
        mcp_servers[server_definition.name] = entry
        content = json.dumps(document, indent=2, sort_keys=True) + "\n"
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
                    message="Rendered Claude configuration is not valid JSON.",
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
                message="Restart Claude to load the updated MCP configuration.",
            )
        ]
