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
from urllib.error import HTTPError
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from addons import dash_server, dbt_exasol, exasol_vscode, json_tables  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest, venv_python  # noqa: E402


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
        service = Mock()
        service.status.return_value = "running"
        with patch.object(dash_server, "_service", return_value=service), \
             patch.object(dash_server, "package_version", return_value="0.1.0"), \
             patch.object(dash_server, "_target", return_value="0.2.0"), \
             patch.object(dash_server, "install", side_effect=AddonFailure("package failed")), \
             patch.object(dash_server, "_start_on") as start_on:
            with self.assertRaisesRegex(AddonFailure, "package failed"):
                dash_server.update(self.ctx)
        service.stop.assert_called_once_with(5100)
        start_on.assert_called_once_with(self.ctx, 5100)
        self.assertIsNone(self.manifest.get("desired.dash_server"))

    def test_dash_venv_uses_managed_python_override(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_MANAGED_PYTHON_VERSION": "3.13"}), \
             patch.object(KitContext, "require_uv"), \
             patch.object(KitContext, "target_version", return_value="0.1.1"), \
             patch.object(KitContext, "run_logged") as run, \
             patch.object(dash_server, "package_version", side_effect=[None, "0.1.1"]), \
             patch.object(dash_server, "_settle_port", return_value=5100), \
             patch.object(dash_server, "_restore_templates"), \
             patch.object(dash_server, "_write_launcher", return_value=self.home / "dash"):
            dash_server.install(self.ctx)
        args = run.call_args_list[0].args
        self.assertEqual("3.13", args[args.index("--python") + 1])
        self.assertEqual("kit", self.manifest.get("components.dash_server.ownership"))

    def test_dash_validation_restarts_owned_process_after_broken_ui(self) -> None:
        python = venv_python(self.home / "dash-server-venv")  # Scripts/python.exe on Windows
        python.parent.mkdir(parents=True)
        python.write_text("python", encoding="utf-8")
        service = Mock()
        service.status.return_value = "running"
        with patch.object(dash_server, "_service", return_value=service), \
             patch.object(dash_server, "_http", side_effect=[True, False, True, True]), \
             patch.object(dash_server.subprocess, "run", return_value=Mock(returncode=0)):
            self.assertTrue(dash_server.validate(self.ctx))
        service.stop.assert_called_once_with(5100)
        service.start.assert_called_once()
        self.assertTrue(self.manifest.get("components.dash_server.validated"))
        self.assertTrue(self.manifest.get("components.dash_server.ui_validated"))

    def test_dash_install_repairs_pip_in_existing_environment(self) -> None:
        python = venv_python(self.home / "dash-server-venv")  # Scripts/python.exe on Windows
        python.parent.mkdir(parents=True)
        python.write_text("python", encoding="utf-8")
        with patch.object(KitContext, "require_uv"), \
             patch.object(KitContext, "target_version", return_value="0.1.1"), \
             patch.object(KitContext, "run_logged") as run, \
             patch.object(dash_server.subprocess, "run", return_value=Mock(returncode=1)), \
             patch.object(dash_server, "package_version", side_effect=[None, "0.1.1"]), \
             patch.object(dash_server, "_settle_port", return_value=5100), \
             patch.object(dash_server, "_restore_templates"), \
             patch.object(dash_server, "_write_launcher", return_value=self.home / "dash"):
            dash_server.install(self.ctx)
        commands = [call.args for call in run.call_args_list]
        self.assertTrue(any("Seeding Dash Server pip" == args[0] for args in commands))
        self.assertTrue(any("Installing Dash Server 0.1.1" == args[0] for args in commands))

    def test_dash_validation_probes_fresh_server_before_stopping_it(self) -> None:
        python = venv_python(self.home / "dash-server-venv")  # Scripts/python.exe on Windows
        python.parent.mkdir(parents=True)
        python.write_text("python", encoding="utf-8")
        service = Mock()
        service.status.return_value = "stopped"
        probe_order = []
        service.stop.side_effect = lambda _port: probe_order.append("stop")
        def probe(_port: int, path: str, *, browser: bool) -> bool:
            probe_order.append(path)
            return True
        with patch.object(dash_server, "_service", return_value=service), \
             patch.object(dash_server, "_http", side_effect=probe), \
             patch.object(dash_server.subprocess, "run", return_value=Mock(returncode=0)):
            self.assertTrue(dash_server.validate(self.ctx))
        self.assertEqual(["/mcp", "/", "stop"], probe_order)
        service.start.assert_called_once()
        service.stop.assert_called_once_with(5100)
        self.assertTrue(self.manifest.get("components.dash_server.ui_validated"))

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

        with patch("addons.json_tables.open_url", return_value=Response(b"wrong")):
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

        with patch("addons.json_tables.open_url", return_value=Response(content)):
            json_tables._asset(self.ctx, "owner/repo", "v1", "engine.bin", "macos-aarch64",
                               {"sha256": {"macos-aarch64": digest}}, None, target)
        self.assertEqual(content, target.read_bytes())
        self.assertIn(f"Checksum verified: engine.bin sha256:{digest}",
                      (self.home / "logs" / "marketplace.log").read_text(encoding="utf-8"))

    def test_json_missing_digest_refuses_before_download_with_remedy(self) -> None:
        target = self.home / "engine.bin"
        with patch.dict(os.environ, {"EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES": ""}), \
             patch.object(json_tables, "open_url") as fetch:
            with self.assertRaises(AddonFailure) as failure:
                json_tables._asset(self.ctx, "owner/repo", "tag", "engine.bin", "linux-x86_64",
                                   {}, None, target)
        self.assertIn("exakit update json-tables", str(failure.exception))
        self.assertIn("EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES=1", str(failure.exception))
        self.assertFalse(target.exists())
        fetch.assert_not_called()

    def test_json_external_install_is_not_removed(self) -> None:
        self.manifest.set_many({"components.json_tables.ownership": "user"})
        with patch.object(KitContext, "require_uv") as uv:
            json_tables.install(self.ctx)
        uv.assert_not_called()
        with self.assertRaisesRegex(AddonFailure, "not kit-owned"):
            json_tables.uninstall(self.ctx)

    def test_json_windows_missing_binary_shim_is_incomplete(self) -> None:
        self.manifest.set_many({"components.json_tables.version": "v0.3.2",
                                "components.json_tables.ownership": "kit"})
        engine = self.home / "json-tables/libexec/json_to_parquet.exe"
        engine.parent.mkdir(parents=True)
        engine.write_bytes(b"engine")
        shim = self.home / "json-tables/shim/cargo.exe"
        with patch.object(json_tables, "_engine", return_value=engine), \
             patch.object(json_tables, "_shim", return_value=shim), \
             patch.object(json_tables, "_package_ok", return_value=True), \
             patch.object(json_tables, "_launchers_current", return_value=True), \
             patch.object(json_tables.platform, "system", return_value="Windows"):
            self.assertIsNone(json_tables.installed_version(self.ctx))
            shim.parent.mkdir(parents=True)
            shim.write_bytes(b"shim")
            self.assertEqual("v0.3.2", json_tables.installed_version(self.ctx))

    def test_json_uninstalled_probe_does_not_start_python(self) -> None:
        with patch.object(json_tables, "_package_ok") as package:
            self.assertIsNone(json_tables.installed_version(self.ctx))
        package.assert_not_called()

    def test_json_release_lookup_uses_token_and_distinguishes_refusal(self) -> None:
        # The release lookup goes through runtime.open_url (SEC-12: the token never follows a redirect off
        # GitHub's host), so that is what is patched; patching urlopen let the test reach the real API.
        response = io.BytesIO(b'{"assets": [{"name": "engine.bin", "digest": "sha256:abc"}]}')
        with patch.dict(os.environ, {"GITHUB_TOKEN": "private-test-token"}), \
             patch.object(json_tables, "open_url", return_value=response) as fetch:
            assets = json_tables._api_assets("owner/repo", "json-tables-v1")
        self.assertIn("engine.bin", assets)
        request = fetch.call_args.args[0]
        self.assertEqual("Bearer private-test-token", request.get_header("Authorization"))
        for code, guidance in ((403, "GITHUB_TOKEN"), (404, "pkg / json-tables")):
            error = HTTPError("https://api.github.com", code, "failed", {}, None)
            with self.subTest(code=code), patch.object(json_tables, "open_url", side_effect=error):
                with self.assertRaisesRegex(AddonFailure, guidance):
                    json_tables._api_assets("owner/repo", "json-tables-v1")

    def test_json_release_lookup_rejects_malformed_metadata(self) -> None:
        for content in (b"not JSON", b'{"assets": {}}'):
            with self.subTest(content=content), \
                 patch.object(json_tables, "open_url", return_value=io.BytesIO(content)):
                with self.assertRaisesRegex(AddonFailure, "Malformed JSON Tables release metadata"):
                    json_tables._api_assets("owner/repo", "json-tables-v1")

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
             patch.object(exasol_vscode, "folder_version", return_value=None), \
             patch.object(exasol_vscode, "expected_digest", return_value="0" * 64), \
             patch("addons.exasol_vscode.urllib.request.urlopen", return_value=Response(b"bad")), \
             patch.object(KitContext, "run_logged") as install:
            with self.assertRaisesRegex(AddonFailure, "checksum mismatch"):
                exasol_vscode.install(self.ctx)
        install.assert_not_called()
        self.assertIsNone(self.manifest.get("components.exasol_vscode.ownership"))

    def test_vscode_install_interrupted_after_the_editor_took_it_stays_the_kits(self) -> None:
        """Audit MKT-06's pattern: the editor holds the extension before the receipt is written. An install stopped
        between the two left an extension system_present read as the user's, and every retry and removal was refused."""
        import service
        from model import load_addons

        _, module = service._module(ROOT, "exasol-vscode")
        version = self.ctx.target_version("exasol-vscode", next(
            row.default_version for row in load_addons(ROOT) if row.id == "exasol-vscode"))
        cli = self.home / "code"
        cli.write_text("editor", encoding="utf-8")
        data = b"verified vsix"
        editor = {"version": None}

        class Response(io.BytesIO):
            url = "https://github.com/release.vsix"

        def run_logged(label, *argv, **_kwargs):               # patched on the class: no self
            if "--install-extension" in argv:
                editor["version"] = version
                raise AddonFailure(f"{label} did not finish; see exakit logs setup")
            if "--uninstall-extension" in argv:
                editor["version"] = None

        with patch.object(module, "code_cli", return_value=cli), \
             patch.object(module, "live_version", side_effect=lambda ctx: editor["version"]), \
             patch.object(module, "folder_version", side_effect=lambda ctx: editor["version"]), \
             patch.object(module, "expected_digest", return_value=hashlib.sha256(data).hexdigest()), \
             patch.object(module.urllib.request, "urlopen", side_effect=lambda *a, **k: Response(data)), \
             patch.object(KitContext, "run_logged", side_effect=run_logged):
            with self.assertRaisesRegex(AddonFailure, "did not finish"):
                service.invoke(ROOT, "exasol-vscode", "install", ctx=self.ctx)
            self.assertEqual(version, editor["version"])                     # the editor has it
            self.assertEqual("kit", self.manifest.get("components.exasol_vscode.ownership"))
            self.assertFalse(module.system_present(self.ctx))
            service.invoke(ROOT, "exasol-vscode", "install", ctx=self.ctx)    # resumes: nothing to download again
            self.assertEqual(version, module.installed_version(self.ctx))
            self.assertIsNone(self.manifest.get("components.exasol_vscode.state"))
            service.invoke(ROOT, "exasol-vscode", "uninstall", ctx=self.ctx)
        self.assertIsNone(editor["version"])
        self.assertIsNone(self.manifest.get("components.exasol_vscode"))

    def test_vscode_uninstall_after_an_interrupted_install_names_only_what_it_removed(self) -> None:
        """Audit MKT-06: `exakit uninstall exasol-vscode` reports what an interrupted install had created from this
        answer, so it is the extension only when the editor had it, and nothing when the install stopped before."""
        import service

        cli = self.home / "code"
        cli.write_text("editor", encoding="utf-8")
        for listed, removed in (([None], []), (["1.9.1", None], [exasol_vscode.EXTENSION_ID])):
            with self.subTest(listed=listed):
                self.manifest.set_many({"components.exasol_vscode.ownership": "kit",
                                        "components.exasol_vscode.state": "installing"})
                with patch.object(exasol_vscode, "code_cli", return_value=cli), \
                     patch.object(exasol_vscode, "live_version", side_effect=listed), \
                     patch.object(KitContext, "run_logged") as invoke:
                    self.assertEqual(removed, service.invoke(ROOT, "exasol-vscode", "uninstall", ctx=self.ctx)[1])
                self.assertEqual(bool(removed), invoke.called)
                self.assertIsNone(self.manifest.get("components.exasol_vscode"))

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

    def test_no_add_on_touches_a_copy_the_user_owns(self) -> None:
        """The rule every add-on keeps: one the user installed is seen (system_present) and never updated or removed
        by the kit."""
        import importlib

        built_by_the_kit: set[str] = set()
        catalog = json.loads((ROOT / "marketplace" / "catalog.json").read_text(encoding="utf-8"))["addons"]
        for row in catalog:
            module = importlib.import_module("addons." + row["id"].replace("-", "_"))
            with self.subTest(addon=row["id"]):
                if row["id"] not in built_by_the_kit:
                    self.assertTrue(callable(getattr(module, "system_present", None)),
                                    f"{row['id']} cannot tell a copy the user installed")
                receipt = f"components.{row['id'].replace('-', '_')}"
                self.manifest.set_many({f"{receipt}.ownership": "user", f"{receipt}.version": "1.0.0"})
                with self.assertRaises(AddonFailure):
                    module.update(self.ctx)
                with self.assertRaises(AddonFailure):
                    module.uninstall(self.ctx)

    def test_a_dash_server_the_user_installed_is_managed_outside_the_kit(self) -> None:
        own = self.home / "bin" / "dash-server"
        theirs = Path(self.temp.name) / "user" / "dash-server"
        theirs.parent.mkdir(parents=True)
        theirs.write_text("", encoding="utf-8")
        with patch.object(dash_server, "paths", return_value=(self.home / "venv", self.home, own)), \
             patch("addons.dash_server.shutil.which", return_value=str(theirs)):
            self.assertTrue(dash_server.system_present(self.ctx))
            self.manifest.set_many({"components.dash_server.version": "0.2.1"})
            self.assertFalse(dash_server.system_present(self.ctx))
        with patch.object(dash_server, "paths", return_value=(self.home / "venv", self.home, own)), \
             patch("addons.dash_server.shutil.which", return_value=None):
            self.assertFalse(dash_server.system_present(self.ctx))

    def test_vscode_extension_found_in_an_editor_folder_without_its_cli_is_managed_outside(self) -> None:
        """No editor command on PATH (common on a Mac), but the extension in ~/.vscode/extensions: the user has it, so
        it is listed as managed outside the kit - never offered for install, never "not available"."""
        user_home = Path(self.temp.name) / "user"
        folder = user_home / ".cursor" / "extensions"
        (folder / "exasol.exasol-vscode-1.7.0").mkdir(parents=True)
        (folder / "exasol.exasol-vscode-1.8.2-darwin-arm64").mkdir()
        with patch.object(exasol_vscode, "code_cli", return_value=None), \
             patch.object(exasol_vscode.Path, "home", return_value=user_home), \
             patch.dict(os.environ, {}, clear=False):
            os.environ.pop("EXAKIT_EXASOL_VSCODE_EXTDIR", None)
            self.assertEqual("1.8.2", exasol_vscode.live_version(self.ctx))
            self.assertTrue(exasol_vscode.system_present(self.ctx))
            self.assertTrue(exasol_vscode.applicable(self.ctx))
            # An editor that removed it lists the folder in .obsolete until it cleans up: not installed.
            (folder / ".obsolete").write_text(json.dumps({"exasol.exasol-vscode-1.7.0": True,
                                                         "exasol.exasol-vscode-1.8.2-darwin-arm64": True}), encoding="utf-8")
            self.assertIsNone(exasol_vscode.live_version(self.ctx))
            self.assertFalse(exasol_vscode.system_present(self.ctx))
            self.assertFalse(exasol_vscode.applicable(self.ctx))

    def test_vscode_folder_counts_only_while_the_editors_extensions_json_lists_it(self) -> None:
        """An editor's extensions.json is its record of what is installed: a folder it no longer lists is an uninstall
        whose folder is not deleted yet. An editor with no extensions.json: every folder counts, as before."""
        user_home = Path(self.temp.name) / "user"
        for relative in exasol_vscode.EXTENSION_DIRS:
            root = user_home / relative
            (root / "exasol.exasol-vscode-1.9.1").mkdir(parents=True)
            with self.subTest(root=relative), patch.object(exasol_vscode.Path, "home", return_value=user_home), \
                    patch.dict(os.environ, {}, clear=False):
                os.environ.pop("EXAKIT_EXASOL_VSCODE_EXTDIR", None)
                self.assertEqual("1.9.1", exasol_vscode.folder_version(self.ctx))       # no extensions.json
                (root / "extensions.json").write_text(json.dumps([{
                    "identifier": {"id": "exasol.exasol-vscode"}, "version": "1.9.1",
                    "location": {"$mid": 1, "path": f"/x/{relative}/Exasol.exasol-vscode-1.9.1", "scheme": "file"}}]),
                    encoding="utf-8")
                self.assertEqual("1.9.1", exasol_vscode.folder_version(self.ctx))       # listed by its location
                (root / "extensions.json").write_text("[]", encoding="utf-8")
                self.assertIsNone(exasol_vscode.folder_version(self.ctx))               # removed, folder left
                (root / "extensions.json").write_text(json.dumps([{"identifier": {"id": "other.ext"},
                                                                   "relativeLocation": "other.ext-1.0.0"}]),
                                                      encoding="utf-8")
                self.assertIsNone(exasol_vscode.folder_version(self.ctx))
            (root / "extensions.json").unlink()
            (root / "exasol.exasol-vscode-1.9.1").rmdir()

    def test_vscode_slow_editor_still_finds_the_users_extension(self) -> None:
        """The editor's tool timing out (a slow first start during an install) once made the install table offer the
        extension the install then refused as the user's: the folder answers without starting the editor."""
        user_home = Path(self.temp.name) / "user"
        (user_home / ".vscode" / "extensions" / "exasol.exasol-vscode-1.7.0").mkdir(parents=True)
        timeout = exasol_vscode.subprocess.TimeoutExpired("code", 20)
        with patch.object(exasol_vscode, "code_cli", return_value=Path("/Applications/code")), \
             patch.object(exasol_vscode.subprocess, "run", side_effect=timeout) as run, \
             patch.object(exasol_vscode.Path, "home", return_value=user_home), \
             patch.dict(os.environ, {}, clear=False):
            os.environ.pop("EXAKIT_EXASOL_VSCODE_EXTDIR", None)
            self.assertTrue(exasol_vscode.system_present(self.ctx))
            run.assert_not_called()                       # the folder answered first
            self.assertEqual("1.7.0", exasol_vscode.live_version(self.ctx))   # and after a timeout too

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

    def _wsl_sandbox(self, honour_install: bool = True) -> tuple[Path, Path, Path]:
        """A WSL shell in a sandbox: a fake wslpath and cmd.exe on PATH, and a fake VS Code launcher that acts as the
        WSL server CLI does - Linux paths only (a C:\\ path fails, as it does there), extensions kept in
        ~/.vscode-server/extensions. honour_install=False is the launcher without the WSL extension: the Windows
        editor gets the Linux path and installs nothing."""
        box = Path(self.temp.name) / "wsl"
        bin_dir, user_home, wintemp = box / "bin", box / "home", box / "wintemp"
        for folder in (bin_dir, user_home, wintemp):
            folder.mkdir(parents=True)
        calls = box / "calls"
        scripts = {
            "wslpath": '#!/bin/sh\nif [ "$1" = -w ]; then printf "C:\\\\Temp\\\\x\\n"; else printf "%s\\n" "$WINTEMP"; fi\n',
            "cmd.exe": '#!/bin/sh\nprintf "C:\\\\Temp\\r\\n"\n',
            "code": "#!/bin/sh\n"
                    'printf "%s\\n" "$*" >> "$CALLS"\n'
                    'ext="$HOME/.vscode-server/extensions"\n'
                    'case "$*" in *"\\\\"*|*"C:"*) echo "not found: $*" >&2; exit 1 ;; esac\n'
                    'case "$1" in\n'
                    '  --install-extension) [ -f "$2" ] || { echo "no such file $2" >&2; exit 1; }\n'
                    f'    {"" if honour_install else "exit 0;"} mkdir -p "$ext/exasol.exasol-vscode-1.9.1"\n'
                    """    printf '[{"identifier":{"id":"exasol.exasol-vscode"},"version":"1.9.1","""
                    """"relativeLocation":"exasol.exasol-vscode-1.9.1"}]' > "$ext/extensions.json" ;;\n"""
                    '  --list-extensions) grep -q exasol.exasol-vscode-1.9.1 "$ext/extensions.json" 2>/dev/null && '
                    'echo "exasol.exasol-vscode@1.9.1"; exit 0 ;;\n'
                    # As the server does: the entry goes now, the folder later.
                    """  --uninstall-extension) printf '[]' > "$ext/extensions.json" ;;\n"""
                    "esac\n",
        }
        for name, text in scripts.items():
            (bin_dir / name).write_text(text, encoding="utf-8")
            (bin_dir / name).chmod(0o755)
        os.environ.update({"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}", "HOME": str(user_home),
                           "WINTEMP": str(wintemp), "CALLS": str(calls), "WSL_DISTRO_NAME": "Ubuntu",
                           "WSL_INTEROP": "/run/WSL/1_interop"})
        os.environ.pop("EXAKIT_EXASOL_VSCODE_EXTDIR", None)
        return bin_dir / "code", calls, user_home

    @unittest.skipIf(os.name == "nt", "a WSL shell: its fake tools are POSIX shell scripts")
    def test_vscode_from_wsl_installs_through_the_launcher_into_the_wsl_server(self) -> None:
        """VS Code's bin/code launcher on WSL's PATH (/mnt/c/.../bin/code) runs the distro's server CLI when the WSL
        extension is there: it gets the VSIX's Linux path, no Windows copy and no C:\\ path, and the extension lands
        where a window opened from WSL loads it; status and uninstall see the same place."""
        cli = Path("/mnt/c/Users/Diego/AppData/Local/Programs/Microsoft VS Code/bin/code")
        payload = b"verified extension"

        class Response(io.BytesIO):
            url = "https://github.com/release.vsix"

        real_run = subprocess.run
        with patch.dict(os.environ, {}, clear=False):
            fake, calls, user_home = self._wsl_sandbox()

            def run(argv, *args, **kwargs):     # the /mnt/c launcher is the fake one in the sandbox
                return real_run([str(fake) if str(a) == str(cli) else a for a in argv], *args, **kwargs)

            with patch.object(exasol_vscode, "code_cli", return_value=cli), \
                 patch("subprocess.run", side_effect=run), \
                 patch.object(exasol_vscode, "expected_digest", return_value=hashlib.sha256(payload).hexdigest()), \
                 patch.object(KitContext, "target_version", return_value="1.9.1"), \
                 patch("addons.exasol_vscode.urllib.request.urlopen", return_value=Response(payload)):
                exasol_vscode.install(self.ctx)
                self.assertEqual("1.9.1", self.manifest.get("components.exasol_vscode.version"))
                self.assertEqual("1.9.1", exasol_vscode.installed_version(self.ctx))
                installs = [line for line in calls.read_text(encoding="utf-8").splitlines()
                            if line.startswith("--install-extension ")]
                self.assertEqual(1, len(installs))
                self.assertTrue(installs[0].split(" ")[1].startswith("/"), installs[0])
                self.assertTrue((user_home / ".vscode-server" / "extensions" / "exasol.exasol-vscode-1.9.1").is_dir())
                with patch.object(exasol_vscode, "code_cli", return_value=None):
                    self.assertEqual("1.9.1", exasol_vscode.live_version(self.ctx))   # the folder agrees
                self.assertEqual(["exasol.exasol-vscode"], exasol_vscode.uninstall(self.ctx))
                # The server deletes the folder later; its extensions.json no longer lists it, so it is gone.
                self.assertTrue((user_home / ".vscode-server" / "extensions" / "exasol.exasol-vscode-1.9.1").is_dir())
                self.assertIsNone(exasol_vscode.live_version(self.ctx))
                with patch.object(exasol_vscode, "code_cli", return_value=None):
                    self.assertIsNone(exasol_vscode.live_version(self.ctx))
                self.assertIsNone(self.manifest.get("components.exasol_vscode"))

    @unittest.skipIf(os.name == "nt", "a WSL shell: its fake tools are POSIX shell scripts")
    def test_vscode_from_wsl_without_the_wsl_extension_says_what_to_install(self) -> None:
        cli = Path("/mnt/c/Users/Diego/AppData/Local/Programs/Microsoft VS Code/bin/code")
        payload = b"verified extension"

        class Response(io.BytesIO):
            url = "https://github.com/release.vsix"

        real_run = subprocess.run
        with patch.dict(os.environ, {}, clear=False):
            fake, _calls, _home = self._wsl_sandbox(honour_install=False)

            def run(argv, *args, **kwargs):
                return real_run([str(fake) if str(a) == str(cli) else a for a in argv], *args, **kwargs)

            with patch.object(exasol_vscode, "code_cli", return_value=cli), \
                 patch("subprocess.run", side_effect=run), \
                 patch.object(exasol_vscode, "expected_digest", return_value=hashlib.sha256(payload).hexdigest()), \
                 patch.object(KitContext, "target_version", return_value="1.9.1"), \
                 patch("addons.exasol_vscode.urllib.request.urlopen", return_value=Response(payload)):
                with self.assertRaisesRegex(AddonFailure, r"ms-vscode-remote\.remote-wsl"):
                    exasol_vscode.install(self.ctx)

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
