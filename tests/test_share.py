"""Dash Server Share contract: approval, read-only profile, preview and promotion."""

import json
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
    def __init__(self, readonly_user="MCP_READONLY", healthy=True):
        self.calls = []
        self.readonly_user = readonly_user
        self.healthy = healthy

    def __call__(self, name, args):
        self.calls.append((name, args))
        if name == "exasol_profile_validate":
            return {"is_valid": True, "profile": {"user": self.readonly_user, "dsn": "127.0.0.1:8563"}}
        if name == "app_deploy_draft":
            return {"build": {"revision": {"revision_number": 3}}, "app": {"preview_path": "/preview/example/3"}}
        if name == "app_build":
            return {"revision": {"revision_number": 3}}
        if name == "app_start_preview":
            return {"app": {"preview_path": "/preview/example/3"}}
        if name == "app_run_healthcheck":
            return {"health": {"status": "healthy" if self.healthy else "degraded"}}
        if name == "app_promote_revision":
            return {"app": {"mounted": True, "route": "/apps/example"}}
        return {}


class ShareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        home = Path(self.temp.name)
        (home / "manifest.json").write_text(json.dumps({"runtime": {"dsn": "127.0.0.1:8563"},
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
            "app_deploy_draft", "app_run_healthcheck", "app_promote_revision", "app_run_healthcheck"])
        files = dict((item["path"], item["content"]) for item in draft.files)
        self.assertIn("SELECT CATEGORY", files["queries/business/result.sql"])
        self.assertEqual(json.loads(files["REVISION.json"])["descriptor_version"], "4")
        self.assertNotIn("PASSWORD", files["app.py"])
        events = [event for event in read_log(self.workflow_id) if event["kind"] == "dashboard.revision"]
        self.assertEqual([event["state"] for event in events], ["preview", "live"])
        self.assertEqual(events[0]["sql"], draft.sql)
        self.assertEqual(events[0]["source_table"], "EXAMPLE.FACT")

    def test_wrong_profile_refused_before_app_creation(self):
        draft = share(Dataset(), "SELECT 1", "Example", "example")
        tool = Tools(readonly_user="ADMIN")
        with self.assertRaisesRegex(RuntimeError, "read-only user"):
            draft.preview(tool)
        self.assertEqual(len(tool.calls), 1)

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

    def test_dash_endpoint_comes_from_status_and_stays_local(self):
        class Result:
            stdout = '{"urls":{"dash-server":"http://127.0.0.1:5101"}}'
        with patch("exakit_nb.dash_mcp.subprocess.run", return_value=Result()):
            self.assertEqual(dash_server_url(), "http://127.0.0.1:5101")
            Result.stdout = '{"urls":{"dash-server":"https://remote.example"}}'
            with self.assertRaisesRegex(RuntimeError, "unexpected"):
                dash_server_url()


if __name__ == "__main__":
    unittest.main()
