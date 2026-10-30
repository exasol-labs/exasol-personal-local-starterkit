"""Scheduler migration keeps verified assets and least privilege receipts."""

from __future__ import annotations

import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from addons import exasol_scheduler as scheduler  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402


class SchedulerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "kit"
        self.home.mkdir()
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text(json.dumps({"runtime": {"dsn": "127.0.0.1:8563"}}))
        self.ctx = KitContext(ROOT, self.home, Path(self.temp.name) / "bin", self.manifest, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_bootstrap_grants_only_when_schema_is_absent(self) -> None:
        queries = []

        def sql(_ctx, statement, *, secret=""):
            queries.append((statement, secret))
            if "EXAKIT_SCHED_USER_PRESENT" in statement:
                return "EXAKIT_SCHED_USER_MISSING"
            if "EXAKIT_SCHED_SCHEMA_PRESENT" in statement:
                return "EXAKIT_SCHED_SCHEMA_MISSING"
            return ""

        with patch.object(scheduler, "_sql", side_effect=sql):
            user, schema, granted = scheduler._user(self.ctx)
        self.assertEqual(("SCHEDULER_SVC", "SCHED", True), (user, schema, granted))
        commands = [item[0] for item in queries]
        self.assertIn("GRANT CREATE SESSION TO SCHEDULER_SVC", commands)
        self.assertIn("GRANT CREATE SCHEMA TO SCHEDULER_SVC", commands)
        self.assertIn("GRANT CREATE TABLE TO SCHEDULER_SVC", commands)
        password = scheduler.paths(self.ctx)[4].read_text().strip()
        self.assertNotIn(password, "\n".join(item[0] for item in queries if not item[0].startswith("CREATE USER")))
        self.assertEqual(password, next(secret for command, secret in queries if command.startswith("CREATE USER")))
        self.assertEqual(0o600, scheduler.paths(self.ctx)[4].stat().st_mode & 0o777)

    def test_existing_schema_does_not_regrant_bootstrap(self) -> None:
        queries = []

        def sql(_ctx, statement, *, secret=""):
            queries.append(statement)
            if "EXAKIT_SCHED_USER_PRESENT" in statement:
                return "EXAKIT_SCHED_USER_PRESENT"
            if "EXAKIT_SCHED_SCHEMA_PRESENT" in statement:
                return "EXAKIT_SCHED_SCHEMA_PRESENT"
            return ""

        with patch.object(scheduler, "_sql", side_effect=sql):
            self.assertFalse(scheduler._user(self.ctx)[2])
        self.assertFalse(any(item.startswith("GRANT CREATE SCHEMA") for item in queries))

    def test_checksum_mismatch_removes_partial_asset(self) -> None:
        archive = self.home / "archive.tar.gz"

        class Response(io.BytesIO):
            url = "https://github.com/release"

        with patch.object(scheduler, "_digest", return_value="0" * 64), \
             patch.object(scheduler, "_https", return_value=Response(b"wrong")):
            with self.assertRaisesRegex(AddonFailure, "Checksum mismatch"):
                scheduler._download(self.ctx, "0.3.1", archive)
        self.assertFalse(archive.exists())

    def test_release_asset_and_digest_follow_versions_document(self) -> None:
        with patch.object(scheduler.platform, "system", return_value="Darwin"), \
             patch.object(scheduler.platform, "machine", return_value="arm64"):
            repo, tag, name = scheduler._asset(self.ctx, "0.3.1")
        self.assertEqual(("exasol-labs/exasol-scheduler", "v0.3.1",
                          "exasol_scheduler-v0.3.1-macos-arm64.tar.gz"), (repo, tag, name))
        block = self.ctx.versions_document()["components"]["exasol-scheduler"]
        version = block["version"].removeprefix("v")
        with patch.object(scheduler, "_platform", return_value="macos-arm64"), \
             patch.object(scheduler, "_https") as fetch:
            self.assertEqual(block["sha256"]["macos-arm64"],
                             scheduler._digest(self.ctx, version, repo, tag, name))
            fetch.assert_not_called()

    def test_archive_requires_one_engine_binary(self) -> None:
        source = self.home / "engine"
        source.write_bytes(b"scheduler engine")
        archive = self.home / "scheduler.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            output.add(source, arcname="target/aarch64/release/exasol_scheduler")
        destination = self.home / "unpacked"
        scheduler._unpack(archive, destination)
        self.assertEqual(source.read_bytes(), destination.read_bytes())
        bad = self.home / "bad.tar.gz"
        with tarfile.open(bad, "w:gz") as output:
            output.add(source, arcname="README")
        with self.assertRaisesRegex(AddonFailure, "one engine binary"):
            scheduler._unpack(bad, self.home / "missing")

    def test_uninstall_requires_kit_ownership_and_preserves_schema(self) -> None:
        with self.assertRaisesRegex(AddonFailure, "not kit-owned"):
            scheduler.uninstall(self.ctx)
        home, launcher, engine, _, credential = scheduler.paths(self.ctx)
        engine.parent.mkdir(parents=True)
        engine.write_text("engine")
        launcher.parent.mkdir(parents=True)
        launcher.write_text("launcher")
        credential.parent.mkdir(parents=True)
        credential.write_text("secret")
        self.manifest.set_many({"components.exasol_scheduler.ownership": "kit",
                                "components.exasol_scheduler.db_user": "scheduler_svc"})
        with patch.object(scheduler, "stop"), patch.object(scheduler, "_sql") as sql:
            self.assertEqual(3, len(scheduler.uninstall(self.ctx, dry_run=True)))
            sql.assert_not_called()
            scheduler.uninstall(self.ctx)
        self.assertFalse(home.exists())
        self.assertFalse(launcher.exists())
        self.assertFalse(credential.exists())
        self.assertEqual("DROP USER SCHEDULER_SVC", sql.call_args.args[1])
        self.assertIsNone(self.manifest.get("components.exasol_scheduler"))

    def test_install_records_launcher_after_python_runtime_is_ready(self) -> None:
        def unpack(_archive: Path, destination: Path) -> None:
            destination.write_text("engine", encoding="utf-8")

        def write_launcher(ctx: KitContext) -> None:
            launcher = scheduler.paths(ctx)[1]
            launcher.parent.mkdir(parents=True, exist_ok=True)
            launcher.write_text("launcher", encoding="utf-8")

        with patch.object(KitContext, "require_uv"), \
             patch.object(scheduler, "_version", return_value="0.3.1"), \
             patch.object(scheduler, "_asset", return_value=("owner/repo", "v0.3.1", "engine.tar.gz")), \
             patch.object(scheduler, "_download"), \
             patch.object(scheduler, "_unpack", side_effect=unpack), \
             patch.object(scheduler, "_user", return_value=("SCHEDULER_SVC", "SCHED", True)), \
             patch.object(scheduler, "venv_python", return_value=Path(sys.executable)), \
             patch.object(scheduler, "_write_launcher", side_effect=write_launcher), \
             patch.object(KitContext, "run_logged"):
            scheduler.install(self.ctx)
        self.assertEqual("kit", self.manifest.get("components.exasol_scheduler.ownership"))
        self.assertEqual(str(scheduler.paths(self.ctx)[1]),
                         self.manifest.get("components.exasol_scheduler.command"))

    def test_failed_update_validation_does_not_record_desired_version(self) -> None:
        self.manifest.set_many({"components.exasol_scheduler.ownership": "kit"})
        with patch.object(scheduler, "_running", side_effect=(False, True)), \
             patch.object(scheduler, "installed_version", return_value="0.2.0"), \
             patch.object(scheduler, "_version", return_value="0.3.1"), \
             patch.object(scheduler, "install"), \
             patch.object(scheduler, "validate", return_value=False), \
             patch.object(scheduler, "stop") as stop:
            with self.assertRaisesRegex(AddonFailure, "did not validate"):
                scheduler.update(self.ctx)
        stop.assert_called_once_with(self.ctx)
        self.assertIsNone(self.manifest.get("desired.exasol_scheduler"))

    def test_restart_clears_prior_give_up_marker(self) -> None:
        home, launcher, engine, _, _ = scheduler.paths(self.ctx)
        engine.parent.mkdir(parents=True)
        engine.write_text("engine", encoding="utf-8")
        launcher.parent.mkdir(parents=True, exist_ok=True)
        launcher.write_text("launcher", encoding="utf-8")
        marker = home / "gave-up"
        marker.write_text("gave up after 5 rapid failures", encoding="utf-8")
        self.manifest.set_many({"components.exasol_scheduler.version": "0.3.1",
                                "components.exasol_scheduler.ownership": "kit"})
        with patch.object(scheduler, "_running", return_value=False):
            self.assertIn("gave up after 5 rapid failures", scheduler.status(self.ctx))
        process = Mock(pid=321)
        process.poll.return_value = None
        with patch.object(scheduler, "_running", return_value=False), \
             patch.object(scheduler, "_creation", return_value=123.0), \
             patch.object(scheduler.subprocess, "Popen", return_value=process), \
             patch.object(scheduler.time, "sleep"):
            scheduler.start(self.ctx)
        self.assertFalse(marker.exists())

    def test_failed_update_attempts_to_restore_running_scheduler(self) -> None:
        self.manifest.set_many({"components.exasol_scheduler.ownership": "kit"})
        with patch.object(scheduler, "_running", return_value=True), \
             patch.object(scheduler, "installed_version", return_value="0.2.0"), \
             patch.object(scheduler, "_version", return_value="0.3.1"), \
             patch.object(scheduler, "stop") as stop, \
             patch.object(scheduler, "install", side_effect=AddonFailure("package failed")), \
             patch.object(scheduler, "start") as start:
            with self.assertRaisesRegex(AddonFailure, "package failed"):
                scheduler.update(self.ctx)
        stop.assert_called_once_with(self.ctx)
        start.assert_called_once_with(self.ctx)
        self.assertIsNone(self.manifest.get("desired.exasol_scheduler"))

    def test_python_runtime_failure_keeps_previous_engine_and_receipt(self) -> None:
        engine = scheduler.paths(self.ctx)[2]
        engine.parent.mkdir(parents=True)
        engine.write_text("old engine", encoding="utf-8")
        self.manifest.set_many({"components.exasol_scheduler.version": "0.2.0",
                                "components.exasol_scheduler.ownership": "kit",
                                "components.exasol_scheduler.engine": str(engine)})

        def unpack(_archive: Path, staged: Path) -> None:
            staged.write_text("new engine", encoding="utf-8")

        def run_logged(label: str, *_args, **_kwargs) -> None:
            if label.startswith("Creating Scheduler Python"):
                raise AddonFailure("Python runtime failed")

        with patch.object(KitContext, "require_uv"), \
             patch.object(scheduler, "_version", return_value="0.3.1"), \
             patch.object(scheduler, "_asset", return_value=("owner/repo", "v0.3.1", "engine.tar.gz")), \
             patch.object(scheduler, "_download"), \
             patch.object(scheduler, "_unpack", side_effect=unpack), \
             patch.object(scheduler, "installed_version", return_value="0.2.0"), \
             patch.object(KitContext, "run_logged", side_effect=run_logged):
            with self.assertRaisesRegex(AddonFailure, "Python runtime failed"):
                scheduler.install(self.ctx)
        self.assertEqual("old engine", engine.read_text(encoding="utf-8"))
        self.assertEqual("0.2.0", self.manifest.get("components.exasol_scheduler.version"))

    def test_update_restores_stopped_state_after_validation(self) -> None:
        self.manifest.set_many({"components.exasol_scheduler.ownership": "kit"})
        with patch.object(scheduler, "_running", side_effect=(False, True)), \
             patch.object(scheduler, "installed_version", return_value="0.3.1"), \
             patch.object(scheduler, "_version", return_value="0.3.1"), \
             patch.object(scheduler, "install") as install, \
             patch.object(scheduler, "validate", return_value=True) as validate, \
             patch.object(scheduler, "stop") as stop:
            scheduler.update(self.ctx)
        install.assert_called_once_with(self.ctx)
        validate.assert_called_once_with(self.ctx)
        stop.assert_called_once_with(self.ctx)
        self.assertEqual("0.3.1", self.manifest.get("desired.exasol_scheduler"))


if __name__ == "__main__":
    unittest.main()
