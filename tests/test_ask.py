"""Approval gates SQL execution and the execution identity is never admin."""

import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook" / "package"))

from exakit_nb import ask as make_proposal  # noqa: E402
import importlib

ask_module = importlib.import_module("exakit_nb.ask")


class Descriptor:
    id = "sample"
    version = 1
    fact_table = "STARTER_KIT.SAMPLE"

    def __init__(self, approved=True):
        self.approved = approved

    def require_approved(self, purpose):
        if not self.approved:
            raise ValueError("descriptor is a Draft")

    def roles(self):
        return [("category", "CATEGORY")]


class AskTest(unittest.TestCase):
    def test_draft_never_runs(self):
        with self.assertRaisesRegex(ValueError, "Draft"):
            make_proposal(Descriptor(False), "How many?", "SELECT COUNT(*) FROM STARTER_KIT.SAMPLE")

    def test_approval_binds_exact_sql_and_audit_gate(self):
        statements = []
        class Frame(dict):
            def __init__(self, rows, columns):
                super().__init__({columns[i]: [row[i] for row in rows] for i in range(len(columns))})

            def __len__(self):
                return len(next(iter(self.values())))

        with mock.patch.dict(sys.modules, {"pandas": types.SimpleNamespace(DataFrame=Frame)}), \
                mock.patch.object(ask_module, "_execute_mcp",
                                  side_effect=lambda sql: statements.append(sql) or {"columns": ["N"], "rows": [[1]]}) as execute:
            proposal = make_proposal(Descriptor(), "How many?", "SELECT COUNT(*) AS N FROM STARTER_KIT.SAMPLE")
            self.assertEqual(statements, [])
            with self.assertRaisesRegex(RuntimeError, "not been approved"):
                proposal.run()
            execute.assert_not_called()
            proposal.approve()
            proposal.edit("SELECT 1 AS N")
            with self.assertRaisesRegex(RuntimeError, "not been approved"):
                proposal.run()
            proposal.approve()
            frame = proposal.run()
        self.assertEqual(statements, ["SELECT 1 AS N"])
        self.assertEqual(frame["N"][0], 1)

    def test_writes_and_multiple_statements_refused(self):
        for sql in ("INSERT INTO T VALUES (1)", "DROP TABLE T", "SELECT 1; DROP TABLE T"):
            with self.subTest(sql=sql), self.assertRaisesRegex(ValueError, "SELECT or WITH"):
                make_proposal(Descriptor(), "question", sql)

    def test_readonly_connection_refuses_admin_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            password = home / "mcp_readonly_password"
            password.write_text("unprinted-secret")
            manifest = {"runtime": {"user": "sys", "dsn": "127.0.0.1:8563"},
                        "components": {"mcp_server": {"connection": {"user": "sys", "password_file": str(password)}}}}
            (home / "manifest.json").write_text(json.dumps(manifest))
            with mock.patch.object(ask_module, "home", return_value=home):
                with self.assertRaisesRegex(RuntimeError, "read-only identity"):
                    ask_module._mcp_settings()

    def test_readonly_connection_uses_validated_mcp_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            password = home / "mcp_readonly_password"
            password.write_text("unprinted-secret")
            manifest = {"runtime": {"user": "sys", "dsn": "127.0.0.1:8563"},
                        "components": {"mcp_server": {"command": "uvx", "package": "exasol-mcp-server",
                                                       "version": "2.2.0", "connection": {
                            "user": "mcp_readonly", "password_file": str(password),
                            "default_schema": "STARTER_KIT", "validated": True}}}}
            (home / "manifest.json").write_text(json.dumps(manifest))
            with mock.patch.object(ask_module, "home", return_value=home):
                command, environment = ask_module._mcp_settings()
            self.assertEqual(command, ["uvx", "exasol-mcp-server@2.2.0"])
            self.assertEqual(environment["EXA_USER"], "mcp_readonly")
            self.assertEqual(environment["EXA_DSN"], "127.0.0.1:8563")
            self.assertEqual(environment["EXA_SSL_CERT_VALIDATION"], "no")

    def test_mcp_protocol_calls_read_query_tool_after_handshake(self):
        with tempfile.TemporaryDirectory() as temporary:
            stub = Path(temporary) / "mcp_stub.py"
            stub.write_text("""import json,sys
for line in sys.stdin:
    request=json.loads(line)
    if request.get('id') == 1:
        print(json.dumps({'jsonrpc':'2.0','id':1,'result':{'protocolVersion':'2024-11-05'}}),flush=True)
    elif request.get('id') == 2:
        assert request['params']['name']=='execute_exasol_query'
        assert request['params']['arguments']['query']=='SELECT 1'
        print(json.dumps({'jsonrpc':'2.0','id':2,'result':{'structuredContent':{'columns':['N'],'rows':[[1]]}}}),flush=True)
        break
""")
            with mock.patch.object(ask_module, "_mcp_settings", return_value=([sys.executable, str(stub)], {})):
                result = ask_module._execute_mcp("SELECT 1")
            self.assertEqual(result, {"columns": ["N"], "rows": [[1]]})


if __name__ == "__main__":
    unittest.main()
