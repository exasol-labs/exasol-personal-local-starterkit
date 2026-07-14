"""Command-line entry points for the MCP subsystem."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from mcp.adapters import AdapterRegistry
from mcp.core.errors import MCPSubsystemError
from mcp.core.models import (
    OperationStatus,
    utc_now,
)
from mcp.core.serialization import to_primitive
from mcp.runtime.environment import ExecutionEnvironment
from mcp.runtime.exakit import ExakitRuntimeLoader
from mcp.runtime.filesystem import FileSystem
from mcp.runtime.manifest import ManifestRepository
from mcp.runtime.paths import RuntimePaths
from mcp.service import MCPAccessSubsystem

SETUP_CLIENT_IDS = (
    "claude_desktop",
    "claude_code",
    "cursor",
    "codex",
    "vscode_copilot",
    "gemini_cli",
    "opencode",
    "continue",
)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m mcp")
    subparsers = parser.add_subparsers(dest="command", required=True)

    setup_parser = subparsers.add_parser(
        "setup-runtime-clients",
        help="Apply permanent MCP client setup for an installed starter-kit runtime.",
    )
    setup_parser.add_argument(
        "--runtime-root",
        default="~/.exasol-starter-kit",
        help="Starter-kit runtime root. Defaults to ~/.exasol-starter-kit.",
    )
    setup_parser.add_argument(
        "--clients",
        nargs="+",
        default=list(SETUP_CLIENT_IDS),
        choices=list(SETUP_CLIENT_IDS),
        help="One or more concrete MCP clients to set up.",
    )
    operation_parser = subparsers.add_parser(
        "run-runtime-operation",
        help="Run a managed MCP lifecycle operation against an installed starter-kit runtime.",
    )
    operation_parser.add_argument(
        "operation",
        choices=("validate", "repair", "backup", "restore", "doctor", "uninstall", "status"),
        help="Managed MCP lifecycle operation to run.",
    )
    operation_parser.add_argument(
        "--runtime-root",
        default="~/.exasol-starter-kit",
        help="Starter-kit runtime root. Defaults to ~/.exasol-starter-kit.",
    )
    operation_parser.add_argument(
        "--clients",
        nargs="*",
        default=[],
        choices=list(SETUP_CLIENT_IDS),
        help="Optional subset of concrete MCP clients.",
    )
    operation_parser.add_argument(
        "--snapshot-id",
        default="",
        help="Optional snapshot id for restore. Defaults to the latest snapshot when omitted.",
    )
    discover_parser = subparsers.add_parser(
        "discover-clients",
        help="Report, per supported MCP client, whether it is installed on this machine and whether a managed config already exists.",
    )
    discover_parser.add_argument(
        "--runtime-root",
        default="~/.exasol-starter-kit",
        help="Starter-kit runtime root. Defaults to ~/.exasol-starter-kit.",
    )

    args = parser.parse_args(argv)
    if args.command == "setup-runtime-clients":
        return _setup_runtime_clients(args)
    if args.command == "run-runtime-operation":
        return _run_runtime_operation(args)
    if args.command == "discover-clients":
        return _discover_clients(args)
    parser.error(f"Unsupported command: {args.command}")
    return 2


def _discover_clients(args: argparse.Namespace) -> int:
    """Emit machine-readable per-client state for dynamic setup menus."""
    environment = ExecutionEnvironment.current()
    filesystem = FileSystem()
    runtime_root = _resolve_runtime_root(args.runtime_root, environment)
    configured: set[str] = set()
    try:
        repository = ManifestRepository(RuntimePaths(runtime_root), filesystem)
        for record in repository.list_active_artifacts():
            client = record.get("client")
            if client:
                configured.add(str(client))
    except Exception:  # no managed state yet → nothing is configured
        configured = set()
    clients = []
    for adapter in AdapterRegistry().all():
        detection = adapter.detect(environment)
        clients.append(
            {
                "id": adapter.adapter_id(),
                "display_name": adapter.display_name(),
                "detected": bool(detection.detected),
                "confidence": detection.confidence,
                "configured": adapter.adapter_id() in configured,
            }
        )
    print(json.dumps({"clients": clients}, indent=2, sort_keys=True))
    return 0


def _setup_runtime_clients(args: argparse.Namespace) -> int:
    environment = ExecutionEnvironment.current()
    filesystem = FileSystem()
    runtime_root = _resolve_runtime_root(args.runtime_root, environment)
    try:
        loader = ExakitRuntimeLoader(environment=environment, filesystem=filesystem)
        repository = ManifestRepository(RuntimePaths(runtime_root), filesystem)
        clients = list(dict.fromkeys(args.clients))
        payload = _permanent_setup(
            environment=environment,
            filesystem=filesystem,
            runtime_root=runtime_root,
            context_loader=loader,
            clients=clients,
        )
        _record_client_setup(repository, clients, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        if payload.get("status") in {
            OperationStatus.SUCCESS.value,
            OperationStatus.SUCCESS_WITH_WARNINGS.value,
            OperationStatus.NO_CHANGE.value,
        }:
            return 0
        return 1
    except MCPSubsystemError as exc:
        print(f"{exc.code}: {exc.message}", file=sys.stderr)
        return 1


def _run_runtime_operation(args: argparse.Namespace) -> int:
    environment = ExecutionEnvironment.current()
    filesystem = FileSystem()
    runtime_root = _resolve_runtime_root(args.runtime_root, environment)
    repository = ManifestRepository(RuntimePaths(runtime_root), filesystem)
    clients = list(dict.fromkeys(args.clients))
    try:
        raw_request = _build_operation_request(
            operation=args.operation,
            environment=environment,
            filesystem=filesystem,
            repository=repository,
            runtime_root=runtime_root,
            clients=clients,
            snapshot_id=args.snapshot_id,
        )
        subsystem = MCPAccessSubsystem(environment=environment, filesystem=filesystem)
        result = subsystem.execute(raw_request)
        payload = result.to_dict()
        payload.update(
            {
                "runtime_root": str(runtime_root),
                "selected_clients": clients,
            }
        )
        print(json.dumps(payload, indent=2, sort_keys=True))
        if payload.get("status") in {
            OperationStatus.SUCCESS.value,
            OperationStatus.SUCCESS_WITH_WARNINGS.value,
            OperationStatus.NO_CHANGE.value,
        }:
            return 0
        return 1
    except MCPSubsystemError as exc:
        print(f"{exc.code}: {exc.message}", file=sys.stderr)
        return 1


def _permanent_setup(
    environment: ExecutionEnvironment,
    filesystem: FileSystem,
    runtime_root: Path,
    context_loader: ExakitRuntimeLoader,
    clients: list[str],
) -> dict:
    context = context_loader.load(runtime_root)
    subsystem = MCPAccessSubsystem(environment=environment, filesystem=filesystem)
    result = subsystem.execute(
        {
            "operation": "configure",
            "target_clients": clients,
            "deployment_mode": "stdio",
            "runtime_root": str(runtime_root),
            "server_definition": to_primitive(context.server_definition),
            "credential_reference": {"kind": "inline_env", "name": "EXA_PASSWORD"},
            "dsn_reference": {"kind": "literal", "value": context.dsn},
            "create_snapshot": True,
            "validate_after_apply": True,
        }
    )
    payload = result.to_dict()
    payload.update(
        {
            "mode": "permanent",
            "runtime_root": str(runtime_root),
            "selected_clients": clients,
        }
    )
    return payload


def _record_client_setup(
    repository: ManifestRepository,
    clients: list[str],
    payload: dict,
) -> None:
    repository.record_client_setup(
        {
            "completed": True,
            "mode": "permanent",
            "clients": clients,
            "status": payload.get("status"),
            "updated_at": utc_now(),
            "artifacts": [artifact["path"] for artifact in payload.get("artifacts", [])],
        }
    )


def _build_operation_request(
    *,
    operation: str,
    environment: ExecutionEnvironment,
    filesystem: FileSystem,
    repository: ManifestRepository,
    runtime_root: Path,
    clients: list[str],
    snapshot_id: str,
) -> dict:
    request: dict = {
        "operation": operation,
        "runtime_root": str(runtime_root),
    }
    if clients:
        request["target_clients"] = clients
    if operation in {"validate", "repair", "doctor"}:
        loader = ExakitRuntimeLoader(environment=environment, filesystem=filesystem)
        context = loader.load(runtime_root)
        request["dsn_reference"] = {"kind": "literal", "value": context.dsn}
    if operation == "repair":
        loader = ExakitRuntimeLoader(environment=environment, filesystem=filesystem)
        context = loader.load(runtime_root)
        request["deployment_mode"] = "stdio"
        request["server_definition"] = to_primitive(context.server_definition)
        request["credential_reference"] = {"kind": "inline_env", "name": "EXA_PASSWORD"}
        request["validate_after_apply"] = True
        request["create_snapshot"] = True
    if operation == "restore":
        resolved_snapshot_id = snapshot_id or repository.latest_snapshot_id()
        if not resolved_snapshot_id:
            raise MCPSubsystemError(
                "runtime_snapshot_missing",
                "No MCP snapshot is available to restore yet.",
            )
        request["snapshot_id"] = resolved_snapshot_id
    return request


def _resolve_runtime_root(raw: str, environment: ExecutionEnvironment) -> Path:
    path = Path(raw).expanduser()
    if path.is_absolute():
        return path
    return environment.home / path


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
