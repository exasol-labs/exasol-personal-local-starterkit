"""End-to-end tests for MCP lifecycle operations."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

from mcp.core.models import Finding, OperationStatus, Severity
from mcp.runtime.environment import ExecutionEnvironment
from mcp.service import MCPAccessSubsystem


class MCPSubsystemLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-subsystem-tests-"))
        self.runtime_root = self._temp_dir / "runtime"
        self.config_path = self._temp_dir / "claude" / "claude_desktop_config.json"
        self.environment = ExecutionEnvironment(
            os_name="darwin",
            home=self._temp_dir,
            env={"CLAUDE_DESKTOP_CONFIG_PATH": str(self.config_path)},
        )
        self.subsystem = MCPAccessSubsystem(environment=self.environment)

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def test_full_lifecycle_flow(self) -> None:
        with self._mock_connectivity():
            configure = self.subsystem.execute(self._base_request("configure"))
            self.assertEqual(configure.status, OperationStatus.SUCCESS)
            self.assertTrue(self.config_path.exists())
            config_doc = json.loads(self.config_path.read_text(encoding="utf-8"))
            self.assertIn("exasol", config_doc["mcpServers"])
            self.assertTrue(config_doc["mcpServers"]["exasol"]["command"].endswith("exasol-mcp-server"))

            discover = self.subsystem.execute(self._base_request("discover"))
            self.assertEqual(discover.status, OperationStatus.SUCCESS)
            discovered = discover.details["discovered_clients"][0]
            self.assertTrue(discovered["detected"])

            validate = self.subsystem.execute(self._base_request("validate"))
            self.assertEqual(validate.status, OperationStatus.SUCCESS)
            self.assertGreaterEqual(len(validate.verification_evidence), 4)

            backup = self.subsystem.execute(self._base_request("backup"))
            self.assertEqual(backup.status, OperationStatus.SUCCESS)
            snapshot_id = backup.details["snapshot_id"]

            drifted = json.loads(self.config_path.read_text(encoding="utf-8"))
            drifted["mcpServers"]["exasol"]["command"] = "unexpected-binary"
            self.config_path.write_text(json.dumps(drifted, indent=2) + "\n", encoding="utf-8")

            drift_validate = self.subsystem.execute(self._base_request("validate"))
            self.assertEqual(drift_validate.status, OperationStatus.FAILED_RECOVERABLE)

            repair = self.subsystem.execute(self._base_request("repair"))
            self.assertEqual(repair.status, OperationStatus.SUCCESS)
            repaired_doc = json.loads(self.config_path.read_text(encoding="utf-8"))
            self.assertEqual(repaired_doc["mcpServers"]["exasol"]["command"], "exasol-mcp-server")

            status = self.subsystem.execute(self._base_request("status"))
            self.assertEqual(status.status, OperationStatus.SUCCESS)
            self.assertEqual(len(status.artifacts), 1)

            doctor = self.subsystem.execute(self._base_request("doctor"))
            self.assertIn(doctor.status, {OperationStatus.SUCCESS, OperationStatus.SUCCESS_WITH_WARNINGS})

            restore_source = json.loads(self.config_path.read_text(encoding="utf-8"))
            restore_source["mcpServers"]["exasol"]["args"] = ["--broken"]
            self.config_path.write_text(
                json.dumps(restore_source, indent=2) + "\n", encoding="utf-8"
            )
            restore = self.subsystem.execute(
                {
                    **self._base_request("restore"),
                    "snapshot_id": snapshot_id,
                }
            )
            self.assertEqual(restore.status, OperationStatus.SUCCESS)
            restored_doc = json.loads(self.config_path.read_text(encoding="utf-8"))
            self.assertEqual(restored_doc["mcpServers"]["exasol"]["args"], ["--profile", "starter-kit"])

            uninstall = self.subsystem.execute(self._base_request("uninstall"))
            self.assertEqual(uninstall.status, OperationStatus.SUCCESS)
            self.assertFalse(self.config_path.exists())

    def test_uninstall_preserves_unmanaged_servers(self) -> None:
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        self.config_path.write_text(
            json.dumps(
                {
                    "mcpServers": {
                        "filesystem": {
                            "command": "npx",
                            "args": ["-y", "@modelcontextprotocol/server-filesystem"],
                        }
                    }
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        with self._mock_connectivity():
            configure = self.subsystem.execute(self._base_request("configure"))
            self.assertEqual(configure.status, OperationStatus.SUCCESS)
            uninstall = self.subsystem.execute(self._base_request("uninstall"))
            self.assertEqual(uninstall.status, OperationStatus.SUCCESS)
            remaining = json.loads(self.config_path.read_text(encoding="utf-8"))
            self.assertIn("filesystem", remaining["mcpServers"])
            self.assertNotIn("exasol", remaining["mcpServers"])

    def test_install_is_explicitly_blocked(self) -> None:
        result = self.subsystem.execute(self._base_request("install"))
        self.assertEqual(result.status, OperationStatus.BLOCKED)

    def test_multi_client_configure_and_uninstall(self) -> None:
        cursor_path = self._temp_dir / "cursor" / "mcp.json"
        codex_path = self._temp_dir / "codex" / "config.toml"
        workspace = self._temp_dir / "workspace"
        workspace.mkdir(parents=True, exist_ok=True)
        environment = ExecutionEnvironment(
            os_name="darwin",
            home=self._temp_dir,
            env={
                "CURSOR_MCP_CONFIG_PATH": str(cursor_path),
                "CODEX_MCP_CONFIG_PATH": str(codex_path),
            },
            cwd=workspace,
        )
        subsystem = MCPAccessSubsystem(environment=environment)
        request = {
            **self._base_request("configure"),
            "target_clients": ["cursor", "codex"],
        }
        with self._mock_connectivity():
            configure = subsystem.execute(request)
            self.assertEqual(configure.status, OperationStatus.SUCCESS)
            self.assertTrue(cursor_path.exists())
            self.assertTrue(codex_path.exists())

            cursor_doc = json.loads(cursor_path.read_text(encoding="utf-8"))
            self.assertIn("exasol", cursor_doc["mcpServers"])
            codex_doc = codex_path.read_text(encoding="utf-8")
            self.assertIn("[mcp_servers.exasol]", codex_doc)

            validate = subsystem.execute(
                {
                    **self._base_request("validate"),
                    "target_clients": ["cursor", "codex"],
                }
            )
            self.assertEqual(validate.status, OperationStatus.SUCCESS)

            uninstall = subsystem.execute(
                {
                    **self._base_request("uninstall"),
                    "target_clients": ["cursor", "codex"],
                }
            )
            self.assertEqual(uninstall.status, OperationStatus.SUCCESS)
            self.assertFalse(cursor_path.exists())
            self.assertFalse(codex_path.exists())

    def _base_request(self, operation: str) -> dict:
        return {
            "operation": operation,
            "target_clients": ["claude_desktop"],
            "deployment_mode": "stdio",
            "runtime_root": str(self.runtime_root),
            "server_definition": {
                "name": "exasol",
                "transport": "stdio",
                "command": "exasol-mcp-server",
                "args": ["--profile", "starter-kit"],
                "env": {
                    "EXASOL_DSN": "127.0.0.1:8563",
                    "EXASOL_USER": "exa_readonly",
                },
            },
            "credential_reference": {"kind": "inline_env", "name": "EXASOL_PASSWORD"},
            "dsn_reference": {"kind": "literal", "value": "127.0.0.1:8563"},
            "create_snapshot": True,
            "validate_after_apply": True,
        }

    def _mock_connectivity(self):
        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        connection.__exit__.return_value = False
        return mock.patch("mcp.validator.service.socket.create_connection", return_value=connection)


if __name__ == "__main__":
    unittest.main()



class StatusFromFindingsTests(unittest.TestCase):
    """Run status must be severity-aware: INFO findings (a client that simply
    isn't installed, or "no managed config recorded") are expected state and
    must NOT downgrade a run to success_with_warnings."""

    @staticmethod
    def _f(severity: Severity, blocking: bool = False) -> Finding:
        return Finding(code="x", severity=severity, message="m", blocking=blocking)

    def test_no_findings_is_success(self) -> None:
        self.assertEqual(MCPAccessSubsystem._status_from_findings([]), OperationStatus.SUCCESS)

    def test_info_only_is_success(self) -> None:
        # the fix: not-installed clients (INFO) no longer read as warnings
        self.assertEqual(
            MCPAccessSubsystem._status_from_findings([self._f(Severity.INFO), self._f(Severity.INFO)]),
            OperationStatus.SUCCESS,
        )

    def test_warning_escalates(self) -> None:
        self.assertEqual(
            MCPAccessSubsystem._status_from_findings([self._f(Severity.INFO), self._f(Severity.WARNING)]),
            OperationStatus.SUCCESS_WITH_WARNINGS,
        )

    def test_error_is_failed_recoverable(self) -> None:
        self.assertEqual(
            MCPAccessSubsystem._status_from_findings([self._f(Severity.ERROR)]),
            OperationStatus.FAILED_RECOVERABLE,
        )

    def test_critical_or_blocking_is_blocked(self) -> None:
        self.assertEqual(
            MCPAccessSubsystem._status_from_findings([self._f(Severity.CRITICAL)]),
            OperationStatus.BLOCKED,
        )
        self.assertEqual(
            MCPAccessSubsystem._status_from_findings([self._f(Severity.WARNING, blocking=True)]),
            OperationStatus.BLOCKED,
        )




class DoctorClientStateTests(unittest.TestCase):
    """The doctor's client-state contract: a client that is neither installed
    nor managed is expected state (INFO from discover, silent in the
    environment stage, status stays SUCCESS); the one warning-worthy
    not-detected case is a managed entry whose client has gone missing."""

    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-doctor-state-tests-"))
        self.runtime_root = self._temp_dir / "runtime"
        self.config_path = self._temp_dir / "claude" / "claude_desktop_config.json"
        self.environment = ExecutionEnvironment(
            os_name="darwin",
            home=self._temp_dir,
            env={"CLAUDE_DESKTOP_CONFIG_PATH": str(self.config_path)},
        )
        self.subsystem = MCPAccessSubsystem(environment=self.environment)

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def _request(self, operation: str, clients: list[str]) -> dict:
        return {
            "operation": operation,
            "target_clients": clients,
            "deployment_mode": "stdio",
            "runtime_root": str(self.runtime_root),
            "server_definition": {
                "name": "exasol",
                "transport": "stdio",
                "command": "exasol-mcp-server",
                "args": ["--profile", "starter-kit"],
                "env": {
                    "EXASOL_DSN": "127.0.0.1:8563",
                    "EXASOL_USER": "exa_readonly",
                },
            },
            "credential_reference": {"kind": "inline_env", "name": "EXASOL_PASSWORD"},
            "dsn_reference": {"kind": "literal", "value": "127.0.0.1:8563"},
            "create_snapshot": True,
            "validate_after_apply": True,
        }

    def _mock_connectivity(self):
        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        connection.__exit__.return_value = False
        return mock.patch("mcp.validator.service.socket.create_connection", return_value=connection)

    def test_absent_unmanaged_clients_leave_doctor_at_plain_success(self) -> None:
        with self._mock_connectivity():
            configure = self.subsystem.execute(self._request("configure", ["claude_desktop"]))
            self.assertEqual(configure.status, OperationStatus.SUCCESS)

            # cursor is neither installed in this sandbox nor managed:
            # expected state, so the run must be SUCCESS, full stop.
            doctor = self.subsystem.execute(self._request("doctor", ["claude_desktop", "cursor"]))
            self.assertEqual(doctor.status, OperationStatus.SUCCESS)
            codes = {finding.code for finding in doctor.findings}
            self.assertIn("client_not_detected", codes)          # discover's INFO
            self.assertNotIn("managed_client_missing", codes)
            self.assertFalse(
                [f for f in doctor.findings if f.severity in (Severity.WARNING, Severity.ERROR)]
            )
            # renderers need the managed set: doctor must carry artifacts
            self.assertEqual(len(doctor.artifacts), 1)
            self.assertEqual(doctor.artifacts[0].client, "claude_desktop")

    def test_managed_entry_with_missing_client_warns(self) -> None:
        with self._mock_connectivity():
            configure = self.subsystem.execute(self._request("configure", ["claude_desktop"]))
            self.assertEqual(configure.status, OperationStatus.SUCCESS)

            # Simulate the client vanishing after setup: config file AND its
            # directory are gone (detection falls back to the parent dir), so
            # detection fails while the managed artifact remains recorded.
            shutil.rmtree(self.config_path.parent)
            doctor = self.subsystem.execute(self._request("doctor", ["claude_desktop"]))
            warnings = [
                finding
                for finding in doctor.findings
                if finding.code == "managed_client_missing"
            ]
            self.assertEqual(len(warnings), 1)
            self.assertEqual(warnings[0].severity, Severity.WARNING)
            self.assertIn("mcp-remove claude_desktop", warnings[0].recommended_action)
            self.assertNotEqual(doctor.status, OperationStatus.SUCCESS)
