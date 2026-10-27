"""exakit_nb.workflow: the workflow id and its log (X-1).

    python3 -m unittest tests.test_workflow

What it pins: the id's shape and that a new one is a start line in a 0600 file in a 0700 folder; the id reaches the
session store and EXAKIT_WORKFLOW_ID (so a child process inherits it); resume continues an existing log and refuses a
bad id or a log that is not there, naming the path; a line's shape; a credential-shaped payload is refused, so the
log never holds one; nothing is written without a workflow; read/list; a log that cannot be written warns and does
not raise; log_sql takes the session and statement ids from the connection; the module's command line.
No database, no kit home: EXAKIT_HOME is a temporary folder.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
import warnings
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "notebook" / "package"
sys.path.insert(0, str(PACKAGE))

from exakit_nb import _kit  # noqa: E402
import importlib  # noqa: E402
wf = importlib.import_module("exakit_nb.workflow")  # the package exports workflow() the function under the module's name

ID = re.compile(r"^wf-\d{8}-[0-9a-f]{6}$")


class FakeResult:
    def __init__(self, value):
        self._value = value

    def fetchval(self):
        return self._value


class FakeConnection:
    """session_id() as pyexasol has it; CURRENT_STATEMENT answers with a fixed number."""

    def __init__(self, current_statement=42):
        self.statements = []
        self.current_statement = current_statement

    def session_id(self):
        return 1234567890

    def execute(self, statement, params=None):
        self.statements.append(statement)
        return FakeResult(self.current_statement)


class WorkflowCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / "kit"
        self.env = mock.patch.dict(os.environ, {"EXAKIT_HOME": str(self.home)})
        self.env.start()
        os.environ.pop(wf.ENV_VARIABLE, None)
        _kit.SESSION.clear()

    def tearDown(self):
        self.env.stop()
        _kit.SESSION.clear()
        self.tmp.cleanup()

    def start(self, name="t"):
        with redirect_stdout(io.StringIO()) as out:
            wid = wf.workflow(name)
        return wid, out.getvalue()


class TestId(WorkflowCase):
    def test_format_and_printed_line(self):
        wid, out = self.start("churn")
        self.assertRegex(wid, ID)
        self.assertEqual(out.strip(), f"Workflow {wid}: log {wf.log_path(wid)}")

    def test_two_starts_differ(self):
        self.assertNotEqual(self.start()[0], self.start()[0])

    def test_session_and_env(self):
        wid, _ = self.start()
        self.assertEqual(wf.current_workflow(), wid)
        self.assertEqual(os.environ[wf.ENV_VARIABLE], wid)
        self.assertEqual(_kit.recall(wf.SESSION_KEY), wid)

    def test_child_process_inherits_the_id(self):
        wid, _ = self.start()
        child = subprocess.run([sys.executable, "-c", "import os; print(os.environ['EXAKIT_WORKFLOW_ID'])"],
                               capture_output=True, text=True, check=True)
        self.assertEqual(child.stdout.strip(), wid)

    def test_current_from_env_alone(self):
        os.environ[wf.ENV_VARIABLE] = "wf-20260101-abcdef"
        self.assertEqual(wf.current_workflow(), "wf-20260101-abcdef")
        os.environ[wf.ENV_VARIABLE] = "not-an-id"
        self.assertIsNone(wf.current_workflow())

    def test_no_workflow(self):
        self.assertIsNone(wf.current_workflow())


class TestStartLine(WorkflowCase):
    def test_start_event(self):
        wid, _ = self.start("churn")
        events = wf.read_log(wid)
        self.assertEqual(len(events), 1)
        first = events[0]
        self.assertEqual(first["kind"], wf.START)
        self.assertEqual(first["workflow_id"], wid)
        self.assertEqual(first["name"], "churn")
        self.assertRegex(first["ts"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        self.assertIn("python", first)
        self.assertIn("platform", first)
        self.assertIsNone(first["kit_version"])

    def test_kit_version_from_manifest(self):
        self.home.mkdir(parents=True)
        (self.home / "manifest.json").write_text(json.dumps({"kit": {"version": "0.5.0"}}), encoding="utf-8")
        wid, _ = self.start()
        self.assertEqual(wf.read_log(wid)[0]["kit_version"], "0.5.0")

    def test_kit_version_from_broken_manifest(self):
        self.home.mkdir(parents=True)
        (self.home / "manifest.json").write_text("{not json", encoding="utf-8")
        wid, _ = self.start()
        self.assertIsNone(wf.read_log(wid)[0]["kit_version"])

    @unittest.skipIf(os.name == "nt", "POSIX permissions")
    def test_permissions(self):
        wid, _ = self.start()
        self.assertEqual(os.stat(wf.workflows_dir()).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(wf.log_path(wid)).st_mode & 0o777, 0o600)


class TestResume(WorkflowCase):
    def test_resume_continues_the_log(self):
        wid, _ = self.start("one")
        _kit.SESSION.clear()
        os.environ.pop(wf.ENV_VARIABLE)
        with redirect_stdout(io.StringIO()) as out:
            self.assertEqual(wf.workflow(resume=wid), wid)
        self.assertIn(f"Workflow {wid}", out.getvalue())
        self.assertEqual(wf.current_workflow(), wid)
        wf.log_event(wf.TRACE, trace_id="t1")
        kinds = [event["kind"] for event in wf.read_log(wid)]
        self.assertEqual(kinds, [wf.START, wf.TRACE])         # no second start line

    def test_resume_bad_format(self):
        with self.assertRaisesRegex(ValueError, "Not a workflow id"):
            wf.workflow(resume="wf-2026-xyz")
        self.assertIsNone(wf.current_workflow())

    def test_resume_missing_log_names_the_path(self):
        with self.assertRaisesRegex(ValueError, re.escape(str(wf.log_path("wf-20260101-abcdef")))):
            wf.workflow(resume="wf-20260101-abcdef")
        self.assertFalse(wf.log_path("wf-20260101-abcdef").exists())


class TestLogEvent(WorkflowCase):
    def test_line_shape(self):
        wid, _ = self.start()
        wf.log_event(wf.MLFLOW_RUN, run_id="r1", experiment="exp", nested={"a": [1, 2]})
        raw = wf.log_path(wid).read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(raw), 2)
        line = json.loads(raw[1])
        self.assertEqual(list(line)[:3], ["ts", "workflow_id", "kind"])
        self.assertEqual(line["workflow_id"], wid)
        self.assertEqual(line["kind"], wf.MLFLOW_RUN)
        self.assertEqual(line["run_id"], "r1")
        self.assertEqual(line["nested"], {"a": [1, 2]})

    def test_noop_without_workflow(self):
        wf.log_event(wf.SQL, sql="SELECT 1")
        wf.log_sql(FakeConnection(), "SELECT 1", 1)
        self.assertFalse(wf.workflows_dir().exists())

    def test_secret_keys_refused(self):
        wid, _ = self.start()
        for key in ("password", "PASSWORD", "token", "Secret", "api_key", "db_password", "langfuse_secret_key"):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "never holds a credential"):
                wf.log_event(wf.TRACE, **{key: "x"})
        self.assertEqual(len(wf.read_log(wid)), 1)

    def test_dsn_with_password_refused(self):
        wid, _ = self.start()
        for value in ("exa+websocket://sys:exasol@127.0.0.1:8563", {"inner": "https://u:p@host"}, ["x", "a://u:p@h/"]):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "DSN with a password"):
                wf.log_event(wf.HANDOFF, where=value)
        wf.log_event(wf.HANDOFF, where="exa+websocket://127.0.0.1:8563", note="user:pass@ without a scheme is text")
        self.assertEqual(len(wf.read_log(wid)), 2)

    def test_credential_sql_is_not_logged(self):
        wid, _ = self.start()
        for statement in ("CREATE USER X IDENTIFIED BY 'secret'", "SELECT PASSWORD FROM T",
                          "SELECT API_KEY FROM CONFIG"):
            with self.subTest(statement=statement), self.assertRaisesRegex(ValueError, "credential-bearing SQL"):
                wf.log_event(wf.SQL, sql=statement)
        self.assertEqual(len(wf.read_log(wid)), 1)

    def test_unwritable_log_warns(self):
        wid, _ = self.start()
        with mock.patch("exakit_nb.workflow.os.open", side_effect=OSError(28, "No space left on device")):
            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always")
                wf.log_event(wf.TRACE, trace_id="t")
        self.assertEqual(len(caught), 1)
        self.assertIn("No space left", str(caught[0].message))
        self.assertEqual(len(wf.read_log(wid)), 1)

    def test_kinds(self):
        self.assertEqual(wf.KINDS, ("start", "describe.draft", "describe.approve", "sql", "trace", "mlflow.run",
                                    "handoff", "dashboard.revision", "model.put", "ask.approve", "ask.answer"))


class TestLogSql(WorkflowCase):
    def test_session_and_statement_ids(self):
        wid, _ = self.start()
        conn = FakeConnection(current_statement=42)
        wf.log_sql(conn, "SELECT * FROM T", 7)
        event = wf.read_log(wid)[1]
        self.assertEqual(event["kind"], wf.SQL)
        self.assertEqual(event["session_id"], "1234567890")
        self.assertEqual(event["statement_id"], "41")             # the one before the lookup's own
        self.assertEqual(event["rows"], 7)
        self.assertEqual(event["sql"], "SELECT * FROM T")
        self.assertEqual(event["sql_digest"], hashlib.sha256(b"SELECT * FROM T").hexdigest())
        self.assertEqual(conn.statements, ["SELECT CURRENT_STATEMENT"])

    def test_given_statement_id_skips_the_lookup(self):
        wid, _ = self.start()
        conn = FakeConnection()
        wf.log_sql(conn, "SELECT 1", 1, statement_id="9")
        self.assertEqual(wf.read_log(wid)[1]["statement_id"], "9")
        self.assertEqual(conn.statements, [])

    def test_lookup_failure_is_not_fatal(self):
        wid, _ = self.start()

        class Broken(FakeConnection):
            def execute(self, statement, params=None):
                raise RuntimeError("closed")

        wf.log_sql(Broken(), "SELECT 1", None)
        self.assertIsNone(wf.read_log(wid)[1]["statement_id"])


class TestReadList(WorkflowCase):
    def test_list_empty(self):
        self.assertEqual(wf.list_workflows(), [])

    def test_list_and_read(self):
        a, _ = self.start("first")
        wf.log_event(wf.TRACE, trace_id="t")
        _kit.SESSION.clear()
        b, _ = self.start("second")
        rows = wf.list_workflows()
        self.assertEqual([row["id"] for row in rows], sorted([a, b]))
        by_id = {row["id"]: row for row in rows}
        self.assertEqual(by_id[a]["name"], "first")
        self.assertEqual(by_id[a]["events"], 2)
        self.assertEqual(by_id[b]["events"], 1)
        self.assertLessEqual(by_id[a]["started"], by_id[a]["last"])
        self.assertEqual(wf.read_log(b)[0]["name"], "second")

    def test_read_missing(self):
        with self.assertRaises(FileNotFoundError):
            wf.read_log("wf-20260101-abcdef")
        with self.assertRaises(ValueError):
            wf.read_log("../etc/passwd")

    def test_list_skips_stray_files(self):
        wid, _ = self.start()
        (wf.workflows_dir() / "notes.jsonl").write_text("x", encoding="utf-8")
        (wf.workflows_dir() / "wf-20260101-abcdef.jsonl").write_text("{broken", encoding="utf-8")
        self.assertEqual([row["id"] for row in wf.list_workflows()], [wid])


class TestMain(WorkflowCase):
    def run_main(self, *args):
        with redirect_stdout(io.StringIO()) as out, redirect_stderr(io.StringIO()) as err:
            code = wf.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_list_table_and_json(self):
        code, out, _ = self.run_main("list")
        self.assertEqual((code, out.strip()), (0, "No workflows yet: start one in a notebook with nb.workflow('name')."))
        wid, _ = self.start("demo")
        code, out, _ = self.run_main("list")
        self.assertEqual(code, 0)
        self.assertIn(wid, out)
        self.assertIn("demo", out)
        code, out, _ = self.run_main("list", "--json")
        self.assertEqual(json.loads(out)[0]["id"], wid)

    def test_show(self):
        wid, _ = self.start("demo")
        wf.log_event(wf.SQL, sql="SELECT 1", rows=1)
        code, out, _ = self.run_main("show", wid)
        self.assertEqual(code, 0)
        self.assertIn("start", out)
        self.assertIn("sql=SELECT 1", out)
        code, out, _ = self.run_main("show", wid, "--json")
        self.assertEqual([event["kind"] for event in json.loads(out)], ["start", "sql"])

    def test_exit_codes(self):
        self.assertEqual(self.run_main()[0], 2)
        self.assertEqual(self.run_main("frobnicate")[0], 2)
        self.assertEqual(self.run_main("show")[0], 2)
        self.assertEqual(self.run_main("show", "nope")[0], 2)
        self.assertEqual(self.run_main("list", "--bogus")[0], 2)
        code, _, err = self.run_main("show", "wf-20260101-abcdef")
        self.assertEqual(code, 1)
        self.assertIn("wf-20260101-abcdef", err)

    def test_as_a_module(self):
        wid, _ = self.start("demo")
        child = subprocess.run([sys.executable, "-m", "exakit_nb.workflow", "show", wid, "--json"],
                               capture_output=True, text=True, cwd=str(PACKAGE))
        self.assertEqual(child.returncode, 0, child.stderr)
        self.assertEqual(json.loads(child.stdout)[0]["workflow_id"], wid)


if __name__ == "__main__":
    unittest.main()
