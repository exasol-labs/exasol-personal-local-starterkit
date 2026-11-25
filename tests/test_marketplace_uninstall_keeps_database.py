"""(run: python3 -m unittest discover -s tests -p 'test_marketplace_uninstall_keeps_database.py' -v) A full uninstall
over a database the user let the kit use keeps everything inside it: with EXAKIT_UNINSTALL_KEEP_DATABASE=1 (set by
the shells while the add-ons go) Semantic Views keeps its schemas, role and Semantic SQL module, JSON Tables keeps its
module and the Scheduler keeps its schema and login (the kit's logins go through kit_logins.py instead). Each add-on
still removes its files, service and receipt on this computer, and without the switch every removal is as before.
No database, network or service is touched: every database step is a stand-in that fails the test if it is called."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
sys.path.insert(0, str(ROOT / "marketplace" / "addons"))
from addons import exasol_scheduler as scheduler  # noqa: E402
from addons import json_tables  # noqa: E402
from addons import semantic_views  # noqa: E402
import runtime  # noqa: E402
from runtime import KitContext, Manifest  # noqa: E402

NOT_IN_THE_DATABASE = AssertionError("the database was touched")


class KeepsDatabaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / "kit home"
        self.home.mkdir()
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text(json.dumps({"runtime": {"dsn": "127.0.0.1:8563", "user": "sys"}}),
                                      encoding="utf-8")
        self.ctx = KitContext(ROOT, self.home, Path(self.temp.name) / "bin", self.manifest, Path("uv"))
        self.addCleanup(os.environ.pop, runtime.KEEP_DATABASE, None)
        os.environ[runtime.KEEP_DATABASE] = "1"

    def test_the_switch_is_on_only_for_one(self) -> None:
        self.assertTrue(runtime.uninstall_keeps_database())
        for value in ("", "0", "yes"):
            os.environ[runtime.KEEP_DATABASE] = value
            self.assertFalse(runtime.uninstall_keeps_database())

    def test_semantic_views_keeps_its_schemas_role_and_module_and_removes_its_folder(self) -> None:
        home = semantic_views.paths(self.ctx)[0]
        home.mkdir(parents=True)
        self.manifest.set_many({"components.semantic_views": {"ownership": "kit", "version": "v0.6.1",
                                                              "role_created": True, "mcp_login": "MCP_READONLY"},
                                "components.preprocessor.modules.semantic-views.version": 1})
        with patch.object(semantic_views, "_db", side_effect=NOT_IN_THE_DATABASE), \
                patch.object(semantic_views.preprocessor_modules, "retire", side_effect=NOT_IN_THE_DATABASE):
            self.assertEqual([home], semantic_views.uninstall(self.ctx, dry_run=True))
            self.assertTrue(home.exists())
            self.assertEqual([home], semantic_views.uninstall(self.ctx))
        self.assertFalse(home.exists())
        self.assertIsNone(self.manifest.get("components.semantic_views"))

    def test_json_tables_keeps_its_module_and_removes_its_files(self) -> None:
        venv = json_tables.paths(self.ctx)[0]
        venv.mkdir(parents=True)
        self.manifest.set_many({"components.json_tables": {"ownership": "kit", "version": "v0.4.1"},
                                "components.preprocessor.modules.json-tables.version": 1})
        with patch.object(json_tables.preprocessor_modules, "retire", side_effect=NOT_IN_THE_DATABASE):
            self.assertEqual([venv], json_tables.uninstall(self.ctx, dry_run=True))
            json_tables.uninstall(self.ctx)
        self.assertFalse(venv.exists())
        self.assertIsNone(self.manifest.get("components.json_tables"))

    def test_the_scheduler_keeps_its_schema_and_login_and_still_stops_and_removes_its_files(self) -> None:
        self.manifest.set_many({"components.exasol_scheduler": {"ownership": "kit", "db_user": "scheduler_svc",
                                                                "schema": "SCHED"}})
        home, _, engine, _, credential = scheduler.paths(self.ctx)
        engine.parent.mkdir(parents=True)
        engine.write_text("engine")
        credential.parent.mkdir(parents=True, exist_ok=True)
        credential.write_text("private credential")
        with patch.object(scheduler, "_sql", side_effect=NOT_IN_THE_DATABASE), patch.object(scheduler, "stop") as stop:
            self.assertEqual(["the running scheduler service (it is stopped first)", home, credential],
                             scheduler.uninstall(self.ctx, dry_run=True))
            scheduler.uninstall(self.ctx)
        stop.assert_called_once_with(self.ctx)
        self.assertFalse(engine.exists())
        self.assertFalse(credential.exists())
        self.assertIsNone(self.manifest.get("components.exasol_scheduler"))

    def test_without_the_switch_the_removal_is_as_before(self) -> None:
        os.environ.pop(runtime.KEEP_DATABASE, None)
        self.manifest.set_many({"components.exasol_scheduler": {"ownership": "kit", "db_user": "scheduler_svc",
                                                                "schema": "SCHED"}})
        plan = scheduler.uninstall(self.ctx, dry_run=True)
        self.assertIn("the database user SCHEDULER_SVC (DROP USER); schema SCHED and its tasks stay, handed to sys", plan)
        queries = []
        with patch.object(scheduler, "_sql", side_effect=lambda _ctx, statement, **_: queries.append(statement) or ""), \
                patch.object(scheduler, "stop"):
            scheduler.uninstall(self.ctx)
        self.assertIn("DROP USER IF EXISTS SCHEDULER_SVC", queries)


if __name__ == "__main__":
    unittest.main()
