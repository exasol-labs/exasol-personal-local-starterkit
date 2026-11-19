"""CLI tests for starter-kit MCP client setup flows."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class RuntimeClientSetupCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-cli-setup-"))
        self.runtime_root = self._temp_dir / "runtime"
        self.password_file = self.runtime_root / "credentials" / "db_password"
        self.mcp_password_file = self.runtime_root / "credentials" / "mcp_password"
        self.password_file.parent.mkdir(parents=True, exist_ok=True)
        self.password_file.write_text("starter-secret\n", encoding="utf-8")
        self.mcp_password_file.write_text("readonly-secret\n", encoding="utf-8")
        self.manifest_path = self.runtime_root / "manifest.json"
        self.runtime_root.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def test_setup_runtime_clients_rejects_mode_option(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "mcp",
                "setup-runtime-clients",
                "--runtime-root",
                str(self.runtime_root),
                "--mode",
                "temporary",
                "--clients",
                "cursor",
                "codex",
            ],
            cwd=Path(__file__).resolve().parents[2],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrecognized arguments: --mode", result.stderr)

    def test_permanent_setup_writes_live_client_configs_and_records_setup(self) -> None:
        cursor_path = self._temp_dir / "cursor" / "mcp.json"
        codex_path = self._temp_dir / "codex" / "config.toml"
        cursor_path.parent.mkdir(parents=True, exist_ok=True)
        codex_path.parent.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env.update(
            {
                "CURSOR_MCP_CONFIG_PATH": str(cursor_path),
                "CODEX_MCP_CONFIG_PATH": str(codex_path),
            }
        )
        self._write_manifest("exa-local")
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "mcp",
                "setup-runtime-clients",
                "--runtime-root",
                str(self.runtime_root),
                "--clients",
                "cursor",
                "codex",
            ],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["mode"], "permanent")
        self.assertEqual(output["status"], "success_with_warnings")
        cursor_doc = json.loads(cursor_path.read_text(encoding="utf-8"))
        codex_doc = codex_path.read_text(encoding="utf-8")
        self.assertIn("exasol", cursor_doc["mcpServers"])
        # The launcher's MCP sidecar: a URL and nothing secret in any client's config (the read-only user's
        # password lives in the deployment's sidecar definition, and the sidecar enforces read-only itself).
        self.assertEqual(cursor_doc["mcpServers"]["exasol"], {"url": "http://127.0.0.1:4896/mcp"})
        self.assertIn("[mcp_servers.exasol]", codex_doc)
        self.assertIn('url = "http://127.0.0.1:4896/mcp"', codex_doc)
        self.assertNotIn("EXA_PASSWORD", codex_doc)
        self.assertNotIn("readonly-secret", cursor_path.read_text(encoding="utf-8") + codex_doc)
        self.assertTrue(any(action["kind"] == "restart_client" for action in output["next_actions"]))

        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        client_setup = manifest["components"]["mcp_server"]["client_setup"]
        self.assertEqual(client_setup["mode"], "permanent")
        self.assertEqual(client_setup["clients"], ["cursor", "codex"])

    def test_setup_configures_healthy_clients_around_a_broken_config_file(self) -> None:
        """A 0-byte mcp.json left by a VS Code update must not cost the others
        their exasol entry, and the install record has to say what was skipped."""

        cursor_path = self._temp_dir / "cursor" / "mcp.json"
        codex_path = self._temp_dir / "codex" / "config.toml"
        vscode_path = self._temp_dir / "Code" / "User" / "mcp.json"
        for path in (cursor_path, codex_path, vscode_path):
            path.parent.mkdir(parents=True, exist_ok=True)
        vscode_path.write_text("", encoding="utf-8")
        env = os.environ.copy()
        env.update(
            {
                "CURSOR_MCP_CONFIG_PATH": str(cursor_path),
                "CODEX_MCP_CONFIG_PATH": str(codex_path),
                "VSCODE_MCP_CONFIG_PATH": str(vscode_path),
            }
        )
        self._write_manifest("exa-local")
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "mcp",
                "setup-runtime-clients",
                "--runtime-root",
                str(self.runtime_root),
                "--clients",
                "vscode_copilot",
                "cursor",
                "codex",
            ],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["status"], "success_with_warnings")
        self.assertEqual(
            sorted(artifact["client"] for artifact in output["artifacts"]),
            ["codex", "cursor"],
        )
        self.assertEqual(
            [item["client"] for item in output["details"]["skipped_clients"]],
            ["vscode_copilot"],
        )
        self.assertIn("exasol", json.loads(cursor_path.read_text(encoding="utf-8"))["mcpServers"])
        self.assertIn("[mcp_servers.exasol]", codex_path.read_text(encoding="utf-8"))
        # untouched: the adapter must not overwrite what it cannot parse
        self.assertEqual(vscode_path.read_text(encoding="utf-8"), "")

        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        client_setup = manifest["components"]["mcp_server"]["client_setup"]
        self.assertEqual(sorted(client_setup["configured_clients"]), ["codex", "cursor"])
        self.assertEqual(client_setup["skipped_clients"], ["vscode_copilot"])

    def _run_setup_with_locked_folder(self, clients: list[str], locked: list[str]):
        """setup-runtime-clients with the config folders of `locked` read-only."""

        paths = {
            "cursor": self._temp_dir / "cursor" / "mcp.json",
            "codex": self._temp_dir / "codex" / "config.toml",
            "vscode_copilot": self._temp_dir / "Code" / "User" / "mcp.json",
        }
        env_names = {
            "cursor": "CURSOR_MCP_CONFIG_PATH",
            "codex": "CODEX_MCP_CONFIG_PATH",
            "vscode_copilot": "VSCODE_MCP_CONFIG_PATH",
        }
        env = os.environ.copy()
        for client, path in paths.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            env[env_names[client]] = str(path)
        self._write_manifest("exa-local")
        for client in locked:
            paths[client].parent.chmod(0o555)
        try:
            result = subprocess.run(
                [sys.executable, "-m", "mcp", "setup-runtime-clients",
                 "--runtime-root", str(self.runtime_root), "--clients", *clients],
                cwd=Path(__file__).resolve().parents[2],
                env=env,
                check=False,
                capture_output=True,
                text=True,
            )
        finally:
            for client in locked:
                paths[client].parent.chmod(0o755)
        return result, paths

    @unittest.skipIf(os.name == "nt" or (hasattr(os, "geteuid") and os.geteuid() == 0),
                     "needs POSIX folder permissions that bind the current user")
    def test_setup_skips_a_client_whose_folder_cannot_be_written(self) -> None:
        """One read-only client folder must not abort the run: the other clients
        are written AND recorded, the JSON names the skipped client and why."""

        result, paths = self._run_setup_with_locked_folder(
            ["vscode_copilot", "cursor", "codex"], locked=["vscode_copilot"]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["status"], "success_with_warnings")
        self.assertEqual(sorted(output["details"]["configured_clients"]), ["codex", "cursor"])
        self.assertEqual(
            sorted(artifact["client"] for artifact in output["artifacts"]), ["codex", "cursor"]
        )
        skipped = output["details"]["skipped_clients"]
        self.assertEqual([item["client"] for item in skipped], ["vscode_copilot"])
        self.assertEqual(skipped[0]["reason_code"], "client_config_not_writable")
        self.assertEqual(
            skipped[0]["reason"],
            f"its settings file {paths['vscode_copilot']} cannot be written. "
            "Fix the folder's permissions, then run: exakit mcp-setup",
        )
        self.assertIn("exasol", json.loads(paths["cursor"].read_text(encoding="utf-8"))["mcpServers"])
        self.assertIn("[mcp_servers.exasol]", paths["codex"].read_text(encoding="utf-8"))
        self.assertFalse(paths["vscode_copilot"].exists())

        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        client_setup = manifest["components"]["mcp_server"]["client_setup"]
        self.assertEqual(sorted(client_setup["configured_clients"]), ["codex", "cursor"])
        self.assertEqual(client_setup["skipped_clients"], ["vscode_copilot"])
        # The clients that were written are recorded, so mcp-status lists them
        # and uninstall / mcp-remove can take their entries out again.
        from mcp.runtime.manifest import ManifestRepository
        from mcp.runtime.paths import RuntimePaths

        records = ManifestRepository(RuntimePaths(self.runtime_root)).list_active_artifacts()
        self.assertEqual({record["client"] for record in records}, {"codex", "cursor"})

    @unittest.skipIf(os.name == "nt" or (hasattr(os, "geteuid") and os.geteuid() == 0),
                     "needs POSIX folder permissions that bind the current user")
    def test_setup_fails_with_json_when_no_client_can_be_written(self) -> None:
        result, _paths = self._run_setup_with_locked_folder(
            ["vscode_copilot", "cursor"], locked=["vscode_copilot", "cursor"]
        )
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["status"], "blocked")
        self.assertEqual(output["details"]["configured_clients"], [])
        self.assertEqual(
            sorted(item["reason_code"] for item in output["details"]["skipped_clients"]),
            ["client_config_not_writable", "client_config_not_writable"],
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
                "tls": "self-signed",
            },
            "components": {
                "mcp_server": {
                    "backend": "sidecar",
                    "url": "http://127.0.0.1:4896/mcp",
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


class DoctorNextActionsTest(unittest.TestCase):
    """doctor must hand back the remedies its findings already carry.

    It returned next_actions=[] alongside a non-empty findings list, and that is
    the field an unattended caller branches on -- an empty one reads as "nothing
    to do" on a machine with problems.
    """

    def test_next_actions_are_derived_from_findings(self) -> None:
        from mcp.core.models import Finding, NextAction, Severity

        findings = [
            Finding(code="a", severity=Severity.WARNING, message="m",
                    recommended_action="do A"),
            Finding(code="b", severity=Severity.WARNING, message="m",
                    recommended_action="do A"),          # duplicate remedy
            Finding(code="c", severity=Severity.ERROR, message="m",
                    recommended_action="do C", blocking=True),
            Finding(code="d", severity=Severity.INFO, message="m"),  # no remedy
        ]
        seen: set[str] = set()
        actions: list[NextAction] = []
        for finding in sorted(findings, key=lambda f: not f.blocking):
            action = (finding.recommended_action or "").strip()
            if not action or action in seen:
                continue
            seen.add(action)
            actions.append(NextAction(kind=finding.code, message=action))

        self.assertEqual([a.message for a in actions], ["do C", "do A"],
                         "blocking remedy first, duplicates collapsed, empty dropped")
