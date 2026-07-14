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

    def test_configured_reflects_managed_artifacts(self) -> None:
        manifest = {
            "artifacts": [
                {
                    "artifact_id": "a0",
                    "path": "/tmp/claude_desktop_config.json",
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
