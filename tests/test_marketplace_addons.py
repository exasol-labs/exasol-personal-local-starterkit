"""Failure and ownership gates for the Python add-on implementations."""

from __future__ import annotations

import io
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

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

    def test_dbt_validation_checks_connection_without_git(self) -> None:
        credential = self.home / "credentials" / "db-password"
        credential.parent.mkdir()
        credential.write_text("private-test-password\n", encoding="utf-8")
        with patch("addons.dbt_exasol.subprocess.run", return_value=Mock(returncode=0)), \
             patch("addons.dbt_exasol.socket.create_connection"), \
             patch.object(KitContext, "run_logged") as run:
            self.assertTrue(dbt_exasol.validate(self.ctx))
        args = run.call_args.args
        self.assertEqual(("debug", "--connection"), args[-2:])
        self.assertNotIn("private-test-password", " ".join(str(arg) for arg in args))
        self.assertEqual("private-test-password", run.call_args.kwargs["env"]["DBT_ENV_SECRET_EXASOL_PASSWORD"])
        self.assertEqual("connection", self.manifest.get("components.dbt_exasol.validated_by"))

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

    def test_vscode_finds_windows_editors_outside_path(self) -> None:
        local = self.home / "Local App Data"
        cursor = local / "Programs" / "cursor" / "resources" / "app" / "bin" / "cursor.cmd"
        cursor.parent.mkdir(parents=True)
        cursor.write_text("editor", encoding="utf-8")
        program_files = self.home / "Program Files"
        code = program_files / "Microsoft VS Code" / "bin" / "code.cmd"
        code.parent.mkdir(parents=True)
        code.write_text("editor", encoding="utf-8")
        with patch("addons.exasol_vscode.shutil.which", return_value=None), \
             patch.dict("addons.exasol_vscode.os.environ", {"LOCALAPPDATA": str(local),
                                                                "ProgramFiles": str(program_files)}):
            self.assertEqual(cursor, exasol_vscode.code_cli(self.ctx))
            cursor.unlink()
            self.assertEqual(code, exasol_vscode.code_cli(self.ctx))

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

    def test_vscode_listing_closes_stdin_and_uses_private_extension_dir(self) -> None:
        cli = self.home / "code"
        cli.write_text("editor", encoding="utf-8")
        extension_dir = self.home / "extensions"
        with patch.object(exasol_vscode, "code_cli", return_value=cli), \
             patch.dict(os.environ, {"EXAKIT_EXASOL_VSCODE_EXTDIR": str(extension_dir)}), \
             patch("addons.exasol_vscode.subprocess.run",
                   return_value=Mock(returncode=0, stdout="other.ext@1\nexasol.exasol-vscode@1.7.0\n")) as invoke:
            self.assertEqual("1.7.0", exasol_vscode.live_version(self.ctx))
            self.assertTrue(exasol_vscode.system_present(self.ctx))
            self.assertIsNone(exasol_vscode.installed_version(self.ctx))
            self.manifest.set_many({"components.exasol_vscode.version": "1.7.0"})
            self.assertFalse(exasol_vscode.system_present(self.ctx))
            self.assertEqual("1.7.0", exasol_vscode.installed_version(self.ctx))
        self.assertEqual(subprocess.DEVNULL, invoke.call_args.kwargs["stdin"])
        self.assertEqual([str(cli), "--extensions-dir", str(extension_dir),
                          "--list-extensions", "--show-versions"], invoke.call_args.args[0])

    def test_vscode_wsl_stages_extension_on_windows_drive(self) -> None:
        source = self.home / "extension.vsix"
        source.write_bytes(b"extension")
        windows_temp = self.home / "Windows Temp"
        windows_temp.mkdir()
        with patch.object(exasol_vscode, "_wsl_windows_cli", return_value=True), \
             patch("addons.exasol_vscode.shutil.which", side_effect=lambda name: name), \
             patch("addons.exasol_vscode.subprocess.run",
                   side_effect=[Mock(returncode=0, stdout="C:\\Temp\n"),
                                Mock(returncode=0, stdout=str(windows_temp) + "\n")]):
            staged = exasol_vscode._stage_for_wsl(Path("/mnt/c/code.cmd"), source)
        self.assertEqual(windows_temp / source.name, staged)
        self.assertEqual(source.read_bytes(), staged.read_bytes())

    def test_vscode_wsl_path_conversion_and_stage_cleanup(self) -> None:
        cli = Path("/mnt/c/Program Files/VS Code/bin/code.cmd")
        with patch.dict(os.environ, {"WSL_INTEROP": "1"}), \
             patch("addons.exasol_vscode.shutil.which", return_value="/usr/bin/wslpath"), \
             patch("addons.exasol_vscode.subprocess.run",
                   return_value=Mock(returncode=0, stdout="C:\\Temp\\extension.vsix\n")):
            self.assertTrue(exasol_vscode._wsl_windows_cli(cli))
            self.assertFalse(exasol_vscode._wsl_windows_cli(Path("/usr/bin/code")))
            self.assertEqual("C:\\Temp\\extension.vsix",
                             exasol_vscode._host_path(cli, Path("/mnt/c/Temp/extension.vsix")))
        staged = self.home / "staged.vsix"
        payload = b"verified extension"
        digest = hashlib.sha256(payload).hexdigest()

        class Response(io.BytesIO):
            url = "https://github.com/release.vsix"

        def stage(_cli: Path, source: Path) -> Path:
            staged.write_bytes(source.read_bytes())
            return staged

        with patch.object(exasol_vscode, "code_cli", return_value=cli), \
             patch.object(exasol_vscode, "system_present", return_value=False), \
             patch.object(exasol_vscode, "live_version", side_effect=[None, "1.7.0"]), \
             patch.object(exasol_vscode, "expected_digest", return_value=digest), \
             patch.object(exasol_vscode, "_stage_for_wsl", side_effect=stage), \
             patch.object(exasol_vscode, "_host_path", return_value="C:\\Temp\\staged.vsix"), \
             patch.object(KitContext, "target_version", return_value="1.7.0"), \
             patch.object(KitContext, "run_logged") as invoke, \
             patch("addons.exasol_vscode.urllib.request.urlopen", return_value=Response(payload)):
            exasol_vscode.install(self.ctx)
        self.assertFalse(staged.exists())
        self.assertEqual("kit", self.manifest.get("components.exasol_vscode.ownership"))
        self.assertIn("C:\\Temp\\staged.vsix", invoke.call_args.args)

    def test_vscode_uses_advertised_digest_and_falls_back_to_release(self) -> None:
        version = self.ctx.versions_document()["components"]["exasol-vscode"]["version"]
        digest = self.ctx.versions_document()["components"]["exasol-vscode"]["sha256"]["vsix"]
        with patch.object(exasol_vscode, "_release_digest") as release:
            self.assertEqual(digest, exasol_vscode.expected_digest(self.ctx, version, "extension.vsix"))
            release.assert_not_called()
            release.return_value = "f" * 64
            self.assertEqual("f" * 64, exasol_vscode.expected_digest(self.ctx, "9.9.9", "extension.vsix"))

    def test_vscode_uninstall_removes_only_kit_extension(self) -> None:
        cli = self.home / "code"
        cli.write_text("editor", encoding="utf-8")
        self.manifest.set_many({"components.exasol_vscode.ownership": "kit",
                                "components.exasol_vscode.version": "1.7.0"})
        with patch.object(exasol_vscode, "code_cli", return_value=cli), \
             patch.object(exasol_vscode, "live_version", side_effect=["1.7.0", None]), \
             patch.object(KitContext, "run_logged") as invoke:
            self.assertEqual([exasol_vscode.EXTENSION_ID], exasol_vscode.uninstall(self.ctx))
        self.assertIn("--uninstall-extension", invoke.call_args.args)
        self.assertIsNone(self.manifest.get("components.exasol_vscode"))

    def test_vscode_missing_editor_and_digest_do_not_claim_install(self) -> None:
        with patch.object(exasol_vscode, "code_cli", return_value=None), \
             patch.object(exasol_vscode, "system_present", return_value=False):
            with self.assertRaisesRegex(AddonFailure, "editor CLI"):
                exasol_vscode.install(self.ctx)
        with patch.object(exasol_vscode, "code_cli", return_value=self.home / "code"), \
             patch.object(exasol_vscode, "system_present", return_value=False), \
             patch.object(exasol_vscode, "live_version", return_value=None), \
             patch.object(exasol_vscode, "expected_digest", return_value=None), \
             patch.dict(os.environ, {"EXAKIT_ALLOW_UNVERIFIED_EXASOL_VSCODE": "0"}), \
             patch("addons.exasol_vscode.urllib.request.urlopen") as download:
            with self.assertRaisesRegex(AddonFailure, "No trusted VSIX checksum"):
                exasol_vscode.install(self.ctx)
            download.assert_not_called()
        self.assertIsNone(self.manifest.get("components.exasol_vscode"))


if __name__ == "__main__":
    unittest.main()
