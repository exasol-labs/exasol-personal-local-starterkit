"""Steps 4 and 5 of the descriptor plan: describe and approve against a stand-in database, the store's versions,
the carry-over when a table changes, and the EXAKIT_SEMANTIC view (DS5.2, DS2.5, DS5.4's statements)."""

from __future__ import annotations

import datetime as dt
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "setup" / "lib"), str(ROOT / "tools")]
from descriptor import draft, flow, profile, publish, store  # noqa: E402

COLUMNS = [("TICKET_ID", "DECIMAL(9,0)"), ("OPENED_ON", "DATE"), ("CHANNEL", "VARCHAR(10) UTF8"),
           ("ESCALATED", "DECIMAL(1,0)"), ("BODY", "VARCHAR(400) UTF8")]


def rows(n: int = 120) -> list[list]:
    words = ["refund", "late", "broken", "password", "invoice", "delivery", "screen", "battery"]
    return [[i, (dt.date(2025, 1, 1) + dt.timedelta(days=i % 90)).isoformat(), ["web", "phone", "mail"][i % 3],
             1 if i % 7 == 0 else 0, f"Ticket {i}: " + " ".join(words[(i * k) % 8] for k in range(1, 9))] for i in range(n)]


class Database:
    """Answers the shape query from its columns and the view read-back from the comments it was sent."""

    def __init__(self, columns, data, fail_publish=False):
        self.columns, self.data, self.fail_publish = list(columns), data, fail_publish
        self.sent: list[str] = []
        self.views: dict[str, list[tuple[str, str]]] = {}

    def run(self, sql: str) -> list[dict]:
        self.sent.append(sql)
        if "EXAKIT_SEMANTIC" in sql and "COLUMN_COMMENT" in sql:
            name = re.search(r"COLUMN_TABLE = '([^']+)'", sql).group(1)
            return [{"COLUMN_NAME": c, "COLUMN_COMMENT": comment} for c, comment in self.views.get(name, [])]
        if "EXA_ALL_VIEWS" in sql:
            name = re.search(r"VIEW_NAME = '([^']+)'", sql).group(1)
            return [{"VIEW_NAME": name}] if name in self.views else []
        if "EXA_ALL_COLUMNS" in sql:
            return [{"COLUMN_NAME": n, "COLUMN_TYPE": t, "IS_VIRTUAL": 0} for n, t in self.columns]
        raise AssertionError(f"unexpected statement {sql}")

    def execute(self, sql: str) -> None:
        self.sent.append(sql)
        if self.fail_publish:
            raise PermissionError("insufficient privileges for CREATE VIEW")
        match = re.match(r'CREATE OR REPLACE VIEW EXAKIT_SEMANTIC\."([^"]+)"', sql)
        if match:
            self.views[match.group(1)] = re.findall(r'"([A-Z_]+)" COMMENT IS \'((?:[^\']|\'\')*)\'', sql.split(") AS SELECT")[0])


class FlowTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.db = Database(COLUMNS, rows())
        patcher = mock.patch.object(profile, "profile", side_effect=self._profile)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.profiles = 0

    def _profile(self, conn, table, *, run=None):
        self.profiles += 1
        return profile.profile_rows(self.db.columns, self.db.data, table)

    def describe(self, **kw):
        return flow.describe(self.db.run, "support.tickets", home=self.home, **kw)

    def approve(self, doc, **kw):
        kw.setdefault("now", lambda: dt.datetime(2026, 11, 3, 10, 14, tzinfo=dt.timezone.utc))
        return flow.approve(self.db.run, self.db.execute, doc, home=self.home, reader="MCP_READONLY", owner="dana", **kw)

    def test_a_new_table_is_drafted_and_nothing_is_versioned_yet(self):
        found = self.describe()
        self.assertEqual("draft", found["status"])
        self.assertEqual("support_tickets", found["doc"]["dataset"])
        self.assertEqual({"key": "TICKET_ID", "time": "OPENED_ON", "text": "BODY", "target": None, "category": "CHANNEL",
                          "entity": None}, found["doc"]["slots"])
        self.assertEqual("no short string column with more than 20 values", found["doc"]["slot_evidence"]["entity"])
        self.assertEqual([], store.versions("SUPPORT.TICKETS", self.home))
        self.assertIsNotNone(store.draft("SUPPORT.TICKETS", self.home))

    def test_approve_writes_v1_current_and_publishes_the_view(self):
        doc = self.describe()["doc"]
        doc["slots"]["target"] = "ESCALATED"
        result = self.approve(doc)
        self.assertEqual(("approved", 1, "EXAKIT_SEMANTIC.SUPPORT__TICKETS"), (result["status"], result["version"], result["published"]))
        v1 = store.read("SUPPORT.TICKETS", 1, self.home)
        self.assertEqual(v1, store.current("SUPPORT.TICKETS", self.home))
        self.assertIn('owner: "dana"', v1)
        self.assertIn('approved_at: "2026-11-03T10:14:00Z"', v1)
        self.assertIsNone(store.draft("SUPPORT.TICKETS", self.home))
        self.assertIsNotNone(store.read_profile("SUPPORT.TICKETS", 1, self.home))
        self.assertTrue(any(s.startswith('GRANT SELECT ON EXAKIT_SEMANTIC."SUPPORT__TICKETS" TO "MCP_READONLY"') for s in self.db.sent))

    def test_describe_on_an_unchanged_approved_table_returns_it_without_profiling(self):
        self.approve(self.describe()["doc"])
        before = self.profiles
        found = self.describe()
        self.assertEqual(("approved", 1, before), (found["status"], found["doc"]["version"], self.profiles))
        self.assertEqual("draft", self.describe(force=True)["status"])

    def test_approving_again_without_changes_writes_nothing(self):
        doc = self.describe()["doc"]
        self.approve(doc)
        again = self.approve(doc)
        self.assertEqual("unchanged", again["status"])
        self.assertEqual([1], store.versions("SUPPORT.TICKETS", self.home))
        # Nothing written, but the run still says where the approval it uses lives, and where agents read it.
        self.assertEqual(str(store.folder("SUPPORT.TICKETS", self.home) / "v1.yaml"), again["path"])
        self.assertEqual("EXAKIT_SEMANTIC.SUPPORT__TICKETS", again["published"])
        self.assertIn(f"It is stored at {again['path']}; published as EXAKIT_SEMANTIC.SUPPORT__TICKETS", again["message"])

    def test_an_unchanged_approval_never_names_a_view_that_is_gone(self):
        doc = self.describe()["doc"]
        self.approve(doc)
        self.db.views.clear()
        again = self.approve(doc)
        self.assertIsNone(again["published"])
        self.assertNotIn("published as", again["message"])

    def test_a_changed_table_drafts_the_next_version_carrying_unchanged_columns_over(self):
        doc = self.describe()["doc"]
        doc["columns"]["CHANNEL"] = dict(doc["columns"]["CHANNEL"], role="identifier")       # a correction by hand
        doc["slots"].update(target="ESCALATED", category=None)
        self.approve(doc)
        v1 = store.read("SUPPORT.TICKETS", 1, self.home)
        self.db.columns.append(("PRIORITY", "VARCHAR(10) UTF8"))
        self.db.data = [r + [["low", "high"][i % 2]] for i, r in enumerate(self.db.data)]
        found = self.describe()
        self.assertEqual(("draft", 2, ["PRIORITY"]), (found["status"], found["doc"]["version"], found["changed"]))
        self.assertEqual("identifier", found["doc"]["columns"]["CHANNEL"]["role"])
        self.assertEqual("ESCALATED", found["doc"]["slots"]["target"])
        self.assertTrue(found["doc"]["columns"]["PRIORITY"]["evidence"].startswith("changed since v1: "))
        self.approve(found["doc"])
        self.assertEqual(v1, store.read("SUPPORT.TICKETS", 1, self.home))           # v1 is never touched
        self.assertEqual([1, 2], store.versions("SUPPORT.TICKETS", self.home))

    def test_a_table_reloaded_between_describe_and_approve_is_refused(self):
        doc = self.describe()["doc"]
        self.db.columns[2] = ("CHANNEL", "VARCHAR(20) UTF8")
        with self.assertRaisesRegex(ValueError, "changed since it was described"):
            self.approve(doc)
        self.assertEqual([], store.versions("SUPPORT.TICKETS", self.home))

    def test_a_column_in_two_slots_or_without_a_role_is_refused(self):
        doc = self.describe()["doc"]
        doc["slots"]["target"] = "CHANNEL"
        doc["slots"]["category"] = "CHANNEL"
        with self.assertRaisesRegex(ValueError, "sits in two slots"):
            self.approve(doc)
        doc = self.describe()["doc"]
        del doc["columns"]["BODY"]
        doc["slots"]["text"] = None
        with self.assertRaisesRegex(ValueError, "every column of the table"):
            self.approve(doc)

    def test_a_publish_that_fails_leaves_the_approval_standing(self):
        self.db.fail_publish = True
        result = self.approve(self.describe()["doc"])
        self.assertEqual("approved, not published", result["status"])
        self.assertIn("insufficient privileges", result["reason"])
        self.assertEqual([1], store.versions("SUPPORT.TICKETS", self.home))

    def test_the_approval_is_logged_once(self):
        lines = []
        self.approve(self.describe()["doc"], log=lambda kind, **payload: lines.append((kind, payload)))
        self.assertEqual([("describe.approve", {"table": "SUPPORT.TICKETS", "version": 1,
                                                   "published": "EXAKIT_SEMANTIC.SUPPORT__TICKETS"})], lines)


class PublishTest(unittest.TestCase):
    DOC = {"source": {"object": "BANKING.COMPLAINTS"}, "version": 3, "grain": "one row per complaint",
           "columns": {"COMPLAINT_ID": {"role": "key"}, "ZIP_CODE": {"role": "identifier", "sensitive": True},
                       "PRODUCT": {"role": "category", "note": "Product line as filed"}}}

    def test_the_view_names_every_column_with_its_role_and_never_star(self):
        create = publish.statements(self.DOC, "MCP_READONLY")[1]
        self.assertIn('CREATE OR REPLACE VIEW EXAKIT_SEMANTIC."BANKING__COMPLAINTS"', create)
        self.assertIn("\"ZIP_CODE\" COMMENT IS 'role=identifier; sensitive; descriptor=v3'", create)
        self.assertIn("\"PRODUCT\" COMMENT IS 'role=category; descriptor=v3 | Product line as filed'", create)
        self.assertIn('AS SELECT "COMPLAINT_ID", "ZIP_CODE", "PRODUCT" FROM "BANKING"."COMPLAINTS"', create)
        self.assertIn("COMMENT IS 'grain=one row per complaint; source=BANKING.COMPLAINTS; descriptor=v3'", create)
        self.assertNotIn("*", create)

    def test_a_long_note_is_trimmed_never_the_marker(self):
        comment = publish.column_comment({"role": "text", "note": "x" * 5000}, 7)
        self.assertEqual(publish.COMMENT_LIMIT, len(comment))
        self.assertTrue(comment.startswith("role=text; descriptor=v7 | "))

    def test_the_grant_follows_every_replace_and_is_left_out_without_a_reader(self):
        self.assertTrue(publish.statements(self.DOC, "MCP_READONLY")[-1].startswith("GRANT SELECT"))
        self.assertFalse(any(s.startswith("GRANT") for s in publish.statements(self.DOC, None)))


class ShippedDescriptorTest(unittest.TestCase):
    """DS5.1: each reference dataset, its descriptor removed, drafts the roles and the key, time and text slots it ships."""

    def test_a_fresh_draft_agrees_with_every_shipped_descriptor(self):
        import descriptor_draft
        import descriptor_rules
        for folder in sorted((ROOT / "data" / "datasets").iterdir()):
            shipped_file = folder / "descriptor.yaml"
            if not shipped_file.is_file() or "descriptor: 1" not in shipped_file.read_text():
                continue
            with self.subTest(dataset=folder.name):
                shipped = descriptor_rules.load_yaml(shipped_file.read_text())
                schema, tables = descriptor_draft.tables((folder / "01_create_schema.sql").read_text())
                table = shipped["source"]["object"].split(".", 1)[1]
                import csv
                with (folder / "data" / f"{table.lower()}.csv").open(encoding="utf-8", newline="") as handle:
                    reader = csv.reader(handle)
                    next(reader)
                    fresh = draft.draft(profile.profile_rows(tables[table], reader, f"{schema}.{table}"), folder.name)
                self.assertEqual({c: e["role"] for c, e in shipped["columns"].items()},
                                 {c: e["role"] for c, e in fresh["columns"].items()})
                for slot in ("key", "time", "text"):
                    self.assertEqual(shipped["slots"][slot], fresh["slots"][slot], slot)
                self.assertIsNone(fresh["slots"]["target"])


if __name__ == "__main__":
    unittest.main()
