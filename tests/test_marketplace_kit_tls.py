"""The add-ons that open their own connections take the database's TLS pin (audit SEC-14): dbt-exasol through the
DSN its launcher hands over, dash-server through its profile, exasol-scheduler through EXA_DSN. Without a recorded
pin each behaves exactly as before."""

from __future__ import annotations

import json
import sys
import tempfile
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))

import dash_launcher  # noqa: E402
import kit_tls  # noqa: E402
import scheduler_launcher  # noqa: E402
from addons import dbt_exasol  # noqa: E402

PIN = "9b82cc4885a52d4372333b60ce0b0e88bce82e03809c6dd08c4d737af9d398ae"
PINNED = {"runtime": {"dsn": "127.0.0.1:8563", "user": "sys", "tls_fingerprint": PIN.upper()}}
PLAIN = {"runtime": {"dsn": "127.0.0.1:8563", "user": "sys"}}


class KitTlsTest(unittest.TestCase):
    def test_the_pin_is_lowercase_and_only_a_real_one(self):
        self.assertEqual(PIN, kit_tls.fingerprint(PINNED))       # exapump and the engine match lowercase only
        self.assertIsNone(kit_tls.fingerprint(PLAIN))
        self.assertIsNone(kit_tls.fingerprint({"runtime": {"tls_fingerprint": "not-hex"}}))

    def test_the_client_dsn_is_pinned_once_recorded(self):
        self.assertEqual(f"127.0.0.1/{PIN}:8563", kit_tls.client_dsn(PINNED))
        self.assertEqual("127.0.0.1:8563", kit_tls.client_dsn(PLAIN))
        self.assertEqual(f"h/{PIN}:1", kit_tls.pinned_dsn(f"h/{PIN}:1", "f" * 64), "an already pinned DSN is kept")
        self.assertEqual(("127.0.0.1", 8563), kit_tls.host_port(kit_tls.client_dsn(PINNED)))


class DbtTest(unittest.TestCase):
    def test_the_profile_reads_the_dsn_the_launcher_hands_over(self):
        manifest = types.SimpleNamespace(get=lambda key, default=None: {"runtime.dsn": "127.0.0.1:8563",
                                                                          "runtime.user": "sys"}.get(key, default))
        text = dbt_exasol._profile_text(types.SimpleNamespace(manifest=manifest))
        self.assertIn('dsn: "{{ env_var(\'EXAKIT_DBT_DSN\', \'127.0.0.1:8563\') }}"', text)
        launcher = (ROOT / "marketplace" / "dbt_launcher.py").read_text(encoding="utf-8")
        self.assertIn('env.setdefault("EXAKIT_DBT_DSN", kit_tls.client_dsn(doc))', launcher)


class DashTest(unittest.TestCase):
    def stored(self, dsn: str) -> Path:
        folder = Path(self.enterContext(tempfile.TemporaryDirectory()))
        profile = folder / "gitops-repo" / "profiles" / "exasol" / "starter-kit.json"
        profile.parent.mkdir(parents=True)
        profile.write_text(json.dumps({"dsn": dsn, "user": "MCP_READONLY"}))
        return folder

    def test_the_kit_seeded_profile_is_repinned_and_no_other(self):
        desired = kit_tls.client_dsn(PINNED)
        runtime = PINNED["runtime"]
        self.assertTrue(dash_launcher.pin_to_repair(self.stored("127.0.0.1:8563"), "starter-kit", runtime, desired))
        self.assertTrue(dash_launcher.pin_to_repair(self.stored(f"127.0.0.1/{'0' * 64}:8563"), "starter-kit", runtime,
                                                    desired), "pinned to an older certificate")
        self.assertFalse(dash_launcher.pin_to_repair(self.stored(desired), "starter-kit", runtime, desired))
        self.assertFalse(dash_launcher.pin_to_repair(self.stored("db.example:8563"), "starter-kit", runtime, desired),
                         "a profile someone pointed elsewhere is left alone")
        self.assertFalse(dash_launcher.pin_to_repair(self.stored("127.0.0.1:8563"), "starter-kit", runtime,
                                                     "127.0.0.1:8563"), "nothing to repin without a pin")


class SchedulerTest(unittest.TestCase):
    DOC = {"components": {"exasol_scheduler": {"db_user": "scheduler_svc", "schema": "SCHED"}}}

    def test_pinned_the_connection_is_exa_dsn_without_the_password(self):
        env = {"EXA_PASSWORD": "secret"}
        scheduler_launcher.connection_env({**self.DOC, **PINNED}, env, "127.0.0.1", 8563)
        self.assertEqual(f"exasol://scheduler_svc@127.0.0.1:8563?tls=1&validateservercertificate=0&certificate_fingerprint={PIN}",
                         env["EXA_DSN"])
        self.assertNotIn("secret", env["EXA_DSN"])
        self.assertNotIn("EXA_HOST", env)
        self.assertEqual("SCHED", env["EXA_SCHEMA"])

    def test_unpinned_the_parts_are_as_before(self):
        env: dict = {}
        scheduler_launcher.connection_env({**self.DOC, **PLAIN}, env, "127.0.0.1", 8563)
        self.assertNotIn("EXA_DSN", env)
        self.assertEqual(("127.0.0.1", "8563", "false"), (env["EXA_HOST"], env["EXA_PORT"], env["EXA_VALIDATE_SERVER_CERT"]))

    def test_a_connection_the_caller_set_is_kept(self):
        env = {"EXA_HOST": "db.example"}
        scheduler_launcher.connection_env({**self.DOC, **PINNED}, env, "127.0.0.1", 8563)
        self.assertNotIn("EXA_DSN", env)
        self.assertEqual("db.example", env["EXA_HOST"])

    def test_pinned_the_launcher_waits_for_the_database_and_starts_the_engine(self):
        """Pinned there is no EXA_HOST: the wait for the database used it and the launcher died with KeyError before
        the engine ever started ("Scheduler stopped during startup")."""
        from unittest import mock

        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            manifest = home / "manifest.json"
            manifest.write_text(json.dumps({**self.DOC, **PINNED}), encoding="utf-8")
            credential = home / "pw"
            credential.write_text("Pw0rdFromTheFile", encoding="utf-8")
            engine = mock.Mock()
            engine.wait.return_value = 0
            argv = ["scheduler_launcher.py", str(home / "run"), str(home / "engine"), str(manifest), str(credential)]
            with mock.patch.object(sys, "argv", argv), \
                 mock.patch.dict(scheduler_launcher.os.environ, {}, clear=True), \
                 mock.patch.object(scheduler_launcher.socket, "create_connection") as connect, \
                 mock.patch.object(scheduler_launcher.subprocess, "Popen", return_value=engine) as popen, \
                 mock.patch.object(scheduler_launcher.signal, "signal"):
                self.assertEqual(0, scheduler_launcher.main())
        self.assertEqual(("127.0.0.1", 8563), connect.call_args.args[0])
        # The engine ignores EXA_PASSWORD once EXA_DSN is set ("User password can not be empty"): it is in the DSN.
        self.assertEqual(f"exasol://scheduler_svc:Pw0rdFromTheFile@127.0.0.1:8563?tls=1&validateservercertificate=0"
                         f"&certificate_fingerprint={PIN}", popen.call_args.kwargs["env"]["EXA_DSN"])

    def test_a_dsn_that_names_a_password_is_kept(self):
        dsn = "exasol://u:own@db:8563?tls=1"
        self.assertEqual(dsn, scheduler_launcher.dsn_with_password(dsn, "other"))
        self.assertEqual("exasol://u:a%2Fb@db:8563", scheduler_launcher.dsn_with_password("exasol://u@db:8563", "a/b"))


if __name__ == "__main__":
    unittest.main()
