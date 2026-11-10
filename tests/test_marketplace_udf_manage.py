"""UDF marketplace lifecycle and command contracts without a live database."""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from cli_entrypoints import entrypoints

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from addons import udf_devkit as udf  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest, activity_sink  # noqa: E402
from udf_manage import _parse, command  # noqa: E402


class UdfManageTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "kit home"
        self.home.mkdir()
        self.store = Manifest(self.home / "manifest.json")
        self.store.path.write_text(json.dumps({"components": {"udf_devkit": {"version": "0.1.0",
                                                                              "ownership": "kit"}}}))
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.store, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_bad_arguments_are_refused_before_manifest_or_bucket_access(self) -> None:
        for command_name, args in (("udf-setup", ["--language", "java"]),
                                   ("udf-use", ["--list", "default"]),
                                   ("udf-build", ["--alias", "X"])):
            with self.subTest(command_name=command_name, args=args):
                with self.assertRaises(udf.UdfFailure):
                    _parse(command_name, args)

    def test_public_commands_report_json_failures_without_resource_changes(self) -> None:
        self.store.delete("components.udf_devkit")
        before = self.store.path.read_bytes()
        env = {**os.environ, "EXAKIT_HOME": str(self.home), "EXAKIT_BIN_DIR": str(self.home / "bin"),
               "EXAKIT_NO_UPDATE_NOTICE": "1", "EXAKIT_NO_FANCY": "1", "EXAKIT_UDF_LANGUAGE": "python"}
        commands = entrypoints()
        self.assertTrue(commands)
        cases = ((["udf-setup", "--language", "java", "--json"], 2),
                 (["udf-use", "--list", "default", "--json"], 2),
                 (["udf-build", "--invented"], 2),
                 (["udf-setup", "--json"], 5),
                 (["udf-use", "--list", "--json"], 5))
        for prefix in commands:
            for args, code in cases:
                with self.subTest(shell=prefix[0], args=args):
                    result = subprocess.run([*prefix, *args], env=env, input="", capture_output=True,
                                            text=True, timeout=45)
                    self.assertEqual(code, result.returncode, result.stdout + result.stderr)
                    if "--json" in args:
                        answer = json.loads(result.stdout)
                        self.assertIs(False, answer["ok"])
                        self.assertEqual("select-container", answer["step"])
                        if code == 5:
                            self.assertEqual("exakit marketplace udf-devkit", answer["remedy"])
        self.assertEqual(before, self.store.path.read_bytes())
        self.assertFalse(udf._home(self.ctx).exists())

    def test_json_has_one_object_even_when_setup_emits_progress(self) -> None:
        output = io.StringIO()

        def setup(*_args, **_kwargs):
            print("  • Preparing UDF container")
            return None, [{"package": "python", "version": "3.12"}]

        with patch.object(udf, "setup_python", setup), contextlib.redirect_stdout(output):
            self.assertEqual(0, command(self.ctx, "udf-setup", ["--json"]))
        answer = json.loads(output.getvalue())
        self.assertEqual("PYTHON3", answer["alias"])
        self.assertEqual([{"package": "python", "version": "3.12"}], answer["smoke"])

    def test_install_records_receipt_then_sets_up_python_and_ml(self) -> None:
        self.store.delete("components.udf_devkit")
        with patch.object(udf, "_launcher_supported"), \
             patch.object(udf, "_database_ready", return_value=True), \
             patch.object(udf, "setup_python") as python_setup, \
             patch.object(udf, "setup_default") as ml_setup:
            udf.install(self.ctx)
        self.assertEqual("0.1.0", self.store.get("components.udf_devkit.version"))
        python_setup.assert_called_once()
        ml_setup.assert_called_once()

    def test_uninstall_never_removes_external_home(self) -> None:
        other = Path(self.temp.name) / "user-udf"
        other.mkdir()
        (other / "keep").write_text("personal")
        self.store.set_many({"components.udf_devkit.home": str(other)})
        with self.assertRaisesRegex(AddonFailure, "outside the kit home"):
            udf.uninstall(self.ctx)
        self.assertEqual("personal", (other / "keep").read_text())

    def test_external_ownership_survives_marketplace_install(self) -> None:
        self.store.set_many({"components.udf_devkit.ownership": "user"})
        with patch.object(udf, "_launcher_supported") as launcher:
            udf.install(self.ctx)
        launcher.assert_not_called()

    def test_absent_receipt_cannot_be_updated_or_uninstalled(self) -> None:
        self.store.delete("components.udf_devkit")
        with self.assertRaisesRegex(AddonFailure, "not kit-owned"):
            udf.update(self.ctx)
        with self.assertRaisesRegex(AddonFailure, "not kit-owned"):
            udf.uninstall(self.ctx)
        self.assertIsNone(self.store.get("components.udf_devkit"))

    def test_old_launcher_is_refused_before_receipt(self) -> None:
        self.store.delete("components.udf_devkit")
        probe = type("Result", (), {"returncode": 0, "stdout": "2.2.9\n", "stderr": ""})()
        with patch.object(udf, "_launcher", return_value="launcher"), \
             patch.object(udf.subprocess, "run", return_value=probe):
            with self.assertRaisesRegex(udf.UdfFailure, "older than 2.3.0"):
                udf.install(self.ctx)
        self.assertIsNone(self.store.get("components.udf_devkit.version"))

    def test_failed_container_install_restarts_previously_running_service(self) -> None:
        calls = []

        def kit(_ctx, *args):
            calls.append(args)
            if args == ("status", "--json"):
                return type("Result", (), {"returncode": 0,
                    "stdout": json.dumps({"services": {"database": "running", "dash-server": "running"}})})()
            return type("Result", (), {"returncode": 0, "stdout": ""})()

        with patch.object(udf, "_kit_command", side_effect=kit), \
             patch.object(udf, "_launcher", return_value="launcher"), \
             patch.object(udf, "_deployment", return_value=Path("/deployment")), \
             patch.object(udf, "_database_ready", return_value=True), \
             patch.object(KitContext, "run_logged", side_effect=AddonFailure("launcher failed")):
            with self.assertRaises(udf.UdfFailure) as failed:
                udf._restart(self.ctx, [["install", "PYTHON3"]], yes=True, reason="test install")
        self.assertEqual(6, failed.exception.code)
        self.assertEqual([("status", "--json"), ("stop", "dash-server"),
                          ("start", "dash-server")], calls)

    def test_restart_activity_changes_before_waiting_for_database(self) -> None:
        labels = []

        def ready(_ctx):
            self.assertEqual("Waiting for database restart", labels[-1])
            return True

        with activity_sink(labels.append), \
             patch.object(udf, "_kit_command", return_value=type("Result", (), {"returncode": 0, "stdout": "{}"})()), \
             patch.object(udf, "_launcher", return_value=sys.executable), \
             patch.object(udf, "_deployment", return_value=self.home), \
             patch.object(KitContext, "run_logged", side_effect=lambda label, *_args, **_kwargs: self.ctx.activity(label)), \
             patch.object(udf, "_database_ready", side_effect=ready):
            udf._restart(self.ctx, [["install", "PYTHON3"]], yes=True, reason="Installing PYTHON3")
        self.assertEqual(["Installing PYTHON3", "Waiting for database restart"], labels)

    def test_failed_service_stop_restores_services_already_stopped(self) -> None:
        calls = []

        def kit(_ctx, *args):
            calls.append(args)
            if args == ("status", "--json"):
                return type("Result", (), {"returncode": 0, "stdout": json.dumps({"services": {
                    "database": "running", "dash-server": "running", "exasol-scheduler": "running"}})})()
            return type("Result", (), {"returncode": int(args == ("stop", "exasol-scheduler")), "stdout": ""})()

        with patch.object(udf, "_kit_command", side_effect=kit), \
             patch.object(KitContext, "run_logged") as install, \
             patch.object(udf, "_database_ready") as ready:
            with self.assertRaises(udf.UdfFailure) as failed:
                udf._restart(self.ctx, [["install", "PYTHON3"]], yes=True, reason="test install")
        self.assertEqual(5, failed.exception.code)
        self.assertEqual([("status", "--json"), ("stop", "dash-server"),
                          ("stop", "exasol-scheduler"), ("start", "dash-server")], calls)
        install.assert_not_called()
        ready.assert_not_called()

    def test_bad_digest_cannot_reach_launcher_restart(self) -> None:
        row = {"arch": "aarch64", "url": "https://example.invalid/container.tar.gz", "size": 100,
               "sha256": "0" * 64, "packages": {"scikit-learn": "1.9.0"}}
        with patch.object(udf, "_ready"), patch.object(udf, "_row", return_value=row), \
             patch.object(udf, "fetch", side_effect=AddonFailure("pinned SHA-256 differs")), \
             patch.object(udf, "_restart") as restart:
            with self.assertRaises(udf.UdfFailure) as failed:
                udf.setup_default(self.ctx)
        self.assertEqual((4, "verify"), (failed.exception.code, failed.exception.step))
        restart.assert_not_called()

    def test_rust_adds_python_in_one_restart_when_missing(self) -> None:
        row = {"arch": "aarch64", "url": "https://example.invalid/rust.tar.gz", "size": 10,
               "smoke_asset": {"sha256": "0" * 64, "size": 1}}
        commands = []

        def restart(_ctx, steps, **_kwargs):
            commands.extend(steps)

        with patch.object(udf, "_ready"), patch.object(udf, "_row", return_value=row), \
             patch.object(udf, "fetch", return_value=Path("/cache/rust.tar.gz")), \
             patch.object(udf, "rust_smoke", return_value=Path("/cache/smoke.so")), \
             patch.object(udf, "_aliases", return_value=set()), \
             patch.object(udf, "_restart", side_effect=restart), \
             patch.object(udf, "_smoke", return_value=[]), \
             patch.object(udf, "_rust_smoke", return_value=[]):
            _, _, steps = udf.setup_rust(self.ctx, yes=True)
        self.assertIn("--no-restart", commands[0])
        self.assertEqual(["install", "PYTHON3", "--auto-approve"], commands[1])
        self.assertEqual(["rust", "python"], [step["language"] for step in steps])

    def test_rust_placeholder_installs_but_stays_unvalidated(self) -> None:
        row = {"arch": "aarch64", "url": "https://example.invalid/rust.tar.gz", "size": 10,
               "smoke_asset": {"sha256": "placeholder", "size": 0}}
        with patch.object(udf, "_ready"), patch.object(udf, "_row", return_value=row), \
             patch.object(udf, "fetch", return_value=Path("/cache/rust.tar.gz")), \
             patch.object(udf, "_aliases", return_value=set()), \
             patch.object(udf, "_restart") as restart, \
             patch.object(udf, "_smoke", return_value=[]):
            with self.assertRaises(udf.UdfFailure) as failed:
                udf.setup_rust(self.ctx, yes=True)
        self.assertEqual((7, "smoke"), (failed.exception.code, failed.exception.step))
        self.assertIs(False, self.store.get("components.udf_devkit.validated"))
        restart.assert_called_once()

    def test_declined_restart_leaves_services_and_launcher_untouched(self) -> None:
        with patch.object(sys.stdin, "isatty", return_value=True), \
             patch.object(sys.stdout, "isatty", return_value=True), \
             patch("builtins.input", return_value="n"), \
             patch.object(udf, "_kit_command") as kit, patch.object(KitContext, "run_logged") as run:
            with self.assertRaises(udf.UdfFailure) as failed:
                udf._restart(self.ctx, [["install", "PYTHON3"]], yes=False, reason="test")
        self.assertEqual(5, failed.exception.code)
        kit.assert_not_called()
        run.assert_not_called()

    def test_existing_ml_container_is_proven_without_install(self) -> None:
        row = {"url": "https://example.invalid/python.tar.gz", "packages": {"scikit-learn": "1.9.0"}}
        with patch.object(udf, "_ready"), patch.object(udf, "_row", return_value=row), \
             patch.object(udf, "_aliases", return_value={udf.ML}), \
             patch.object(udf, "_smoke", return_value=[]) as smoke, \
             patch.object(udf, "fetch") as fetch, patch.object(udf, "_restart") as restart:
            udf.setup_default(self.ctx, install=False)
        smoke.assert_called_once_with(self.ctx, udf.ML, ["scikit-learn==1.9.0"])
        fetch.assert_not_called()
        restart.assert_not_called()
        self.assertEqual(udf.ML, self.store.get("components.udf_devkit.python_alias"))

    def test_failed_smoke_is_not_recorded_as_ready(self) -> None:
        for code in (3, 1):
            with self.subTest(code=code), patch.object(udf, "_tool", return_value=SimpleNamespace(
                    returncode=code, stdout="", stderr="missing package")):
                with self.assertRaises(udf.UdfFailure) as failed:
                    udf._smoke(self.ctx, udf.ML, ["scikit-learn==1.9.0"])
            self.assertEqual(3 if code == 3 else 7, failed.exception.code)
            self.assertIs(False, self.store.get("components.udf_devkit.validated"))

    def test_rust_smoke_digest_failure_precedes_restart(self) -> None:
        row = {"arch": "aarch64", "size": 10, "smoke_asset": {"sha256": "0" * 64, "size": 1}}
        with patch.object(udf, "_ready"), patch.object(udf, "_row", return_value=row), \
             patch.object(udf, "fetch", return_value=self.home / "rust.tar.gz"), \
             patch.object(udf, "rust_smoke", side_effect=AddonFailure("SHA-256 mismatch")), \
             patch.object(udf, "_restart") as restart:
            with self.assertRaises(udf.UdfFailure) as failed:
                udf.setup_rust(self.ctx)
        self.assertEqual((4, "verify"), (failed.exception.code, failed.exception.step))
        restart.assert_not_called()

    def test_build_refuses_unpinned_packages_and_insufficient_disk_before_install(self) -> None:
        from addons import notebook
        requirements = self.home / "requirements.txt"
        requirements.write_text("numpy\n")
        with patch.object(KitContext, "run_logged") as run:
            with self.assertRaises(udf.UdfFailure) as failed:
                udf.build(self.ctx, requirements, "CUSTOM", yes=True)
            self.assertEqual(2, failed.exception.code)
            requirements.write_text("numpy==2.4.6\n")
            with patch.object(notebook, "installed_version", return_value="3.1.0"), \
                 patch.object(udf, "_ready"), patch.object(udf, "_engine", return_value={}), \
                 patch.object(udf.shutil, "disk_usage", return_value=SimpleNamespace(free=1)):
                with self.assertRaisesRegex(udf.UdfFailure, "25 GB"):
                    udf.build(self.ctx, requirements, "CUSTOM", yes=True)
            run.assert_not_called()

    def test_engine_requires_running_runtime_and_preserves_explicit_socket(self) -> None:
        with patch.object(udf.shutil, "which", return_value=None):
            with self.assertRaisesRegex(udf.UdfFailure, "running Docker or Podman"):
                udf._engine(self.ctx)
        with patch.object(udf.shutil, "which", side_effect=lambda name: name if name == "podman" else None), \
             patch.object(udf.subprocess, "run", return_value=SimpleNamespace(returncode=0)), \
             patch.dict(os.environ, {"DOCKER_HOST": "unix:///test/podman.sock"}):
            self.assertEqual("unix:///test/podman.sock", udf._engine(self.ctx)["DOCKER_HOST"])

    def test_uninstall_keeps_deployment_models_and_preview_changes_nothing(self) -> None:
        home = udf._home(self.ctx)
        home.mkdir(parents=True)
        model = self.home / "deployment" / "models" / "mine.onnx"
        model.parent.mkdir(parents=True)
        model.write_bytes(b"model")
        with patch.object(udf, "stop") as stop:
            self.assertEqual([home], udf.uninstall(self.ctx, dry_run=True))
            stop.assert_not_called()
            self.assertTrue(home.exists())
            udf.uninstall(self.ctx)
            stop.assert_called_once()
        self.assertEqual(b"model", model.read_bytes())
        self.assertFalse(home.exists())
        self.assertIsNone(self.store.get("components.udf_devkit"))


if __name__ == "__main__":
    unittest.main()
