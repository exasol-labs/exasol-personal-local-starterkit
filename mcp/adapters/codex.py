"""Codex adapter."""

from __future__ import annotations

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11: tomllib was added in 3.11.
    # Keep the whole MCP package importable on older interpreters (registry.py
    # imports this adapter unconditionally); Codex operations degrade to a
    # clear finding instead of crashing the subsystem at import time.
    tomllib = None
from pathlib import Path
import re

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


class CodexAdapter(ClientAdapter):
    _CONFIG_ENV_NAME = "CODEX_MCP_CONFIG_PATH"

    def adapter_id(self) -> str:
        return "codex"

    def display_name(self) -> str:
        return "Codex"

    def describe_capabilities(self) -> AdapterCapabilities:
        return AdapterCapabilities(
            supports_stdio=True,
            supports_http=True,
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
            path=environment.home / ".codex" / "config.toml",
            evidence=["Using the documented user-level Codex config location."],
        )

    def detect(self, environment: ExecutionEnvironment) -> DetectionResult:
        location = self.locate(environment)
        evidence = list(location.evidence)
        if location.path is None:
            return DetectionResult(False, "none", location, evidence)
        if location.path.exists():
            evidence.append("Config file exists.")
            return DetectionResult(True, "high", location, evidence)
        if location.path.parent.exists():
            evidence.append("Config directory exists.")
            return DetectionResult(True, "medium", location, evidence)
        evidence.append("No local config evidence was found.")
        return DetectionResult(False, "low", location, evidence)

    def inspect(self, path: Path, server_name: str) -> AdapterInspection:
        if not path.exists():
            return AdapterInspection(path=path, exists=False, document={}, file_valid=True)
        if tomllib is None:
            return AdapterInspection(
                path=path,
                exists=True,
                document=None,
                file_valid=False,
                findings=[
                    Finding(
                        code="codex_requires_python_311",
                        severity=Severity.ERROR,
                        message="Codex configuration support requires Python 3.11 or newer.",
                        scope={"path": str(path)},
                        recommended_action="Run this tool under Python 3.11+ (the starter kit's managed runtime), or configure Claude or Cursor instead.",
                        blocking=True,
                    )
                ],
            )
        try:
            document = tomllib.loads(path.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as exc:
            return AdapterInspection(
                path=path,
                exists=True,
                document=None,
                file_valid=False,
                findings=[
                    Finding(
                        code="invalid_client_config",
                        severity=Severity.ERROR,
                        message="Codex configuration is not valid TOML.",
                        scope={"path": str(path)},
                        evidence=[str(exc)],
                        recommended_action="Repair or restore the managed Codex configuration before applying changes.",
                        blocking=True,
                    )
                ],
            )
        mcp_servers = document.get("mcp_servers", {})
        if mcp_servers is None:
            mcp_servers = {}
        if not isinstance(mcp_servers, dict):
            return AdapterInspection(
                path=path,
                exists=True,
                document=document,
                file_valid=False,
                findings=[
                    Finding(
                        code="invalid_client_config",
                        severity=Severity.ERROR,
                        message="The 'mcp_servers' section must be a TOML table.",
                        scope={"path": str(path)},
                        recommended_action="Repair or remove the invalid 'mcp_servers' section.",
                        blocking=True,
                    )
                ],
            )
        managed_entry = mcp_servers.get(server_name)
        managed_hash = sha256_json(managed_entry) if managed_entry is not None else None
        return AdapterInspection(
            path=path,
            exists=True,
            document=document,
            file_valid=True,
            managed_entry=managed_entry,
            managed_hash=managed_hash,
            other_server_names=[name for name in mcp_servers.keys() if name != server_name],
        )

    def render(
        self, server_definition: ServerDefinition, inspection: AdapterInspection
    ) -> RenderResult:
        if server_definition.transport != DeploymentMode.STDIO:
            raise ValueError("Codex rendering currently supports stdio only.")
        if not server_definition.command:
            raise ValueError("Codex stdio rendering requires a command.")
        document = dict(inspection.document or {})
        mcp_servers = dict(document.get("mcp_servers", {}))
        entry = {
            "command": server_definition.command,
            "args": list(server_definition.args),
        }
        if server_definition.env:
            entry["env"] = dict(server_definition.env)
        mcp_servers[server_definition.name] = entry
        document["mcp_servers"] = mcp_servers
        return RenderResult(
            path=inspection.path,
            content=_dump_toml(document),
            managed_hash=sha256_json(entry),
            entry_name=server_definition.name,
        )

    def render_removal(self, inspection: AdapterInspection, server_name: str) -> RenderResult:
        document = dict(inspection.document or {})
        mcp_servers = dict(document.get("mcp_servers", {}))
        mcp_servers.pop(server_name, None)
        if mcp_servers:
            document["mcp_servers"] = mcp_servers
        else:
            document.pop("mcp_servers", None)
        remove_file = not document
        return RenderResult(
            path=inspection.path,
            content=None if remove_file else _dump_toml(document),
            managed_hash=None,
            entry_name=server_name,
            remove_file=remove_file,
        )

    def validate_render(self, rendered: RenderResult) -> list[Finding]:
        if rendered.remove_file:
            return []
        if tomllib is None:
            # Cannot re-parse TOML on Python < 3.11; inspect() already blocks
            # Codex there, so this path is not reached in practice.
            return []
        try:
            tomllib.loads(rendered.content or "")
            return []
        except tomllib.TOMLDecodeError as exc:
            return [
                Finding(
                    code="invalid_render_output",
                    severity=Severity.ERROR,
                    message="Rendered Codex configuration is not valid TOML.",
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
                message="Restart Codex or reload the client to load the updated MCP configuration.",
            )
        ]


def _dump_toml(document: dict) -> str:
    lines: list[str] = []
    _emit_toml_table(lines, document, ())
    return "".join(lines).rstrip() + "\n"


def _emit_toml_table(lines: list[str], table: dict, prefix: tuple[str, ...]) -> None:
    scalar_items = []
    nested_items = []
    for key, value in table.items():
        if isinstance(value, dict):
            nested_items.append((key, value))
        else:
            scalar_items.append((key, value))
    if prefix:
        lines.append(f"[{'.'.join(_toml_key(part) for part in prefix)}]\n")
    for key, value in scalar_items:
        lines.append(f"{_toml_key(key)} = {_toml_value(value)}\n")
    if scalar_items and nested_items:
        lines.append("\n")
    for index, (key, value) in enumerate(nested_items):
        _emit_toml_table(lines, value, prefix + (key,))
        if index != len(nested_items) - 1:
            lines.append("\n")


_BARE_TOML_KEY = re.compile(r"^[A-Za-z0-9_-]+$")


def _toml_key(value: object) -> str:
    text = str(value)
    if _BARE_TOML_KEY.match(text):
        return text
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _toml_value(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(_toml_value(item) for item in value) + "]"
    text = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f"\"{text}\""
