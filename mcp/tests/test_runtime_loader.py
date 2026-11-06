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

SIDECAR_URL = "http://127.0.0.1:4896/mcp"


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

    def test_load_without_the_sidecar_record_names_the_fix(self) -> None:
        """The launcher's sidecar is the kit's only MCP server: there is no stdio server to describe instead."""
        for state in ({}, {"backend": "sidecar"}, {"backend": "stdio", "url": SIDECAR_URL},
                      {"backend": "sidecar", "url": "http://db.example:4896/mcp"}):
            with self.subTest(state=state):
                self._write_manifest(components={"mcp_server": {**state, "connection": self._connection()}})
                with self.assertRaises(MCPSubsystemError) as ctx:
                    self.loader.load(self.runtime_root)
                self.assertEqual(ctx.exception.code, "runtime_mcp_server_not_set_up")
                self.assertIn("exakit mcp-setup", str(ctx.exception))

    def test_load_describes_the_sidecar_url_and_nothing_secret(self) -> None:
        self._write_sidecar()
        definition = self.loader.load(self.runtime_root).server_definition
        self.assertEqual((definition.transport.value, definition.url), ("http", SIDECAR_URL))
        self.assertEqual({}, dict(definition.env))
        self.assertNotIn("readonly-secret", json.dumps([definition.url, list(definition.bridge.args)]))

    def test_load_prefers_recorded_mcp_command(self) -> None:
        self._write_sidecar(command="/custom/tools/uvx")
        context = self.loader.load(self.runtime_root)
        self.assertEqual(context.server_definition.bridge.command, "/custom/tools/uvx")

    def test_load_falls_back_to_managed_home_local_bin_command(self) -> None:
        managed_command = self._temp_dir / ".local" / "bin" / "uvx"
        managed_command.parent.mkdir(parents=True, exist_ok=True)
        managed_command.write_text("", encoding="utf-8")
        self._write_sidecar()
        context = self.loader.load(self.runtime_root)
        self.assertEqual(context.server_definition.bridge.command, str(managed_command))

    def test_load_supports_windows_managed_command_path(self) -> None:
        managed_command = self._temp_dir / ".local" / "bin" / "uvx.exe"
        managed_command.parent.mkdir(parents=True, exist_ok=True)
        managed_command.write_text("", encoding="utf-8")
        self._write_sidecar()
        loader = ExakitRuntimeLoader(
            environment=ExecutionEnvironment(os_name="win32", home=self._temp_dir, env={}),
        )
        context = loader.load(self.runtime_root)
        self.assertEqual(context.server_definition.bridge.command, str(managed_command))

    def _connection(self) -> dict:
        return {"user": "mcp_readonly", "password_file": str(self.mcp_password_file), "validated": True}

    def _write_sidecar(self, **mcp_server) -> None:
        self._write_manifest(components={"mcp_server": {"backend": "sidecar", "url": SIDECAR_URL,
                                                        "connection": self._connection(), **mcp_server}})

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
