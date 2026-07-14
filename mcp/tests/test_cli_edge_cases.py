"""CLI failure-path coverage for MCP runtime commands."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class RuntimeCLIErrorCaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-cli-edge-"))
        self.runtime_root = self._temp_dir / "runtime"
        self.manifest_path = self.runtime_root / "manifest.json"
        self.password_file = self.runtime_root / "credentials" / "db_password"
        self.mcp_password_file = self.runtime_root / "credentials" / "mcp_password"
        self.password_file.parent.mkdir(parents=True, exist_ok=True)
        self.password_file.write_text("admin-secret\n", encoding="utf-8")
        self.mcp_password_file.write_text("readonly-secret\n", encoding="utf-8")
        self.runtime_root.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def test_export_runtime_configs_command_is_not_available(self) -> None:
        self._write_manifest(components={})
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "mcp",
                "export-runtime-configs",
                "--runtime-root",
                str(self.runtime_root),
            ],
            cwd=Path(__file__).resolve().parents[2],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid choice: 'export-runtime-configs'", result.stderr)

    def test_validate_runtime_operation_fails_when_mcp_connection_unvalidated(self) -> None:
        self._write_manifest(
            components={
                "mcp_server": {
                    "connection": {
                        "user": "mcp_readonly",
                        "password_file": str(self.mcp_password_file),
                        "validated": False,
                    }
                }
            }
        )
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "mcp",
                "run-runtime-operation",
                "validate",
                "--runtime-root",
                str(self.runtime_root),
            ],
            cwd=Path(__file__).resolve().parents[2],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime_mcp_connection_unvalidated", result.stderr)

    def test_restore_runtime_operation_fails_without_snapshot(self) -> None:
        self._write_manifest(
            components={
                "mcp_server": {
                    "connection": {
                        "user": "mcp_readonly",
                        "password_file": str(self.mcp_password_file),
                        "validated": True,
                    }
                }
            }
        )
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "mcp",
                "run-runtime-operation",
                "restore",
                "--runtime-root",
                str(self.runtime_root),
            ],
            cwd=Path(__file__).resolve().parents[2],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime_snapshot_missing", result.stderr)

    def _write_manifest(self, *, components: dict) -> None:
        manifest = {
            "manifest_version": 1,
            "kit_level": 1,
            "runtime": {
                "type": "personal",
                "dsn": "127.0.0.1:8563",
                "user": "sys",
                "password_file": str(self.password_file),
            },
            "components": components,
            "steps_completed": ["runtime", "mcp_server"],
        }
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
