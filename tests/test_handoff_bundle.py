"""The hand-off bundle (exakit_nb.handoff_bundle): one folder and zip with the column map, the schema map, the distinct
queries of the workflow with their digests, the workflow log and a README that says how to repeat the work; a
``handoff`` line in the log; nothing when there is no workflow but the column map."""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import types
import unittest
import zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
import importlib  # noqa: E402

import exakit_nb  # noqa: E402
wf = importlib.import_module("exakit_nb.workflow")          # exakit_nb.workflow is also the function that starts one
_kit = importlib.import_module("exakit_nb._kit")


def dataset(home: Path) -> types.SimpleNamespace:
    store = home / "descriptors" / "SHOP.ORDERS"
    store.mkdir(parents=True)
    (store / "current.yaml").write_text("descriptor: 1\ndataset: orders\n", encoding="utf-8")
    schema = home / "descriptors" / "SHOP"
    schema.mkdir()
    (schema / "current.json").write_text(json.dumps({"schema": "SHOP", "relations": []}), encoding="utf-8")
    descriptor = types.SimpleNamespace(slots={"key": "ORDER_ID", "time": "ORDERED_ON", "text": None, "target": "CANCELLED",
                                              "category": "CHANNEL", "entity": None})
    return types.SimpleNamespace(id="orders", fact_table="SHOP.ORDERS", version=2, status="approved", owner="dana",
                                 created="2026-11-08T09:00:00Z", descriptor=descriptor, descriptor_path=store / "current.yaml")


class HandoffBundleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        env = mock.patch.dict(os.environ, {"EXAKIT_HOME": str(self.home)}, clear=False)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("EXAKIT_WORKFLOW_ID", None)
        session = mock.patch.dict(_kit.SESSION, {}, clear=True)
        session.start()
        self.addCleanup(session.stop)
        self.ds = dataset(self.home)

    def test_the_bundle_holds_the_map_the_queries_the_log_and_a_readme(self):
        with contextlib.redirect_stdout(io.StringIO()):
            workflow_id = wf.workflow("test")
        conn = mock.Mock(**{"session_id.return_value": "7"})
        wf.log_sql(conn, "SELECT 1 FROM SHOP.ORDERS", 10, statement_id="1")
        wf.log_sql(conn, "SELECT 1 FROM SHOP.ORDERS", 10, statement_id="2")           # the same statement again
        wf.log_sql(conn, "SELECT 2 FROM SHOP.ORDERS", 3, statement_id="3")
        wf.log_event(wf.ASK_APPROVE, dataset="orders", question="How many per channel?", sql="SELECT 2")
        wf.log_event(wf.DASHBOARD_REVISION, app="orders-by-channel", revision=1, state="preview", preview_path="/preview/x/1")
        bundle = exakit_nb.handoff_bundle(conn, self.ds)
        self.assertEqual(self.home / "bundles" / workflow_id, bundle.path)
        self.assertEqual(["README.md", "descriptor.yaml", "schema-map.json", "queries.sql", "workflow.jsonl"], bundle.files)
        self.assertEqual((self.home / "bundles" / f"{workflow_id}.zip"), bundle.zip_path)
        with zipfile.ZipFile(bundle.zip_path) as archive:
            self.assertEqual({f"{workflow_id}/{name}" for name in bundle.files},
                             {name for name in archive.namelist() if not name.endswith("/")})
        queries = (bundle.path / "queries.sql").read_text(encoding="utf-8")
        self.assertEqual(2, queries.count("-- "), "the same statement is listed once")
        self.assertIn("SELECT 2 FROM SHOP.ORDERS;", queries)
        self.assertIn("sha256 ", queries)
        self.assertIn("10 rows", queries)
        readme = (bundle.path / "README.md").read_text(encoding="utf-8")
        self.assertIn("# Hand-off: orders", readme)
        self.assertIn("Column map: v2, approved, by dana, 2026-11-08T09:00:00Z.", readme)
        self.assertIn("| target | `CANCELLED` |", readme)
        self.assertIn("| entity | - |", readme)
        self.assertIn("2 distinct queries ran", readme)
        self.assertIn('1 question approved in Ask your data: "How many per channel?"', readme)
        self.assertIn("1 dashboard revision: orders-by-channel r1 (preview) at /preview/x/1", readme)
        self.assertIn(f"exakit workflow show {workflow_id}", readme)
        events = wf.read_log(workflow_id)
        self.assertEqual("handoff", events[-1]["kind"])
        self.assertEqual((str(bundle.path), True, "orders", 2), (events[-1]["path"], events[-1]["bundle"], events[-1]["descriptor_id"], events[-1]["version"]))
        self.assertIn("workflow.jsonl", (bundle.path / "workflow.jsonl").name)
        self.assertIn("2 distinct queries, the column map v2, the schema map, the workflow log.", str(bundle))
        self.assertIn("<code>queries.sql</code>", bundle._repr_html_())
        if os.name != "nt":
            self.assertEqual(0o700, bundle.path.stat().st_mode & 0o777)
            self.assertEqual(0o600, (bundle.path / "descriptor.yaml").stat().st_mode & 0o777)

    def test_without_a_workflow_the_bundle_is_the_column_map_and_says_so(self):
        bundle = exakit_nb.handoff_bundle(mock.Mock(), self.ds)
        self.assertEqual(self.home / "bundles" / "orders-v2", bundle.path)
        self.assertEqual(["README.md", "descriptor.yaml", "schema-map.json"], bundle.files)
        self.assertIn("No workflow was active or remembered: the bundle holds the column map only.", bundle.summary)
        self.assertIn("Workflow: none was active.", (bundle.path / "README.md").read_text(encoding="utf-8"))

    def test_a_bundle_is_written_again_whole_and_into_a_folder_of_choice(self):
        target = self.home / "elsewhere"
        first = exakit_nb.handoff_bundle(mock.Mock(), self.ds, folder=target, zip_it=False)
        (target / "stale.txt").write_text("old", encoding="utf-8")
        again = exakit_nb.handoff_bundle(mock.Mock(), self.ds, folder=target, zip_it=False)
        self.assertEqual((target, None), (again.path, again.zip_path))
        self.assertFalse((target / "stale.txt").exists(), "the folder is replaced whole")
        self.assertEqual(first.files, again.files)

    def test_a_dataset_without_a_map_file_is_bundled_with_a_note(self):
        self.ds.descriptor_path = None
        self.ds.fact_table = "NOWHERE.X"
        bundle = exakit_nb.handoff_bundle(mock.Mock(), self.ds, zip_it=False)
        self.assertEqual(["README.md"], bundle.files)
        self.assertTrue(any("No column-map file" in line for line in bundle.summary))


if __name__ == "__main__":
    unittest.main()
