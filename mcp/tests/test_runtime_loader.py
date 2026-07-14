"""Failure-path tests for loading starter-kit MCP runtime state."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import tempfile
import unittest

from mcp.core.errors import MCPSubsystemError
from mcp.runtime.environment import ExecutionEnvironment
from mcp.runtime.exakit import ExakitRuntimeLoader


class RuntimeLoaderEdgeCaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-runtime-loader-"))
        self.runtime_root = self._temp_dir / "runtime"
        self.manifest_path = self.runtime_root / "manifest.json"
        self.password_file = self.runtime_root / "credentials" / "db_password"
        self.mcp_password_file = self.runtime_root / "credentials" / "mcp_password"
        self.password_file.parent.mkdir(parents=True, exist_ok=True)
        self.password_file.write_text("admin-secret\n", encoding="utf-8")
        self.mcp_password_file.write_text("readonly-secret\n", encoding="utf-8")
        self.runtime_root.mkdir(parents=True, exist_ok=True)
        self.loader = ExakitRuntimeLoader(
            environment=ExecutionEnvironment(os_name="darwin", home=self._temp_dir, env={}),
        )

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def test_load_requires_mcp_connection_block(self) -> None:
        self._write_manifest(components={})
        with self.assertRaises(MCPSubsystemError) as ctx:
            self.loader.load(self.runtime_root)
        self.assertEqual(ctx.exception.code, "runtime_mcp_connection_missing")

    def test_load_requires_validated_mcp_connection(self) -> None:
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
        with self.assertRaises(MCPSubsystemError) as ctx:
            self.loader.load(self.runtime_root)
        self.assertEqual(ctx.exception.code, "runtime_mcp_connection_unvalidated")

    def test_load_rejects_admin_user_as_mcp_connection(self) -> None:
        self._write_manifest(
            components={
                "mcp_server": {
                    "connection": {
                        "user": "sys",
                        "password_file": str(self.password_file),
                        "validated": True,
                    }
                }
            }
        )
        with self.assertRaises(MCPSubsystemError) as ctx:
            self.loader.load(self.runtime_root)
        self.assertEqual(ctx.exception.code, "runtime_mcp_connection_not_isolated")

    def test_load_rejects_incomplete_mcp_connection(self) -> None:
        self._write_manifest(
            components={
                "mcp_server": {
                    "connection": {
                        "user": "mcp_readonly",
                        "validated": True,
                    }
                }
            }
        )
        with self.assertRaises(MCPSubsystemError) as ctx:
            self.loader.load(self.runtime_root)
        self.assertEqual(ctx.exception.code, "runtime_mcp_connection_incomplete")

    def test_load_prefers_recorded_mcp_command(self) -> None:
        self._write_manifest(
            components={
                "mcp_server": {
                    "command": "/custom/tools/uvx",
                    "connection": {
                        "user": "mcp_readonly",
                        "password_file": str(self.mcp_password_file),
                        "validated": True,
                    },
                }
            }
        )
        context = self.loader.load(self.runtime_root)
        self.assertEqual(context.server_definition.command, "/custom/tools/uvx")

    def test_load_disables_certificate_validation_for_local_self_signed_runtime(self) -> None:
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
        context = self.loader.load(self.runtime_root)
        self.assertEqual(context.server_definition.env["EXA_SSL_CERT_VALIDATION"], "no")

    def test_load_passes_openssl_armcap_workaround_to_client_env(self) -> None:
        self._write_manifest(
            components={
                "mcp_server": {
                    "openssl_armcap_workaround": True,
                    "connection": {
                        "user": "mcp_readonly",
                        "password_file": str(self.mcp_password_file),
                        "validated": True,
                    },
                }
            }
        )
        context = self.loader.load(self.runtime_root)
        self.assertEqual(context.server_definition.env["OPENSSL_armcap"], "0")

    def test_load_omits_openssl_armcap_when_workaround_not_recorded(self) -> None:
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
        context = self.loader.load(self.runtime_root)
        self.assertNotIn("OPENSSL_armcap", context.server_definition.env)

    def test_load_enables_read_only_mcp_query_tools(self) -> None:
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
        context = self.loader.load(self.runtime_root)
        settings = json.loads(context.server_definition.env["EXA_MCP_SETTINGS"])
        self.assertTrue(settings["enable_read_query"])
        self.assertTrue(settings["enable_summarize_table"])
        self.assertTrue(settings["enable_query_profiling"])
        self.assertFalse(settings["enable_write_query"])
        self.assertFalse(settings["enable_write_bucketfs"])

    def test_load_falls_back_to_managed_home_local_bin_command(self) -> None:
        managed_command = self._temp_dir / ".local" / "bin" / "uvx"
        managed_command.parent.mkdir(parents=True, exist_ok=True)
        managed_command.write_text("", encoding="utf-8")
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
        context = self.loader.load(self.runtime_root)
        self.assertEqual(context.server_definition.command, str(managed_command))

    def test_load_supports_windows_managed_command_path(self) -> None:
        managed_command = self._temp_dir / ".local" / "bin" / "uvx.exe"
        managed_command.parent.mkdir(parents=True, exist_ok=True)
        managed_command.write_text("", encoding="utf-8")
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
        loader = ExakitRuntimeLoader(
            environment=ExecutionEnvironment(os_name="win32", home=self._temp_dir, env={}),
        )
        context = loader.load(self.runtime_root)
        self.assertEqual(context.server_definition.command, str(managed_command))

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
