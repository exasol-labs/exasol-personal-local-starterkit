"""Dash Server port, launcher and service recovery contracts."""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
import dash_launcher  # noqa: E402
from addons import dash_server  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402


class ProbeTest(unittest.TestCase):
    """runtime.probe: a question that cannot be asked, or is not answered in time, is None - never an exception
    that ends the install (the dash-server import timing out after ten seconds did exactly that)."""

    def test_a_timeout_and_a_missing_program_answer_none(self) -> None:
        import subprocess
        import runtime  # noqa: E402
        with patch.object(runtime.subprocess, "run", side_effect=subprocess.TimeoutExpired(["x"], 1)):
            self.assertIsNone(runtime.probe(["x"], timeout=1))
        self.assertIsNone(runtime.probe([str(Path(tempfile.gettempdir()) / "no-such-program-exakit")], timeout=1))
        self.assertGreaterEqual(runtime.FIRST_IMPORT_TIMEOUT, 60)

    def test_an_answer_comes_back_whole(self) -> None:
        import runtime  # noqa: E402
        result = runtime.probe([sys.executable, "-c", "print('answered')"], timeout=30)
        self.assertIsNotNone(result)
        self.assertEqual((0, "answered"), (result.returncode, result.stdout.strip()))


class CmdFileTest(unittest.TestCase):
    """runtime.cmd_file_bytes (audit WIN-02): a .cmd launcher under a non-ASCII user profile still names a path
    cmd.exe can open - the profile is folded into %USERPROFILE%, so the bytes stay ASCII - and a path the console
    code page cannot spell is refused by name, never written wrong."""

    def test_the_profile_folds_to_the_variable(self) -> None:
        import runtime  # noqa: E402
        profile = "C:\\Users\\M\u00fcller"
        with patch.dict(os.environ, {"USERPROFILE": profile}):
            data = runtime.cmd_file_bytes(f'@echo off\r\n"{profile}\\.exasol-starter-kit\\venv\\python.exe" %*\r\n')
        self.assertEqual(b'@echo off\r\n"%USERPROFILE%\\.exasol-starter-kit\\venv\\python.exe" %*\r\n', data)

    @unittest.skipIf(os.name == "nt", "off Windows the code page is ASCII, so any non-ASCII byte must be refused")
    def test_an_unspellable_path_is_refused_by_name(self) -> None:
        import runtime  # noqa: E402
        with patch.dict(os.environ, {"USERPROFILE": "C:\\Users\\someone"}), self.assertRaises(AddonFailure) as caught:
            runtime.cmd_file_bytes('"D:\\Daten \u00e4\\kit\\python.exe" %*')
        self.assertIn("code page", str(caught.exception))


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

    def _update(self, *, installed: str, env_port: str, running_on: int) -> tuple[Mock, Mock, Mock, Mock]:
        """dash_server.update with the service, the package and the AI-client registration stood in. The fake
        service runs on `running_on` only; install records the port it settles, as the real one does."""
        self.manifest.set_many({"components.dash_server.ownership": "kit", "components.dash_server.version": installed,
                                "components.dash_server.port": 5100})
        service = Mock()
        service.status.side_effect = lambda port: "running" if port == running_on else "stopped"

        def install(ctx: KitContext) -> None:
            ctx.manifest.set_many({"components.dash_server.port": dash_server._port(ctx),
                                   "components.dash_server.version": "0.2.0"})

        installer = Mock(side_effect=install)
        start = Mock()
        register = Mock(return_value="")
        import integration
        with patch.object(dash_server, "_service", return_value=service), \
             patch.object(dash_server, "package_version", return_value=installed), \
             patch.object(dash_server, "_target", return_value="0.2.0"), \
             patch.object(dash_server, "install", installer), \
             patch.object(dash_server, "validate", return_value=True), \
             patch.object(dash_server, "_settle_port", side_effect=lambda ctx: dash_server._port(ctx)), \
             patch.object(dash_server, "start", start), \
             patch.object(integration, "register_mcp_endpoint", register), \
             patch.dict(os.environ, {"EXAKIT_DASH_SERVER_PORT": env_port}):
            dash_server.update(self.ctx)
        return service, installer, start, register

    def test_an_update_to_a_new_port_stops_the_server_on_the_recorded_port(self) -> None:
        """#48 / DOC-05: EXAKIT_DASH_SERVER_PORT=5200 exakit update dash-server looked for the server on 5200, found
        nothing, and left the old one serving the old code on 5100. It is stopped on 5100 and started on 5200, and
        the AI clients are pointed at 5200."""
        service, installer, start, register = self._update(installed="0.1.0", env_port="5200", running_on=5100)
        self.assertEqual(5100, service.status.call_args_list[0].args[0])
        service.stop.assert_called_once_with(5100)
        installer.assert_called_once()
        start.assert_called_once_with(self.ctx)
        self.assertEqual(5200, self.manifest.get("components.dash_server.port"))
        register.assert_called_once()

    def test_a_new_port_moves_the_server_at_the_same_version(self) -> None:
        service, installer, start, register = self._update(installed="0.2.0", env_port="5200", running_on=5100)
        service.stop.assert_called_once_with(5100)
        installer.assert_not_called()
        start.assert_called_once_with(self.ctx)
        self.assertEqual(5200, self.manifest.get("components.dash_server.port"))
        register.assert_called_once()

    def test_the_same_version_on_the_same_port_changes_nothing(self) -> None:
        service, installer, start, register = self._update(installed="0.2.0", env_port="", running_on=5100)
        service.stop.assert_not_called()
        installer.assert_not_called()
        start.assert_not_called()
        register.assert_not_called()

    def test_a_version_update_on_the_same_port_restarts_and_registers_nothing(self) -> None:
        service, installer, start, register = self._update(installed="0.1.0", env_port="", running_on=5100)
        service.stop.assert_called_once_with(5100)
        start.assert_called_once_with(self.ctx)
        self.assertEqual(5100, self.manifest.get("components.dash_server.port"))
        register.assert_not_called()

    def test_a_stopped_server_stays_stopped_when_its_port_moves(self) -> None:
        service, installer, start, register = self._update(installed="0.2.0", env_port="5200", running_on=0)
        service.stop.assert_not_called()
        start.assert_not_called()
        self.assertEqual(5200, self.manifest.get("components.dash_server.port"))
        register.assert_called_once()

    def _states(self, *, installed: str, running: bool, force: str = "") -> list[str]:
        """dash_server.update on the same port, in the order things happened: the service's stop and start, the
        install and the validation, all recorded on one parent mock (QAT-01, QAT-05)."""
        self.manifest.set_many({"components.dash_server.ownership": "kit", "components.dash_server.version": installed,
                                "components.dash_server.port": 5100})
        order = Mock()
        order.service.status.side_effect = lambda port: "running" if running and port == 5100 else "stopped"
        order.validate.return_value = True
        import integration
        with patch.object(dash_server, "_service", return_value=order.service), \
             patch.object(dash_server, "package_version", return_value=installed), \
             patch.object(dash_server, "_target", return_value="0.2.0"), \
             patch.object(dash_server, "install", order.install), \
             patch.object(dash_server, "validate", order.validate), \
             patch.object(dash_server, "start", order.start), \
             patch.object(integration, "register_mcp_endpoint", order.register), \
             patch.dict(os.environ, {"EXAKIT_DASH_SERVER_PORT": "", "EXAKIT_FORCE_COMPONENT_INSTALL": force}):
            dash_server.update(self.ctx)
        return [name for name, _, _ in order.mock_calls if name in ("service.stop", "install", "validate", "start", "register")]

    def test_a_running_server_is_stopped_updated_then_started_on_the_new_version(self) -> None:
        self.assertEqual(["service.stop", "install", "validate", "start"], self._states(installed="0.1.0", running=True))

    def test_a_stopped_server_is_updated_and_stays_stopped(self) -> None:
        self.assertEqual(["install", "validate"], self._states(installed="0.1.0", running=False))

    def test_the_same_version_leaves_a_running_server_alone(self) -> None:
        self.assertEqual([], self._states(installed="0.2.0", running=True))

    def test_a_forced_same_version_update_restarts_a_running_server(self) -> None:
        self.assertEqual(["service.stop", "install", "validate", "start"],
                         self._states(installed="0.2.0", running=True, force="1"))

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

    def test_the_seeded_demo_dashboard_is_removed_once(self) -> None:
        apps = {"apps": [{"name": "demo", "title": "Demo Dashboard"}, {"name": "sales", "title": "Sales"}]}
        calls = []

        def tool(port, name, arguments):
            calls.append((name, arguments))
            return apps if name == "apps_list" else {"deleted": True}

        with patch.object(dash_server, "_tool", side_effect=tool):
            dash_server._drop_demo(self.ctx, 5100)
            dash_server._drop_demo(self.ctx, 5100)
        self.assertEqual([("apps_list", {}), ("app_delete", {"name": "demo", "confirmation": "demo"})], calls)
        self.assertIs(True, self.manifest.get("components.dash_server.demo_removed"))

    def test_a_dashboard_a_person_called_demo_stays(self) -> None:
        calls = []

        def tool(port, name, arguments):
            calls.append(name)
            return {"apps": [{"name": "demo", "title": "Our demo"}]}

        with patch.object(dash_server, "_tool", side_effect=tool):
            dash_server._drop_demo(self.ctx, 5100)
        self.assertEqual(["apps_list"], calls)
        self.assertIs(True, self.manifest.get("components.dash_server.demo_removed"))

    def test_an_unreachable_control_plane_leaves_the_demo_for_the_next_start(self) -> None:
        with patch.object(dash_server, "_tool", side_effect=AddonFailure("refused")), \
             patch.object(KitContext, "activity") as said:
            dash_server._drop_demo(self.ctx, 5100)
        self.assertIsNone(self.manifest.get("components.dash_server.demo_removed"))
        said.assert_called_once()

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

    def test_a_slow_first_import_never_ends_the_install(self) -> None:
        """A fresh environment's first import can outlast any short budget (bytecode compiled on the spot, macOS
        checking each new native library): the probe answers None, the template repair steps aside and says so,
        validate records "not validated" - and nothing raises (a real install ended with "timed out after 10 s")."""
        venv = dash_server.paths(self.ctx)[0]
        python = dash_server.venv_python(venv)
        python.parent.mkdir(parents=True)
        python.write_text("fake")
        with patch.object(dash_server, "probe", return_value=None), \
             patch.object(KitContext, "activity") as activity:
            dash_server._restore_templates(self.ctx, "0.2.1")
            self.assertFalse(dash_server.validate(self.ctx))
        self.assertEqual(False, self.manifest.get("components.dash_server.validated"))
        said = " ".join(str(call.args[0]) for call in activity.call_args_list)
        self.assertIn("did not answer in time", said)
        self.assertIn("exakit update dash-server", said)

    def test_install_compiles_bytecode_so_the_first_import_is_quick(self) -> None:
        self.manifest.set_many({"components.dash_server.ownership": "kit"})
        venv = dash_server.paths(self.ctx)[0]
        python = dash_server.venv_python(venv)
        python.parent.mkdir(parents=True)
        python.write_text("fake")
        with patch.object(KitContext, "require_uv"), \
             patch.object(KitContext, "target_version", return_value="0.2.1"), \
             patch.object(dash_server, "package_version", side_effect=["0.1.9", "0.2.1", "0.2.1"]), \
             patch.object(dash_server, "_settle_port", return_value=5100), \
             patch.object(dash_server, "_restore_templates"), \
             patch.object(dash_server.subprocess, "run", return_value=Mock(returncode=0)), \
             patch.object(KitContext, "run_logged") as run_logged:
            dash_server.install(self.ctx)
        installs = [call.args for call in run_logged.call_args_list if "pip" in call.args and "install" in call.args]
        self.assertTrue(installs, run_logged.call_args_list)
        self.assertIn("--compile-bytecode", installs[-1])

    @unittest.skipIf(os.name == "nt", "Unix execve contract")
    def test_launcher_uses_recorded_port_and_keeps_secret_out_of_arguments(self) -> None:
        credential = self.home / "credentials" / "db-password"
        credential.parent.mkdir(parents=True)
        credential.write_text("private-test-password\n", encoding="utf-8")
        venv = self.home / "dash-server-venv"
        instance = self.home / "dash-server" / "instance"
        doc = {"components": {"dash_server": {"version": "0.1.1", "port": 5102,
                                             "venv": str(venv), "instance": str(instance)},
                              "mcp_server": {"connection": {"user": "mcp_readonly", "validated": True,
                                                            "password_file": str(credential)}}},
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

    @unittest.skipIf(os.name == "nt", "Unix execve contract")
    def test_dashboards_query_as_the_read_only_user_and_an_admin_profile_is_repaired(self) -> None:
        credentials = self.home / "credentials"
        credentials.mkdir(parents=True)
        (credentials / "personal_sys_password").write_text("admin-secret\n", encoding="utf-8")
        (credentials / "mcp_readonly_password").write_text("reader-secret\n", encoding="utf-8")
        venv = self.home / "dash-server-venv"
        instance = self.home / "dash-server" / "instance"
        doc = {"components": {"dash_server": {"version": "0.1.1", "port": 5100, "venv": str(venv), "instance": str(instance)},
                              "mcp_server": {"connection": {"user": "mcp_readonly", "validated": True,
                                                            "password_file": str(credentials / "mcp_readonly_password")}}},
               "runtime": {"dsn": "127.0.0.1:8563", "user": "sys", "password_file": str(credentials / "personal_sys_password")}}
        self.manifest.path.write_text(json.dumps(doc), encoding="utf-8")

        said = io.StringIO()

        def launch_env() -> dict:
            with patch.dict(os.environ, {"EXAKIT_HOME": str(self.home)}), patch.object(sys, "argv", ["dash-server"]), \
                    patch.object(dash_launcher.os, "execve") as launch, redirect_stderr(said):
                dash_launcher.main()
            return launch.call_args.args[2]

        env = launch_env()
        self.assertEqual("mcp_readonly", env["DASH_SERVER_EXASOL_USER"])
        self.assertEqual("reader-secret", env["EXA_PASSWORD"])
        self.assertNotIn("DASH_SERVER_EXASOL_OVERWRITE", env)                  # no stored profile: a plain seed
        stored = instance / "gitops-repo" / "profiles" / "exasol" / "starter-kit.json"
        stored.parent.mkdir(parents=True)
        stored.write_text(json.dumps({"name": "starter-kit", "user": "sys", "dsn": "127.0.0.1:8563"}), encoding="utf-8")
        self.assertEqual("true", launch_env().get("DASH_SERVER_EXASOL_OVERWRITE"))   # the earlier kit's admin profile
        stored.write_text(json.dumps({"name": "starter-kit", "user": "analyst", "dsn": "127.0.0.1:8563"}), encoding="utf-8")
        self.assertNotIn("DASH_SERVER_EXASOL_OVERWRITE", launch_env())         # someone's own choice stays
        doc["components"]["mcp_server"]["connection"]["validated"] = False
        self.manifest.path.write_text(json.dumps(doc), encoding="utf-8")
        env = launch_env()
        # No read-only user yet: no database profile at all - never the administrator's password (audit SEC-01).
        self.assertNotIn("DASH_SERVER_EXASOL_USER", env)
        self.assertNotIn("admin-secret", json.dumps(env))
        self.assertNotIn("DASH_SERVER_EXASOL_OVERWRITE", env)
        self.assertIn("exakit mcp-setup", said.getvalue())


if __name__ == "__main__":
    unittest.main()
