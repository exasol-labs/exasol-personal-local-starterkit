"""Dash Server Share contract: approval, read-only profile, preview and promotion."""

import ast
import csv
import io
import json
import math
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "notebook/package"))
from exakit_nb.share import share
from exakit_nb.dash_mcp import dash_server_url
from exakit_nb.workflow import read_log, workflow


class Dataset:
    id = "example"
    version = 4
    fact_table = "EXAMPLE.FACT"
    approved = True

    def require_approved(self, purpose):
        if not self.approved:
            raise RuntimeError(f"Draft descriptor cannot {purpose}")


class Tools:
    def __init__(self, readonly_user="MCP_READONLY", healthy=True, changed_path=None, existing_lineage=None):
        self.calls = []
        self.readonly_user = readonly_user
        self.healthy = healthy
        self.changed_path = changed_path
        self.existing_lineage = existing_lineage

    def __call__(self, name, args):
        self.calls.append((name, args))
        if name == "exasol_profile_validate":
            return {"is_valid": True, "profile": {"user": self.readonly_user, "dsn": "127.0.0.1:8563"}}
        if name == "app_create_exasol_dashboard" and self.existing_lineage is not None:
            return {"isError": True, "structuredContent": {"error": {"category": "app_conflict"}}}
        if name == "app_read_file":
            return {"content": json.dumps(self.existing_lineage)}
        if name == "app_deploy_draft":
            return {"build": {"revision": {"revision_number": 3}}, "app": {"preview_path": "/preview/example/3"}}
        if name == "app_build":
            return {"revision": {"revision_number": 3}}
        if name == "app_start_preview":
            return {"app": {"preview_path": "/preview/example/3"}}
        if name == "app_run_healthcheck":
            return {"health": {"status": "healthy" if self.healthy else "degraded"}}
        if name == "app_diff_draft_vs_artifact":
            return {"files": [{"path": path, "status": "changed" if path == self.changed_path else "unchanged"} for path in
                    ("app.py", "assets/share.css", "queries/business/result.sql", "REVISION.json")]}
        if name == "app_promote_revision":
            return {"app": {"mounted": True, "route": "/apps/example"}}
        return {}


class ShareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        home = Path(self.temp.name)
        (home / "manifest.json").write_text(json.dumps({"runtime": {"dsn": "127.0.0.1:8563", "user": "SYS"},
            "components": {"mcp_server": {"connection": {"validated": True, "user": "MCP_READONLY"}}}}))
        self.env = patch.dict(os.environ, {"EXAKIT_HOME": str(home)}, clear=False)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.workflow_id = workflow("share-test")

    def test_preview_then_confirm(self):
        draft = share(Dataset(), "SELECT CATEGORY, COUNT(*) AS N FROM T GROUP BY 1", "Example", "example")
        tool = Tools()
        self.assertEqual(draft.preview(tool), "/preview/example/3")
        with self.assertRaisesRegex(RuntimeError, "verify the figures"):
            draft.confirm(tool)
        self.assertEqual(draft.confirm(tool, figures_checked=True), "/apps/example")
        self.assertEqual([name for name, _ in tool.calls], [
            "exasol_profile_validate", "app_create_exasol_dashboard", "app_put_files",
            "app_deploy_draft", "app_diff_draft_vs_artifact", "app_run_healthcheck",
            "app_promote_revision", "app_run_healthcheck"])
        files = dict((item["path"], item["content"]) for item in draft.files)
        self.assertIn("SELECT CATEGORY", files["queries/business/result.sql"])
        self.assertEqual(json.loads(files["REVISION.json"])["descriptor_version"], "4")
        self.assertNotIn("PASSWORD", files["app.py"])
        events = [event for event in read_log(self.workflow_id) if event["kind"] == "dashboard.revision"]
        self.assertEqual([event["state"] for event in events], ["preview", "live"])
        self.assertEqual(events[0]["sql"], draft.sql)
        self.assertEqual(events[0]["source_table"], "EXAMPLE.FACT")

    def test_existing_managed_dashboard_gets_a_new_draft(self):
        draft = share(Dataset(), "SELECT 1", "Example", "example")
        tool = Tools(existing_lineage={"workflow_id": "wf-old", "descriptor_id": "example",
                                       "descriptor_version": "3", "query_digest": "old-digest"})
        self.assertEqual(draft.preview(tool), "/preview/example/3")
        self.assertEqual([name for name, _ in tool.calls[:3]],
                         ["exasol_profile_validate", "app_create_exasol_dashboard", "app_read_file"])
        self.assertIn("app_put_files", [name for name, _ in tool.calls])

    def test_existing_unrelated_dashboard_is_left_alone(self):
        draft = share(Dataset(), "SELECT 1", "Example", "example")
        tool = Tools(existing_lineage={"workflow_id": "wf-old", "descriptor_id": "other",
                                       "descriptor_version": "3", "query_digest": "old-digest"})
        with self.assertRaisesRegex(RuntimeError, "different dataset"):
            draft.preview(tool)
        self.assertNotIn("app_put_files", [name for name, _ in tool.calls])

    def test_wrong_profile_refused_before_app_creation(self):
        draft = share(Dataset(), "SELECT 1", "Example", "example")
        tool = Tools(readonly_user="ADMIN")
        with self.assertRaisesRegex(RuntimeError, "read-only user"):
            draft.preview(tool)
        self.assertEqual(len(tool.calls), 1)

    def test_missing_or_admin_mcp_identity_refused_before_tool_call(self):
        draft = share(Dataset(), "SELECT 1", "Example", "example")
        path = Path(self.temp.name) / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["components"].pop("mcp_server")
        path.write_text(json.dumps(manifest))
        tool = Tools()
        with self.assertRaisesRegex(RuntimeError, "mcp-doctor"):
            draft.preview(tool)
        self.assertFalse(tool.calls)
        manifest["components"]["mcp_server"] = {"connection": {"validated": True, "user": "SYS"}}
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(RuntimeError, "mcp-doctor"):
            draft.preview(tool)
        self.assertFalse(tool.calls)

    def test_draft_or_write_sql_refused(self):
        dataset = Dataset()
        dataset.approved = False
        with self.assertRaisesRegex(RuntimeError, "Draft"):
            share(dataset, "SELECT 1", "Example", "example")
        dataset.approved = True
        with self.assertRaisesRegex(ValueError, "SELECT"):
            share(dataset, "DROP TABLE T", "Example", "example")

    def test_windows_uses_build_preview(self):
        draft = share(Dataset(), "SELECT 1", "Example", "example")
        tool = Tools()
        self.assertEqual(draft.preview(tool, windows=True), "/preview/example/3")
        names = [name for name, _ in tool.calls]
        self.assertIn("app_build", names)
        self.assertIn("app_start_preview", names)
        self.assertNotIn("app_deploy_draft", names)

    def test_unhealthy_preview_blocks_promotion(self):
        draft = share(Dataset(), "SELECT 1", "Example", "example")
        tool = Tools(healthy=False)
        with self.assertRaisesRegex(RuntimeError, "unhealthy"):
            draft.preview(tool)
        with self.assertRaisesRegex(RuntimeError, "healthy preview"):
            draft.confirm(tool, figures_checked=True)

    def test_failed_rebuild_cannot_reuse_an_earlier_preview_approval(self):
        draft = share(Dataset(), "SELECT 1", "Example", "example")
        draft.preview(Tools())
        tool = Tools(changed_path="assets/share.css")
        with self.assertRaisesRegex(RuntimeError, "lineage files"):
            draft.preview(tool)
        with self.assertRaisesRegex(RuntimeError, "healthy preview"):
            draft.confirm(tool, figures_checked=True)
        self.assertIsNone(draft.revision_number)
        self.assertNotIn("app_promote_revision", [name for name, _ in tool.calls])

    def test_changed_stylesheet_blocks_preview(self):
        draft = share(Dataset(), "SELECT 1", "Example", "example")
        with self.assertRaisesRegex(RuntimeError, "lineage files"):
            draft.preview(Tools(changed_path="assets/share.css"))

    def test_changed_lineage_file_blocks_preview(self):
        draft = share(Dataset(), "SELECT 1", "Example", "example")
        tool = Tools(changed_path="REVISION.json")
        with self.assertRaisesRegex(RuntimeError, "lineage files"):
            draft.preview(tool)
        self.assertNotIn("app_run_healthcheck", [name for name, _ in tool.calls])

    def test_dash_endpoint_comes_from_status_and_stays_local(self):
        class Result:
            stdout = '{"urls":{"dash-server":"http://127.0.0.1:5101"},"services":{"dash-server":"running"}}'
        with patch("exakit_nb.dash_mcp.subprocess.run", return_value=Result()):
            self.assertEqual(dash_server_url(), "http://127.0.0.1:5101")
            Result.stdout = '{"urls":{"dash-server":"http://127.0.0.1:5101"},"services":{"dash-server":"stopped"}}'
            with self.assertRaisesRegex(RuntimeError, "stopped"):
                dash_server_url()
            Result.stdout = '{"urls":{"dash-server":"https://remote.example"},"services":{"dash-server":"running"}}'
            with self.assertRaisesRegex(RuntimeError, "unexpected"):
                dash_server_url()





class ShareFilterTest(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[1] / "notebook/package/exakit_nb/share_template.py"
        from exakit_nb.share_template import APP_SOURCE
        tree = ast.parse(APP_SOURCE)
        functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in ("number", "category_key", "filtered_rows", "export_csv", "composition_series")]
        self.namespace = {"json": json, "math": math, "csv": csv, "io": io}
        exec(compile(ast.Module(body=functions, type_ignores=[]), str(path), "exec"), self.namespace)
        self.select = self.namespace["filtered_rows"]
        self.key = self.namespace["category_key"]
        self.rows = [{"CATEGORY": "A", "N": 4}, {"CATEGORY": "B", "N": 12}, {"CATEGORY": "C", "N": 7}]

    def test_filters_and_top_n_use_the_same_sorted_rows(self):
        selected = self.select(self.rows, [self.key("A"), self.key("C")], 1)
        self.assertEqual(selected, [{"CATEGORY": "C", "N": 7}])
        self.assertEqual(sum(row["N"] for row in selected), 7)
        self.assertEqual(self.select(self.rows, [], 1000), [self.rows[1], self.rows[2], self.rows[0]])
        self.assertEqual(self.rows[0]["CATEGORY"], "A")  # filter never mutates the source result

    def test_many_categories_keep_a_bounded_legend_and_the_same_total(self):
        labels=["C"+str(n) for n in range(50)]
        values=list(range(1,51))
        names,numbers,colors=self.namespace["composition_series"](labels,values,["blue"]*50)
        self.assertEqual(len(names),9)
        self.assertEqual(sum(numbers),sum(values))
        self.assertEqual(names[-1],"Other displayed categories")
        self.assertEqual(numbers[:8],list(range(50,42,-1)))

    def test_csv_export_neutralizes_formulas_without_changing_the_result(self):
        rows = [{"=header": "=1+1", "value": -2}, {"=header": " \t@SUM(A1:A2)", "value": "normal, text"}]
        text = self.namespace["export_csv"](rows)
        parsed = list(csv.reader(io.StringIO(text)))
        self.assertEqual(parsed[0][0], "'=header")
        self.assertEqual(parsed[1], ["'=1+1", "-2"])
        self.assertTrue(parsed[2][0].startswith("'"))
        self.assertEqual(parsed[2][1], "normal, text")
        self.assertEqual(rows[0]["=header"], "=1+1")
        for prefix in ("=", "+", "-", "@", "\t=", "\r+", "\ufeff@"):
            value=prefix+"formula"
            exported=self.namespace["export_csv"]([{"K":value}])
            self.assertEqual(list(csv.reader(io.StringIO(exported)))[1][0], "'"+value)

    def test_search_and_sort_are_shared_across_every_result_view(self):
        self.assertEqual(self.select(self.rows, [], 10, "c"), [self.rows[2]])
        self.assertEqual(self.select(self.rows, [], 1, None, "smallest"), [self.rows[0]])
        self.assertEqual(self.select(self.rows, [], 10, None, "category"), self.rows)

    def test_empty_missing_and_non_numeric_categories(self):
        self.assertEqual(self.select([], None, 10), [])
        self.assertEqual(self.select(self.rows, [self.key("absent")], 10), [])
        rows = [{"K": None, "V": "text"}, {"K": "(missing)", "V": "other"}]
        self.assertEqual(self.select(rows, [self.key(None)], 10), [rows[0]])

    def test_template_substitution_preserves_unusual_titles_as_data(self):
        from exakit_nb.share import _app_source
        title = "A LINEAGE = {} and TITLE = '' title"
        source = _app_source(title, {"descriptor_version": "1", "measure": "count"})
        tree = ast.parse(source)
        values = {n.targets[0].id: ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                  and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("TITLE", "LINEAGE")}
        self.assertEqual(values["TITLE"], title)
        self.assertEqual(values["LINEAGE"]["measure"], "count")

if __name__ == "__main__":
    unittest.main()
