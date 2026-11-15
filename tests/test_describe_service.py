"""(run: python3 tests/test_describe_service.py) The service behind `exakit describe` on the role-per-column
descriptor (setup/lib/descriptor): draft, approve with the corrections the command line gives, show, versions and
republish through a stand-in database, the exit codes, and the content digest a training handoff records
(deterministic, order-independent, its SQL, the first rows only of a virtual table)."""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "setup" / "lib"), str(ROOT / "tools"), str(ROOT / "tests")]

import describe_service as svc  # noqa: E402
from descriptor import profile, store  # noqa: E402
from test_descriptor_flow import COLUMNS as TICKETS, Database, rows as ticket_rows  # noqa: E402


class FakeStatement:
    def __init__(self, rows: list[dict]):
        self._rows = rows

    def column_names(self):
        return list(self._rows[0].keys()) if self._rows else []

    def fetchall(self):
        return list(self._rows)


class FakeConn:
    """Answers the column list, COUNT(*) and the digest statement over rows held here (each row hashed the way the
    database would, over the columns the statement names, the first LIMIT rows when it has one). ``fetched`` counts
    the rows the digest read."""

    def __init__(self, columns: list[tuple[str, str]], rows: list[dict], virtual: bool = False):
        self.columns, self.rows, self.virtual = columns, rows, virtual
        self.statements: list[str] = []
        self.fetched = 0

    def execute(self, sql: str):
        self.statements.append(sql)
        if "EXA_ALL_COLUMNS" in sql:
            if "'NOPE'" in sql:
                return FakeStatement([])
            return FakeStatement([{"COLUMN_NAME": n, "COLUMN_TYPE": t, "COLUMN_ORDINAL_POSITION": i, "IS_VIRTUAL": int(self.virtual)}
                                  for i, (n, t) in enumerate(self.columns, 1)])
        if sql.startswith("SELECT COUNT(*) AS N, SUM(TO_NUMBER"):
            return FakeStatement([self._digest(sql)])
        return FakeStatement([{"N": len(self.rows)}])

    def _digest(self, sql: str) -> dict:
        names = re.findall(r'(?:CAST|TO_CHAR)\("((?:[^"]|"")+)"', sql)
        limit = re.search(r"LIMIT (\d+)\)\)$", sql)
        rows = self.rows[:int(limit.group(1))] if limit else self.rows
        self.fetched += len(rows)
        sums = [0] * svc.DIGEST_SLICES
        for r in rows:
            text = "\x1f".join(svc.NULL_MARK if r.get(n) is None else str(r[n]) for n in names)
            h = hashlib.sha256(text.encode("utf-8")).hexdigest()
            for i in range(svc.DIGEST_SLICES):
                sums[i] += int(h[12 * i:12 * i + 12], 16)
        return dict({"N": len(rows)}, **{f"S{i}": str(v) for i, v in enumerate(sums)})


class Profiles:
    COLUMNS = [("ID", "DECIMAL(9,0)"), ("NAME", "VARCHAR(100) UTF8"), ("KIND", "VARCHAR(20) UTF8"), ("TAKEN_ON", "DATE"),
               ("ALARM", "BOOLEAN"), ("NOTE", "VARCHAR(2000) UTF8"), ("EMPTY", "VARCHAR(10) UTF8"), ("SHAPE", "GEOMETRY")]

    @staticmethod
    def rows(n: int = 500) -> list[dict]:
        return [{"ID": i, "NAME": f"device {i % 60}", "KIND": ["gas", "water", "power"][i % 3], "TAKEN_ON": f"2024-{1 + i % 12:02d}-{1 + i % 28:02d}",
                 "ALARM": i % 4 == 0, "NOTE": ("the reading was taken on a quiet day and nothing stood out " * 5) + str(i),
                 "EMPTY": None, "SHAPE": "POINT(1 2)"} for i in range(n)]


class QuotedNames(unittest.TestCase):
    def test_identifiers_are_always_quoted(self):
        self.assertEqual(svc.quoted('order date'), '"order date"')
        self.assertEqual(svc.quoted('say "hi"'), '"say ""hi"""')
        self.assertEqual(svc.split_table("lab.readings"), ("LAB", "READINGS"))
        self.assertEqual(svc.split_table('"my schema"."order data"'), ("my schema", "order data"))
        for bad in ("READINGS", "A.B.C", "", 'LAB."unclosed', "LAB.1X"):
            with self.assertRaises(svc.Refused):
                svc.split_table(bad)


class Digest(unittest.TestCase):
    ROLES = {"entity": "NAME", "category": "KIND", "date": "TAKEN_ON", "label": "ALARM", "text": ["NOTE"]}

    def test_the_digest_is_deterministic_and_order_independent_and_sees_a_change(self):
        rows = Profiles.rows()
        first = svc.digest(FakeConn(Profiles.COLUMNS, rows), "LAB.READINGS", self.ROLES)
        again = svc.digest(FakeConn(Profiles.COLUMNS, rows), "lab.readings", self.ROLES)
        shuffled = svc.digest(FakeConn(Profiles.COLUMNS, list(reversed(rows))), "LAB.READINGS", self.ROLES)
        self.assertEqual(first["digest"], again["digest"])
        self.assertEqual(first["digest"], shuffled["digest"])
        self.assertRegex(first["digest"], r"^sha256:[0-9a-f]{64}$")
        self.assertEqual((first["scope"], first["rows"], first["hashed_rows"], first["statements"]), ("full", 500, 500, 2))
        changed = [dict(r) for r in rows]
        changed[7]["KIND"] = "steam"
        self.assertNotEqual(first["digest"], svc.digest(FakeConn(Profiles.COLUMNS, changed), "LAB.READINGS", self.ROLES)["digest"])
        self.assertNotEqual(first["digest"], svc.digest(FakeConn(Profiles.COLUMNS, rows[:-1]), "LAB.READINGS", self.ROLES)["digest"])
        other = svc.digest(FakeConn(Profiles.COLUMNS, rows), "LAB.READINGS", dict(self.ROLES, entity="ID"))
        self.assertNotEqual(first["digest"], other["digest"])                      # the role columns are part of it
        self.assertEqual(first["digest"], svc.digest(FakeConn(Profiles.COLUMNS, rows), "LAB.READINGS",
                                                     {r: {"table": "LAB.READINGS", "column": c} for r, c in self.ROLES.items() if r != "text"}
                                                     | {"text": [{"table": "LAB.READINGS", "column": "NOTE"}]})["digest"])

    def test_the_digest_sql(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
        sql = svc.digest(conn, "LAB.READINGS", self.ROLES)["sql"]
        self.assertTrue(sql.startswith("SELECT COUNT(*) AS N, SUM(TO_NUMBER(SUBSTR(H, 1, 12), 'XXXXXXXXXXXX')) AS S0, "))
        self.assertIn("SUM(TO_NUMBER(SUBSTR(H, 49, 12), 'XXXXXXXXXXXX')) AS S4 FROM (SELECT HASH_SHA256(", sql)
        self.assertIn('COALESCE(CAST("NAME" AS VARCHAR(2000000)), \'<null>\') || CHR(31) || COALESCE(CAST("KIND" AS VARCHAR(2000000)), \'<null>\') '
                      '|| CHR(31) || COALESCE(TO_CHAR("TAKEN_ON", \'YYYY-MM-DD\'), \'<null>\') || CHR(31) || COALESCE(CAST("ALARM" AS VARCHAR(2000000)), \'<null>\') '
                      '|| CHR(31) || COALESCE(CAST("NOTE" AS VARCHAR(2000000)), \'<null>\')) AS H FROM "LAB"."READINGS")', sql)
        self.assertNotIn("ORDER BY", sql)
        self.assertNotIn("RANDOM", sql)
        self.assertEqual(sum(1 for s in conn.statements if s.startswith("SELECT COUNT(*) AS N, SUM")), 1)
        ts = svc.digest_sql('"A"."B"', [{"column": "AT", "kind": "timestamp", "type": "TIMESTAMP"}])
        self.assertIn("TO_CHAR(\"AT\", 'YYYY-MM-DD HH24:MI:SS.FF6')", ts)

    def test_a_virtual_table_is_hashed_over_its_first_sample_rows(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows(2000), virtual=True)
        out = svc.digest(conn, "LAB.READINGS", self.ROLES, sample=300)
        self.assertEqual((out["scope"], out["rows"], out["hashed_rows"], out["sample"], out["statements"]), ("sample", 2000, 300, 300, 3))
        self.assertTrue(out["sql"].endswith('FROM (SELECT "NAME", "KIND", "TAKEN_ON", "ALARM", "NOTE" FROM "LAB"."READINGS" LIMIT 300))'))
        self.assertEqual(conn.fetched, 300)
        self.assertEqual(out["digest"], svc.digest(FakeConn(Profiles.COLUMNS, Profiles.rows(2000), virtual=True), "LAB.READINGS", self.ROLES, sample=300)["digest"])

    def test_a_role_column_the_table_lacks_is_refused_naming_the_role(self):
        with self.assertRaises(svc.Refused) as caught:
            svc.digest(FakeConn(Profiles.COLUMNS, Profiles.rows()), "LAB.READINGS", dict(self.ROLES, entity="NOPE"))
        self.assertIn("no column NOPE (the entity role)", str(caught.exception))
        with self.assertRaises(svc.NotFound):
            svc.digest(FakeConn(Profiles.COLUMNS, []), "LAB.NOPE", self.ROLES)
        with self.assertRaises(svc.Refused):
            svc.digest(FakeConn(Profiles.COLUMNS, Profiles.rows()), "LAB.READINGS", {})


class Database(Database):
    """The flow tests' stand-in, as a pyexasol-like connection: SELECTs answered, DDL recorded."""

    def execute(self, sql: str):                       # noqa: D102 - pyexasol's name
        if "FROM DUAL UNION ALL" in sql:                # exakit_nb.dataset's column check, answered in tuples as pyexasol does
            answered = [(sql.split("'")[1],)] + [(f"SUPPORT.TICKETS.{name}",) for name, _type in self.columns]
            return types.SimpleNamespace(fetchall=lambda: answered)
        if sql.startswith("SELECT DISTINCT CAST("):        # exakit_nb.dataset's look at the label's values
            return types.SimpleNamespace(fetchall=lambda: [("0",), ("1",)])
        if sql.lstrip().upper().startswith("SELECT"):
            return FakeStatement(self.run(sql))
        super().execute(sql)
        return FakeStatement([])

    def close(self):
        pass


class Service(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        env = mock.patch.dict(os.environ, {"EXAKIT_HOME": self.temp.name, "EXAKIT_MCP_READER": "MCP_READONLY",
                                           "EXAKIT_DESCRIPTOR_OWNER": "dana", "EXAKIT_NB_KIT": str(ROOT),
                                           "EXAKIT_NB_DATASETS": str(ROOT / "data" / "datasets")})
        env.start()
        self.addCleanup(env.stop)
        self.db = Database(TICKETS, ticket_rows())
        patcher = mock.patch.object(profile, "profile", side_effect=lambda conn, table, *, run=None:
                                    profile.profile_rows(self.db.columns, self.db.data, table))
        patcher.start()
        self.addCleanup(patcher.stop)
        connect = mock.patch.object(svc, "connect", return_value=self.db)
        connect.start()
        self.addCleanup(connect.stop)

    def run_main(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("sys.stdout", out), redirect_stderr(err):
            code = svc.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_draft_approve_show_and_versions_on_the_command_line(self):
        code, out, err = self.run_main("draft", "support.tickets", "--id", "support_tickets", "--json")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(("draft", "BODY"), (json.loads(out)["status"], json.loads(out)["doc"]["slots"]["text"]))
        code, out, err = self.run_main("approve", "support_tickets", "--role", "label=ESCALATED", "--json")
        result = json.loads(out)
        self.assertEqual((code, result["status"], result["version"], result["owner"]), (0, "approved", 1, "dana"))
        self.assertEqual("semantic model support (SEM_SUPPORT)", result["published"])
        self.assertIn('target: "ESCALATED"', store.current("SUPPORT.TICKETS"))
        code, out, _ = self.run_main("versions", "support_tickets", "--json")
        self.assertEqual([(1, "approved", "dana")], [(v["version"], v["status"], v["owner"]) for v in json.loads(out)])
        code, out, _ = self.run_main("show", "SUPPORT.TICKETS")
        self.assertTrue(out.startswith("descriptor: 1"))
        code, out, _ = self.run_main("comments", "support_tickets")
        self.assertEqual(0, code)
        self.assertTrue(out.startswith("Published semantic model support (SEM_SUPPORT): 1 views, 5 dimensions, 1 metrics"), out)

    def test_a_multi_source_model_its_ai_proposal_its_refresh_and_the_list(self):
        self.run_main("draft", "support.tickets", "--id", "support_tickets")
        self.run_main("approve", "support_tickets")
        code, out, err = self.run_main("model", "support_360", "--table", "support.tickets", "--dry-run", "--json")
        found = json.loads(out)
        self.assertEqual((0, "dry run", "SEM_SUPPORT_360"), (code, found["status"], found["published_schema"]))
        self.assertNotIn("support_360", self.db.sv.models, "a dry run writes nothing")
        answer = json.dumps({"model": "Support tickets by channel", "labels": {"opened_on": {"display": "Opened"}},
                             "metrics": [{"view": "TICKETS", "name": "ticket_total", "expression": "tickets_count * 1"},
                                         {"view": "TICKETS", "name": "bad", "expression": "SUM(body)"}]})
        with mock.patch.object(svc, "_chat", return_value=answer), \
                mock.patch.dict(os.environ, {"EXAKIT_MODEL_ID": "m", "EXAKIT_PROVIDER_BASE_URL": "http://127.0.0.1:1"}):
            code, out, err = self.run_main("model", "support_360", "--table", "SUPPORT.TICKETS", "--ai")
        self.assertEqual(0, code, err)
        self.assertIn("AI proposal refused: metric bad", out)
        model = self.db.sv.models["support_360"]
        self.assertTrue(model["description"].startswith("Support tickets by channel"))
        self.assertIn("DISPLAY ''Opened''\n", next(s for s in self.db.sent if "ALTER SEMANTIC VIEW support_360.TICKETS" in s))
        self.assertTrue(any("ADD OR REPLACE METRIC ticket_total" in d for d in model["definitions"]))
        code, out, _ = self.run_main("refresh", "support_360")
        self.assertEqual(0, code)
        self.assertTrue(out.startswith("Refreshed semantic model support_360 (SEM_SUPPORT_360)"), out)
        self.assertTrue(any("ticket_total" in d for d in self.db.sv.models["support_360"]["definitions"]),
                        "a refresh keeps the AI's accepted metrics")
        code, out, _ = self.run_main("models", "--json")
        self.assertEqual({"support", "support_360", "all_data"}, {m["model"] for m in json.loads(out)})
        self.assertTrue(all(m["kit"] and m["refreshable"] for m in json.loads(out)))
        self.assertEqual(3, self.run_main("refresh", "never_built")[0])

    def test_whole_schemas_go_into_a_model_and_only_backed_links_are_used(self):
        self.run_main("draft", "support.tickets", "--id", "support_tickets")
        self.run_main("approve", "support_tickets")
        high = {"from": "SUPPORT.TICKETS.CHANNEL", "to": "CRM.CHANNELS.NAME", "confidence": "high", "proposed_by": "values",
                "found": 3, "checked": 3, "share": 1.0, "key_evidence": "measured", "from_live": False, "to_live": False,
                "evidence_text": "3 of 3"}
        low = dict(high, **{"from": "SUPPORT.TICKETS.TICKET_ID", "to": "CRM.CASES.ID", "confidence": "low"})
        found = {"links": [high, low], "partial": [{"from": "SUPPORT.TICKETS.BODY", "to": "CRM.X.Y", "share": 0.6, "found": 3, "checked": 5}],
                 "schemas": ["SUPPORT", "CRM"], "checked": 2, "statements": 9, "not_checked": 0}
        with mock.patch.object(svc, "find_links", return_value=found) as finder, \
                mock.patch.object(svc.publishing, "approved_tables", side_effect=lambda schema, home=None: (
                    {"SUPPORT.TICKETS": svc.flow.load(store.current("SUPPORT.TICKETS"))} if schema == "SUPPORT" else {})):
            result = svc.semantic_model(self.db, "everything", [], schemas=["support"], dry_run=True, discover=True)
            self.assertFalse(finder.called, "one schema: nothing to link across")
            # two schemas: the search runs; the table of the other schema has no approved map, so no link can be used
            result = svc.semantic_model(self.db, "everything", ["SUPPORT.TICKETS"], schemas=["SUPPORT"], dry_run=True)
        self.assertEqual(("dry run", ["TICKETS"]), (result["status"], [o["name"] for o in result["spec"]["objects"]]))
        with self.assertRaises(svc.Refused):
            svc.semantic_model(self.db, "nothing", [], schemas=["CRM"], dry_run=True)
        text = svc.links_text(dict(found, ai=None, rejected=[{"from": "A.B.C", "to": "D.E.F", "why": "no"}]))
        self.assertIn("[high] 3 of 3", text)
        self.assertIn("[low]", text)
        self.assertIn("[partial] SUPPORT.TICKETS.BODY", text)
        self.assertIn("[rejected] A.B.C -> D.E.F", text)
        self.assertEqual(2, self.run_main("links", "SUPPORT")[0])           # two schemas at least

    def test_a_table_gets_a_description_and_a_link_given_as_a_dict_is_read(self):
        """table_notes says what a table is: the model keeps it as that entity's description. A link may be a dict as
        find_links returns it, with a note in a person's words; a link that does not name a column on both sides is
        refused before anything is built."""
        self.run_main("draft", "support.tickets", "--id", "support_tickets")
        self.run_main("approve", "support_tickets")
        result = svc.semantic_model(self.db, "desk", ["SUPPORT.TICKETS"], dry_run=True,
                                    table_notes={"support.tickets": "  One row per   support ticket. "})
        self.assertEqual(["One row per support ticket."], [e["description"] for e in result["spec"]["entities"]])
        with self.assertRaisesRegex(svc.Refused, "names SCHEMA.TABLE.COLUMN on both sides"):
            svc.semantic_model(self.db, "desk", ["SUPPORT.TICKETS"], [{"from": "SUPPORT.TICKETS", "to": "CRM.CHANNELS.NAME"}], dry_run=True)
        with self.assertRaisesRegex(svc.Refused, "at least two tables"):
            svc.find_links(self.db, [], tables=["SUPPORT.TICKETS"])

    def test_set_gives_a_column_a_role_and_a_bad_one_is_exit_2(self):
        self.run_main("draft", "support.tickets")
        code, out, _ = self.run_main("approve", "SUPPORT.TICKETS", "--set", "CHANNEL=identifier", "--role", "category=-", "--json")
        self.assertEqual((0, "identifier"), (code, json.loads(out) and svc.flow.load(store.current("SUPPORT.TICKETS"))["columns"]["CHANNEL"]["role"]))
        code, _, err = self.run_main("approve", "SUPPORT.TICKETS", "--set", "CHANNEL=ninth")
        self.assertEqual(2, code)
        self.assertIn("the roles are key, time", err)

    def test_exit_codes(self):
        self.assertEqual(2, self.run_main("draft")[0])
        self.assertEqual(2, self.run_main("draft", "A.B", "--bogus")[0])
        self.assertEqual(2, self.run_main("nope", "A.B")[0])
        self.assertEqual(3, self.run_main("show", "no_such_set")[0])
        self.assertEqual(3, self.run_main("approve", "OTHER.TABLE")[0])
        with mock.patch.object(svc, "connect", side_effect=svc.Unreachable("no settings; check with: exakit status")):
            code, _, err = self.run_main("draft", "support.tickets")
        self.assertEqual((4, True), (code, "exakit status" in err))

    def test_the_notebook_cell_describes_corrects_and_approves(self):
        sys.path.insert(0, str(ROOT / "notebook" / "package"))
        nb_describe = __import__("importlib").import_module("exakit_nb.describe")
        with redirect_stderr(io.StringIO()), mock.patch("sys.stdout", io.StringIO()) as out:
            d = nb_describe.describe("SUPPORT.TICKETS", conn=self.db, id="support_tickets")
            d.set(CHANNEL="identifier").slot(target="ESCALATED", category=None)
            with self.assertRaisesRegex(ValueError, "the roles are key, time, measure"):
                d.set(BODY="ninth")
            d.show()
            ds = d.approve(conn=self.db)
        self.assertIn("slots: key=TICKET_ID; time=OPENED_ON; text=BODY; target=ESCALATED", out.getvalue())
        self.assertIn("Published in Exasol Semantic Views as semantic model support (SEM_SUPPORT)", out.getvalue())
        self.assertEqual((ds.status, ds.version, ds.col("label"), ds.text_cols()), ("approved", 1, "ESCALATED", ["BODY"]))
        self.assertEqual("identifier", d.column_roles["CHANNEL"])
        again = nb_describe.describe("SUPPORT.TICKETS", conn=self.db)
        self.assertEqual(("approved", 1), (again.status, again.version))

    def test_a_shipped_dataset_is_reviewed_from_its_approved_roles_and_keeps_its_target(self):
        # The kit ships an approved descriptor whose target is set; the user's store is empty. The target is never
        # drafted, so a fresh draft approved as it stands would publish a version without it.
        self.run_main("draft", "support.tickets", "--id", "support_tickets")
        self.run_main("approve", "support_tickets", "--role", "target=ESCALATED")
        shipped = Path(self.temp.name) / "kit" / "data" / "datasets" / "support_tickets"
        shipped.mkdir(parents=True)
        (shipped / "descriptor.yaml").write_text(store.current("SUPPORT.TICKETS"), encoding="utf-8")
        fresh = tempfile.TemporaryDirectory()
        self.addCleanup(fresh.cleanup)
        stale = Path(fresh.name) / "descriptors" / "SUPPORT.TICKETS" / "draft.yaml"
        stale.parent.mkdir(parents=True)
        stale.write_text("an earlier draft without the target", encoding="utf-8")
        with mock.patch.dict(os.environ, {"EXAKIT_HOME": fresh.name}), \
             mock.patch.object(svc, "kit_root", return_value=Path(self.temp.name) / "kit"):
            code, out, _ = self.run_main("draft", "SUPPORT.TICKETS", "--json")
            found = json.loads(out)
            self.assertEqual((0, "approved", "ESCALATED"), (code, found["status"], found["doc"]["slots"]["target"]))
            self.assertFalse(stale.exists())
            code, out, _ = self.run_main("approve", "support_tickets", "--json")
            self.assertEqual((0, "unchanged"), (code, json.loads(out)["status"]))
            code, out, _ = self.run_main("approve", "support_tickets", "--role", "category=-", "--json")
            self.assertEqual((0, "approved", 2), (code, json.loads(out)["status"], json.loads(out)["version"]))
            self.assertIn('target: "ESCALATED"', store.current("SUPPORT.TICKETS"))
            self.assertIsNone(svc.adopt_shipped("SUPPORT.TICKETS"))          # once only: the store is the user's now

    def test_help_is_exit_0(self):
        code, out, _ = self.run_main("--help")
        self.assertEqual(0, code)
        self.assertIn("approve <dataset id", out)


class SemanticSurfaces(unittest.TestCase):
    """Structured requests, verified questions and fusion, through the product's own scripts (a stand-in answers)."""

    class Conn:
        def __init__(self, answers):
            self.answers, self.sent = answers, []

        def execute(self, sql):
            self.sent.append(sql)
            for marker, rows in self.answers.items():
                if marker in sql:
                    return FakeStatement(rows(sql) if callable(rows) else rows)
            return FakeStatement([])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        env = mock.patch.dict(os.environ, {"EXAKIT_HOME": self.temp.name})
        env.start()
        self.addCleanup(env.stop)

    def test_a_request_compiles_to_sql_or_comes_back_with_the_products_reason(self):
        ok = self.Conn({"COMPILE_REQUEST_JSON": [{"STATUS": "OK", "GENERATED_SQL": "SELECT\n 1", "PLAN_JSON": '{"joins": []}',
                                                  "CLARIFICATION_JSON": None, "AGENT_REQUEST_ID": 7}]})
        found = svc.compile_request(ok, {"model": "sales", "object": "ORDERS", "metrics": ["total_amount"]})
        self.assertEqual(("ok", "SELECT 1", {"joins": []}, 7), (found["status"], found["sql"], found["plan"], found["request_id"]))
        self.assertIn('"client": "exakit-notebook"', ok.sent[0])
        bad = self.Conn({"COMPILE_REQUEST_JSON": [{"STATUS": "ERROR", "ERROR_CODE": "SEMANTIC_REQUEST_020",
                                                   "ERROR_MESSAGE": "unknown metric x", "CLARIFICATION_JSON": '{"choices": ["a"]}'}]})
        found = svc.compile_request(bad, {"model": "sales", "metrics": ["x"]})
        self.assertEqual(("error", {"choices": ["a"]}), (found["status"], found["clarification"]))
        self.assertIn("SEMANTIC_REQUEST_020", found["error"])
        with self.assertRaises(svc.Refused):
            svc.compile_request(ok, {"model": "sales"})

    def test_a_view_you_wrote_is_adopted_and_a_refusal_says_why(self):
        view = [{"VIEW_SCHEMA": "MART_SEMANTIC", "VIEW_NAME": "SHIPPING",
                 "VIEW_TEXT": "CREATE VIEW SHIPPING AS SELECT ship_mode, SUM(freight) AS freight FROM MART.ORDERS GROUP BY 1"}]
        conn = self.Conn({"EXA_ALL_SCRIPTS": [{"SCRIPT_NAME": "ADOPT_VIEW"}], "EXA_ALL_VIEWS": view, "ADOPT_VIEW": [{"MODEL_NAME": "logistics", "OBJECT_NAME": "SHIPPING", "DIMENSIONS": 1,
                                                                  "METRICS": 1, "STATUS": "PUBLISHED", "DDL": "CREATE_MODEL;\nPUBLISH"}]})
        planned = svc.adopt_view(conn, "Logistics", "mart_semantic.shipping", dry_run=True)
        self.assertEqual(("dry_run", "EXECUTE SCRIPT SEMANTIC_ADMIN.ADOPT_VIEW('logistics', 'MART_SEMANTIC', 'SHIPPING')"),
                         (planned["status"], planned["sql"]))
        self.assertFalse(any("EXECUTE SCRIPT SEMANTIC_ADMIN.ADOPT_VIEW" in sql for sql in conn.sent), "a dry run reads the view only")
        self.assertIn("SUM(freight)", planned["view_sql"])
        found = svc.adopt_view(conn, "logistics", "MART_SEMANTIC.SHIPPING")
        self.assertEqual(("logistics", "SHIPPING", 1, 1, "published", ["CREATE_MODEL", "PUBLISH"]),
                         (found["model"], found["object"], found["dimensions"], found["metrics"], found["status"], found["ddl"]))

        class Refusing(self.Conn):
            def execute(self, sql):
                if "ADOPT_VIEW" in sql:
                    raise RuntimeError("[SEMANTIC_ADMIN_229] the view has a join")
                return super().execute(sql)
        with self.assertRaisesRegex(svc.Refused, "another shape.*SEMANTIC_ADMIN_229"):
            svc.adopt_view(Refusing({"EXA_ALL_SCRIPTS": [{"SCRIPT_NAME": "ADOPT_VIEW"}], "EXA_ALL_VIEWS": view}), "logistics", "MART_SEMANTIC.SHIPPING")
        with self.assertRaisesRegex(svc.Refused, "arrives with Semantic Views 0.7.1"):
            svc.adopt_view(self.Conn({"EXA_ALL_VIEWS": view, "PRODUCT_VERSION": [{"DISPLAY_VERSION": "0.6.1"}]}), "logistics", "MART_SEMANTIC.SHIPPING")
        with self.assertRaises(svc.NotFound):
            svc.adopt_view(self.Conn({}), "logistics", "MART_SEMANTIC.NOPE")
        with self.assertRaisesRegex(svc.Refused, "SCHEMA.VIEW"):
            svc.adopt_view(conn, "logistics", "SHIPPING")
        from descriptor import publish
        publish.keep({"model": "sales"}, {"tables": []})
        with self.assertRaisesRegex(svc.Refused, "column maps"):
            svc.adopt_view(conn, "sales", "MART_SEMANTIC.SHIPPING")

    def test_validation_explanation_and_glossary_are_semantic_views_own_words(self):
        conn = self.Conn({"VALIDATE_MODEL": [{"SEVERITY": "error", "OBJECT_TYPE": "METRIC", "OBJECT_NAME": "x", "RULE_CODE": "SEMANTIC_MODEL_076",
                                              "MESSAGE": "declares  DECIMAL"}],
                          "CHECK_METRIC_TYPES": [{"OBJECT_NAME": "ORDERS", "METRIC_NAME": "x", "DECLARED_TYPE": "DECIMAL(18,2)",
                                                  "COMPILED_TYPE": "DOUBLE", "COMPATIBLE": False, "PROBE_ERROR": None},
                                                 {"OBJECT_NAME": "ORDERS", "METRIC_NAME": "y", "COMPATIBLE": True}],
                          "SUGGEST_GRAIN_METADATA": [],
                          "COMPILE_REQUEST_JSON": [{"STATUS": "OK", "GENERATED_SQL": "SELECT 1 FROM S.T", "AGENT_REQUEST_ID": 42}],
                          "EXPLAIN_COMPILED_SQL": [{"GOVERNANCE": "Certified model.\nRow policy: none.", "SELECTED_MATERIALIZATION": None}],
                          "GET_BUSINESS_GLOSSARY": [{"GLOSSARY_TEXT": "total_amount: revenue incl. tax"}]})
        found = svc.validate_model(conn, "Sales")
        self.assertEqual((1, "SEMANTIC_MODEL_076", "declares DECIMAL", ["x"]),
                         (found["errors"], found["issues"][0]["rule"], found["issues"][0]["message"], [t["metric"] for t in found["types"]]))
        self.assertIn("ALTER SESSION SET QUERY_TIMEOUT=60", conn.sent, "the product's data probes are bounded")
        compiled = svc.compile_request(conn, {"model": "sales", "object": "ORDERS", "metrics": ["m"]})
        self.assertEqual(["Semantic Views: Certified model.", "Semantic Views: Row policy: none.", "Reads S.T."], compiled["explained"],
                         "the product's own words first")
        self.assertIn("EXPLAIN_COMPILED_SQL('AGENT_REQUEST', 42)", " ".join(conn.sent))
        self.assertEqual("total_amount: revenue incl. tax", svc.glossary(conn, "sales", "orders"))
        self.assertEqual("", svc.glossary(self.Conn({}), "sales", "orders"))

    def test_a_new_computer_reads_the_data_map_back_from_the_model_and_restores_a_version(self):
        from descriptor import publish
        record = {"version": 3, "inputs": {"all": True, "tables": ["SHOP.ORDERS"], "grains": {"SHOP.ORDERS": "one order"},
                                           "links": [], "metrics": [], "instructions": ["Tax included."]}}
        conn = self.Conn({"GET_CUSTOM_EXTENSIONS": [{"SCOPE_TYPE": "MODEL", "EXTENSION_NAME": "data_map_v3", "DATA_JSON": json.dumps(record)}]})
        with mock.patch.object(publish, "data_map_inputs", side_effect=lambda t, m: {"tables": {}, "missing": [], "saved": publish.kept(m) is not None}), \
                mock.patch.object(svc, "restore_column_maps") as maps:
            found = svc.data_map_inputs(["shop.orders"], "all_data", conn)
        maps.assert_not_called()
        self.assertTrue(found["saved"], "put back from the model, which is the record")
        self.assertEqual((3, ["Tax included."]), (publish.kept("all_data")["version"], publish.kept("all_data")["inputs"]["instructions"]))
        self.assertEqual([3], [v["version"] for v in svc.data_map_versions(conn)])
        with mock.patch.object(svc, "semantic_model", return_value={"version": 4}) as saved:
            self.assertEqual({"version": 4}, svc.restore_data_map(conn, 3))
        self.assertEqual(({"SHOP.ORDERS": "one order"}, ["Tax included."], True),
                         (saved.call_args.kwargs["grains"], saved.call_args.kwargs["instructions"], saved.call_args.kwargs["replace_links"]))
        with self.assertRaises(svc.NotFound):
            svc.restore_data_map(conn, 9)

    def test_allowed_combinations_are_semantic_views_own(self):
        conn = self.Conn({"VALID_COMBINATIONS_FOR_AGENT": [{"METRIC_NAME": "m", "DIMENSION_NAME": "d", "IS_VALID": False, "REASON_CODE": "FANOUT"}]})
        self.assertEqual([{"metric": "m", "dimension": "d", "valid": False, "reason": "FANOUT"}],
                         svc.valid_combinations(conn, "sales", "orders", ["m"]))
        self.assertIn("METRIC_NAME IN ('m')", conn.sent[-1])
        self.assertEqual([], svc.valid_combinations(self.Conn({}), "sales", "orders"))

    def test_the_request_format_and_definition_hashes_are_semantic_views_own(self):
        conn = self.Conn({"COMPILE_REQUEST_SCHEMA_FOR_AGENT": [{"CONTRACT_SECTION": "REQUEST_KEY", "NAME": "limit", "DESCRIPTION": "rows",
                                                                "IS_REQUIRED": False, "VALUE_TYPE": "integer", "ALLOWED_VALUES": None}],
                          "DEFINITION_HASHES_FOR_AGENT": [{"FIELD_KIND": "MODEL", "FIELD_NAME": None, "DEFINITION_HASH": "a"},
                                                          {"FIELD_KIND": "metric", "FIELD_NAME": "total_amount", "DEFINITION_HASH": "b"}]})
        self.assertEqual([{"section": "REQUEST_KEY", "name": "limit", "about": "rows", "required": False, "type": "integer"}],
                         svc.request_contract(conn))
        self.assertEqual({"MODEL": "a", "METRIC:total_amount": "b"}, svc.definition_hashes(conn, "sales"))
        self.assertEqual(({}, []), (svc.definition_hashes(self.Conn({}), "sales"), svc.request_contract(self.Conn({}))))

    def test_fusion_health_and_feedback_are_semantic_views_own(self):
        conn = self.Conn({"CHECK_FUSION_HEALTH": [{"ENTITY_NAME": "customers", "ATTRIBUTE_NAME": "region", "FUSION_STRATEGY": "COALESCE",
                                                   "TOTAL_KEYS": 10, "FROM_FIRST_SOURCE": 8, "FILLED": 1, "UNRESOLVED": 1}]})
        self.assertEqual([("region", 1)], [(h["attribute"], h["unresolved"]) for h in svc.fusion_health(conn, "crm")])
        self.assertTrue(svc.record_feedback(conn, 5, "ACCEPTED", "ok"))
        self.assertIn("RECORD_AGENT_FEEDBACK('AGENT_REQUEST', 5, 'ACCEPTED', 'ok', NULL)", conn.sent[-1])
        self.assertFalse(svc.record_feedback(conn, None, "ACCEPTED"))

    def test_stored_totals_are_compiled_stored_registered_and_refreshed_by_semantic_views(self):
        from descriptor import publish
        publish.keep({"model": "all_data", "objects": [{"metrics": [{"name": "total_amount", "kind": "ADDITIVE"},
                                                                    {"name": "avg_amount", "kind": "RATIO"}]}]}, {"tables": []})
        conn = self.Conn({"COMPILE_REQUEST_JSON": [{"STATUS": "OK", "GENERATED_SQL": "SELECT s AS SHIP_STATE, x AS TOTAL_AMOUNT FROM T"}],
                          "EXA_ALL_COLUMNS": [{"COLUMN_NAME": "SHIP_STATE"}, {"COLUMN_NAME": "TOTAL_AMOUNT"}, {"COLUMN_NAME": "AVG_AMOUNT"}]})
        found = svc.store_totals(conn, "all_data", "order_lines", ["total_amount", "avg_amount"], ["ship_state"], max_age="6 hours")
        sent = " | ".join(conn.sent)
        self.assertIn('CREATE OR REPLACE TABLE EXAKIT_TOTALS."ORDER_LINES_SHIP_STATE" AS SELECT s AS SHIP_STATE', sent)
        self.assertIn("REGISTER_MATERIALIZATION('all_data', 'order_lines_ship_state', 'EXAKIT_TOTALS', 'ORDER_LINES_SHIP_STATE', 'AGGREGATE', 'MAX_AGE 6 HOURS')", sent)
        self.assertEqual(["DIRECT", "SUM", "NONE"], [c["rollup"] for c in found["columns"]], "only additive metrics roll up")
        self.assertIn("MARK_MATERIALIZATION_REFRESHED('all_data', 'order_lines_ship_state', NULL, NULL)", sent)
        self.assertIn("'totals_order_lines_ship_state')", sent, "kept in the model, so a rebuild registers it again")
        with self.assertRaisesRegex(svc.Refused, "MINUTES, HOURS or DAYS"):
            svc.store_totals(conn, "all_data", "order_lines", ["total_amount"], [], max_age="soon")
        record = {"name": "t", "schema": "EXAKIT_TOTALS", "table": "T", "sql": "SELECT 1", "max_age": "1 DAYS", "columns": []}
        later = self.Conn({"GET_CUSTOM_EXTENSIONS": [{"SCOPE_TYPE": "MODEL", "EXTENSION_NAME": "totals_t", "DATA_JSON": json.dumps(record)}]})
        svc.refresh_totals(later, "all_data", "t")
        self.assertEqual(['DELETE FROM EXAKIT_TOTALS."T"', 'INSERT INTO EXAKIT_TOTALS."T" SELECT 1'], later.sent[1:3])
        with self.assertRaises(svc.NotFound):
            svc.refresh_totals(later, "all_data", "nope")

    def test_frozen_views_governance_logging_suggestions_and_imports(self):
        conn = self.Conn({"CHECK_FROZEN_VIEWS": [{"VIEW_SCHEMA": "BI", "VIEW_NAME": "R", "STATUS": "STALE", "DETAIL": "metric changed"}],
                          "SET_QUERY_LOGGING": [{"DEPLOYMENT_VALUE": "ON", "SESSION_VALUE": None, "EFFECTIVE_VALUE": "ON"}],
                          "MODEL_EVOLUTION_SUGGESTIONS": [{"SUGGESTION_ID": 1, "REVIEW_STATUS": "PENDING"}, {"SUGGESTION_ID": 2, "REVIEW_STATUS": "CERTIFIED"}],
                          "REVIEW_MODEL_EVOLUTION": [{"SUGGESTION_ID": 1, "REVIEW_STATUS": "CERTIFIED"}],
                          "VALIDATE_MODEL": []})
        made = svc.freeze_view(conn, "bi.revenue", "SELECT ship_state, total_amount FROM SEMANTIC_ALL_DATA.ORDER_LINES GROUP BY ship_state;")
        self.assertEqual("BI.REVENUE", made["view"])
        at = conn.sent.index("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        self.assertTrue(conn.sent[at + 1].startswith("CREATE OR REPLACE VIEW BI.REVENUE AS SELECT ship_state"))
        self.assertEqual("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()", conn.sent[at + 2], "the preprocessor is switched off after")
        with self.assertRaisesRegex(svc.Refused, "one SELECT over a semantic view"):
            svc.freeze_view(conn, "bi.x", "SELECT 1 FROM DUAL")
        self.assertEqual([("BI.R", "STALE")], [(v["view"], v["status"]) for v in svc.frozen_views(conn, "all_data")])
        self.assertEqual("GOVERNED", svc.governance_mode(conn, "all_data", "governed")["mode"])
        with self.assertRaises(svc.Refused):
            svc.governance_mode(conn, "all_data", "strict")
        self.assertEqual("ON", svc.query_logging(conn, True)["effective"])
        self.assertIn("SET_QUERY_LOGGING('DEPLOYMENT', 'ON')", conn.sent[-1])
        self.assertEqual([1], [r["SUGGESTION_ID"] for r in svc.suggestions(conn, "all_data")], "only those waiting")
        self.assertEqual("CERTIFIED", svc.review_change(conn, 1, "certified", "matches finance")["status"])
        with self.assertRaises(svc.Refused):
            svc.review_change(conn, 1, "certified", "")
        from descriptor import publish
        publish.keep({"model": "all_data"}, {"tables": []})
        with self.assertRaisesRegex(svc.Refused, "a model of its own"):
            svc.import_databricks(conn, "all_data", "version: 0.1")
        with self.assertRaises(svc.Refused):
            svc.import_osi(conn, {"no": "operations"})

    def test_a_verified_question_is_compiled_first_and_kept_beside_the_model(self):
        from descriptor import publish
        publish.keep({"model": "sales"}, {"tables": []})
        conn = self.Conn({"COMPILE_REQUEST_JSON": [{"STATUS": "OK", "GENERATED_SQL": "SELECT 1"}]})
        svc.verify_question(conn, "sales", "orders", "Revenue by state", "What is revenue per state?",
                            {"metrics": ["total_amount"], "dimensions": ["state"]})
        self.assertTrue(conn.sent[-1].startswith("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_VERIFIED_QUERY('sales', 'ORDERS', 'Revenue by state'"))
        self.assertEqual("Revenue by state", publish.kept("sales")["verified"][0]["name"])
        with self.assertRaises(svc.Refused):                         # a name is kept once
            svc.verify_question(conn, "sales", "orders", "Revenue by state", "again?", {"metrics": ["total_amount"]})
        refused = self.Conn({"COMPILE_REQUEST_JSON": [{"STATUS": "ERROR", "ERROR_MESSAGE": "no"}]})
        with self.assertRaises(svc.Refused):
            svc.verify_question(refused, "sales", "orders", "Other", "q?", {"metrics": ["x"]})
        self.assertFalse(any("ADD_VERIFIED_QUERY" in s for s in refused.sent), "a refused request is never stored")

    def test_fusion_is_dry_run_first_and_an_applied_document_is_kept(self):
        from descriptor import publish
        publish.keep({"model": "crm"}, {"tables": []})
        doc = {"entities": {"customer": {"representations": [{"name": "mongo", "source_schema": "VS_MONGO",
                                                               "source_object": "CUSTOMERS", "priority": 20}]}}}
        conn = self.Conn({"APPLY_FUSION_DECLARATION": [{"STATUS": "DRY_RUN", "APPLIED_COUNT": 0}],
                          "EXPORT_FUSION_DECLARATION": [{"DECLARATION_JSON": json.dumps(doc)}]})
        found = svc.fuse(conn, "crm", doc)
        self.assertEqual(("dry_run", True), (found["status"], found["dry_run"]))
        self.assertEqual("ALTER SESSION SET QUERY_TIMEOUT=60", conn.sent[0])
        self.assertTrue(conn.sent[1].endswith(", TRUE)"))
        self.assertNotIn("fusion", publish.kept("crm"))
        conn.answers["APPLY_FUSION_DECLARATION"] = [{"STATUS": "OK", "APPLIED_COUNT": 3}]
        found = svc.fuse(conn, "crm", doc, dry_run=False)
        self.assertEqual(doc, publish.kept("crm")["fusion"])
        conn.answers["APPLY_FUSION_DECLARATION"] = [{"STATUS": "ERROR", "MESSAGE": "SEMANTIC_FUSION_011 unknown key"}]
        self.assertEqual("error", svc.fuse(conn, "crm", doc, dry_run=False)["status"])

    def test_a_lost_store_is_put_back_from_the_column_maps_the_model_carries(self):
        from descriptor import store
        older = {"table": "SHOP.ORDERS", "version": 1, "text": "version: 1\n"}
        newer = {"table": "SHOP.ORDERS", "version": 2, "text": "version: 2\n"}
        rows = [{"MODEL_NAME": "sales", "OBJECT_NAME": "orders", "EXTENSION_KEY": f"column_map_v{d['version']}",
                 "EXTENSION_VALUE": json.dumps(d)} for d in (older, newer)]
        rows.append({"MODEL_NAME": "other", "EXTENSION_KEY": "column_map_v9", "EXTENSION_VALUE": json.dumps(dict(newer, version=9))})
        old = self.Conn({"CUSTOM_EXTENSIONS": rows})
        old.execute = (lambda inner: lambda sql: (_ for _ in ()).throw(RuntimeError("no such script")) if "GET_CUSTOM_EXTENSIONS" in sql
                       else inner(sql))(old.execute)
        self.assertEqual({"SHOP.ORDERS": {"version": 2, "text": "version: 2\n"}}, svc.column_maps_in_model(old, "sales"),
                         "an older product: its catalog view, this model's rows")
        conn = self.Conn({"GET_CUSTOM_EXTENSIONS": [{"SCOPE_TYPE": "ENTITY", "SCOPE_NAME": "orders", "VENDOR_NAME": "exakit",
                                                     "EXTENSION_NAME": f"column_map_v{d['version']}", "DATA_JSON": json.dumps(d)}
                                                    for d in (older, newer)]})
        self.assertEqual({"SHOP.ORDERS": {"version": 2, "text": "version: 2\n"}}, svc.column_maps_in_model(conn, "sales"))
        self.assertIn("GET_CUSTOM_EXTENSIONS('sales', NULL, NULL, 'exakit')", " ".join(conn.sent), "Semantic Views' own reader")
        said = svc.restore_column_maps(conn, "sales")
        self.assertEqual("would be written to the store", said[0]["action"])
        self.assertEqual([], store.versions("SHOP.ORDERS"), "nothing written without write=True")
        svc.restore_column_maps(conn, "sales", write=True)
        self.assertEqual(([2], "version: 2\n"), (store.versions("SHOP.ORDERS"), store.current("SHOP.ORDERS")))
        self.assertEqual("the store is current", svc.restore_column_maps(conn, "sales", write=True)[0]["action"])

    def test_a_fusion_document_binds_every_field_on_the_other_copy_and_names_one_winner(self):
        from descriptor import publish
        spec = {"model": "crm", "entities": [{"name": "customers", "schema": "SHOP", "table": "CUSTOMERS", "alias": "t1",
                                              "key": ["ID"]}],
                "objects": [{"name": "CUSTOMERS", "root": "customers",
                             "dimensions": [{"name": "region", "entity": "customers", "expression": 't1."REGION"',
                                             "type": "VARCHAR(20)", "column": "REGION"},
                                            {"name": "tier", "entity": "customers", "expression": 't1."TIER"',
                                             "type": "VARCHAR(10)", "column": "TIER"}],
                             "facts": [{"name": "customers_row", "entity": "customers", "row": True, "expression": "1", "type": "DECIMAL(1,0)"}]}]}
        publish.keep(spec, {"tables": ["SHOP.CUSTOMERS"]})
        conn = self.Conn({"EXA_ALL_COLUMNS": [{"COLUMN_NAME": "CUST_ID", "COLUMN_TYPE": "DECIMAL(18,0)", "COLUMN_ORDINAL_POSITION": 1, "IS_VIRTUAL": 1},
                                              {"COLUMN_NAME": "REGION", "COLUMN_TYPE": "VARCHAR(20) UTF8", "COLUMN_ORDINAL_POSITION": 2, "IS_VIRTUAL": 1}]})
        doc = svc.fusion_document(conn, "crm", "shop.customers", "VS_CRM.CUSTOMERS", key="cust_id", wins="other")
        customers = doc["entities"]["customers"]
        primary, other = customers["representations"]
        self.assertEqual(("primary", "SUPPLEMENTAL"), (primary["name"], primary["authority"]))
        self.assertEqual(("VIRTUAL_SCHEMA", "VS_CRM", "CUSTOMERS", "AUTHORITATIVE"),
                         (other["source_kind"], other["source_schema"], other["source_object"], other["authority"]))
        self.assertEqual("DIRECT", other["identity_binding"]["binding_kind"], "keys named differently: one identity")
        self.assertEqual('t1.CUST_ID', other["identity_binding"]["source_expression"])
        bound = {b["attribute_name"]: b["source_expression"] for b in other["attribute_bindings"]}
        self.assertEqual({"region": 't1."REGION"', "tier": "CAST(NULL AS VARCHAR(10))"}, bound)
        self.assertEqual([("region", "RECONCILE")], [(p["attribute_name"], p["strategy"]) for p in customers["attribute_policies"]])
        with self.assertRaises(svc.Refused):
            svc.fusion_document(conn, "crm", "SHOP.ORDERS", "VS_CRM.CUSTOMERS")
        # different ids: a certified mapping table pairs them (a MAPPED identity)
        both = self.Conn({"EXA_ALL_COLUMNS": [{"COLUMN_NAME": c, "COLUMN_TYPE": t, "COLUMN_ORDINAL_POSITION": i, "IS_VIRTUAL": 0}
                                              for i, (c, t) in enumerate((("CUST_ID", "DECIMAL(18,0)"), ("ACCOUNT_ID", "DECIMAL(18,0)"),
                                                                          ("REGION", "VARCHAR(20) UTF8"), ("CREATED", "DATE")), 1)]})
        mapped = svc.fusion_document(both, "crm", "SHOP.CUSTOMERS", "VS_CRM.CUSTOMERS", key="CUST_ID",
                                     mapping={"table": "CRM.XREF", "local": "account_id", "key": "cust_id"})
        binding = mapped["entities"]["customers"]["representations"][1]["identity_binding"]
        self.assertEqual(("MAPPED", {"source_schema": "CRM", "source_object": "XREF", "source_local_column": "ACCOUNT_ID",
                                     "semantic_key_column": "CUST_ID", "certification_status": "CERTIFIED"}),
                         (binding["binding_kind"], binding["mapping"]))
        self.assertIn("identity", mapped["entities"]["customers"])
        # older rows in another source: a date split, each side's window, no winner
        split = svc.fusion_document(both, "crm", "SHOP.CUSTOMERS", "VS_CRM.CUSTOMERS", key="CUST_ID",
                                    split={"column": "created", "at": "2026-01-01"})
        hot, cold = split["entities"]["customers"]["representations"]
        self.assertEqual(({"predicate": "t1.CREATED >= TIMESTAMP '2026-01-01 00:00:00'", "valid_from": "2026-01-01 00:00:00"},
                          {"predicate": "t1.CREATED < TIMESTAMP '2026-01-01 00:00:00'", "valid_to": "2026-01-01 00:00:00"}),
                         (hot["coverage"], cold["coverage"]))
        self.assertFalse({"authority", "identity_binding"} & (set(hot) | set(cold)))
        self.assertNotIn("attribute_policies", split["entities"]["customers"], "a date split reconciles nothing")
        self.assertEqual(["primary", split["split"]["representation"]], [c["representation_name"] for c in split["split"]["coverage"]],
                         "both windows go to Semantic Views as one batch")

        class Tx(self.Conn):
            def __init__(self, answers):
                super().__init__(answers)
                self.log = []

            def set_autocommit(self, on):
                self.log.append(("autocommit", on))

            def rollback(self):
                self.log.append(("rollback",))
        tx = Tx({"ADD_ENTITY_REPRESENTATION_WITH_COVERAGE": [{"STATUS": "OK"}]})
        checked = svc.fuse(tx, "crm", split, dry_run=True)
        self.assertEqual("dry_run", checked["status"])
        self.assertTrue(any("ADD_ENTITY_REPRESENTATION_WITH_COVERAGE('crm', 'customers'" in x for x in tx.sent))
        self.assertEqual([("autocommit", False), ("rollback",), ("autocommit", True)], tx.log, "a check is rolled back")
        with self.assertRaisesRegex(svc.Refused, "not both"):
            svc.fusion_document(both, "crm", "SHOP.CUSTOMERS", "VS_CRM.CUSTOMERS", mapping={"table": "CRM.XREF"}, split={"column": "CREATED"})
        with self.assertRaisesRegex(svc.Refused, "YYYY-MM-DD"):
            svc.fusion_document(both, "crm", "SHOP.CUSTOMERS", "VS_CRM.CUSTOMERS", key="CUST_ID", split={"column": "CREATED", "at": "soon"})


class RulesTest(unittest.TestCase):
    """The rules a column map is drafted with and links are found with can be read and changed for one run."""

    def test_a_rule_changes_the_draft_and_the_defaults_come_back(self):
        from descriptor import roles, rules
        column = {"column": "SEGMENT", "type": "VARCHAR(20) UTF8", "kind": "string", "rows": 1000, "non_null": 1000,
                  "approx_distinct": 80, "avg_length": 6.0}
        before = roles.classify(dict(column))
        with rules.using({"CATEGORY_DISTINCT": 100}):
            during = roles.classify(dict(column))
        self.assertEqual(("category", "low"), (before["role"], before["confidence"]), "80 values: over the default 50, a guess")
        self.assertEqual(("category", "high", "80 distinct"), (during["role"], during["confidence"], during["evidence"]),
                         "under the rule's 100: a sure group")
        self.assertEqual(before, roles.classify(dict(column)), "the defaults are back afterwards")
        self.assertIn("MEASURE_HINTS", svc.role_rules())
        self.assertEqual(0.9, svc.link_rules()["MIN_SHARE"])
        with self.assertRaisesRegex(ValueError, "not a link rule"):
            with rules.using(None, {"NOPE": 1}):
                pass
        with self.assertRaisesRegex(ValueError, "is a number"):
            with rules.using({"CATEGORY_DISTINCT": "many"}):
                pass

    def test_a_link_search_runs_with_the_rules_given(self):
        from descriptor import links
        seen = {}
        with mock.patch.object(svc, "_find_links", side_effect=lambda *a, **k: seen.setdefault("share", links.MIN_SHARE)):
            svc.find_links(None, ["A", "B"], rules={"MIN_SHARE": 0.75})
        self.assertEqual((0.75, 0.9), (seen["share"], links.MIN_SHARE))

if __name__ == "__main__":
    unittest.main()
