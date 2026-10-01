"""Doctor blames the client whose file drifted, and only that one.

The per-client state is derived from the findings: a WARNING or ERROR that
names a client marks that client; one that names none taints every managed
client. The permission and missing-file findings named none, so a single
client's file left at 0644 read as every configured client needing attention,
and the JSON gave an agent no way to tell which one to fix.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

from mcp.core.models import OperationStatus, Severity
from mcp.runtime.environment import ExecutionEnvironment
from mcp.service import MCPAccessSubsystem
from mcp.validator.service import REPAIR_ACTION


class DoctorAttributionTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-doctor-attribution-"))
        self.runtime_root = self._temp_dir / "runtime"
        self.claude_path = self._temp_dir / "claude" / "claude_desktop_config.json"
        self.cursor_path = self._temp_dir / "cursor" / "mcp.json"
        self.environment = ExecutionEnvironment(
            os_name="darwin",
            home=self._temp_dir,
            env={
                "CLAUDE_DESKTOP_CONFIG_PATH": str(self.claude_path),
                "CURSOR_MCP_CONFIG_PATH": str(self.cursor_path),
            },
        )
        self.subsystem = MCPAccessSubsystem(environment=self.environment)

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def _request(self, operation: str) -> dict:
        return {
            "operation": operation,
            "target_clients": ["claude_desktop", "cursor"],
            "deployment_mode": "stdio",
            "runtime_root": str(self.runtime_root),
            "server_definition": {
                "name": "exasol",
                "transport": "stdio",
                "command": "uvx",
                "args": ["exasol-mcp-server@2.0.0"],
                "env": {"EXA_DSN": "127.0.0.1:8563", "EXA_USER": "mcp_readonly"},
            },
            "credential_reference": {"kind": "inline_env", "name": "EXA_PASSWORD"},
            "dsn_reference": {"kind": "literal", "value": "127.0.0.1:8563"},
            "create_snapshot": True,
            "validate_after_apply": True,
        }

    def _mock_connectivity(self):
        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        connection.__exit__.return_value = False
        return mock.patch("mcp.validator.service.socket.create_connection", return_value=connection)

    def _states(self, result) -> dict[str, str]:
        return {row["client"]: row["state"] for row in (result.details or {}).get("clients", [])}

    @unittest.skipIf(os.name == "nt", "file modes are a POSIX concept")
    def test_a_loose_file_mode_blames_only_that_client(self) -> None:
        with self._mock_connectivity():
            self.subsystem.execute(self._request("configure"))
            os.chmod(self.cursor_path, 0o644)
            doctor = self.subsystem.execute(self._request("doctor"))
        states = self._states(doctor)
        self.assertEqual(states["cursor"], "needs_attention")
        self.assertEqual(states["claude_desktop"], "connected", states)
        drift = [f for f in doctor.findings if f.code == "permission_drift"]
        self.assertEqual(len(drift), 1)
        self.assertEqual(drift[0].scope.get("client"), "cursor")
        self.assertEqual(drift[0].recommended_action, REPAIR_ACTION)

    def test_a_deleted_entry_blames_only_that_client(self) -> None:
        with self._mock_connectivity():
            self.subsystem.execute(self._request("configure"))
            self.cursor_path.write_text('{"mcpServers": {}}\n', encoding="utf-8")
            doctor = self.subsystem.execute(self._request("doctor"))
        states = self._states(doctor)
        self.assertEqual(states["cursor"], "needs_attention")
        self.assertEqual(states["claude_desktop"], "connected", states)
        named = {
            f.scope.get("client")
            for f in doctor.findings
            if f.severity in (Severity.WARNING, Severity.ERROR) and f.code.startswith("manifest_drift")
        }
        self.assertEqual(named, {"cursor"})

    def test_every_drift_remedy_names_the_command(self) -> None:
        with self._mock_connectivity():
            self.subsystem.execute(self._request("configure"))
            self.cursor_path.unlink()
            doctor = self.subsystem.execute(self._request("doctor"))
        self.assertNotEqual(doctor.status, OperationStatus.SUCCESS)
        actions = {
            f.recommended_action
            for f in doctor.findings
            if f.severity in (Severity.WARNING, Severity.ERROR) and "drift" in f.code or f.code == "managed_artifact_missing"
        }
        self.assertTrue(actions, "the missing file must produce a warning or error")
        for action in actions:
            self.assertIn("exakit mcp-doctor", action or "")


    @unittest.skipIf(os.name == "nt", "file modes are a POSIX concept")
    def test_one_loose_file_is_one_finding(self) -> None:
        # Two managed entries in one file (exasol plus an add-on's) are two
        # artifacts on one path; the loosened mode was reported once per
        # artifact. One file, one finding.
        with self._mock_connectivity():
            self.subsystem.execute(self._request("configure"))
            second = dict(self._request("configure"))
            second["server_definition"] = dict(second["server_definition"], name="dash-server",
                                               transport="http", command=None, args=[],
                                               url="http://127.0.0.1:5100/mcp", env={})
            second["deployment_mode"] = "http"
            second["target_clients"] = ["cursor"]
            self.subsystem.execute(second)
            os.chmod(self.cursor_path, 0o644)
            doctor = self.subsystem.execute(self._request("doctor"))
        drift = [f for f in doctor.findings if f.code == "permission_drift"]
        self.assertEqual(len(drift), 1, [f.scope for f in drift])


class WindowsPermissionPostureTests(unittest.TestCase):
    """SEC-06: doctor must not report a pass for a check it skipped.

    `validate_permission_posture` read stat().st_mode and compared it only when
    NOT on Windows - then fell into the else and recorded
    "Managed config uses the expected local file mode" as PASS evidence. On
    Windows that sentence was about a mode that means nothing there, for an ACL
    nothing had read. These are the AI client configs holding EXA_PASSWORD in
    plaintext, and mcp-doctor is the command the docs point at for this exact
    question.
    """

    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-win-posture-"))
        self.addCleanup(shutil.rmtree, self._temp_dir, True)
        self.artifact_path = self._temp_dir / "claude.json"
        self.artifact_path.write_text('{"mcpServers": {}}\n', encoding="utf-8")

    def _stage(self, posture, os_name="win32"):
        """Run the stage with describe_protection stubbed to one answer."""
        from mcp.validator import service as svc

        validator = svc.ValidatorService.__new__(svc.ValidatorService)
        validator._environment = mock.Mock(os_name=os_name)
        artifact = mock.Mock(path=str(self.artifact_path), client="claude_desktop")
        with mock.patch.object(svc, "describe_protection", return_value=posture):
            return svc.ValidatorService.validate_permission_posture(validator, [artifact])

    def test_an_owner_only_acl_passes_and_says_so_accurately(self) -> None:
        from mcp.runtime.filesystem import OWNER_ONLY_ACL
        result = self._stage(OWNER_ONLY_ACL)
        self.assertEqual(result.findings, [])
        self.assertEqual([e.status for e in result.evidence], ["pass"])
        # It must not claim a "file mode" on Windows - that was the false part.
        self.assertIn("ACL", result.evidence[0].details)
        self.assertNotIn("mode", result.evidence[0].details)

    def test_a_drifted_acl_is_reported_as_drift(self) -> None:
        from mcp.runtime.filesystem import NOT_OWNER_ONLY_ACL
        result = self._stage(NOT_OWNER_ONLY_ACL)
        self.assertEqual([f.code for f in result.findings], ["permission_drift"])
        self.assertEqual(result.findings[0].scope.get("client"), "claude_desktop")

    def test_an_unreadable_acl_is_not_a_pass(self) -> None:
        """The whole point. Before, this path recorded pass evidence."""
        result = self._stage(None)
        self.assertEqual(result.findings, [])
        self.assertEqual([e.status for e in result.evidence], ["unverified"])
        self.assertNotIn("pass", [e.status for e in result.evidence])

    def test_posix_0600_still_passes_with_its_own_wording(self) -> None:
        result = self._stage("0600", os_name="posix")
        self.assertEqual(result.findings, [])
        self.assertEqual([e.status for e in result.evidence], ["pass"])
        self.assertIn("mode", result.evidence[0].details)

    def test_posix_0644_is_still_drift(self) -> None:
        result = self._stage("0644", os_name="posix")
        self.assertEqual([f.code for f in result.findings], ["permission_drift"])
        self.assertEqual(result.findings[0].evidence, ["0644"])
