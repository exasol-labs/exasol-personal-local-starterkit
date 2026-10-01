"""Continue adapter."""

from __future__ import annotations

import re
import shutil
from pathlib import Path

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

# The block file is written entirely by the kit, so it is safe to recreate or
# delete wholesale. The header says so to anyone who opens it.
_HEADER = (
    "# Managed by the Exasol Personal Local Starter Kit.\n"
    "# Recreate with `exakit mcp-setup`; remove with `exakit mcp-remove`.\n"
)

# A YAML scalar can be left unquoted only when it is a plain, unambiguous token
# (no YAML indicators, no leading/trailing space). Anything else — colons (the
# DSN host:port!), spaces, quotes — is double-quoted and escaped.
_KIT_SERVER_NAME = "exasol"
_BLOCK_FILE_STEM = "exasol-starter-kit"
# A block file name is derived from a server name, so anything that could walk
# out of the blocks directory or confuse a path is folded to a dash.
_UNSAFE_FILE_CHARS = re.compile(r"[^A-Za-z0-9._-]+")

_YAML_BARE = re.compile(r"^[A-Za-z0-9_./@+-]+$")
# YAML 1.1 parsers (common in JS/TS tooling) coerce these bare tokens to
# booleans/null, and coerce numeric-looking tokens to numbers. Env values like
# "no" (EXA_SSL_CERT_VALIDATION) or a bare port MUST stay strings, so quote them.
_YAML_RESERVED = frozenset(
    {"true", "false", "yes", "no", "on", "off", "null", "none", "~"}
)
_YAML_NUMERIC = re.compile(r"^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$")


class ContinueAdapter(ClientAdapter):
    """Adapter for Continue's global MCP block file.

    Continue (the VS Code and JetBrains extension) loads user-wide "blocks"
    from the global ``~/.continue`` directory, including MCP servers defined as
    YAML block files under ``~/.continue/mcpServers/``. Unlike Claude/Cursor's
    shared JSON configs, this is a dedicated file the kit owns end to end (one
    block file, one server), so it is written, rewritten, and removed wholesale
    — no merging with unrelated settings, and the whole file is deleted on
    removal.

    The block-file schema is YAML with top-level ``name``/``version``/``schema``
    metadata and an ``mcpServers`` LIST whose entries carry ``name``,
    ``command``, ``args``, and ``env``. Because no YAML library ships with the
    kit's runtime, the file is emitted by a small purpose-built writer and its
    integrity is tracked by hashing the whole (kit-owned) file.
    """

    _CONFIG_ENV_NAME = "CONTINUE_MCP_CONFIG_PATH"

    def adapter_id(self) -> str:
        return "continue"

    def display_name(self) -> str:
        return "Continue"

    def describe_capabilities(self) -> AdapterCapabilities:
        return AdapterCapabilities(
            supports_stdio=True,
            supports_http=True,
            supports_managed_file=True,
            supports_patch_mode=False,
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
            path=environment.home / ".continue" / "mcpServers" / "exasol-starter-kit.yaml",
            evidence=[
                "Using the Continue global block-file location "
                "(~/.continue/mcpServers/exasol-starter-kit.yaml)."
            ],
        )

    def locate_for_server(
        self, environment: ExecutionEnvironment, server_name: str
    ) -> LocationResult:
        """One block file per server, because Continue loads them that way.

        The kit's own server keeps the historical file name, so an existing
        install is not orphaned; every other server gets a file named after it.
        An explicit CONTINUE_MCP_CONFIG_PATH names ONE file, which is the kit
        server's: a second server is written beside it under a derived name
        rather than on top of it.
        """
        if server_name == _KIT_SERVER_NAME:
            return self.locate(environment)
        suffix = _safe_file_stem(server_name)
        override = environment.env.get(self._CONFIG_ENV_NAME)
        if override:
            base = Path(override)
            path = base.with_name(base.stem + "-" + suffix + (base.suffix or ".yaml"))
            return LocationResult(
                available=True,
                path=path,
                evidence=[
                    "Using a per-server block file beside "
                    + self._CONFIG_ENV_NAME
                    + " (" + path.name + ")."
                ],
            )
        file_name = _BLOCK_FILE_STEM + "-" + suffix + ".yaml"
        return LocationResult(
            available=True,
            path=environment.home / ".continue" / "mcpServers" / file_name,
            evidence=[
                "Using a per-server Continue block file "
                f"(~/.continue/mcpServers/{file_name})."
            ],
        )

    def detect(self, environment: ExecutionEnvironment) -> DetectionResult:
        # The block file is kit-owned by definition, so it is never evidence;
        # Continue's own files under ~/.continue (config.yaml, sessions) are.
        return self.detect_from_evidence(
            environment,
            client_label="Continue",
            programs=("cn", "continue"),
            client_dir=lambda env, path: env.home / ".continue",
            kit_only=lambda path: True,
            kit_paths=lambda path: set(path.parent.glob("exasol-starter-kit*.yaml")) | {path},
            override_env=self._CONFIG_ENV_NAME,
        )
    def inspect(self, path: Path, server_name: str) -> AdapterInspection:
        # The block file is kit-owned, so "inspection" is deliberately simple:
        # its identity is the hash of the whole file (drift = any manual edit).
        if not path.exists():
            return AdapterInspection(
                path=path,
                exists=False,
                document={},
                file_valid=True,
            )
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            return AdapterInspection(
                path=path,
                exists=True,
                document=None,
                file_valid=False,
                findings=[
                    Finding(
                        code="invalid_client_config",
                        severity=Severity.ERROR,
                        message="Continue block file could not be read as UTF-8 text.",
                        scope={"path": str(path)},
                        evidence=[str(exc)],
                        recommended_action="Repair or remove the managed Continue block file before applying changes.",
                        blocking=True,
                    )
                ],
            )
        managed = f"name: {server_name}" in text
        return AdapterInspection(
            path=path,
            exists=True,
            document={"text": text},
            file_valid=True,
            managed_entry={"present": True} if managed else None,
            managed_hash=sha256_json(text) if managed else None,
            other_server_names=[],
        )

    def render(
        self, server_definition: ServerDefinition, inspection: AdapterInspection
    ) -> RenderResult:
        if server_definition.transport == DeploymentMode.STDIO and not server_definition.command:
            raise ValueError("Continue stdio rendering requires a command.")
        if server_definition.transport == DeploymentMode.HTTP and not server_definition.url:
            raise ValueError("Continue HTTP rendering requires a url.")
        content = self._emit_block_file(server_definition)
        return RenderResult(
            path=inspection.path,
            content=content,
            managed_hash=sha256_json(content),
            entry_name=server_definition.name,
        )

    def render_removal(self, inspection: AdapterInspection, server_name: str) -> RenderResult:
        # The block file holds only the kit's server, so removal deletes it.
        return RenderResult(
            path=inspection.path,
            content=None,
            managed_hash=None,
            entry_name=server_name,
            remove_file=True,
        )

    def validate_render(self, rendered: RenderResult) -> list[Finding]:
        if rendered.remove_file:
            return []
        content = rendered.content or ""
        # Cheap structural sanity check (no YAML parser available): the two keys
        # Continue requires must be present in what we emitted.
        if "mcpServers:" in content and "name:" in content:
            return []
        return [
            Finding(
                code="invalid_render_output",
                severity=Severity.ERROR,
                message="Rendered Continue block file is missing required keys.",
                scope={"path": str(rendered.path)},
                recommended_action="Inspect the rendered configuration before applying it.",
                blocking=True,
            )
        ]

    def activation_instructions(self) -> list[NextAction]:
        return [
            NextAction(
                kind="restart_client",
                message="Reload the Continue extension (or restart your IDE) to load the updated MCP configuration.",
            )
        ]

    def _emit_block_file(self, server_definition: ServerDefinition) -> str:
        lines = [_HEADER.rstrip("\n")]
        lines.append("name: Exasol Starter Kit")
        lines.append("version: 0.0.1")
        lines.append('schema: "v1"')
        lines.append("mcpServers:")
        lines.append(f"  - name: {_yaml_scalar(server_definition.name)}")
        if server_definition.transport == DeploymentMode.HTTP:
            # Continue names its transports in the block itself; "streamable-http"
            # is the one that matches an MCP endpoint served over plain HTTP.
            lines.append("    type: streamable-http")
            lines.append(f"    url: {_yaml_scalar(server_definition.url)}")
            if server_definition.headers:
                lines.append("    requestOptions:")
                lines.append("      headers:")
                for key, value in server_definition.headers.items():
                    lines.append(f"        {_yaml_scalar(key)}: {_yaml_scalar(value)}")
            return "\n".join(lines) + "\n"
        lines.append(f"    command: {_yaml_scalar(server_definition.command)}")
        if server_definition.args:
            lines.append("    args:")
            for arg in server_definition.args:
                lines.append(f"      - {_yaml_scalar(arg)}")
        else:
            lines.append("    args: []")
        if server_definition.env:
            lines.append("    env:")
            for key, value in server_definition.env.items():
                lines.append(f"      {_yaml_scalar(key)}: {_yaml_scalar(value)}")
        return "\n".join(lines) + "\n"


def _safe_file_stem(server_name: str) -> str:
    stem = _UNSAFE_FILE_CHARS.sub("-", server_name).strip("-.")
    return stem or "server"


def _yaml_scalar(value: object) -> str:
    text = str(value)
    if (
        text
        and _YAML_BARE.match(text)
        and text.lower() not in _YAML_RESERVED
        and not _YAML_NUMERIC.match(text)
    ):
        return text
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'
