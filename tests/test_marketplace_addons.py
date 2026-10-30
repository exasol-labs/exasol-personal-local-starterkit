"""Failure and ownership gates for the Python add-on implementations."""

from __future__ import annotations

import io
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from addons import dash_server, dbt_exasol, exasol_vscode, json_tables  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402


class AddonSafetyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "home"
        self.home.mkdir()
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text(json.dumps({"runtime": {
            "dsn": "127.0.0.1:8563", "user": "sys",
            "password_file": str(self.home / "credentials" / "db-password")}}), encoding="utf-8")
        self.ctx = KitContext(ROOT, self.home, Path(self.temp.name) / "bin", self.manifest, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_dash_external_receipt_is_never_claimed_or_removed(self) -> None:
        self.manifest.set_many({"components.dash_server.ownership": "user"})
        with patch.object(KitContext, "require_uv") as uv:
            dash_server.install(self.ctx)
        uv.assert_not_called()
        with self.assertRaisesRegex(AddonFailure, "not kit-owned"):
            dash_server.uninstall(self.ctx)

    def test_dash_failed_update_attempts_to_restore_running_service(self) -> None:
        self.manifest.set_many({"components.dash_server.ownership": "kit"})
        with patch.object(dash_server, "status", return_value="running"), \
             patch.object(dash_server, "stop") as stop, \
             patch.object(dash_server, "install", side_effect=AddonFailure("package failed")), \
             patch.object(dash_server, "start") as start:
            with self.assertRaisesRegex(AddonFailure, "package failed"):
                dash_server.update(self.ctx)
        stop.assert_called_once_with(self.ctx)
        start.assert_called_once_with(self.ctx)
        self.assertIsNone(self.manifest.get("desired.dash_server"))

    def test_dbt_uses_a_secret_reference_and_preserves_external_adapter(self) -> None:
        profile = dbt_exasol._profile_text(self.ctx)
        self.assertIn("DBT_ENV_SECRET_EXASOL_PASSWORD", profile)
        self.assertNotIn("db-password", profile)
        self.manifest.set_many({"components.dbt_exasol.ownership": "user"})
        with patch.object(KitContext, "require_uv") as uv:
            dbt_exasol.install(self.ctx)
        uv.assert_not_called()
        with self.assertRaisesRegex(AddonFailure, "not kit-owned"):
            dbt_exasol.uninstall(self.ctx)

    def test_json_asset_digest_mismatch_deletes_partial_download(self) -> None:
        target = self.home / "engine.bin"
        class Response(io.BytesIO):
            url = "https://example.test/engine"

        with patch("addons.json_tables.urllib.request.urlopen", return_value=Response(b"wrong")):
            with self.assertRaisesRegex(AddonFailure, "Checksum mismatch"):
                json_tables._asset(self.ctx, "owner/repo", "v1", "engine.bin", "macos-aarch64",
                                   {"sha256": {"macos-aarch64": "0" * 64}}, None, target)
        self.assertFalse(target.exists())

    def test_json_verified_asset_records_its_digest_in_marketplace_log(self) -> None:
        target = self.home / "engine.bin"
        content = b"verified engine"
        digest = hashlib.sha256(content).hexdigest()
        class Response(io.BytesIO):
            url = "https://example.test/engine"

        with patch("addons.json_tables.urllib.request.urlopen", return_value=Response(content)):
            json_tables._asset(self.ctx, "owner/repo", "v1", "engine.bin", "macos-aarch64",
                               {"sha256": {"macos-aarch64": digest}}, None, target)
        self.assertEqual(content, target.read_bytes())
        self.assertIn(f"Checksum verified: engine.bin sha256:{digest}",
                      (self.home / "logs" / "marketplace.log").read_text(encoding="utf-8"))

    def test_json_external_install_is_not_removed(self) -> None:
        self.manifest.set_many({"components.json_tables.ownership": "user"})
        with patch.object(KitContext, "require_uv") as uv:
            json_tables.install(self.ctx)
        uv.assert_not_called()
        with self.assertRaisesRegex(AddonFailure, "not kit-owned"):
            json_tables.uninstall(self.ctx)

    def test_vscode_reuses_user_extension_without_download(self) -> None:
        with patch.object(exasol_vscode, "system_present", return_value=True), \
             patch("addons.exasol_vscode.urllib.request.urlopen") as fetch:
            exasol_vscode.install(self.ctx)
        fetch.assert_not_called()
        self.assertIsNone(self.manifest.get("components.exasol_vscode.ownership"))
        with self.assertRaisesRegex(AddonFailure, "not kit-owned"):
            exasol_vscode.uninstall(self.ctx)

    def test_vscode_bad_digest_refuses_before_extension_install(self) -> None:
        cli = self.home / "code"
        cli.write_text("editor", encoding="utf-8")
        class Response(io.BytesIO):
            url = "https://github.com/release.vsix"

        with patch.object(exasol_vscode, "code_cli", return_value=cli), \
             patch.object(exasol_vscode, "live_version", return_value=None), \
             patch.object(exasol_vscode, "expected_digest", return_value="0" * 64), \
             patch("addons.exasol_vscode.urllib.request.urlopen", return_value=Response(b"bad")), \
             patch.object(KitContext, "run_logged") as install:
            with self.assertRaisesRegex(AddonFailure, "checksum mismatch"):
                exasol_vscode.install(self.ctx)
        install.assert_not_called()
        self.assertIsNone(self.manifest.get("components.exasol_vscode.ownership"))


if __name__ == "__main__":
    unittest.main()
