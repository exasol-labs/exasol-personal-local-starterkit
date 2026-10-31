"""Notebook package plan and ownership without downloading its large runtime."""

from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from addons import notebook  # noqa: E402
import notebook_cli  # noqa: E402
from notebook_cli import OnDemandServer, command  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402


class NotebookPlanTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.store = Manifest(self.home / "manifest.json")
        self.store.path.write_text(json.dumps({"runtime": {"dsn": "127.0.0.1:8563", "user": "sys",
                                                        "password_file": str(self.home / "db-password")}}))
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.store, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_selected_frontends_have_one_resolution_and_shared_sklearn_pin(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_NOTEBOOK_FRONTENDS": "jupyterlab,marimo"}), \
             patch.object(notebook, "_external_jupyter", return_value=None):
            selected = notebook._frontends(self.ctx)
            specs = notebook._specs(self.ctx, "3.1.0", selected)
        self.assertEqual(("jupyterlab", "marimo"), selected)
        self.assertTrue(any(spec.startswith("exasol-notebook-connector[") and "jupyter" in spec for spec in specs))
        self.assertTrue(any(spec.startswith("scikit-learn==") for spec in specs))
        self.assertTrue(any(spec.startswith("jupyterlab==") for spec in specs))
        self.assertTrue(any(spec.startswith("marimo==") for spec in specs))
        self.assertIn(str(ROOT / "notebook" / "package"), specs)
        self.assertIn("docker-db", specs[0])

    def test_connector_widget_import_failure_refuses_before_connecting(self) -> None:
        python = self.home / "notebook-venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
        python.parent.mkdir(parents=True)
        python.touch()
        with patch.object(notebook_cli.subprocess, "run", return_value=SimpleNamespace(returncode=1)) as run, \
             patch.object(notebook_cli, "_confirm", return_value=False), \
             patch.object(notebook_cli, "_database_up") as database:
            with self.assertRaisesRegex(AddonFailure, "environment is broken"):
                notebook_cli._preflight(self.ctx)
        self.assertIn("from exasol.nb_connector.ui.access import access_store", run.call_args.args[0][-1])
        database.assert_not_called()

    def test_frontend_and_sklearn_pins_follow_active_versions_document(self) -> None:
        document = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))
        document["components"]["notebook"]["frontends"]["jupyterlab"] = "99.1.2"
        document["components"]["notebook"]["frontends"]["marimo"] = "99.2.3"
        for row in document["components"]["udf-devkit"]["containers"]:
            if row.get("language") == "python":
                row["packages"]["scikit-learn"] = "8.8.8"
        active = self.home / "active-versions.json"
        active.write_text(json.dumps(document), encoding="utf-8")
        with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_VERSIONS_DOC": str(active),
                                  "EXAKIT_NOTEBOOK_FRONTENDS": "jupyterlab,marimo"}), \
             patch.object(notebook, "_external_jupyter", return_value=None):
            ctx = KitContext(ROOT, self.home, self.home / "bin", self.store, Path("uv"))
            specs = notebook._specs(ctx, "3.1.0", notebook._frontends(ctx))
        self.assertIn("jupyterlab==99.1.2", specs)
        self.assertIn("marimo==99.2.3", specs)
        self.assertIn("scikit-learn==8.8.8", specs)

    def test_bad_frontend_refused_before_any_package_action(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_NOTEBOOK_FRONTENDS": "marimo,not-real"}):
            with self.assertRaisesRegex(AddonFailure, "Unknown"):
                notebook._frontends(self.ctx)
        with patch.dict(os.environ, {"EXAKIT_NOTEBOOK_FRONTENDS": "none"}):
            self.assertEqual((), notebook._frontends(self.ctx))

    def test_legacy_skip_answers_and_jupyter_alias_still_work(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_NOTEBOOK_JUPYTER": "skip",
                                  "EXAKIT_NOTEBOOK_MARIMO": "false"}, clear=True):
            self.assertEqual(("positron",), notebook._frontends(self.ctx))
        with patch.dict(os.environ, {"EXAKIT_NOTEBOOK_FRONTENDS": "Jupyter; Marimo"}, clear=True):
            self.assertEqual(("jupyterlab", "marimo"), notebook._frontends(self.ctx))

    def test_uninstall_preview_keeps_venv_store_and_notebooks(self) -> None:
        self.store.set_many({"components.notebook.ownership": "kit"})
        venv, home, folder = notebook.paths(self.ctx)
        venv.mkdir()
        home.mkdir()
        (home / "connection.scs").write_text("encrypted")
        folder.mkdir()
        (folder / "my-analysis.ipynb").write_text("keep")
        targets = notebook.uninstall(self.ctx, dry_run=True)
        self.assertEqual(2, len(targets))
        self.assertTrue((home / "connection.scs").exists())
        self.assertTrue((folder / "my-analysis.ipynb").exists())

    def test_remove_notebooks_is_explicit_in_preview(self) -> None:
        self.store.set_many({"components.notebook.ownership": "kit"})
        _, _, folder = notebook.paths(self.ctx)
        folder.mkdir()
        (folder / "analysis.ipynb").write_text("mine")
        with patch.dict(os.environ, {"EXAKIT_UNINSTALL_NOTEBOOKS": "remove"}):
            targets = notebook.uninstall(self.ctx, dry_run=True)
        self.assertIn(folder, targets)
        self.assertTrue((folder / "analysis.ipynb").exists())

    def test_unowned_notebook_is_never_removed(self) -> None:
        with self.assertRaisesRegex(AddonFailure, "not kit-owned"):
            notebook.uninstall(self.ctx)

    def test_receipt_paths_outweigh_changed_environment_on_uninstall(self) -> None:
        venv, home, folder = notebook.paths(self.ctx)
        venv.mkdir()
        home.mkdir()
        folder.mkdir()
        other = self.home / "other-users-environment"
        other.mkdir()
        (other / "keep.txt").write_text("keep")
        self.store.set_many({"components.notebook.ownership": "kit",
                             "components.notebook.venv": str(venv),
                             "components.notebook.store_file": str(home / "connection.scs"),
                             "components.notebook.notebooks_dir": str(folder)})
        with patch.dict(os.environ, {"EXAKIT_NOTEBOOK_VENV": str(other)}):
            self.assertEqual(venv, notebook.paths(self.ctx)[0])
            notebook.uninstall(self.ctx, dry_run=True)
        self.assertEqual("keep", (other / "keep.txt").read_text())

    def test_install_records_frontends_only_after_package_and_store_steps(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_NOTEBOOK_FRONTENDS": "jupyterlab,marimo"}), \
             patch.object(KitContext, "require_uv"), \
             patch.object(KitContext, "run_logged") as commands, \
             patch.object(notebook, "_package_version", return_value="3.1.0"), \
             patch.object(notebook, "_external_jupyter", return_value=None), \
             patch.object(notebook, "_copy") as copied, \
             patch.object(notebook, "_write_store") as store_written, \
             patch.object(notebook, "_register_kernel") as registered:
            notebook.install(self.ctx)
        self.assertTrue(commands.called)
        self.assertEqual(["jupyter", "marimo"], [call.args[1] for call in copied.call_args_list])
        store_written.assert_called_once()
        registered.assert_called_once()
        self.assertEqual("kit", self.store.get("components.notebook.ownership"))
        self.assertEqual("jupyterlab,marimo", self.store.get("components.notebook.front_ends"))

    def test_no_frontends_remains_an_explicit_choice_after_install(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_NOTEBOOK_FRONTENDS": "none"}), \
             patch.object(KitContext, "require_uv"), patch.object(KitContext, "run_logged"), \
             patch.object(notebook, "_package_version", return_value="3.1.0"), \
             patch.object(notebook, "_external_jupyter", return_value=None), \
             patch.object(notebook, "_copy"), patch.object(notebook, "_write_store"), \
             patch.object(notebook, "_register_kernel"):
            notebook.install(self.ctx)
        self.assertEqual("none", self.store.get("components.notebook.front_ends"))
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual((), notebook._frontends(self.ctx))

    def test_notebook_command_rejects_bad_port_before_preflight(self) -> None:
        self.store.set_many({"components.notebook.version": "3.1.0"})
        with self.assertRaisesRegex(AddonFailure, "port"):
            command(self.ctx, ["marimo", "--port", "99999"])

    def test_command_rejects_unknown_option_and_names_missing_addon(self) -> None:
        with self.assertRaisesRegex(AddonFailure, "Unknown option"):
            command(self.ctx, ["--invented"])
        with self.assertRaisesRegex(AddonFailure, "exakit marketplace notebook"):
            command(self.ctx, ["jupyterlab"])

    def test_stop_does_not_require_database_or_notebook_environment(self) -> None:
        self.store.set_many({"components.notebook.version": "3.1.0"})
        with patch.object(notebook_cli, "_preflight") as preflight, \
             patch.object(notebook_cli, "OnDemandServer") as server, \
             redirect_stdout(StringIO()):
            self.assertEqual(0, command(self.ctx, ["--stop"]))
        preflight.assert_not_called()
        self.assertEqual(["jupyterlab", "marimo"], [call.args[1] for call in server.call_args_list])
        self.assertEqual(2, server.return_value.stop.call_count)

    def test_missing_frontend_uses_explicit_setup_in_headless_mode(self) -> None:
        with patch.object(notebook_cli, "_find_jupyter", return_value=None), \
             patch.object(notebook_cli.sys.stdin, "isatty", return_value=False), \
             patch.dict(os.environ, {"EXAKIT_NOTEBOOK_JUPYTER": ""}):
            with self.assertRaisesRegex(AddonFailure, "exakit notebook jupyterlab setup"):
                notebook_cli._ensure_frontend(self.ctx, "jupyterlab", False)
        seen = []
        with patch.object(notebook_cli, "_find_jupyter", return_value=None), \
             patch.object(notebook, "install", side_effect=lambda _: seen.append(os.environ["EXAKIT_NOTEBOOK_FRONTENDS"])) as install, \
             patch.dict(os.environ, {"EXAKIT_NOTEBOOK_FRONTENDS": "marimo"}):
            notebook_cli._ensure_frontend(self.ctx, "jupyterlab", True)
            self.assertEqual("marimo", os.environ["EXAKIT_NOTEBOOK_FRONTENDS"])
        install.assert_called_once()
        self.assertEqual(["jupyterlab,marimo"], seen)

    def test_preflight_refuses_missing_environment_and_down_database_without_consent(self) -> None:
        with patch.object(notebook_cli, "_confirm", return_value=False), \
             patch.object(notebook, "install") as install:
            with self.assertRaisesRegex(AddonFailure, "exakit update notebook"):
                notebook_cli._preflight(self.ctx)
        install.assert_not_called()
        python = notebook_cli.venv_python(notebook.paths(self.ctx)[0])
        python.parent.mkdir(parents=True)
        python.write_text("test", encoding="utf-8")
        with patch.object(notebook_cli.subprocess, "run", return_value=SimpleNamespace(returncode=0)), \
             patch.object(notebook_cli, "_database_up", return_value=False), \
             patch.object(notebook_cli, "_confirm", return_value=False), \
             patch.object(notebook, "_write_store") as store:
            with self.assertRaisesRegex(AddonFailure, "exakit start"):
                notebook_cli._preflight(self.ctx)
        store.assert_not_called()

    def test_preflight_refreshes_connection_and_notebooks_on_each_launch(self) -> None:
        python = notebook_cli.venv_python(notebook.paths(self.ctx)[0])
        python.parent.mkdir(parents=True)
        python.write_text("test", encoding="utf-8")
        with patch.object(notebook_cli.subprocess, "run", return_value=SimpleNamespace(returncode=0)), \
             patch.object(notebook_cli, "_database_up", return_value=True), \
             patch.object(notebook, "_write_store") as store, \
             patch.object(notebook, "_register_kernel") as kernel, \
             patch.object(notebook, "_copy") as copied:
            notebook_cli._preflight(self.ctx)
            notebook_cli._preflight(self.ctx)
        self.assertEqual(2, store.call_count)
        self.assertEqual(2, kernel.call_count)
        self.assertEqual(2, copied.call_count)
        self.assertTrue(notebook.paths(self.ctx)[2].is_dir())

    def test_port_collision_refuses_explicit_port_and_skips_to_free_default(self) -> None:
        with patch.object(notebook_cli, "_port_open", side_effect=lambda port: port == 28888):
            with self.assertRaisesRegex(AddonFailure, "choose another with --port"):
                notebook_cli._choose_port(28888, True)
            with redirect_stdout(StringIO()):
                self.assertEqual(28889, notebook_cli._choose_port(28888, False))

    def test_browser_failure_reports_private_login_file_without_token(self) -> None:
        for result in (False, notebook_cli.webbrowser.Error("no browser")):
            with self.subTest(result=result), \
                 patch.object(notebook_cli.webbrowser, "open", side_effect=result if isinstance(result, Exception) else None,
                              return_value=False), redirect_stdout(StringIO()) as output:
                notebook_cli._open_logged_in(self.ctx, "marimo", "http://127.0.0.1:2718/?access_token=test-secret")
            self.assertIn("open-marimo.html", output.getvalue())
            self.assertNotIn("test-secret", output.getvalue())

    def test_skip_aliases_never_install_a_missing_frontend(self) -> None:
        for answer in ("skip", "no", "0", "false", "none"):
            with self.subTest(answer=answer), \
                 patch.dict(os.environ, {"EXAKIT_NOTEBOOK_JUPYTER": answer}), \
                 patch.object(notebook_cli, "_find_jupyter", return_value=None), \
                 patch.object(notebook, "install") as install:
                with self.assertRaisesRegex(AddonFailure, "was skipped"):
                    notebook_cli._ensure_frontend(self.ctx, "jupyterlab", True)
                install.assert_not_called()

    def test_menu_explains_external_missing_and_starting_frontends(self) -> None:
        rows = []

        def run(args, **kwargs):
            rows.extend(json.loads(Path(args[args.index("--states") + 1]).read_text())["tools"])
            Path(args[args.index("--out") + 1]).write_text('{"selected": []}')
            return SimpleNamespace(returncode=0)

        self.store.set_many({"components.notebook.front_ends": "jupyterlab,marimo"})
        with patch.object(notebook_cli, "_find_jupyter", return_value=self.home / "external/jupyter-lab"), \
             patch.object(notebook_cli, "_positron_command", return_value=None), \
             patch.object(OnDemandServer, "state", return_value="stopped"), \
             patch.object(OnDemandServer, "recorded_port", side_effect=lambda port: port), \
             patch.object(notebook_cli.subprocess, "run", side_effect=run):
            self.assertEqual([], notebook_cli._menu(self.ctx))
        self.assertIn("ready (yours:", rows[0]["detail"])
        self.assertIn("missing - reinstall", rows[1]["detail"])
        self.assertTrue(rows[2]["disabled"])
        self.assertIn("positron.posit.co", rows[2]["detail"])
        rows.clear()
        with patch.object(notebook_cli, "_find_jupyter", return_value=None), \
             patch.object(notebook_cli, "_positron_command", return_value=None), \
             patch.object(OnDemandServer, "state", return_value="starting"), \
             patch.object(OnDemandServer, "recorded_port", return_value=28999), \
             patch.object(notebook_cli.subprocess, "run", side_effect=run):
            notebook_cli._menu(self.ctx)
        self.assertEqual("starting on port 28999", rows[0]["detail"])
        self.assertEqual("starting on port 28999", rows[1]["detail"])

    def test_stale_pidfile_is_not_treated_as_our_server(self) -> None:
        server = OnDemandServer(self.ctx, "jupyterlab")
        server.pidfile.parent.mkdir(parents=True)
        server.pidfile.write_text('{"pid":1,"created":"not-this-process"}\n')
        self.assertIsNone(server.pid())
        with patch("notebook_cli._healthy", return_value=True):
            self.assertEqual("stopped", server.state(8888))
        with patch("notebook_cli.os.kill") as kill, patch("notebook_cli.os.killpg", create=True) as kill_group:
            server.stop()
        kill.assert_not_called()
        kill_group.assert_not_called()
        self.assertFalse(server.pidfile.exists())

    def test_store_retry_recovers_and_restores_original_on_failure(self) -> None:
        (self.home / "db-password").write_text("test-password", encoding="utf-8")
        _, home, _ = notebook.paths(self.ctx)
        home.mkdir()
        store = home / "connection.scs"
        master = notebook._credential(self.ctx, "notebook_store_master_password")
        for fails_again in (False, True):
            with self.subTest(fails_again=fails_again):
                store.write_text("old-encrypted-store", encoding="utf-8")
                calls = []

                def write(_ctx, name, *, env):
                    calls.append(name)
                    self.assertEqual(str(self.home / "db-password"), env["EXAKIT_NB_PWFILE"])
                    self.assertEqual(master.read_text().strip(), env["SCS_MASTER_PASSWORD"])
                    self.assertEqual("127.0.0.1", env["EXAKIT_NB_HOST"])
                    self.assertEqual("8563", env["EXAKIT_NB_PORT"])
                    if len(calls) == 1 or fails_again:
                        raise AddonFailure("cannot write store")
                    store.write_text("new-encrypted-store", encoding="utf-8")

                with patch.object(notebook, "_run_helper", side_effect=write):
                    if fails_again:
                        with self.assertRaisesRegex(AddonFailure, "cannot write store"):
                            notebook._write_store(self.ctx)
                    else:
                        notebook._write_store(self.ctx)
                self.assertEqual(2, len(calls))
                self.assertEqual("old-encrypted-store" if fails_again else "new-encrypted-store",
                                 store.read_text())

    def test_uninstall_removes_owned_files_and_retains_user_notebooks(self) -> None:
        self.store.set_many({"components.notebook.ownership": "kit",
                             "components.notebook.version": "3.1.0"})
        venv, home, directory = notebook.paths(self.ctx)
        python = notebook_cli.venv_python(venv)
        python.parent.mkdir(parents=True)
        python.write_text("test", encoding="utf-8")
        home.mkdir()
        (home / "connection.scs").write_text("encrypted", encoding="utf-8")
        directory.mkdir()
        (directory / "analysis.ipynb").write_text("user notebook", encoding="utf-8")
        settings = directory / ".vscode" / "settings.json"
        settings.parent.mkdir()
        settings.write_text('{}', encoding="utf-8")
        token = notebook._credential(self.ctx, "notebook_jupyter_token")
        with patch.object(notebook_cli, "OnDemandServer") as server, \
             patch.object(notebook, "_run_helper") as helper:
            notebook.uninstall(self.ctx)
        self.assertEqual(2, server.return_value.stop.call_count)
        self.assertEqual(["remove_kernel.py", "notebooks.py"],
                         [call.args[1] for call in helper.call_args_list])
        self.assertFalse(venv.exists())
        self.assertFalse(token.exists())
        self.assertFalse((home / "connection.scs").exists())
        self.assertEqual("user notebook", (directory / "analysis.ipynb").read_text())
        self.assertIsNone(self.store.get("components.notebook"))

    def test_menu_selection_continues_after_one_frontend_fails(self) -> None:
        self.store.set_many({"components.notebook.version": "3.1.0"})
        with patch.object(notebook_cli, "_preflight"), \
             patch.object(notebook_cli.sys.stdin, "isatty", return_value=True), \
             patch.object(notebook_cli.sys.stdout, "isatty", return_value=True), \
             patch.object(notebook_cli, "_menu", return_value=["jupyterlab", "marimo"]), \
             patch.object(notebook_cli, "_start_frontend", side_effect=[AddonFailure("test failure"), None]) as start:
            self.assertEqual(1, command(self.ctx, []))
        self.assertEqual(["jupyterlab", "marimo"], [call.args[1] for call in start.call_args_list])

    def test_starting_server_is_waited_for_at_its_recorded_port(self) -> None:
        with patch.object(notebook_cli, "_ensure_frontend"), \
             patch.object(notebook_cli, "OnDemandServer") as server_type, \
             redirect_stdout(StringIO()) as output:
            server = server_type.return_value
            server.recorded_port.return_value = 28999
            server.state.return_value = "starting"
            notebook_cli._start_frontend(self.ctx, "marimo", None, False, False)
            server.wait_ready.assert_called_once_with(28999)
            server.start.assert_not_called()
        self.assertIn("http://127.0.0.1:28999/", output.getvalue())

    def test_starting_server_timeout_never_reports_running_or_stops_other_launch(self) -> None:
        with patch.object(notebook_cli, "_ensure_frontend"), \
             patch.object(notebook_cli, "OnDemandServer") as server_type, \
             redirect_stdout(StringIO()) as output:
            server = server_type.return_value
            server.recorded_port.return_value = 28999
            server.state.return_value = "starting"
            server.wait_ready.side_effect = AddonFailure("startup timed out")
            with self.assertRaisesRegex(AddonFailure, "startup timed out"):
                notebook_cli._start_frontend(self.ctx, "marimo", None, False, False)
            server.start.assert_not_called()
            server.stop.assert_not_called()
        self.assertNotIn("is running", output.getvalue())

    def test_server_that_exits_during_start_is_not_left_recorded(self) -> None:
        notebook.paths(self.ctx)[2].mkdir(parents=True)
        server = OnDemandServer(self.ctx, "jupyterlab")
        with patch.object(notebook_cli, "_port_open", return_value=False), \
             patch.object(notebook_cli, "_healthy", return_value=False):
            with self.assertRaisesRegex(AddonFailure, "did not start"):
                server.start([sys.executable, "-c", "raise SystemExit(1)", server.marker], 28888)
        self.assertFalse(server.pidfile.exists())

    def test_jupyter_and_marimo_open_separate_notebook_views(self) -> None:
        _, home, directory = notebook.paths(self.ctx)
        home.mkdir(parents=True)
        with patch.object(notebook_cli, "_ensure_frontend"), \
             patch.object(notebook_cli, "_find_jupyter", return_value=Path("/tools/jupyter-lab")), \
             patch.object(notebook_cli, "_choose_port", side_effect=lambda port, _: port), \
             patch.object(notebook_cli, "OnDemandServer") as server_type, \
             patch.object(notebook, "_copy"):
            server_type.return_value.state.return_value = "stopped"
            with redirect_stdout(StringIO()):
                notebook_cli._start_frontend(self.ctx, "jupyterlab", 28888, False, False)
            jupyter_args = server_type.return_value.start.call_args.args[0]
            config = home / "jupyter_server_config.json"
            self.assertIn(f"--config={config}", jupyter_args)
            self.assertIn(f"--ServerApp.root_dir={directory}", jupyter_args)
            self.assertIn("marimo", json.loads(config.read_text(encoding="utf-8"))["ContentsManager"]["hide_globs"])
            with redirect_stdout(StringIO()):
                notebook_cli._start_frontend(self.ctx, "marimo", 2718, False, False)
            marimo_args = server_type.return_value.start.call_args.args[0]
            self.assertEqual("edit", marimo_args[4])
            self.assertEqual(str(directory / "marimo"), marimo_args[5])

    @unittest.skipIf(os.name == "nt", "native Windows process test is a separate release gate")
    def test_frontend_launch_keeps_token_out_of_argv_and_stops_owned_server(self) -> None:
        for frontend in ("jupyterlab", "marimo"):
            with self.subTest(frontend=frontend):
                self._check_server_launch(frontend)

    def _check_server_launch(self, frontend: str) -> None:
        venv, home, directory = notebook.paths(self.ctx)
        home.mkdir(parents=True, exist_ok=True)
        directory.mkdir(parents=True, exist_ok=True)
        python = notebook_cli.venv_python(venv)
        python.parent.mkdir(parents=True, exist_ok=True)
        if not python.exists():
            python.symlink_to(sys.executable)
        program = notebook_cli.venv_executable(venv, "marimo") if frontend == "marimo" else self.home / "jupyter-lab"
        program.write_text("""#!/usr/bin/env python3
import http.server
import os
import sys
from pathlib import Path

if '--port' in sys.argv:
    port = int(sys.argv[sys.argv.index('--port') + 1])
    token = Path(sys.argv[sys.argv.index('--token-password-file') + 1]).read_text().strip()
else:
    port = int(next(arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--ServerApp.port=')))
    token = os.environ.get('JUPYTER_TOKEN', '')
Path(os.environ['EXAKIT_TEST_TOKEN_FILE']).write_text(token)
print('token=' + token, flush=True)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"version":"test"}')

    def log_message(self, *args):
        pass

http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()
""", encoding="utf-8")
        program.chmod(0o755)
        try:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
        except PermissionError:
            self.skipTest("local socket binding is blocked in this sandbox")
        token_seen = self.home / "token-seen"
        server = OnDemandServer(self.ctx, frontend)
        try:
            with patch.dict(os.environ, {"EXAKIT_TEST_TOKEN_FILE": str(token_seen)}), \
                 patch.object(notebook_cli, "_ensure_frontend"), \
                 patch.object(notebook_cli, "_find_jupyter", return_value=program), \
                 patch.object(notebook, "_copy"), \
                 patch.object(notebook_cli.webbrowser, "open") as browser, \
                 redirect_stdout(StringIO()) as output:
                notebook_cli._start_frontend(self.ctx, frontend, port, True, False)
            token = token_seen.read_text(encoding="utf-8")
            self.assertTrue(token)
            self.assertEqual("running", server.state(port))
            self.assertNotIn(token, notebook_cli._command(server.pid()))
            self.assertNotIn(token, output.getvalue())
            self.assertNotIn(token, server.log.read_text(encoding="utf-8"))
            self.assertIn("token=***", server.log.read_text(encoding="utf-8"))
            opened = home / ("open-jupyter.html" if frontend == "jupyterlab" else "open-marimo.html")
            self.assertIn(token, opened.read_text(encoding="utf-8"))
            self.assertEqual(0o600, opened.stat().st_mode & 0o777)
            browser.assert_called_once_with(opened.as_uri())
        finally:
            server.stop()
        self.assertEqual("stopped", server.state(port))
        self.assertFalse(opened.exists())

    def test_failed_update_validation_does_not_mark_desired_version(self) -> None:
        self.store.set_many({"components.notebook.ownership": "kit", "components.notebook.version": "3.1.0"})
        with patch.object(notebook, "install"), patch.object(notebook, "validate", return_value=False):
            with self.assertRaisesRegex(AddonFailure, "did not validate"):
                notebook.update(self.ctx)
        self.assertIsNone(self.store.get("desired.notebook"))


if __name__ == "__main__":
    unittest.main()
