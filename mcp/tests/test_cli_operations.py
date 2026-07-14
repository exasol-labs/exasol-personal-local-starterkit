"""CLI tests for managed MCP lifecycle operations."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class RuntimeClientOperationCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-cli-ops-"))
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

    def test_status_validate_and_remove_runtime_operations(self) -> None:
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

        setup = subprocess.run(
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
        self.assertEqual(setup.returncode, 0, setup.stderr)

        status = subprocess.run(
            [
                sys.executable,
                "-m",
                "mcp",
                "run-runtime-operation",
                "status",
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
        self.assertEqual(status.returncode, 0, status.stderr)
        status_doc = json.loads(status.stdout)
        self.assertEqual(status_doc["status"], "success")
        self.assertEqual(len(status_doc["artifacts"]), 2)

        validate = subprocess.run(
            [
                sys.executable,
                "-m",
                "mcp",
                "run-runtime-operation",
                "validate",
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
        self.assertEqual(validate.returncode, 0, validate.stderr)
        validate_doc = json.loads(validate.stdout)
        self.assertEqual(validate_doc["status"], "success_with_warnings")

        remove = subprocess.run(
            [
                sys.executable,
                "-m",
                "mcp",
                "run-runtime-operation",
                "uninstall",
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
        self.assertEqual(remove.returncode, 0, remove.stderr)
        remove_doc = json.loads(remove.stdout)
        self.assertEqual(remove_doc["status"], "success")
        self.assertFalse(cursor_path.exists())
        self.assertFalse(codex_path.exists())

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
