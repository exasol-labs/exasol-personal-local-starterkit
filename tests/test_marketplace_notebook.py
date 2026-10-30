"""Notebook package plan and ownership without downloading its large runtime."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
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

    def test_notebook_command_rejects_bad_port_before_preflight(self) -> None:
        self.store.set_many({"components.notebook.version": "3.1.0"})
        with self.assertRaisesRegex(AddonFailure, "port"):
            command(self.ctx, ["marimo", "--port", "99999"])

    def test_stale_pidfile_is_not_treated_as_our_server(self) -> None:
        server = OnDemandServer(self.ctx, "jupyterlab")
        server.pidfile.parent.mkdir(parents=True)
        server.pidfile.write_text('{"pid":1,"created":"not-this-process"}\n')
        self.assertIsNone(server.pid())
        with patch("notebook_cli._healthy", return_value=True):
            self.assertEqual("stopped", server.state(8888))
        with patch("notebook_cli.os.kill") as kill, patch("notebook_cli.os.killpg") as kill_group:
            server.stop()
        kill.assert_not_called()
        kill_group.assert_not_called()
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

    def test_failed_update_validation_does_not_mark_desired_version(self) -> None:
        self.store.set_many({"components.notebook.ownership": "kit", "components.notebook.version": "3.1.0"})
        with patch.object(notebook, "install"), patch.object(notebook, "validate", return_value=False):
            with self.assertRaisesRegex(AddonFailure, "did not validate"):
                notebook.update(self.ctx)
        self.assertIsNone(self.store.get("desired.notebook"))


if __name__ == "__main__":
    unittest.main()
