"""A managed entry can be intact and still be out of date.

The manifest hash only ever answers "has anyone touched this since we wrote
it?". An entry nobody has touched since an update moved the pinned MCP server
version on is byte-identical to that record and still wrong -- it is what we
wrote then, not what we would write now. These tests pin down that validate and
doctor report it, that repair actually rewrites it, that a current entry stays
clean, and that the hash-drift case still behaves exactly as it did.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from mcp.core.models import OperationStatus, Severity
from mcp.runtime.environment import ExecutionEnvironment
from mcp.service import MCPAccessSubsystem

REPO_ROOT = Path(__file__).resolve().parents[2]


class StaleVersionPinTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-stale-pin-tests-"))
        self.runtime_root = self._temp_dir / "runtime"
        self.config_path = self._temp_dir / "claude" / "claude_desktop_config.json"
        self.cursor_path = self._temp_dir / "cursor" / "mcp.json"
        self.environment = ExecutionEnvironment(
            os_name="darwin",
            home=self._temp_dir,
            env={
                "CLAUDE_DESKTOP_CONFIG_PATH": str(self.config_path),
                "CURSOR_MCP_CONFIG_PATH": str(self.cursor_path),
            },
        )
        self.subsystem = MCPAccessSubsystem(environment=self.environment)

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    # ---------------------------------------------------------------- helpers

    def _request(self, operation: str, version: str, clients: list[str] | None = None) -> dict:
        return {
            "operation": operation,
            "target_clients": clients if clients is not None else ["claude_desktop"],
            "deployment_mode": "stdio",
            "runtime_root": str(self.runtime_root),
            "server_definition": {
                "name": "exasol",
                "transport": "stdio",
                "command": "uvx",
                "args": [f"exasol-mcp-server@{version}"],
                "env": {
                    "EXA_DSN": "127.0.0.1:8563",
                    "EXA_USER": "mcp_readonly",
                },
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
        return mock.patch(
            "mcp.validator.service.socket.create_connection", return_value=connection
        )

    def _pin(self, path: Path | None = None) -> str:
        document = json.loads((path or self.config_path).read_text(encoding="utf-8"))
        return document["mcpServers"]["exasol"]["args"][0]

    def _codes(self, result) -> set[str]:
        return {finding.code for finding in result.findings}

    # ------------------------------------------------------------------ tests

    def test_validate_reports_an_intact_but_stale_pin(self) -> None:
        with self._mock_connectivity():
            self.assertEqual(
                self.subsystem.execute(self._request("configure", "1.10.1")).status,
                OperationStatus.SUCCESS,
            )
            self.assertEqual(self._pin(), "exasol-mcp-server@1.10.1")

            validate = self.subsystem.execute(self._request("validate", "2.0.0"))

        self.assertIn("managed_entry_outdated", self._codes(validate))
        # The file is exactly what we last wrote, so this is NOT hash drift.
        self.assertNotIn("manifest_drift_hash_mismatch", self._codes(validate))
        self.assertEqual(validate.status, OperationStatus.SUCCESS_WITH_WARNINGS)
        outdated = next(f for f in validate.findings if f.code == "managed_entry_outdated")
        self.assertEqual(outdated.severity, Severity.WARNING)
        self.assertEqual(outdated.scope["client"], "claude_desktop")
        self.assertIn("mcp-doctor", outdated.recommended_action or "")
        # Never the env block in the evidence: it carries the DB password.
        self.assertNotIn("EXA_PASSWORD", " ".join(outdated.evidence))

    def test_doctor_reports_an_intact_but_stale_pin_without_writing(self) -> None:
        with self._mock_connectivity():
            self.subsystem.execute(self._request("configure", "1.10.1"))
            before = self.config_path.read_bytes()

            doctor = self.subsystem.execute(self._request("doctor", "2.0.0"))

        # Doctor diagnoses; it must not fix anything on the way past. Asserted
        # first so a doctor that writes fails on THAT, not on a knock-on change
        # to the findings.
        self.assertEqual(self.config_path.read_bytes(), before)
        self.assertIn("managed_entry_outdated", self._codes(doctor))
        self.assertNotEqual(doctor.status, OperationStatus.SUCCESS)

    def test_repair_rewrites_an_intact_but_stale_pin(self) -> None:
        with self._mock_connectivity():
            self.subsystem.execute(self._request("configure", "1.10.1"))

            repair = self.subsystem.execute(self._request("repair", "2.0.0"))
            self.assertEqual(repair.status, OperationStatus.SUCCESS)
            self.assertEqual(self._pin(), "exasol-mcp-server@2.0.0")

            # And the repair is durable: nothing is reported the next time round.
            after = self.subsystem.execute(self._request("validate", "2.0.0"))

        self.assertEqual(after.status, OperationStatus.SUCCESS)
        self.assertNotIn("managed_entry_outdated", self._codes(after))

    def test_a_current_pin_still_reports_clean(self) -> None:
        with self._mock_connectivity():
            self.subsystem.execute(self._request("configure", "2.0.0"))

            validate = self.subsystem.execute(self._request("validate", "2.0.0"))
            doctor = self.subsystem.execute(self._request("doctor", "2.0.0"))
            repair = self.subsystem.execute(self._request("repair", "2.0.0"))

        self.assertEqual(validate.status, OperationStatus.SUCCESS)
        self.assertEqual(doctor.status, OperationStatus.SUCCESS)
        self.assertNotIn("managed_entry_outdated", self._codes(validate))
        self.assertNotIn("managed_entry_outdated", self._codes(doctor))
        self.assertEqual(repair.status, OperationStatus.NO_CHANGE)

    def test_hash_drift_is_unchanged_and_reads_differently(self) -> None:
        with self._mock_connectivity():
            self.subsystem.execute(self._request("configure", "2.0.0"))

            drifted = json.loads(self.config_path.read_text(encoding="utf-8"))
            drifted["mcpServers"]["exasol"]["command"] = "unexpected-binary"
            self.config_path.write_text(json.dumps(drifted, indent=2) + "\n", encoding="utf-8")

            validate = self.subsystem.execute(self._request("validate", "2.0.0"))
            self.assertEqual(validate.status, OperationStatus.FAILED_RECOVERABLE)
            self.assertIn("manifest_drift_hash_mismatch", self._codes(validate))
            # A hand edit is a different problem from a superseded definition,
            # and must not be double-reported as both.
            self.assertNotIn("managed_entry_outdated", self._codes(validate))
            drift = next(
                f for f in validate.findings if f.code == "manifest_drift_hash_mismatch"
            )
            self.assertEqual(drift.severity, Severity.ERROR)

            repair = self.subsystem.execute(self._request("repair", "2.0.0"))
            self.assertEqual(repair.status, OperationStatus.SUCCESS)
            repaired = json.loads(self.config_path.read_text(encoding="utf-8"))
            self.assertEqual(repaired["mcpServers"]["exasol"]["command"], "uvx")

    def test_the_two_findings_do_not_read_alike(self) -> None:
        """Different problems, different sentences -- the user has to be able to
        tell "somebody edited this" from "this is a version behind"."""

        with self._mock_connectivity():
            self.subsystem.execute(self._request("configure", "1.10.1"))
            stale = self.subsystem.execute(self._request("validate", "2.0.0"))

            drifted = json.loads(self.config_path.read_text(encoding="utf-8"))
            drifted["mcpServers"]["exasol"]["command"] = "unexpected-binary"
            self.config_path.write_text(json.dumps(drifted, indent=2) + "\n", encoding="utf-8")
            drift = self.subsystem.execute(self._request("validate", "2.0.0"))

        stale_message = next(
            f.message for f in stale.findings if f.code == "managed_entry_outdated"
        )
        drift_message = next(
            f.message for f in drift.findings if f.code == "manifest_drift_hash_mismatch"
        )
        self.assertNotEqual(stale_message, drift_message)
        # The stale one names the client, because "which client is stale" is the
        # part the user acts on.
        self.assertIn("Claude", stale_message)

    def test_repair_of_a_stale_pin_leaves_unconnected_clients_alone(self) -> None:
        """Repair now fires on a superseded entry, which is common -- so it must
        not use that as a licence to configure clients nobody connected."""

        with self._mock_connectivity():
            self.subsystem.execute(self._request("configure", "1.10.1", ["claude_desktop"]))
            self.assertFalse(self.cursor_path.exists())

            repair = self.subsystem.execute(
                self._request("repair", "2.0.0", ["claude_desktop", "cursor"])
            )

        self.assertEqual(repair.status, OperationStatus.SUCCESS)
        self.assertEqual(self._pin(), "exasol-mcp-server@2.0.0")
        self.assertFalse(
            self.cursor_path.exists(),
            "repair created a managed entry for a client that was never connected",
        )


class StaleVersionPinCLITests(unittest.TestCase):
    """The desired definition has to reach validate and doctor through the CLI
    too: that is the layer that previously handed one to repair only."""

    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-stale-pin-cli-"))
        self.runtime_root = self._temp_dir / "runtime"
        self.password_file = self.runtime_root / "credentials" / "db_password"
        self.mcp_password_file = self.runtime_root / "credentials" / "mcp_password"
        self.password_file.parent.mkdir(parents=True, exist_ok=True)
        self.password_file.write_text("starter-secret\n", encoding="utf-8")
        self.mcp_password_file.write_text("readonly-secret\n", encoding="utf-8")
        self.manifest_path = self.runtime_root / "manifest.json"
        self.cursor_path = self._temp_dir / "cursor" / "mcp.json"
        self.cursor_path.parent.mkdir(parents=True, exist_ok=True)
        # These cases drive the real CLI in a SUBPROCESS, so unlike their
        # in-process siblings they cannot mock socket.create_connection -- and
        # setup validates connectivity after applying. Hardcoding 127.0.0.1:8563
        # therefore made the outcome depend on whether the developer happened to
        # have the starter kit running: success_with_warnings on that machine,
        # failed_recoverable (error connectivity_failed) on a clean one or any CI
        # runner. Own the endpoint instead: a listening socket on an ephemeral
        # port answers the TCP probe and needs nothing installed.
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(8)
        self.dsn = "127.0.0.1:%d" % self._listener.getsockname()[1]
        self._write_manifest(self.dsn)

    def tearDown(self) -> None:
        try:
            self._listener.close()
        except OSError:
            pass
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def _env(self, version: str) -> dict:
        env = os.environ.copy()
        env.update(
            {
                "CURSOR_MCP_CONFIG_PATH": str(self.cursor_path),
                "EXAKIT_MCP_VERSION": version,
                "EXAKIT_MCP_COMMAND": "uvx",
            }
        )
        return env

    def _run(self, args: list[str], version: str) -> dict:
        completed = subprocess.run(
            [sys.executable, "-m", "mcp", *args],
            cwd=REPO_ROOT,
            env=self._env(version),
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertTrue(completed.stdout, completed.stderr)
        return json.loads(completed.stdout)

    def _operation(self, operation: str, version: str) -> dict:
        return self._run(
            [
                "run-runtime-operation",
                operation,
                "--runtime-root",
                str(self.runtime_root),
                "--clients",
                "cursor",
            ],
            version,
        )

    def _pin(self) -> str:
        document = json.loads(self.cursor_path.read_text(encoding="utf-8"))
        return document["mcpServers"]["exasol"]["args"][0]

    def test_doctor_reports_and_repair_fixes_a_stale_pin_via_the_cli(self) -> None:
        setup = self._run(
            [
                "setup-runtime-clients",
                "--runtime-root",
                str(self.runtime_root),
                "--clients",
                "cursor",
            ],
            "1.10.1",
        )
        # Include the payload in the failure: a bare status mismatch here says
        # nothing about WHY, and this ran green for as long as nobody ran these
        # tests on Linux. The findings are the diagnosis.
        self.assertIn(
            setup["status"],
            {"success", "success_with_warnings"},
            "setup did not succeed; status=%s findings=%s summary=%s"
            % (
                setup.get("status"),
                [
                    (f.get("severity"), f.get("code"), f.get("message"))
                    for f in setup.get("findings", [])
                ],
                setup.get("summary"),
            ),
        )
        self.assertEqual(self._pin(), "exasol-mcp-server@1.10.1")

        doctor = self._operation("doctor", "2.0.0")
        codes = {finding["code"] for finding in doctor["findings"]}
        self.assertIn("managed_entry_outdated", codes)
        self.assertNotEqual(doctor["status"], "success")

        repair = self._operation("repair", "2.0.0")
        self.assertIn(repair["status"], {"success", "success_with_warnings"})
        self.assertEqual(self._pin(), "exasol-mcp-server@2.0.0")

        clean = self._operation("doctor", "2.0.0")
        self.assertNotIn(
            "managed_entry_outdated",
            {finding["code"] for finding in clean["findings"]},
        )

    def _write_manifest(self, dsn: str) -> None:
        manifest = {
            "manifest_version": 1,
            "kit_level": 1,
            "runtime": {
                "type": "personal",
                "dsn": dsn,
                "user": "sys",
                "password_file": str(self.password_file),
            },
            "components": {
                "mcp_server": {
                    "connection": {
                        "user": "mcp_readonly",
                        "password_file": str(self.mcp_password_file),
                        "validated": True,
                    }
                }
            },
            "steps_completed": ["runtime", "mcp_server"],
        }
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
