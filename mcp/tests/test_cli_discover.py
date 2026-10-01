"""Tests for the discover-clients CLI command (dynamic setup menus)."""

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

from mcp import cli


class DiscoverClientsTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-discover-tests-"))

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def _run_discover(self, runtime_root: Path) -> dict:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = cli.main(["discover-clients", "--runtime-root", str(runtime_root)])
        self.assertEqual(code, 0)
        return json.loads(buffer.getvalue())

    def test_reports_all_supported_clients(self) -> None:
        payload = self._run_discover(self._temp_dir)
        ids = {client["id"] for client in payload["clients"]}
        self.assertEqual(
            ids,
            {"claude_desktop", "claude_code", "cursor", "codex", "vscode_copilot", "gemini_cli", "opencode", "continue"},
        )
        for client in payload["clients"]:
            self.assertIn("detected", client)
            self.assertIn("configured", client)
            self.assertIn("display_name", client)

    def _managed_claude_file(self) -> Path:
        # A file that still carries the entry the kit wrote: the case the
        # manifest record is a truthful summary of.
        path = self._temp_dir / "claude_desktop_config.json"
        path.write_text(
            json.dumps({"mcpServers": {"exasol": {"command": "uvx", "args": ["exasol-mcp-server"]}}}),
            encoding="utf-8",
        )
        return path

    def test_configured_reflects_managed_artifacts(self) -> None:
        manifest = {
            "artifacts": [
                {
                    "artifact_id": "a0",
                    "path": str(self._managed_claude_file()),
                    "kind": "client_config",
                    "ownership_state": "managed",
                    "client": "claude_desktop",
                    "removed_at": None,
                },
                {
                    "artifact_id": "a1",
                    "path": "/tmp/removed.json",
                    "kind": "client_config",
                    "ownership_state": "managed",
                    "client": "codex",
                    "removed_at": "2026-01-01T00:00:00Z",  # removed → not configured
                },
            ]
        }
        (self._temp_dir / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        payload = self._run_discover(self._temp_dir)
        state = {client["id"]: client["configured"] for client in payload["clients"]}
        self.assertTrue(state["claude_desktop"])
        self.assertFalse(state["codex"])  # removed artifacts do not count
        self.assertFalse(state["claude_code"])
        self.assertFalse(state["cursor"])

    def test_a_managed_file_without_the_entry_is_not_configured(self) -> None:
        # The audit case: the kit's entry deleted from the client's file by hand.
        # The manifest still remembers writing it; the file no longer has it.
        # `exakit mcp-setup` read the record, said "already connected" and did
        # nothing - so a record whose file has drifted must read as NOT
        # configured, which is what makes setup offer the client again.
        path = self._managed_claude_file()
        gone = self._temp_dir / "gone.json"
        manifest = {
            "artifacts": [
                {"artifact_id": "a0", "path": str(path), "kind": "client_config",
                 "ownership_state": "managed", "client": "claude_desktop", "removed_at": None},
                {"artifact_id": "a1", "path": str(gone), "kind": "client_config",
                 "ownership_state": "managed", "client": "cursor", "removed_at": None},
            ]
        }
        (self._temp_dir / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        self.assertTrue(self._run_discover(self._temp_dir)["clients"][0]["id"])  # sanity: runs
        state = {c["id"]: c["configured"] for c in self._run_discover(self._temp_dir)["clients"]}
        self.assertTrue(state["claude_desktop"])
        self.assertFalse(state["cursor"], "a record whose file is gone is not a configured client")

        path.write_text(json.dumps({"mcpServers": {"other": {"command": "x"}}}), encoding="utf-8")
        state = {c["id"]: c["configured"] for c in self._run_discover(self._temp_dir)["clients"]}
        self.assertFalse(state["claude_desktop"], "the entry is gone from the file, so setup must offer it again")

    def test_an_addon_entry_does_not_make_a_client_configured(self) -> None:
        # Round 3: the file still holds dash-server's entry, but the exasol
        # entry is gone. Setup must offer the client again; the add-on record
        # must not stand in for the kit's own.
        path = self._temp_dir / "mcp.json"
        path.write_text(json.dumps({"servers": {"dash-server": {"url": "http://127.0.0.1:5100/mcp"}}}), encoding="utf-8")
        manifest = {
            "artifacts": [
                {"artifact_id": "a0", "path": str(path), "kind": "client_config", "ownership_state": "managed",
                 "client": "vscode_copilot", "removed_at": None, "metadata": {"entry_name": "exasol"}},
                {"artifact_id": "a1", "path": str(path), "kind": "client_config", "ownership_state": "managed",
                 "client": "vscode_copilot", "removed_at": None, "metadata": {"entry_name": "dash-server"}},
            ]
        }
        (self._temp_dir / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        state = {c["id"]: c["configured"] for c in self._run_discover(self._temp_dir)["clients"]}
        self.assertFalse(state["vscode_copilot"])

    def test_connected_clients_are_detected_with_the_exasol_entry_present(self) -> None:
        # The set an add-on endpoint may be written into: detected AND the exasol
        # entry present. A record for a client that is not on the machine, or
        # whose file lost the entry, is not in it.
        from mcp.runtime.environment import ExecutionEnvironment
        from mcp.runtime.filesystem import FileSystem
        from mcp.runtime.manifest import ManifestRepository
        from mcp.runtime.paths import RuntimePaths
        from mcp.adapters import AdapterRegistry

        present = self._managed_claude_file()
        gone = self._temp_dir / "cursor.json"
        manifest = {
            "artifacts": [
                {"artifact_id": "a0", "path": str(present), "kind": "client_config", "ownership_state": "managed",
                 "client": "claude_desktop", "removed_at": None, "metadata": {"entry_name": "exasol"}},
                {"artifact_id": "a1", "path": str(gone), "kind": "client_config", "ownership_state": "managed",
                 "client": "cursor", "removed_at": None, "metadata": {"entry_name": "exasol"}},
                {"artifact_id": "a2", "path": str(present), "kind": "client_config", "ownership_state": "managed",
                 "client": "gemini_cli", "removed_at": None, "metadata": {"entry_name": "dash-server"}},
            ]
        }
        (self._temp_dir / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        repository = ManifestRepository(RuntimePaths(self._temp_dir), FileSystem())
        detected_env = ExecutionEnvironment(os_name="darwin", home=self._temp_dir,
                                            env={"CLAUDE_DESKTOP_CONFIG_PATH": str(present)})
        self.assertEqual(cli._connected_clients(repository, AdapterRegistry(), detected_env), ["claude_desktop"])
        bare_env = ExecutionEnvironment(os_name="darwin", home=self._temp_dir,
                                        env={"PATH": "/usr/bin:/bin", "EXAKIT_MCP_APP_ROOTS": str(self._temp_dir / "Applications")})
        self.assertEqual(cli._connected_clients(repository, AdapterRegistry(), bare_env), [])

    def test_missing_manifest_means_nothing_configured(self) -> None:
        payload = self._run_discover(self._temp_dir / "does-not-exist")
        self.assertTrue(all(not client["configured"] for client in payload["clients"]))

    def test_undetected_when_machine_has_no_clients(self) -> None:
        # Run in a subprocess with a bare HOME and PATH: no client apps, CLIs,
        # or config dirs exist there, so every client must report detected=false
        # (this is what hides not-installed clients from the setup menu).
        bare_home = self._temp_dir / "bare-home"
        bare_home.mkdir()
        repo_root = Path(__file__).resolve().parents[2]
        env = {
            "HOME": str(bare_home),
            "PATH": "/usr/bin:/bin",
            "PYTHONPATH": str(repo_root),
            # No app bundles either: the developer's real /Applications must
            # not count as this bare machine's.
            "EXAKIT_MCP_APP_ROOTS": str(bare_home / "Applications"),
        }
        result = subprocess.run(
            [sys.executable, "-m", "mcp", "discover-clients", "--runtime-root", str(self._temp_dir)],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(repo_root),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        detected = {client["id"]: client["detected"] for client in payload["clients"]}
        if os.name == "posix" and sys.platform == "darwin":
            self.assertFalse(detected["claude_code"])
            self.assertFalse(detected["codex"])
            self.assertFalse(detected["cursor"])
            self.assertFalse(detected["claude_desktop"])
            self.assertFalse(detected["vscode_copilot"])
            self.assertFalse(detected["gemini_cli"])


if __name__ == "__main__":
    unittest.main()
