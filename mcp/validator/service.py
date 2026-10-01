"""Validation services for MCP operations."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import json
import os
import queue
import socket
import stat
import subprocess
import threading
import time
from typing import Iterable
from urllib.parse import urlparse

from mcp.adapters.base import AdapterInspection, ClientAdapter
from mcp.adapters.registry import AdapterRegistry
from mcp.runtime.filesystem import OWNER_ONLY_ACL, describe_protection
from mcp.core.models import (
    ArtifactReference,
    DiscoveredClient,
    Finding,
    OperationRequest,
    ServerDefinition,
    Severity,
    VerificationEvidence,
)
from mcp.runtime.environment import ExecutionEnvironment
from mcp.runtime.manifest import ManifestRepository
from mcp.runtime.paths import RuntimePaths


# Every drift finding names the SAME next step, and names it as a command the
# reader can type. "Run repair" named an operation of this module that no
# exakit command exposes by that name: the agent reading `mcp-doctor --json`
# went looking for `exakit mcp-repair`, which does not exist, while the human
# form of the very same command would have repaired it.
REPAIR_ACTION = (
    "Run: exakit mcp-doctor (it repairs drift and re-checks; --json only reports)"
)


class _ServerLaunchError(RuntimeError):
    """The configured MCP server started but did not behave like an MCP server."""


@dataclass
class StageResult:
    stage: str
    status: str
    findings: list[Finding] = field(default_factory=list)
    evidence: list[VerificationEvidence] = field(default_factory=list)


def _stage_status(findings: list[Finding]) -> str:
    # Severity-aware, mirroring the service's _status_from_findings so the
    # stage path and the findings path can never disagree: INFO findings are
    # expected state and keep the stage at "pass"; only WARNING or worse
    # downgrades it.
    if any(finding.blocking or finding.severity == Severity.CRITICAL for finding in findings):
        return "fail_blocking"
    if any(finding.severity == Severity.ERROR for finding in findings):
        return "fail_recoverable"
    if any(finding.severity == Severity.WARNING for finding in findings):
        return "pass_with_warnings"
    return "pass"


class ValidatorService:
    """Run staged validation across environment, files, and manifest state."""

    def __init__(
        self,
        registry: AdapterRegistry,
        manifest_repository: ManifestRepository,
        environment: ExecutionEnvironment,
    ) -> None:
        self._registry = registry
        self._manifest_repository = manifest_repository
        self._environment = environment

    def validate_environment(
        self, request: OperationRequest, runtime_paths: RuntimePaths
    ) -> StageResult:
        findings: list[Finding] = []
        evidence: list[VerificationEvidence] = []
        runtime_paths.ensure()
        evidence.append(
            VerificationEvidence(
                stage="environment",
                status="pass",
                details="Runtime root is accessible.",
                subject=str(runtime_paths.runtime_root),
            )
        )
        managed_clients = {
            record.get("client")
            for record in self._manifest_repository.list_active_artifacts()
        }
        for client_id in request.target_clients or tuple(
            adapter.adapter_id() for adapter in self._registry.all()
        ):
            adapter = self._registry.get(client_id)
            detection = adapter.detect(self._environment)
            if detection.detected:
                evidence.append(
                    VerificationEvidence(
                        stage="environment",
                        status="pass",
                        details=f"{adapter.display_name()} detection confidence: {detection.confidence}.",
                        subject=adapter.adapter_id(),
                    )
                )
            elif client_id in managed_clients:
                # A managed Exasol entry exists but the client itself is gone
                # (uninstalled after setup, or detection broke) — the one
                # not-detected case that IS warning-worthy.
                findings.append(
                    Finding(
                        code="managed_client_missing",
                        severity=Severity.WARNING,
                        message=f"{adapter.display_name()} has a managed Exasol entry but the client is no longer detected.",
                        scope={"client": adapter.adapter_id()},
                        evidence=detection.evidence,
                        recommended_action=f"Reinstall the client, or remove the stale entry with 'exakit mcp-remove {adapter.adapter_id()}'.",
                    )
                )
            # A client that is neither installed nor managed is expected
            # state, not a problem: discover already reports it as an INFO
            # "not installed (skipped)". Re-warning here counted the same
            # absent client twice and degraded healthy doctor runs to
            # success_with_warnings.
        status = _stage_status(findings)
        return StageResult("environment", status, findings, evidence)

    def validate_config_syntax(
        self, artifacts: Iterable[ArtifactReference]
    ) -> StageResult:
        findings: list[Finding] = []
        evidence: list[VerificationEvidence] = []
        for artifact in artifacts:
            adapter = self._registry.get(artifact.client)
            entry_name = str(artifact.metadata.get("entry_name", "exasol"))
            inspection = adapter.inspect(Path(artifact.path), entry_name)
            findings.extend(inspection.findings)
            if inspection.file_valid:
                evidence.append(
                    VerificationEvidence(
                        stage="config_syntax",
                        status="pass",
                        details="Client configuration is valid JSON and structurally compatible.",
                        subject=artifact.client,
                    )
                )
        if any(finding.blocking for finding in findings):
            status = "fail_blocking"
        elif findings:
            status = "pass_with_warnings"
        else:
            status = "pass"
        return StageResult("config_syntax", status, findings, evidence)

    def validate_connectivity(self, request: OperationRequest) -> StageResult:
        evidence: list[VerificationEvidence] = []
        findings: list[Finding] = []
        if request.dsn_reference is None or request.dsn_reference.kind != "literal":
            findings.append(
                Finding(
                    code="connectivity_not_verified",
                    severity=Severity.WARNING,
                    message="Connectivity could not be verified because no literal DSN was provided.",
                    recommended_action="Provide a host:port literal DSN when connectivity probing is required.",
                )
            )
            return StageResult("connectivity", "pass_with_warnings", findings, evidence)
        host, port = self._parse_host_port(request.dsn_reference.value or "")
        if host is None or port is None:
            findings.append(
                Finding(
                    code="invalid_dsn_literal",
                    severity=Severity.WARNING,
                    message="Connectivity probing expects a literal DSN in host:port form.",
                    evidence=[request.dsn_reference.value or "<missing-dsn>"],
                    recommended_action="Use a host:port DSN for transport-level validation.",
                )
            )
            return StageResult("connectivity", "pass_with_warnings", findings, evidence)
        try:
            with socket.create_connection((host, port), timeout=1.0):
                pass
        except OSError as exc:
            findings.append(
                Finding(
                    code="connectivity_failed",
                    severity=Severity.ERROR,
                    message="TCP connectivity to the configured Exasol endpoint failed.",
                    evidence=[str(exc)],
                    recommended_action="Verify the DSN and the local network path before continuing.",
                )
            )
            return StageResult("connectivity", "fail_recoverable", findings, evidence)
        evidence.append(
            VerificationEvidence(
                stage="connectivity",
                status="pass",
                details=f"Successfully opened a TCP connection to {host}:{port}.",
                subject=request.dsn_reference.value or "",
            )
        )
        return StageResult("connectivity", "pass", findings, evidence)

    # How long the server gets to answer the handshake. Generous on purpose: the
    # command is normally `uvx exasol-mcp-server@<version>`, and the very first
    # run resolves and downloads the package before it says anything at all.
    SERVER_LAUNCH_TIMEOUT_SECONDS = 90

    def validate_server_launch(self, request: OperationRequest) -> StageResult:
        """Actually start the configured MCP server and speak MCP to it.

        WHY: every other stage inspects paperwork. Config syntax reads the client
        file, connectivity opens a TCP socket to the DATABASE, manifest
        consistency compares hashes — so a client whose entry is present and
        well-formed was reported "connected" while the server behind it could not
        start at all. A missing uvx, a package that will not resolve, a python
        too old: every one of those is a healthy doctor report and an AI client
        with no Exasol tools in it. This stage is the one that would have caught
        them, because it is the only one that runs the thing.

        Deliberately forgiving about SPEED and strict about OUTCOME: a timeout is
        a warning (first-run downloads are slow, and a slow server is not a
        broken one), while a server that exits, crashes, or answers something
        that is not MCP is an error with the repair named.
        """
        findings: list[Finding] = []
        evidence: list[VerificationEvidence] = []
        definition = request.server_definition
        if definition is None or not definition.command:
            findings.append(
                Finding(
                    code="server_launch_not_verified",
                    severity=Severity.INFO,
                    message="No stdio server command was supplied, so the server was not started.",
                    recommended_action="Run 'exakit mcp-doctor' on an installed kit to verify the server itself.",
                )
            )
            return StageResult("server_launch", "pass_with_warnings", findings, evidence)

        command = [definition.command, *definition.args]
        # The env block carries EXA_PASSWORD. It is passed to the child and is
        # never echoed: nothing below puts `env` (or the child's stderr, which
        # can quote its own configuration) into a finding or into evidence.
        child_env = dict(os.environ)
        child_env.update(definition.env)
        # DO NOT LET THE KIT'S OWN IMPORT PATH REACH THE SERVER.
        #
        # This subsystem is a package called `mcp`, and it is reached by putting
        # the kit root on PYTHONPATH (Invoke-McpModule does exactly that so
        # `python -m mcp` resolves). The MCP server is a separate program that
        # imports the official `mcp` SDK - so if it inherits that PYTHONPATH,
        # `import mcp` finds OUR package instead and the server dies on import
        # with "FastMCP server support is not installed", exits 1, and doctor
        # reports server_launch_failed against a server that is in fact fine.
        #
        # Measured, same command and credentials, only the environment differing:
        #   clean                      -> tools/list answered
        #   PYTHONPATH=<kit root>      -> exited (code 1)
        #   PYTHONPATH dropped         -> tools/list answered
        # The working directory was tested separately and is harmless, which is
        # why only the variables are removed and cwd is left alone.
        #
        # PYTHONPATH is the one proven to bite; PYTHONHOME goes with it because
        # it would poison the same import in the same way and nothing here needs
        # to pass either to a child that brings its own interpreter.
        child_env.pop("PYTHONPATH", None)
        child_env.pop("PYTHONHOME", None)
        printable = " ".join([Path(command[0]).name, *command[1:]])

        try:
            tools = self._mcp_handshake(command, child_env)
        except subprocess.TimeoutExpired:
            findings.append(
                Finding(
                    code="server_launch_timeout",
                    severity=Severity.WARNING,
                    message=(
                        f"The MCP server did not answer within "
                        f"{self.SERVER_LAUNCH_TIMEOUT_SECONDS}s ({printable})."
                    ),
                    recommended_action=(
                        "Usually a first-run package download. Run the command once by hand "
                        "to warm it, then re-run 'exakit mcp-doctor'."
                    ),
                )
            )
            return StageResult("server_launch", "pass_with_warnings", findings, evidence)
        except FileNotFoundError:
            findings.append(
                Finding(
                    code="server_command_missing",
                    severity=Severity.ERROR,
                    blocking=True,
                    message=f"The configured MCP server command does not exist: {command[0]}",
                    recommended_action="Run 'exakit mcp-doctor' to rewrite the entry from the current definition.",
                )
            )
            return StageResult("server_launch", "fail_recoverable", findings, evidence)
        except _ServerLaunchError as exc:
            findings.append(
                Finding(
                    code="server_launch_failed",
                    severity=Severity.ERROR,
                    blocking=True,
                    message=f"The MCP server did not complete an MCP handshake ({printable}): {exc}",
                    # No "rewrite the entry" advice here: the entry is fine, the
                    # server behind it will not start. Rewriting a correct entry
                    # changes nothing, and doctor has already tried. The only
                    # thing that moves this forward is seeing the failure.
                    recommended_action=(
                        "Run that command by hand to see why it fails - the config "
                        "entry is correct, so rewriting it will not help."
                    ),
                )
            )
            return StageResult("server_launch", "fail_recoverable", findings, evidence)

        evidence.append(
            VerificationEvidence(
                stage="server_launch",
                status="pass",
                # The tool COUNT, not the list: it is the fact that matters
                # ("the client will see tools"), and it stays honest when the
                # server's tool set changes upstream.
                details=f"The MCP server started and offered {len(tools)} tools.",
                subject=printable,
            )
        )
        return StageResult("server_launch", "pass", findings, evidence)

    def _mcp_handshake(self, command: list[str], env: dict[str, str]) -> list[str]:
        """initialize + tools/list over stdio. Returns the tool names.

        STDIN STAYS OPEN until the answer arrives. subprocess.communicate() would
        be the obvious way to do this and it is wrong here: it closes stdin as
        soon as the requests are written, and an MCP stdio server treats that EOF
        as "the client is gone" and shuts down — measured against the real
        server, which exited without ever answering tools/list. So the requests
        are written, the pipe is left open, and stdout is drained on a helper
        thread until the reply lands or the deadline passes.
        """
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            # The server's stderr is noisy (a startup banner, framework warnings,
            # full tracebacks) and can quote its own configuration, which holds
            # the database password. Nothing here reads it, so nothing can leak it.
            stderr=subprocess.DEVNULL,
            env=env,
            text=True,
            bufsize=1,
        )
        lines: "queue.Queue[str]" = queue.Queue()

        def drain() -> None:
            try:
                for line in process.stdout:  # type: ignore[union-attr]
                    lines.put(line)
            except (OSError, ValueError):
                pass

        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        try:
            for message in (
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {},
                        "clientInfo": {"name": "exakit-mcp-doctor", "version": "1"},
                    },
                },
                {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
            ):
                process.stdin.write(json.dumps(message) + "\n")  # type: ignore[union-attr]
                process.stdin.flush()  # type: ignore[union-attr]

            deadline = time.monotonic() + self.SERVER_LAUNCH_TIMEOUT_SECONDS
            while time.monotonic() < deadline:
                try:
                    line = lines.get(timeout=0.5)
                except queue.Empty:
                    # The server died without answering: no point waiting out the
                    # rest of a 90-second budget for a process that is gone.
                    if process.poll() is not None and lines.empty():
                        raise _ServerLaunchError(
                            f"the server exited (code {process.returncode}) before answering"
                        )
                    continue
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") != 2:
                    continue
                if "error" in message:
                    raise _ServerLaunchError(
                        str((message["error"] or {}).get("message", "tools/list failed"))
                    )
                tools = [
                    tool.get("name", "")
                    for tool in (message.get("result") or {}).get("tools", [])
                    if isinstance(tool, dict)
                ]
                if not tools:
                    raise _ServerLaunchError("the server offered no tools")
                return tools
            raise subprocess.TimeoutExpired(command, self.SERVER_LAUNCH_TIMEOUT_SECONDS)
        except BrokenPipeError as exc:
            raise _ServerLaunchError(f"the server closed its input ({exc})") from exc
        finally:
            if process.poll() is None:
                process.kill()
            for stream in (process.stdin, process.stdout):
                try:
                    if stream is not None:
                        stream.close()
                except OSError:
                    pass

    def validate_permission_posture(
        self, artifacts: Iterable[ArtifactReference]
    ) -> StageResult:
        findings: list[Finding] = []
        evidence: list[VerificationEvidence] = []
        # One finding per FILE. Two managed entries in the same file (exasol and
        # an add-on's) are two artifacts on one path, and a loosened mode was
        # reported once per artifact - the same sentence twice in doctor's output.
        seen_paths: set[str] = set()
        for artifact in artifacts:
            if artifact.path in seen_paths:
                continue
            seen_paths.add(artifact.path)
            path = Path(artifact.path)
            if not path.exists():
                findings.append(
                    Finding(
                        code="managed_artifact_missing",
                        severity=Severity.WARNING,
                        message="Managed artifact is missing from disk.",
                        # The client is in scope on EVERY per-artifact finding:
                        # doctor's per-client state taints every managed client
                        # for a finding that names none, so one client's file
                        # read as four clients needing attention.
                        scope={"path": artifact.path, "client": artifact.client},
                        recommended_action=REPAIR_ACTION,
                    )
                )
                continue
            # WINDOWS USED TO SHORT-CIRCUIT INTO THE PASS. The condition read
            # `os_name != "win32" and mode != 0o600`, so on Windows it was
            # always false and control fell to the else - recording
            # "uses the expected local file mode" about a mode that means
            # nothing there and an ACL nobody had looked at. These are the AI
            # client configs that carry EXA_PASSWORD in plaintext, and
            # mcp-doctor is the command the docs point at for exactly this
            # question. The drift is not hypothetical either: the files belong
            # to the CLIENTS, which rewrite them on their own schedule, and a
            # rewrite that creates a new file re-inherits the parent ACL and
            # discards the owner-only DACL protect_path applied.
            #
            # describe_protection is the read side of protect_path, and it has
            # three answers rather than two, because "I could not look" is not
            # the same as "it is fine".
            posture = describe_protection(path)
            if posture is None:
                evidence.append(
                    VerificationEvidence(
                        stage="permission_posture",
                        status="unverified",
                        details=(
                            "Could not read this file's permissions, so its posture is "
                            "unknown - this is not a pass."
                        ),
                        subject=artifact.path,
                    )
                )
            elif posture in {OWNER_ONLY_ACL, "0600"}:
                evidence.append(
                    VerificationEvidence(
                        stage="permission_posture",
                        status="pass",
                        details=(
                            "Managed config carries an owner-only ACL."
                            if posture == OWNER_ONLY_ACL
                            else "Managed config uses the expected local file mode."
                        ),
                        subject=artifact.path,
                    )
                )
            else:
                findings.append(
                    Finding(
                        code="permission_drift",
                        severity=Severity.WARNING,
                        message="Managed client configuration is not restricted to owner read/write.",
                        scope={"path": artifact.path, "client": artifact.client},
                        evidence=[posture],
                        recommended_action=REPAIR_ACTION,
                    )
                )
        status = "pass_with_warnings" if findings else "pass"
        return StageResult("permission_posture", status, findings, evidence)

    def validate_manifest_consistency(
        self, desired: ServerDefinition | None = None
    ) -> StageResult:
        """Compare every managed entry against the manifest AND against ``desired``.

        The manifest hash answers "has anyone touched this since we wrote it?".
        On its own that misses the other way a managed entry goes wrong: nobody
        touched it, an update moved the definition on, and the entry is now a
        faithful copy of what we wrote THEN rather than what we would write NOW.
        Passing the desired definition in is what makes that case visible;
        without it this stage can only ever see a hand edit.
        """

        findings: list[Finding] = []
        evidence: list[VerificationEvidence] = []
        for record in self._manifest_repository.list_active_artifacts():
            artifact = ArtifactReference(**record)
            adapter = self._registry.get(artifact.client)
            entry_name = str(artifact.metadata.get("entry_name", "exasol"))
            path = Path(artifact.path)
            inspection = adapter.inspect(path, entry_name)
            if not path.exists():
                findings.append(
                    Finding(
                        code="manifest_drift_missing_artifact",
                        severity=Severity.ERROR,
                        message="Managed artifact recorded in the manifest is missing.",
                        scope={"path": artifact.path, "client": artifact.client},
                        recommended_action=REPAIR_ACTION,
                    )
                )
                continue
            if inspection.managed_hash != artifact.content_hash:
                findings.append(
                    Finding(
                        code="manifest_drift_hash_mismatch",
                        severity=Severity.ERROR,
                        message="Managed client configuration has drifted from the manifest.",
                        scope={"path": artifact.path, "client": artifact.client},
                        evidence=[
                            f"manifest={artifact.content_hash}",
                            f"current={inspection.managed_hash}",
                        ],
                        recommended_action=REPAIR_ACTION,
                    )
                )
                continue
            evidence.append(
                VerificationEvidence(
                    stage="manifest_consistency",
                    status="pass",
                    details="Manifest hash matches the current managed configuration entry.",
                    subject=artifact.path,
                )
            )
            # The hash check above passed, so the entry is intact. Whether it is
            # also CURRENT is a separate question with a separate answer.
            outdated = self._outdated_entry_finding(adapter, artifact, entry_name, inspection, desired)
            if outdated is not None:
                findings.append(outdated)
        # Severity-aware, via the same helper the other stages use. The two
        # drift findings are ERROR, so they still yield "fail_recoverable"
        # exactly as the old unconditional expression did; an out-of-date entry
        # is a WARNING and lands on "pass_with_warnings" instead, because a
        # client pinned to last month's server is behind, not broken.
        status = _stage_status(findings)
        return StageResult("manifest_consistency", status, findings, evidence)

    @staticmethod
    def _outdated_entry_finding(
        adapter: ClientAdapter,
        artifact: ArtifactReference,
        entry_name: str,
        inspection: AdapterInspection,
        desired: ServerDefinition | None,
    ) -> Finding | None:
        """Report an intact entry that is no longer the one we would write.

        Re-rendering the desired definition against the file as it stands is the
        comparison: every adapter's ``render`` reports the hash the entry WOULD
        have, in the same shape ``inspect`` reports the hash it DOES have, which
        is the invariant the manifest check already relies on. Rendering is a
        pure computation -- nothing is written -- so the read-only callers stay
        read-only.
        """

        if desired is None:
            return None
        if desired.name != entry_name:
            # This artifact records a different server entry than the one the
            # desired definition describes; there is nothing to compare.
            return None
        try:
            rendered = adapter.render(desired, inspection)
        except (ValueError, NotImplementedError):
            # An adapter that cannot render this definition at all (a non-stdio
            # transport, a definition with no command) has nothing to say about
            # how current the entry is. Configure reports that on its own path.
            return None
        if rendered.managed_hash is None or rendered.managed_hash == inspection.managed_hash:
            return None
        return Finding(
            code="managed_entry_outdated",
            severity=Severity.WARNING,
            message=(
                f"{adapter.display_name()} still has the managed Exasol entry from an "
                "earlier setup; it no longer matches the one this kit would write "
                "(a superseded MCP server version is the usual reason)."
            ),
            scope={"path": artifact.path, "client": artifact.client},
            # Hashes only, deliberately: the rendered entry carries the managed
            # env block, and that block holds the database password.
            evidence=[
                f"installed={inspection.managed_hash}",
                f"expected={rendered.managed_hash}",
            ],
            recommended_action="Run 'exakit mcp-doctor' to re-write the entry from the current definition.",
        )

    def run(
        self,
        request: OperationRequest,
        runtime_paths: RuntimePaths,
        artifacts: Iterable[ArtifactReference],
    ) -> list[StageResult]:
        artifact_list = list(artifacts)
        stages: list[StageResult] = []
        for stage_name in request.stages:
            if stage_name == "environment":
                stages.append(self.validate_environment(request, runtime_paths))
            elif stage_name == "config_syntax":
                stages.append(self.validate_config_syntax(artifact_list))
            elif stage_name == "connectivity":
                stages.append(self.validate_connectivity(request))
            elif stage_name == "server_launch":
                stages.append(self.validate_server_launch(request))
            elif stage_name == "permission_posture":
                stages.append(self.validate_permission_posture(artifact_list))
            elif stage_name == "manifest_consistency":
                # The desired definition travels with the request, so validate
                # and doctor get the out-of-date check for free once the caller
                # supplies one.
                stages.append(self.validate_manifest_consistency(request.server_definition))
        return stages

    @staticmethod
    def _parse_host_port(raw: str) -> tuple[str | None, int | None]:
        if not raw:
            return None, None
        if "://" in raw:
            parsed = urlparse(raw)
            return parsed.hostname, parsed.port
        host, separator, port_text = raw.rpartition(":")
        if not separator:
            return None, None
        # Bracketed IPv6 literals ("[::1]:8563") must lose the brackets
        # before being handed to socket.create_connection.
        if host.startswith("[") and host.endswith("]"):
            host = host[1:-1]
        try:
            return host, int(port_text)
        except ValueError:
            return None, None
