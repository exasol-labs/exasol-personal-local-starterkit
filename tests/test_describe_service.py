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
        self.assertEqual("EXAKIT_SEMANTIC.SUPPORT__TICKETS", result["published"])
        self.assertIn('target: "ESCALATED"', store.current("SUPPORT.TICKETS"))
        code, out, _ = self.run_main("versions", "support_tickets", "--json")
        self.assertEqual([(1, "approved", "dana")], [(v["version"], v["status"], v["owner"]) for v in json.loads(out)])
        code, out, _ = self.run_main("show", "SUPPORT.TICKETS")
        self.assertTrue(out.startswith("descriptor: 1"))
        code, out, _ = self.run_main("comments", "support_tickets")
        self.assertEqual((0, "Published EXAKIT_SEMANTIC.SUPPORT__TICKETS (5 columns)\n"), (code, out))

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
        self.assertIn("Published as EXAKIT_SEMANTIC.SUPPORT__TICKETS", out.getvalue())
        self.assertEqual((ds.status, ds.version, ds.col("label"), ds.text_cols()), ("approved", 1, "ESCALATED", ["BODY"]))
        self.assertEqual("identifier", d.column_roles["CHANNEL"])
        again = nb_describe.describe("SUPPORT.TICKETS", conn=self.db)
        self.assertEqual(("approved", 1), (again.status, again.version))

    def test_help_is_exit_0(self):
        code, out, _ = self.run_main("--help")
        self.assertEqual(0, code)
        self.assertIn("approve <dataset id", out)


if __name__ == "__main__":
    unittest.main()
