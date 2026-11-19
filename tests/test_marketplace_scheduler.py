"""Scheduler migration keeps verified assets and least privilege receipts."""

from __future__ import annotations

import contextlib
import io
import hashlib
import json
import os
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from addons import exasol_scheduler as scheduler  # noqa: E402
import scheduler_launcher  # noqa: E402
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
        if os.name != "nt":
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
        self.assertIn("GRANT USAGE ON SCHEMA SCHED TO SCHEDULER_SVC", queries)
        self.assertIn("GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA SCHED TO SCHEDULER_SVC", queries)

    def test_bootstrap_quotes_digit_leading_and_mixed_case_passwords(self) -> None:
        credential = scheduler.paths(self.ctx)[4]
        credential.parent.mkdir(parents=True)
        for present, password in ((False, "7aB" * 10), (True, "aB7" * 10)):
            credential.write_text(password + "\n")
            queries = []

            def sql(_ctx, statement, *, secret=""):
                queries.append((statement, secret))
                if "EXAKIT_SCHED_USER_PRESENT" in statement:
                    return "EXAKIT_SCHED_USER_PRESENT" if present else "EXAKIT_SCHED_USER_MISSING"
                return "EXAKIT_SCHED_SCHEMA_PRESENT"

            with patch.object(scheduler, "_sql", side_effect=sql):
                scheduler._user(self.ctx)
            verb = "ALTER" if present else "CREATE"
            self.assertIn((f'{verb} USER SCHEDULER_SVC IDENTIFIED BY "{password}"', password), queries)

    def test_administrator_cannot_be_used_or_removed_as_the_scheduler_user(self) -> None:
        with patch.dict("os.environ", {"EXAKIT_EXASOL_SCHEDULER_USER": "sys"}), \
             patch.object(scheduler, "_sql") as sql:
            with self.assertRaisesRegex(AddonFailure, "dedicated database user"):
                scheduler._user(self.ctx)
            sql.assert_not_called()
        self.assertFalse(scheduler.paths(self.ctx)[4].exists())
        self.manifest.set_many({"components.exasol_scheduler.ownership": "kit",
                                "components.exasol_scheduler.db_user": "SYS"})
        with patch.object(scheduler, "stop") as stop, patch.object(scheduler, "_sql") as sql:
            with self.assertRaisesRegex(AddonFailure, "administrator"):
                scheduler.uninstall(self.ctx)
            stop.assert_not_called()
            sql.assert_not_called()

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

    def on(self, system: str, machine: str, glibc: str | None) -> contextlib.ExitStack:
        """This machine as `system`/`machine` with glibc `glibc` (None: musl, the name is unknown to confstr)."""
        def confstr(name: str) -> str:
            if name != "CS_GNU_LIBC_VERSION" or glibc is None:
                raise ValueError("unrecognized configuration name")
            return f"glibc {glibc}"
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(scheduler.platform, "system", return_value=system))
        stack.enter_context(patch.object(scheduler, "host_machine", return_value=machine))
        stack.enter_context(patch.object(os, "confstr", confstr, create=True))
        return stack

    def test_linux_below_the_binarys_glibc_is_not_on_offer_and_says_why(self) -> None:
        # LNX-07: both Linux binaries need GLIBC_2.38; Ubuntu 22.04, Debian 12 and RHEL 9 have less.
        for machine, have in (("x86_64", "2.35"), ("x86_64", "2.36"), ("aarch64", "2.34")):
            with self.subTest(machine=machine, have=have), self.on("Linux", machine, have):
                self.assertFalse(scheduler.applicable(self.ctx))
                self.assertEqual(f"the prebuilt scheduler binary needs glibc 2.38 or newer (this system has {have})",
                                 scheduler.applicable_reason(self.ctx))
        with self.on("Linux", "x86_64", None):
            self.assertFalse(scheduler.applicable(self.ctx))
            self.assertIn("not glibc", scheduler.applicable_reason(self.ctx))

    def test_linux_at_or_above_the_binarys_glibc_is_on_offer(self) -> None:
        for machine, have in (("x86_64", "2.38"), ("aarch64", "2.39")):
            with self.subTest(machine=machine, have=have), self.on("Linux", machine, have):
                self.assertTrue(scheduler.applicable(self.ctx))
                self.assertEqual("", scheduler.applicable_reason(self.ctx))
        with self.on("Darwin", "arm64", None):
            self.assertTrue(scheduler.applicable(self.ctx))
        with self.on("Linux", "riscv64", "2.40"):
            self.assertEqual("no prebuilt scheduler binary is published for Linux/riscv64",
                             scheduler.applicable_reason(self.ctx))

    def test_the_sidecar_backend_does_not_need_the_hosts_glibc(self) -> None:
        self.manifest.set_many({"components.exasol_scheduler.backend": "sidecar"})
        with self.on("Linux", "x86_64", "2.35"):
            self.assertTrue(scheduler.applicable(self.ctx))

    def test_install_below_the_floor_refuses_before_any_download(self) -> None:
        with self.on("Linux", "x86_64", "2.35"), \
             patch.object(scheduler, "_https", side_effect=AssertionError("downloaded")), \
             patch.object(scheduler, "_user", side_effect=AssertionError("database touched")):
            with self.assertRaisesRegex(AddonFailure, r"needs glibc 2\.38 or newer \(this system has 2\.35\)"):
                scheduler.install(self.ctx)
        self.assertIsNone(self.manifest.get("components.exasol_scheduler.ownership"))

    def test_partial_download_is_removed_and_retry_preserves_other_receipts(self) -> None:
        payload = b"verified scheduler archive"
        archive = self.home / "scheduler.tar.gz"
        self.manifest.set_many({"components.dbt_exasol.version": "1.12.3"})
        before = self.manifest.path.read_bytes()
        class Interrupted(io.BytesIO):
            def read(self, size=-1):
                if self.tell():
                    raise OSError("transfer interrupted")
                return super().read(5)
        with patch.object(scheduler, "_digest", return_value=hashlib.sha256(payload).hexdigest()), \
             patch.object(scheduler, "_https", return_value=Interrupted(payload)):
            with self.assertRaisesRegex(OSError, "transfer interrupted"):
                scheduler._download(self.ctx, "0.4.0", archive)
        self.assertFalse(archive.exists())
        with patch.object(scheduler, "_digest", return_value=hashlib.sha256(payload).hexdigest()), \
             patch.object(scheduler, "_https", return_value=io.BytesIO(payload)):
            scheduler._download(self.ctx, "0.4.0", archive)
        self.assertEqual(payload, archive.read_bytes())
        self.assertEqual(before, self.manifest.path.read_bytes())

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
        with patch.object(scheduler, "stop") as stop, patch.object(scheduler, "_sql") as sql:
            plan = [str(item) for item in scheduler.uninstall(self.ctx, dry_run=True)]
            sql.assert_not_called()
            stop.assert_not_called()
            # The preview names every action the removal performs, not only its three paths: the service is
            # stopped, the database user dropped, the task schema handed to the administrator.
            self.assertEqual(["the running scheduler service (it is stopped first)",
                              "the database user SCHEDULER_SVC (DROP USER); schema SCHED and its tasks stay, "
                              "handed to sys", str(home), str(launcher), str(credential)], plan)
            scheduler.uninstall(self.ctx)
        self.assertFalse(home.exists())
        self.assertFalse(launcher.exists())
        self.assertFalse(credential.exists())
        self.assertEqual("DROP USER IF EXISTS SCHEDULER_SVC", sql.call_args.args[1])
        self.assertIsNone(self.manifest.get("components.exasol_scheduler"))

    def test_a_0_2_5_windows_install_is_installed_needs_an_update_and_its_old_launcher_goes(self) -> None:
        """The 0.2.5 -> 0.3.0 upgrade on Windows: kit 0.2.5 wrote the launcher as <bin>/exasol-scheduler.ps1 and a
        receipt with no ownership and no command (setup/lib/exasol-scheduler.ps1 at 14df2ecb). This kit's launcher is
        <bin>/exasol-scheduler.cmd, so status said "not installed" over a running engine. It is installed and needs
        an update; the update writes the .cmd, removes the .ps1 and rewrites the boot entry; the removal previews and
        removes the .ps1 too."""
        fake_os = type("FakeOs", (), {"name": "nt", "environ": os.environ, "replace": staticmethod(os.replace)})()
        engine = self.home / "exasol-scheduler" / "libexec" / "exasol_scheduler.exe"
        engine.parent.mkdir(parents=True)
        engine.write_bytes(b"engine")
        self.manifest.path.write_text(json.dumps({"runtime": {"dsn": "127.0.0.1:8563"}, "components": {
            "exasol_scheduler": {"version": "0.4.1", "engine": str(engine), "db_user": "scheduler_svc",
                                 "schema": "SCHED", "bootstrap_revoked": "true", "validated": "true"}}}))
        old = self.ctx.bin_dir / "exasol-scheduler.ps1"
        old.parent.mkdir(parents=True)
        old.write_text("# exasol-scheduler launcher - generated by the Exasol Personal Local Starter Kit.\r\n"
                       "# Supervises the scheduler engine: waits for the database, restarts on failure,\r\n"
                       "# refuses a second copy, stops on a crash loop. Regenerated by exakit update.\r\n",
                       encoding="ascii")
        with patch.object(scheduler, "os", fake_os), patch.object(scheduler, "_running", return_value=True):
            self.assertEqual("0.4.1", scheduler.installed_version(self.ctx))
            self.assertEqual("running", scheduler.status(self.ctx))
            self.assertTrue(scheduler.needs_update(self.ctx))
            self.assertIn(str(old), [str(item) for item in scheduler.uninstall(self.ctx, dry_run=True)])
            with patch.object(scheduler, "applicable", return_value=True), \
                 patch.object(scheduler, "_sidecar_mode", return_value=False), \
                 patch.object(KitContext, "require_uv", return_value=Path("uv")), \
                 patch.object(scheduler, "_version", return_value="0.4.1"), \
                 patch.object(scheduler, "_ensure_python", return_value=Path("python")), \
                 patch.object(scheduler, "_download", side_effect=AssertionError("downloaded")), \
                 patch.object(scheduler, "cmd_file_bytes", side_effect=lambda text: text.encode("utf-8")), \
                 patch.object(scheduler, "_refresh_boot_entry") as boot:
                scheduler.install(self.ctx)
            boot.assert_called_once_with(self.ctx)
            self.assertFalse(old.exists())
            self.assertTrue((self.ctx.bin_dir / "exasol-scheduler.cmd").is_file())
            self.assertFalse(scheduler.needs_update(self.ctx))
            self.assertEqual("running", scheduler.status(self.ctx))
        # Real removal with the old launcher back (an update that never ran): it goes with the rest.
        old.write_text("launcher", encoding="ascii")
        with patch.object(scheduler, "os", fake_os), patch.object(scheduler, "stop"), \
             patch.object(scheduler, "_sql", return_value=""):
            scheduler.uninstall(self.ctx)
        self.assertFalse(old.exists())

    def test_a_posix_launcher_in_place_needs_no_update(self) -> None:
        home, launcher, engine, _, _ = scheduler.paths(self.ctx)
        engine.parent.mkdir(parents=True)
        engine.write_bytes(b"engine")
        self.manifest.set_many({"components.exasol_scheduler.ownership": "kit",
                                "components.exasol_scheduler.version": "0.4.1"})
        self.assertTrue(scheduler.needs_update(self.ctx))             # no launcher at all: the update writes one
        launcher.parent.mkdir(parents=True)
        launcher.write_text("launcher")
        self.assertFalse(scheduler.needs_update(self.ctx))

    def test_the_preview_of_a_sidecar_scheduler_names_the_sidecar_and_runs_nothing(self) -> None:
        deployment = self.home / "deployment"
        deployment.mkdir()
        self.manifest.set_many({"components.exasol_scheduler.ownership": "kit",
                                "components.exasol_scheduler.backend": "sidecar",
                                "components.exasol_scheduler.db_user": "scheduler_svc",
                                "runtime.user": "sys"})
        with patch.dict(os.environ, {"EXAKIT_PERSONAL_DEPLOY_DIR": str(deployment)}), \
             patch.object(scheduler, "_launch") as launch, patch.object(scheduler, "_sql") as sql:
            plan = [str(item) for item in scheduler.uninstall(self.ctx, dry_run=True)]
        launch.assert_not_called()
        sql.assert_not_called()
        self.assertEqual(["the scheduler sidecar 'exasol-scheduler' beside the database",
                          "the database user SCHEDULER_SVC (DROP USER); schema SCHED and its tasks stay, handed to sys"],
                         plan)

    def test_uninstall_transfers_only_the_scheduler_schema_before_dropping_its_user(self) -> None:
        self.manifest.set_many({"components.exasol_scheduler.ownership": "kit",
                                "components.exasol_scheduler.db_user": "scheduler_svc",
                                "components.exasol_scheduler.schema": "SCHED"})
        queries = []

        def sql(_ctx, statement, **_kwargs):
            queries.append(statement)
            return "EXAKIT_SCHED_OWNS_SCHEMA" if "SCHEMA_NAME = 'SCHED'" in statement else ""

        with patch.object(scheduler, "stop"), patch.object(scheduler, "_sql", side_effect=sql):
            scheduler.uninstall(self.ctx)
        self.assertIn('ALTER SCHEMA SCHED CHANGE OWNER "sys"', queries)
        self.assertLess(queries.index('ALTER SCHEMA SCHED CHANGE OWNER "sys"'),
                        queries.index("DROP USER IF EXISTS SCHEDULER_SVC"))
        self.assertFalse(any("CASCADE" in query or query.startswith("DROP SCHEMA") for query in queries))
        self.manifest.set_many({"components.exasol_scheduler.ownership": "kit",
                                "runtime.user": 'team-"admin'})
        with patch.object(scheduler, "stop"), patch.object(scheduler, "_sql", side_effect=sql):
            scheduler.uninstall(self.ctx)
        self.assertIn('ALTER SCHEMA SCHED CHANGE OWNER "team-""admin"', queries)

    def test_failed_database_cleanup_keeps_files_credentials_and_receipt_for_retry(self) -> None:
        self.manifest.set_many({"components.exasol_scheduler.ownership": "kit"})
        home, launcher, engine, _, credential = scheduler.paths(self.ctx)
        engine.parent.mkdir(parents=True)
        engine.write_text("engine")
        credential.parent.mkdir(parents=True)
        credential.write_text("private credential")
        before = self.manifest.path.read_bytes()
        with patch.object(scheduler, "stop"), \
             patch.object(scheduler, "_sql", side_effect=AddonFailure("database unavailable")):
            with self.assertRaises(AddonFailure):
                scheduler.uninstall(self.ctx)
        self.assertEqual(before, self.manifest.path.read_bytes())
        self.assertTrue(engine.exists())
        self.assertTrue(credential.exists())

    def test_uninstall_refuses_to_change_unrelated_schema_owners(self) -> None:
        self.manifest.set_many({"components.exasol_scheduler.ownership": "kit"})
        before = self.manifest.path.read_bytes()
        with patch.object(scheduler, "stop"), \
             patch.object(scheduler, "_sql", return_value="EXAKIT_SCHED_OTHER_SCHEMAS") as sql:
            with self.assertRaisesRegex(AddonFailure, "other schemas"):
                scheduler.uninstall(self.ctx)
        self.assertEqual(1, sql.call_count)
        self.assertEqual(before, self.manifest.path.read_bytes())

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
        python = scheduler.venv_python(home / "python")
        python.parent.mkdir(parents=True)
        python.touch()
        process = Mock(pid=321)
        process.poll.return_value = None
        with patch.object(scheduler, "_running", return_value=False), \
             patch.object(scheduler, "_creation", return_value=123.0), \
             patch.object(scheduler.subprocess, "Popen", return_value=process), \
             patch.object(scheduler.time, "sleep"):
            scheduler.start(self.ctx)
        self.assertFalse(marker.exists())

    def test_start_migrates_legacy_runtime_without_replacing_engine_or_credentials(self) -> None:
        home, launcher, engine, _, credential = scheduler.paths(self.ctx)
        engine.parent.mkdir(parents=True)
        engine.write_bytes(b"existing engine")
        credential.parent.mkdir(parents=True)
        credential.write_text("existing credential")
        self.manifest.set_many({"components.exasol_scheduler.version": "0.3.1",
                                "components.exasol_scheduler.ownership": "kit"})
        python = scheduler.venv_python(home / "python")
        def create(_label, *args):
            python.parent.mkdir(parents=True)
            python.touch()
        process = Mock(pid=321)
        process.poll.return_value = None
        with patch.object(scheduler, "_running", return_value=False), \
             patch.object(KitContext, "require_uv", return_value=Path("uv")), \
             patch.object(KitContext, "run_logged", side_effect=create) as run, \
             patch.object(scheduler, "_user") as user, patch.object(scheduler, "_download") as download, \
             patch.object(scheduler, "_creation", return_value="created"), \
             patch.object(scheduler.subprocess, "Popen", return_value=process), \
             patch.object(scheduler.time, "sleep"):
            scheduler.start(self.ctx)
        run.assert_called_once()
        self.assertTrue(python.is_file())
        self.assertTrue(launcher.is_file())
        self.assertEqual(b"existing engine", engine.read_bytes())
        self.assertEqual("existing credential", credential.read_text())
        user.assert_not_called()
        download.assert_not_called()

    def test_service_identity_survives_checkout_to_installed_source_switch(self) -> None:
        home = scheduler.paths(self.ctx)[0]
        home.mkdir()
        (home / "exasol-scheduler.pid").write_text(json.dumps({"pid": 321, "created": "created"}))
        command = f"python /another/source/marketplace/scheduler_launcher.py {home} engine manifest credential"
        with patch("process._creation", return_value="created"), \
             patch("process._command", return_value=command):
            self.assertEqual(321, scheduler._service(self.ctx).recorded_pid())

    def test_start_does_not_create_runtime_for_external_receipts(self) -> None:
        engine = scheduler.paths(self.ctx)[2]
        engine.parent.mkdir(parents=True)
        engine.write_bytes(b"external engine")
        for owner in ("user", "unknown"):
            with self.subTest(owner=owner):
                self.manifest.set_many({"components.exasol_scheduler.version": "0.3.1",
                                        "components.exasol_scheduler.ownership": owner})
                with patch.object(scheduler, "_running", return_value=False), \
                     patch.object(KitContext, "run_logged") as run:
                    with self.assertRaisesRegex(AddonFailure, "owner must repair"):
                        scheduler.start(self.ctx)
                run.assert_not_called()

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


class SupervisorRecoveryTest(unittest.TestCase):
    """The supervisor never gives up (scheduler_launcher.py, THE SUPERVISOR NEVER GIVES UP). Live on Windows 11 a
    30-second Docker Desktop restart made the engine fail five times in a row ("No connection could be made because
    the target machine actively refused it"), the supervisor wrote "gave up after 5 rapid failures" and exited, and
    the scheduler stayed down after the database was back until someone ran exakit start."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.home = root / "sched"
        self.manifest = root / "manifest.json"
        self.manifest.write_text(json.dumps({"runtime": {"dsn": "127.0.0.1:8563"}}), encoding="utf-8")
        self.credential = root / "pw"
        self.credential.write_text("secret", encoding="utf-8")
        self.argv = ["scheduler_launcher.py", str(self.home), str(root / "engine"), str(self.manifest),
                     str(self.credential)]
        self.database_up = True
        self.markers: list[str] = []     # what exakit status would have read at each pause
        self.engine_runs = 0

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _connect(self, *_args, **_kwargs):
        if not self.database_up:
            raise ConnectionRefusedError("actively refused")
        return contextlib.nullcontext()

    def _sleep(self, _seconds) -> None:
        marker = self.home / "restarting"
        self.markers.append(marker.read_text(encoding="utf-8").strip() if marker.is_file() else "")

    def _supervise(self, engine_codes: list[int], on_failure=None) -> int:
        codes = iter(engine_codes)

        def popen(*_args, **_kwargs):
            self.engine_runs += 1
            code = next(codes)
            child = Mock()
            child.poll.return_value = code
            child.wait.return_value = code
            if code and on_failure:
                on_failure(self.engine_runs)
            return child

        with patch.object(sys, "argv", self.argv), patch.dict(os.environ, {}, clear=True), \
                patch.object(scheduler_launcher.signal, "signal"), \
                patch.object(scheduler_launcher.socket, "create_connection", side_effect=self._connect), \
                patch.object(scheduler_launcher.subprocess, "Popen", side_effect=popen), \
                patch.object(scheduler_launcher.time, "sleep", side_effect=self._sleep), \
                contextlib.redirect_stderr(io.StringIO()) as self.stderr:
            return scheduler_launcher.main()

    def test_more_rapid_failures_than_the_old_limit_still_end_with_the_engine_running(self) -> None:
        # Nine rapid failures, then an engine that runs (and here ends cleanly, so the supervisor returns).
        self.assertEqual(0, self._supervise([1] * 9 + [0]))
        self.assertEqual(10, self.engine_runs, "the engine was started again after the fifth failure")
        self.assertFalse((self.home / "gave-up").exists())
        self.assertNotIn("gave up", self.stderr.getvalue())
        self.assertFalse((self.home / "restarting").exists(), "the marker is gone once the engine runs")
        # Truthful while it waited: the status marker named the failures.
        self.assertIn("9 rapid failures, last exit 1", self.markers)

    def test_a_crash_loop_backs_off_to_a_minute(self) -> None:
        self.assertEqual([5, 5, 5, 5, 10, 20, 40, 60, 60, 60],
                         [scheduler_launcher.retry_wait(n) for n in range(1, 11)])
        self._supervise([1] * 8 + [0])
        # One sleep(1) per second waited: 4 x 5s, then 10 + 20 + 40 + 60 before the ninth start.
        self.assertEqual(4 * 5 + 10 + 20 + 40 + 60, len(self.markers))

    def test_a_database_outage_waits_for_the_database_then_starts_the_engine(self) -> None:
        # The database goes away under a running engine (Docker Desktop restarting): the engine fails, the
        # database does not answer for a while, and no engine is started until it does.
        down_probes = []

        def database_goes_away(run: int) -> None:
            if run == 1:
                self.database_up = False

        original = self._sleep

        def sleep(seconds) -> None:
            original(seconds)
            if not self.database_up:
                down_probes.append(self.engine_runs)
                if len(down_probes) >= 30:      # about 30 seconds of outage
                    self.database_up = True
        self._sleep = sleep
        self.assertEqual(0, self._supervise([1, 0], on_failure=database_goes_away))
        self.assertEqual(2, self.engine_runs, "the engine came back by itself, with no exakit start")
        self.assertEqual({1}, set(down_probes), "no engine was started while the database was down")
        self.assertIn("waiting for the database", self.markers)
        self.assertIn("the database does not answer", self.stderr.getvalue())

    def test_status_says_restarting_while_the_supervisor_waits(self) -> None:
        kit = Path(self.temp.name) / "kit"
        kit.mkdir()
        store = Manifest(kit / "manifest.json")
        store.path.write_text(json.dumps({"runtime": {"dsn": "127.0.0.1:8563"}}))
        ctx = KitContext(ROOT, kit, Path(self.temp.name) / "bin", store, Path("uv"))
        home, launcher, engine, _, _ = scheduler.paths(ctx)
        engine.parent.mkdir(parents=True)
        engine.write_text("engine", encoding="utf-8")
        launcher.parent.mkdir(parents=True, exist_ok=True)
        launcher.write_text("launcher", encoding="utf-8")
        store.set_many({"components.exasol_scheduler.version": "0.3.1",
                        "components.exasol_scheduler.ownership": "kit"})
        (home / "restarting").write_text("waiting for the database\n", encoding="utf-8")
        with patch.object(scheduler, "_running", return_value=True):
            self.assertEqual("restarting (waiting for the database. Diagnose: exakit logs exasol-scheduler)",
                             scheduler.status(ctx))
        # exakit start on a supervisor waiting out its backoff starts it over, so the engine is tried now.
        with patch.object(scheduler, "_running", side_effect=[True, False]), \
                patch.object(scheduler, "stop") as stop, \
                patch.object(scheduler, "_write_launcher"), patch.object(scheduler, "_creation", return_value="t"), \
                patch.object(scheduler.subprocess, "Popen", return_value=Mock(pid=321, **{"poll.return_value": None})), \
                patch.object(scheduler.time, "sleep"):
            python = scheduler.venv_python(home / "python")
            python.parent.mkdir(parents=True)
            python.touch()
            scheduler.start(ctx)
        stop.assert_called_once()
        (home / "restarting").unlink()
        with patch.object(scheduler, "_running", return_value=True):
            self.assertEqual("running", scheduler.status(ctx))


if __name__ == "__main__":
    unittest.main()
