"""(run: python3 tests/test_semantic_cli.py) exakit semantic and exakit board (setup/lib/semantic_cli.py): each action
reaches the notebook's own function with what was given, writes only when told to (--apply, --write,
--figures-checked), refuses with exit 2 and a reason, and answers one JSON object with --json. The database and Dash
Server are stand-ins."""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "setup" / "lib"), str(ROOT / "notebook" / "package")]

import semantic_cli as cli  # noqa: E402


def run(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = cli.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class SemanticTest(unittest.TestCase):
    def setUp(self):
        self.conn = mock.Mock()
        patch = mock.patch.object(cli.svc, "connect", return_value=self.conn)
        patch.start()
        self.addCleanup(patch.stop)

    def test_fuse_is_a_dry_run_until_apply(self):
        doc = {"entities": {"customers": {"representations": []}}}
        with mock.patch.object(cli.svc, "fusion_document", return_value=doc) as drawn, \
                mock.patch.object(cli.svc, "fuse", return_value={"status": "dry_run", "dry_run": True, "message": "", "document": None}) as fuse:
            code, out, _ = run("semantic", "fuse", "all_data", "--table", "MY_DATA.CUSTOMERS", "--same-as", "VS_CRM.CUSTOMERS",
                               "--key", "CUST_ID")
        self.assertEqual(0, code)
        drawn.assert_called_once_with(self.conn, "all_data", "MY_DATA.CUSTOMERS", "VS_CRM.CUSTOMERS", key="CUST_ID", wins="model")
        self.assertTrue(fuse.call_args.kwargs["dry_run"])
        self.assertIn("Apply it with --apply", out)
        with mock.patch.object(cli.svc, "fusion_document", return_value=doc), \
                mock.patch.object(cli.svc, "fuse", return_value={"status": "ok", "dry_run": False, "message": "", "document": doc}) as fuse:
            code, out, _ = run("semantic", "fuse", "all_data", "--table", "A.B", "--same-as", "C.D", "--apply", "--json")
        self.assertFalse(fuse.call_args.kwargs["dry_run"])
        self.assertEqual(doc, json.loads(out)["document"])
        code, _, err = run("semantic", "fuse", "all_data", "--table", "A.B", "--same-as", "C.D", "--wins", "both")
        self.assertEqual((2, True), (code, "--wins" in err))

    def test_compile_verify_and_restore_reach_the_service(self):
        with mock.patch.object(cli.svc, "compile_request", return_value={"status": "error", "sql": "", "error": "SEMANTIC_REQUEST_031: ambiguous",
                                                                          "clarification": {"choices": ["state"]}}) as compiled:
            code, out, _ = run("semantic", "compile", '{"model": "all_data", "metrics": ["total_amount"]}')
        self.assertEqual({"model": "all_data", "metrics": ["total_amount"]}, compiled.call_args.args[1])
        self.assertIn("Choices", out)
        code, _, err = run("semantic", "compile", "not json")
        self.assertEqual(2, code)
        self.assertIn("not JSON", err)
        with mock.patch.object(cli.svc, "verify_question", return_value={"verified": {}, "sql": "SELECT 1"}) as verified:
            code, _, _ = run("semantic", "verify", "all_data", "--object", "ORDERS", "--name", "Revenue", "--question", "Revenue?",
                             "--request", '{"metrics": ["total_amount"]}')
        self.assertEqual((0, ("all_data", "ORDERS", "Revenue", "Revenue?", {"metrics": ["total_amount"]})),
                         (code, verified.call_args.args[1:]))
        code, _, err = run("semantic", "verify", "all_data", "--name", "x", "--question", "q", "--request", "{}")
        self.assertEqual(2, code)
        self.assertIn("--object", err)
        with mock.patch.object(cli.svc, "restore_column_maps", return_value=[]) as restored:
            run("semantic", "restore-maps", "all_data")
            self.assertFalse(restored.call_args.kwargs["write"], "nothing written without --write")
            run("semantic", "restore-maps", "all_data", "--write")
            self.assertTrue(restored.call_args.kwargs["write"])

    def test_unknown_actions_and_options_are_refused_with_exit_2(self):
        self.assertEqual(2, run("semantic", "nope")[0])
        self.assertEqual(2, run("semantic", "fields", "all_data", "--nosuch")[0])
        self.assertEqual(2, run("semantic", "fields")[0])
        self.assertEqual(0, run("semantic", "--help")[0])


class BoardTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        env = mock.patch.dict(os.environ, {"EXAKIT_HOME": self.temp.name})
        env.start()
        self.addCleanup(env.stop)

    def test_pin_arrange_and_the_publish_gate(self):
        sql = "SELECT STATE, SUM(AMOUNT) AS REVENUE FROM SHOP.ORDERS GROUP BY 1"
        with mock.patch("exakit_nb.ask._execute_mcp", side_effect=RuntimeError("no MCP here")):
            code, out, err = run("board", "pin", "sales", "--page", "Revenue", "--question", "Revenue by state?", "--sql", sql,
                                 "--kind", "bar", "--json")
        self.assertEqual(0, code, err)
        tile = json.loads(out)
        self.assertEqual(("bar", sql), (tile["kind"], tile["sql"]))
        code, out, _ = run("board", "move", "sales", tile["id"], "Overview")
        self.assertIn("Overview", out)
        self.assertEqual(3, run("board", "remove", "sales", "nosuchid")[0])
        self.assertEqual(2, run("board", "kind", "sales", tile["id"], "pie")[0])
        code, _, err = run("board", "publish", "sales")
        self.assertEqual(2, code)
        self.assertIn("--figures-checked", err)
        code, _, err = run("board", "publish", "sales", "--figures-checked")
        self.assertEqual(2, code)
        self.assertIn("preview first", err.lower())
        code, out, _ = run("board", "list", "--json")
        self.assertEqual(["sales"], [b["name"] for b in json.loads(out)])

    def test_a_board_changed_since_its_preview_is_not_published(self):
        sql = "SELECT 1 AS N"
        with mock.patch("exakit_nb.ask._execute_mcp", side_effect=RuntimeError("no MCP here")):
            run("board", "pin", "sales", "--question", "One?", "--sql", sql, "--kind", "kpi")
        tools = types.SimpleNamespace(url="http://127.0.0.1:5100")
        import importlib
        share = importlib.import_module("exakit_nb.share")

        def preview(self, tool, *a, **k):
            self.revision_number, self.healthy = 7, True
            return "/preview/sales/7"
        with mock.patch("exakit_nb.dash_mcp.dash_tools", return_value=tools), \
                mock.patch.object(share.ShareDraft, "preview", preview), mock.patch("sys.stdout", io.StringIO()):
            code = cli.main(["board", "preview", "sales"])
        self.assertEqual(0, code)
        with mock.patch("exakit_nb.ask._execute_mcp", side_effect=RuntimeError("no MCP here")):
            run("board", "pin", "sales", "--question", "Two?", "--sql", "SELECT 2 AS N", "--kind", "kpi")
        with mock.patch("exakit_nb.dash_mcp.dash_tools", return_value=tools):
            code, _, err = run("board", "publish", "sales", "--figures-checked")
        self.assertEqual(2, code)
        self.assertIn("changed since its preview", err)
        with mock.patch("exakit_nb.dash_mcp.dash_tools", return_value=tools), \
                mock.patch.object(share.ShareDraft, "preview", preview), mock.patch("sys.stdout", io.StringIO()):
            cli.main(["board", "preview", "sales"])
        with mock.patch("exakit_nb.dash_mcp.dash_tools", return_value=tools), \
                mock.patch.object(share.ShareDraft, "confirm", lambda self, tool, figures_checked=False: "/apps/sales") as confirm:
            code, out, err = run("board", "publish", "sales", "--figures-checked", "--json")
        self.assertEqual((0, "http://127.0.0.1:5100/apps/sales"), (code, json.loads(out)["live"]), err)


if __name__ == "__main__":
    unittest.main()
