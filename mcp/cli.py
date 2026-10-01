"""Command-line entry points for the MCP subsystem."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

from mcp.adapters import AdapterRegistry
from mcp.core.errors import MCPSubsystemError
from mcp.core.models import (
    OperationRequest,
    OperationStatus,
    ServerDefinition,
    Severity,
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
        "--servers",
        nargs="*",
        default=[],
        help=(
            "Optional subset of managed server entries, by name (e.g. dash-server). "
            "Only uninstall reads it; it exists so removing one add-on's entry "
            "leaves every other managed entry in the same file alone."
        ),
    )
    operation_parser.add_argument(
        "--snapshot-id",
        default="",
        help="Optional snapshot id for restore. Defaults to the latest snapshot when omitted.",
    )
    addon_parser = subparsers.add_parser(
        "register-addon-servers",
        help=(
            "Register the MCP endpoints of installed add-ons with clients that "
            "are already connected, without touching the database or any credential."
        ),
    )
    addon_parser.add_argument(
        "--runtime-root",
        default="~/.exasol-starter-kit",
        help="Starter-kit runtime root. Defaults to ~/.exasol-starter-kit.",
    )
    addon_parser.add_argument(
        "--clients",
        nargs="+",
        default=list(SETUP_CLIENT_IDS),
        choices=list(SETUP_CLIENT_IDS),
        help="One or more concrete MCP clients to register the add-on endpoints with.",
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
    if args.command == "register-addon-servers":
        return _register_addon_servers(args)
    if args.command == "discover-clients":
        return _discover_clients(args)
    parser.error(f"Unsupported command: {args.command}")
    return 2


def _discover_clients(args: argparse.Namespace) -> int:
    """Emit machine-readable per-client state for dynamic setup menus."""
    environment = ExecutionEnvironment.current()
    filesystem = FileSystem()
    runtime_root = _resolve_runtime_root(args.runtime_root, environment)
    # A client is CONFIGURED when its file still carries the entry the kit
    # wrote, not when the manifest remembers writing one. The manifest record
    # alone made `exakit mcp-setup` answer "already connected" for a file the
    # user had emptied by hand, and then do nothing - the one situation setup
    # exists to put right. A record whose file is gone, or whose file no longer
    # holds the managed entry, is drift, and drift reads as not configured so
    # setup offers the client again.
    registry = AdapterRegistry()
    configured: set[str] = set()
    try:
        repository = ManifestRepository(RuntimePaths(runtime_root), filesystem)
        for record in repository.list_active_artifacts():
            client = record.get("client")
            if not client:
                continue
            # Only the kit's own `exasol` entry says a client is connected. An
            # add-on's entry (dash-server) in the same file kept a client
            # "configured" after the user had deleted the exasol entry, so
            # setup said "already connected" and did nothing - the round-2 fix
            # counted any managed record, and a file can carry two.
            if _record_entry_name(record) != "exasol":
                continue
            if _managed_entry_present(registry, record):
                configured.add(str(client))
    except Exception:  # no managed state yet → nothing is configured
        configured = set()
    clients = []
    for adapter in registry.all():
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


def _record_entry_name(record: dict) -> str:
    metadata = record.get("metadata") or {}
    if not isinstance(metadata, dict):
        return "exasol"
    return str(metadata.get("entry_name", "exasol"))


def _connected_clients(
    repository: ManifestRepository, registry: AdapterRegistry, environment: ExecutionEnvironment
) -> list[str]:
    """Clients that are connected: detected on this machine AND their file still
    carries the kit's `exasol` entry.

    This is the only set an add-on endpoint may be written into. Repair used to
    hand `register-addon-servers` every supported client, which CREATED config
    files for four clients that were not installed - and doctor then warned about
    each of them, forever, with a remedy pointing at a stale entry the repair
    itself had just written.
    """
    connected: list[str] = []
    try:
        records = repository.list_active_artifacts()
    except Exception:
        return connected
    for record in records:
        client = str(record.get("client") or "")
        if not client or client in connected or _record_entry_name(record) != "exasol":
            continue
        if not _managed_entry_present(registry, record):
            continue
        try:
            if not registry.get(client).detect(environment).detected:
                continue
        except Exception:
            continue
        connected.append(client)
    return connected


def _managed_entry_present(registry: AdapterRegistry, record: dict) -> bool:
    """True when the managed file still holds the entry the record describes.

    Conservative on failure: an adapter that cannot inspect the path (unknown
    client id, unreadable file) keeps the manifest's word, so a transient read
    error never flips a connected client to "offer it again".
    """
    path = Path(str(record.get("path") or ""))
    if not path.exists():
        return False
    try:
        adapter = registry.get(str(record.get("client")))
        metadata = record.get("metadata") or {}
        entry_name = str(metadata.get("entry_name", "exasol")) if isinstance(metadata, dict) else "exasol"
        inspection = adapter.inspect(path, entry_name)
    except Exception:
        return True
    return inspection.managed_hash is not None


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


def _register_addon_servers(args: argparse.Namespace) -> int:
    """Register installed add-on MCP endpoints with already-connected clients.

    This is the hook an add-on install calls, and it is deliberately NOT
    `setup-runtime-clients`: that path prepares the read-only database user and
    re-renders the exasol entry with its credentials, so installing a dashboard
    server would have started depending on a running database. An add-on
    endpoint is a loopback URL and needs neither.
    """
    environment = ExecutionEnvironment.current()
    filesystem = FileSystem()
    runtime_root = _resolve_runtime_root(args.runtime_root, environment)
    clients = list(dict.fromkeys(args.clients))
    try:
        loader = ExakitRuntimeLoader(environment=environment, filesystem=filesystem)
        definition = loader.load_dash_server(runtime_root)
        payload: dict = {
            "mode": "addon_servers",
            "runtime_root": str(runtime_root),
            "selected_clients": clients,
        }
        if definition is None:
            payload.update(
                {
                    "status": OperationStatus.NO_CHANGE.value,
                    "summary": "No add-on MCP endpoint is installed.",
                    "dash_server": None,
                }
            )
            print(json.dumps(payload, indent=2, sort_keys=True))
            return 0
        subsystem = MCPAccessSubsystem(environment=environment, filesystem=filesystem)
        dash = _register_dash_server(
            subsystem=subsystem,
            runtime_root=runtime_root,
            clients=clients,
            definition=definition,
            payload=payload,
        )
        payload["dash_server"] = dash
        payload["status"] = dash.get("status")
        payload["summary"] = (
            f"Registered '{dash['server_name']}' with "
            f"{len(dash['configured_clients'])} client(s)."
        )
        print(json.dumps(payload, indent=2, sort_keys=True))
        if payload["status"] in {
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
    servers = list(dict.fromkeys(getattr(args, "servers", []) or []))
    try:
        raw_request = _build_operation_request(
            operation=args.operation,
            environment=environment,
            filesystem=filesystem,
            repository=repository,
            runtime_root=runtime_root,
            clients=clients,
            servers=servers,
            snapshot_id=args.snapshot_id,
        )
        subsystem = MCPAccessSubsystem(environment=environment, filesystem=filesystem)
        addon_payload: dict = {}
        addon_result = None
        if args.operation == "repair":
            # BEFORE the repair, not after. Repair re-renders ONE definition and
            # the request carries the exasol server's, so an add-on entry that
            # had been hand-edited stayed hand-edited -- validate reported drift,
            # repair reported success, and the next validate reported the same
            # drift. Re-rendering it first also puts it back before repair's own
            # validation stage inspects every managed entry, so the status
            # repair reports describes the state it is actually leaving behind.
            loader = ExakitRuntimeLoader(environment=environment, filesystem=filesystem)
            dash_definition = loader.load_dash_server(runtime_root)
            if dash_definition is not None:
                # Into CONNECTED clients only (detected, exasol entry present),
                # narrowed further by an explicit selection. Never the whole
                # supported list: that wrote add-on entries into config files
                # for clients that were not on the machine.
                connected = _connected_clients(repository, AdapterRegistry(), environment)
                addon_targets = [c for c in (clients or connected) if c in connected]
                if addon_targets:
                    addon_result = _register_dash_server(
                        subsystem=subsystem,
                        runtime_root=runtime_root,
                        clients=addon_targets,
                        definition=dash_definition,
                        payload=addon_payload,
                    )
        result = subsystem.execute(raw_request)
        payload = result.to_dict()
        payload.update(
            {
                "runtime_root": str(runtime_root),
                "selected_clients": clients,
            }
        )
        if addon_result is not None:
            payload["dash_server"] = addon_result
            payload.setdefault("findings", []).extend(addon_payload.get("findings") or [])
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
    dash_definition = context_loader.load_dash_server(runtime_root)
    if dash_definition is not None:
        payload["dash_server"] = _register_dash_server(
            subsystem=subsystem,
            runtime_root=runtime_root,
            clients=clients,
            definition=dash_definition,
            payload=payload,
        )
    return payload


_NOT_REGISTERED_ACTION = (
    "Add {url} to the client by hand, or rerun `exakit mcp-setup` for a client "
    "that supports remote MCP servers."
)


def _register_dash_server(
    subsystem: MCPAccessSubsystem,
    runtime_root: Path,
    clients: list[str],
    definition: ServerDefinition,
    payload: dict,
) -> dict:
    """Register the dash-server add-on's control plane alongside the exasol server.

    A second configure pass rather than a second entry inside the first: every
    client keys its servers by name, and the manifest keys artifacts by
    (client, path, entry name), so the two passes merge into the same files
    without either erasing the other.

    The pass carries no credential and no snapshot. There is nothing secret in
    a loopback URL, and the first pass already snapshotted these very files
    moments earlier -- a second snapshot would only record the state the first
    pass just wrote.

    Its findings and artifacts are folded into the main payload so the install
    record misses nothing, but the run's headline status stays the exasol
    server's: an AI client that can query the database is the thing setup
    promised, and a dashboard control plane that could not be registered must
    not report that as a failure.
    """
    result = subsystem.execute(
        {
            "operation": "configure",
            "target_clients": clients,
            "deployment_mode": "http",
            "runtime_root": str(runtime_root),
            "server_definition": to_primitive(definition),
            "create_snapshot": False,
            "validate_after_apply": True,
            # No connectivity or environment stage: those ask about the database
            # and the server package behind the exasol entry, neither of which
            # this entry is.
            "stages": ["config_syntax", "permission_posture", "manifest_consistency"],
        }
    )
    dash_payload = result.to_dict()
    details = dash_payload.get("details") or {}
    configured = list(details.get("configured_clients") or [])
    skipped = [item.get("client") for item in details.get("skipped_clients") or []]
    payload.setdefault("findings", []).extend(dash_payload.get("findings") or [])
    payload.setdefault("artifacts", []).extend(dash_payload.get("artifacts") or [])
    # Deduplicated by message: this pass configures the same clients as the
    # first one, so every "restart Cursor" it produces is already there.
    _existing = {
        str(action.get("message", "")) for action in payload.get("next_actions") or []
    }
    for action in dash_payload.get("next_actions") or []:
        message = str(action.get("message", ""))
        if message and message not in _existing:
            _existing.add(message)
            payload.setdefault("next_actions", []).append(action)
    if not configured:
        # Every requested client was skipped. Recorded as a warning because the
        # add-on IS installed and its tools are now reachable by nobody.
        payload["findings"].append(
            {
                "code": "dash_server_not_registered",
                "severity": Severity.WARNING.value,
                "message": (
                    "The dash-server add-on is installed but its MCP control plane "
                    "could not be registered with any selected client."
                ),
                "scope": {"server": definition.name},
                "evidence": [f"Endpoint: {definition.url}"],
                "recommended_action": _NOT_REGISTERED_ACTION.format(url=definition.url),
            }
        )
        # next_actions is the field an unattended caller reads, and a
        # recommended_action that appears only inside a finding never reaches
        # it. Kind is the finding code, matching the doctor path.
        payload.setdefault("next_actions", []).append(
            {
                "kind": "dash_server_not_registered",
                "message": _NOT_REGISTERED_ACTION.format(url=definition.url),
            }
        )
    return {
        "server_name": definition.name,
        "url": definition.url,
        "status": dash_payload.get("status"),
        "configured_clients": configured,
        "skipped_clients": skipped,
    }


def _record_client_setup(
    repository: ManifestRepository,
    clients: list[str],
    payload: dict,
) -> None:
    details = payload.get("details") or {}
    repository.record_client_setup(
        {
            "completed": True,
            "mode": "permanent",
            "clients": clients,
            "status": payload.get("status"),
            "updated_at": utc_now(),
            # Deduplicated: two managed entries in one client config file are
            # two artifacts and one path, and the record is a list of files.
            "artifacts": list(
                dict.fromkeys(
                    artifact["path"] for artifact in payload.get("artifacts", [])
                )
            ),
            # A client can be skipped on its own (unparseable config file, or
            # unsupported platform) while the rest are configured, so the
            # record has to say which clients were actually written.
            "configured_clients": details.get("configured_clients", []),
            "skipped_clients": [
                item.get("client") for item in details.get("skipped_clients", [])
            ],
            # WHY the status is "success_with_warnings", not just that it is.
            # The record carried the qualified status and nothing else, so the
            # install log scrolled away and the manifest kept a permanent
            # "with warnings" that named no warning — unanswerable after the
            # fact, from the one file that is supposed to be the install record.
            "findings": _setup_findings(payload),
            # Which clients took the add-on's control plane, recorded separately
            # because configured_clients above answers only for the exasol
            # server. Without this a client that cannot hold a remote MCP entry
            # was recorded as fully configured, with nothing saying it has no
            # dash-server entry -- and the skip is an INFO finding, which
            # _setup_findings drops.
            "dash_server": payload.get("dash_server"),
        }
    )


def _setup_findings(payload: dict) -> list[dict]:
    """The warnings and errors behind a qualified status, flattened for the record.

    Kept to the fields a reader acts on (severity, code, message, the client it
    is about, and the recommended action) rather than the whole finding: this
    goes into manifest.json, which `exakit info --json` prints verbatim.
    """
    findings = []
    for finding in payload.get("findings") or []:
        if not isinstance(finding, dict):
            continue
        if finding.get("severity") not in ("warning", "error"):
            continue
        scope = finding.get("scope") or {}
        findings.append(
            {
                "severity": finding.get("severity"),
                "code": finding.get("code"),
                "client": scope.get("client") if isinstance(scope, dict) else None,
                "message": finding.get("message"),
                "recommended_action": finding.get("recommended_action"),
            }
        )
    return findings


def _doctor_stages() -> list[str]:
    """The doctor's stage list, including the one that actually starts the server.

    `server_launch` is a live probe: it spawns the configured command and speaks
    MCP to it. That is the whole point — every other stage inspects paperwork, so
    a client whose entry was present and well-formed reported "connected" while
    the server behind it could not start at all (a missing uvx, a package that
    will not resolve), which is a healthy doctor report and an AI client with no
    Exasol tools in it.

    It costs a subprocess and, on a cold uvx cache, a download. Set
    EXAKIT_MCP_SKIP_SERVER_PROBE=1 to leave it out where that is unacceptable —
    an offline machine, or a suite that must not reach the network.
    """
    stages = list(OperationRequest.stages)
    if os.environ.get("EXAKIT_MCP_SKIP_SERVER_PROBE") == "1":
        return stages
    return stages[: stages.index("connectivity") + 1] + ["server_launch"] + stages[
        stages.index("connectivity") + 1 :
    ]


def _build_operation_request(
    *,
    operation: str,
    environment: ExecutionEnvironment,
    filesystem: FileSystem,
    repository: ManifestRepository,
    runtime_root: Path,
    clients: list[str],
    servers: list[str],
    snapshot_id: str,
) -> dict:
    request: dict = {
        "operation": operation,
        "runtime_root": str(runtime_root),
    }
    if clients:
        request["target_clients"] = clients
    if servers:
        request["target_servers"] = servers
    if operation in {"validate", "repair", "doctor"}:
        loader = ExakitRuntimeLoader(environment=environment, filesystem=filesystem)
        context = loader.load(runtime_root)
        request["dsn_reference"] = {"kind": "literal", "value": context.dsn}
        # Validate and doctor need the desired definition too, not just repair.
        # Without it, the manifest-consistency stage can only compare a client
        # entry against the hash recorded when we last wrote it, so an entry that
        # nobody has touched since an update moved the pinned server version on
        # reads as perfectly consistent and doctor reports success. It is an input
        # to a comparison on both paths; the read-only paths never apply it.
        request["deployment_mode"] = "stdio"
        request["server_definition"] = to_primitive(context.server_definition)
    if operation == "doctor":
        request["stages"] = _doctor_stages()
    if operation == "repair":
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
