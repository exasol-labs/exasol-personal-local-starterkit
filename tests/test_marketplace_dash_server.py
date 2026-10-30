"""Dash Server port, launcher and service recovery contracts."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
import dash_launcher  # noqa: E402
from addons import dash_server  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402


class DashServerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "kit home"
        self.home.mkdir()
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text("{}", encoding="utf-8")
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.manifest, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_busy_default_port_moves_but_explicit_port_refuses(self) -> None:
        service = Mock()
        service.status.side_effect = lambda port: "foreign" if port == 5100 else "stopped"
        with patch.object(dash_server, "_service", return_value=service), \
             patch.dict(os.environ, {"EXAKIT_DASH_SERVER_PORT": ""}):
            self.assertEqual(5101, dash_server._settle_port(self.ctx))
        with patch.object(dash_server, "_service", return_value=service), \
             patch.dict(os.environ, {"EXAKIT_DASH_SERVER_PORT": "5100"}):
            with self.assertRaisesRegex(AddonFailure, "Port 5100 is in use"):
                dash_server._settle_port(self.ctx)

    def test_same_version_install_restores_missing_launcher(self) -> None:
        self.manifest.set_many({"components.dash_server.ownership": "kit",
                                "components.dash_server.version": "0.1.1"})
        launcher = dash_server.paths(self.ctx)[2]
        with patch.object(KitContext, "require_uv"), \
             patch.object(KitContext, "target_version", return_value="0.1.1"), \
             patch.object(dash_server, "package_version", return_value="0.1.1"), \
             patch.object(dash_server, "_settle_port", return_value=5100), \
             patch.object(KitContext, "run_logged") as install_package:
            dash_server.install(self.ctx)
        install_package.assert_not_called()
        self.assertTrue(launcher.is_file())
        self.assertEqual(str(launcher), self.manifest.get("components.dash_server.command"))

    @unittest.skipIf(os.name == "nt", "Unix execve contract")
    def test_launcher_uses_recorded_port_and_keeps_secret_out_of_arguments(self) -> None:
        credential = self.home / "credentials" / "db-password"
        credential.parent.mkdir(parents=True)
        credential.write_text("private-test-password\n", encoding="utf-8")
        venv = self.home / "dash-server-venv"
        instance = self.home / "dash-server" / "instance"
        doc = {"components": {"dash_server": {"version": "0.1.1", "port": 5102,
                                             "venv": str(venv), "instance": str(instance)}},
               "runtime": {"dsn": "127.0.0.1:8563", "user": "SYS", "password_file": str(credential)}}
        self.manifest.path.write_text(json.dumps(doc), encoding="utf-8")
        launcher = dash_server._write_launcher(self.ctx)
        self.assertNotIn("private-test-password", launcher.read_text(encoding="utf-8"))
        with patch.dict(os.environ, {"EXAKIT_HOME": str(self.home), "DASH_SERVER_PORT": "9999"}), \
             patch.object(sys, "argv", ["dash-server", "--host", "0.0.0.0", "--port=9999", "--verbose"]), \
             patch.object(dash_launcher.os, "execve") as launch:
            dash_launcher.main()
        executable, args, env = launch.call_args.args
        self.assertEqual(str(venv / "bin/dash-server"), executable)
        self.assertEqual([executable, "--verbose", "--host", "127.0.0.1", "--port", "5102"], args)
        self.assertEqual("127.0.0.1", env["DASH_SERVER_HOST"])
        self.assertEqual("5102", env["DASH_SERVER_PORT"])
        self.assertEqual("private-test-password", env["EXA_PASSWORD"])
        self.assertNotIn("private-test-password", " ".join(args))


if __name__ == "__main__":
    unittest.main()
