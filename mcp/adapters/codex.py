"""Codex adapter."""

from __future__ import annotations

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11: tomllib was added in 3.11.
    # Keep the whole MCP package importable on older interpreters (registry.py
    # imports this adapter unconditionally); Codex operations degrade to a
    # clear finding instead of crashing the subsystem at import time.
    tomllib = None
import datetime
import math
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
    KIT_MANAGED_SERVER_NAMES,
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
            # Streamable HTTP is first-class in Codex now. Verified against
            # Codex CLI 0.147.0 on 2026-09-03 by letting it write the entry
            # itself (`codex mcp add <name> --url <url>`), which produces
            #     [mcp_servers.<name>]
            #     url = "<url>"
            # with no feature flag. That is exactly the shape render() emits
            # for an HTTP definition. (An earlier Codex gated this behind an
            # experimental flag, which is why this adapter used to say no.)
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
        return self.detect_from_evidence(
            environment,
            client_label="Codex",
            programs=("codex",),
            client_dir=lambda env, path: env.home / ".codex",
            kit_only=_toml_is_kit_only,
            override_env=self._CONFIG_ENV_NAME,
        )
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
        document = dict(inspection.document or {})
        mcp_servers = dict(document.get("mcp_servers", {}))
        entry: dict
        if server_definition.transport is DeploymentMode.HTTP:
            # A remote server is one key: Codex reads `url` and speaks
            # streamable HTTP to it. No env block -- the client does not start
            # anything, so there is no process to hand variables to.
            if not server_definition.url:
                raise ValueError("Codex HTTP rendering requires a url.")
            entry = {"url": server_definition.url}
        else:
            if not server_definition.command:
                raise ValueError("Codex stdio rendering requires a command.")
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
            expected_document=document,
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
            expected_document=None if remove_file else document,
        )

    def validate_render(self, rendered: RenderResult) -> list[Finding]:
        if rendered.remove_file:
            return []
        if tomllib is None:
            # Cannot re-parse TOML on Python < 3.11; inspect() already blocks
            # Codex there, so this path is not reached in practice.
            return []
        try:
            parsed = tomllib.loads(rendered.content or "")
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
        if rendered.expected_document is not None and not _same_toml(parsed, rendered.expected_document):
            # The write would change a value the user (or Codex itself) already
            # had -- a float turned into a string, a dropped key. Refuse it and
            # leave their config.toml exactly as it is.
            return [
                Finding(
                    code="lossy_render_output",
                    severity=Severity.ERROR,
                    message="Writing the Codex configuration would change settings that are already in it, so it was left untouched.",
                    scope={"path": str(rendered.path)},
                    recommended_action="Add the exasol entry to the Codex config by hand, or report this config.toml shape to the starter kit.",
                    blocking=True,
                )
            ]
        return []

    def activation_instructions(self) -> list[NextAction]:
        return [
            NextAction(
                kind="restart_client",
                message="Restart Codex or reload the client to load the updated MCP configuration.",
            )
        ]


def _toml_is_kit_only(path: Path) -> bool:
    """True when config.toml carries nothing but kit-managed mcp_servers entries."""
    if tomllib is None:
        return False
    try:
        document = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    if set(document) - {"mcp_servers"}:
        return False
    servers = document.get("mcp_servers") or {}
    return isinstance(servers, dict) and set(servers) <= KIT_MANAGED_SERVER_NAMES


def _dump_toml(document: dict) -> str:
    """Serialise a parsed Codex config back to TOML without losing a type.

    The kit re-writes the user's whole config.toml to add its own entry, so
    every value Codex or the user put there has to come back exactly as
    tomllib read it: a float stays a float (`startup_timeout_sec = 120.0`,
    never `"120.0"`, which Codex rejects), dates stay dates, and a list of
    tables stays a list of tables. validate_render re-parses the output and
    refuses the write if anything differs.
    """
    lines: list[str] = []
    _emit_toml_table(lines, document, (), None)
    return "".join(lines).rstrip() + "\n"


def _is_table_array(value: object) -> bool:
    return isinstance(value, list) and bool(value) and all(isinstance(item, dict) for item in value)


def _emit_toml_table(
    lines: list[str], table: dict, prefix: tuple[str, ...], header: str | None
) -> None:
    scalar_items = []
    nested_items = []
    for key, value in table.items():
        if isinstance(value, dict) or _is_table_array(value):
            nested_items.append((key, value))
        else:
            scalar_items.append((key, value))
    if header is not None:
        lines.append(header)
    for key, value in scalar_items:
        lines.append(f"{_toml_key(key)} = {_toml_value(value)}\n")
    if scalar_items and nested_items:
        lines.append("\n")
    for index, (key, value) in enumerate(nested_items):
        path = prefix + (key,)
        dotted = ".".join(_toml_key(part) for part in path)
        if isinstance(value, dict):
            _emit_toml_table(lines, value, path, f"[{dotted}]\n")
        else:
            for item_index, item in enumerate(value):
                _emit_toml_table(lines, item, path, f"[[{dotted}]]\n")
                if item_index != len(value) - 1:
                    lines.append("\n")
        if index != len(nested_items) - 1:
            lines.append("\n")


_BARE_TOML_KEY = re.compile(r"^[A-Za-z0-9_-]+$")


def _toml_key(value: object) -> str:
    text = str(value)
    if _BARE_TOML_KEY.match(text):
        return text
    return _toml_string(text)


_TOML_ESCAPES = {"\\": "\\\\", '"': '\\"', "\b": "\\b", "\t": "\\t", "\n": "\\n", "\f": "\\f", "\r": "\\r"}


def _toml_string(text: str) -> str:
    out = []
    for char in text:
        if char in _TOML_ESCAPES:
            out.append(_TOML_ESCAPES[char])
        elif ord(char) < 0x20 or ord(char) == 0x7F:
            out.append(f"\\u{ord(char):04X}")
        else:
            out.append(char)
    return '"' + "".join(out) + '"'


def _toml_value(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if math.isnan(value):
            return "nan"
        if math.isinf(value):
            return "inf" if value > 0 else "-inf"
        return repr(value)
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, list):
        return "[" + ", ".join(_toml_value(item) for item in value) + "]"
    if isinstance(value, dict):
        if not value:
            return "{}"
        return "{ " + ", ".join(f"{_toml_key(k)} = {_toml_value(v)}" for k, v in value.items()) + " }"
    return _toml_string(str(value))


def _same_toml(left: object, right: object) -> bool:
    """Equality of parsed TOML, with nan equal to nan."""
    if isinstance(left, float) and isinstance(right, float) and math.isnan(left) and math.isnan(right):
        return True
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(_same_toml(left[k], right[k]) for k in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(_same_toml(a, b) for a, b in zip(left, right))
    return left == right
