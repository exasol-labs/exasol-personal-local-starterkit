"""Steps 4 and 5 of the descriptor plan: describe and approve against a stand-in database, the store's versions,
the carry-over when a table changes, and the schema's Exasol Semantic Views model an approval rebuilds (DS5.2,
DS2.5, DS5.4)."""

from __future__ import annotations

import datetime as dt
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "setup" / "lib"), str(ROOT / "tools"), str(ROOT / "tests")]
from descriptor import draft, flow, profile, publish, semantic_model, store  # noqa: E402
from semantic_fake import SemanticViews  # noqa: E402

MODEL = "semantic model support (SEM_SUPPORT)"

COLUMNS = [("TICKET_ID", "DECIMAL(9,0)"), ("OPENED_ON", "DATE"), ("CHANNEL", "VARCHAR(10) UTF8"),
           ("ESCALATED", "DECIMAL(1,0)"), ("BODY", "VARCHAR(400) UTF8")]


def rows(n: int = 120) -> list[list]:
    words = ["refund", "late", "broken", "password", "invoice", "delivery", "screen", "battery"]
    return [[i, (dt.date(2025, 1, 1) + dt.timedelta(days=i % 90)).isoformat(), ["web", "phone", "mail"][i % 3],
             1 if i % 7 == 0 else 0, f"Ticket {i}: " + " ".join(words[(i * k) % 8] for k in range(1, 9))] for i in range(n)]


class Database:
    """Answers the shape query from its columns, and Semantic Views' catalog from the scripts it was sent."""

    def __init__(self, columns, data, fail_publish=False):
        self.columns, self.data, self.fail_publish = list(columns), data, fail_publish
        self.sent: list[str] = []
        self.sv = SemanticViews()

    def run(self, sql: str) -> list[dict]:
        self.sent.append(sql)
        answer = self.sv.answer(sql)
        if answer is not None:
            return answer
        if "EXA_ALL_COLUMNS" in sql and "COLUMN_SCHEMA IN" in sql:
            return [{"COLUMN_SCHEMA": "SUPPORT", "COLUMN_TABLE": "TICKETS", "COLUMN_NAME": n, "COLUMN_TYPE": t}
                    for n, t in self.columns]
        if "EXA_SCHEMAS" in sql:
            return []
        if "EXA_ALL_COLUMNS" in sql:
            return [{"COLUMN_NAME": n, "COLUMN_TYPE": t, "IS_VIRTUAL": 0} for n, t in self.columns]
        answer = self.review(sql)
        if answer is not None:
            return answer
        raise AssertionError(f"unexpected statement {sql}")

    def values(self, column: str) -> list:
        i = [n for n, _ in self.columns].index(column)
        return [row[i] for row in self.data]

    def review(self, sql: str) -> list[dict] | None:
        """The approve step's review (descriptor/review.py), answered from the rows."""
        text = lambda v: None if v is None else str(v)
        if sql.startswith("SELECT COUNT(*) AS N"):
            row = {"N": len(self.data)}
            key = re.search(r'COUNT\("(\w+)"\) AS KN', sql)
            if key:
                present = [v for v in self.values(key.group(1)) if v is not None]
                row.update(KN=len(present), KD=len(set(present)))
            target = re.search(r'COUNT\(DISTINCT "(\w+)"\) AS TD', sql)
            if target:
                row["TD"] = len({v for v in self.values(target.group(1)) if v is not None})
            return [row]
        if "AS V, COUNT(*) AS N" in sql:
            target = re.search(r'CAST\("(\w+)"', sql).group(1)
            counts: dict = {}
            for v in self.values(target):
                if v is not None:
                    counts[text(v)] = counts.get(text(v), 0) + 1
            return [{"V": v, "N": n} for v, n in sorted(counts.items(), key=lambda item: (item[1], item[0]))]
        if "GROUPING SETS" in sql:
            columns = re.findall(r'GROUPING\("(\w+)"\)', sql)
            target, rare = re.search(r'WHEN CAST\("(\w+)" AS VARCHAR\(2000\)\) = \'([^\']*)\'', sql).groups()
            labels = [text(v) for v in self.values(target)]
            found = []
            for i, column in enumerate(columns):
                groups: dict = {}
                for value, label in zip(self.values(column), labels):
                    if label is None:
                        continue
                    n, h = groups.get(text(value), (0, 0))
                    groups[text(value)] = (n + 1, h + (label == rare))
                for value, (n, h) in groups.items():
                    row = {f"G{j}": 1 for j in range(len(columns))}
                    row.update({f"V{j}": None for j in range(len(columns))})
                    row.update({f"G{i}": 0, f"V{i}": value, "N": n, "H": h})
                    found.append(row)
            return found
        return None

    def execute(self, sql: str) -> None:
        self.sent.append(sql)
        if self.fail_publish:
            raise PermissionError("insufficient privileges for EXECUTE SCRIPT")
        if not self.sv.apply(sql) and not sql.startswith("GRANT "):
            raise AssertionError(f"unexpected statement {sql}")


class FlowTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.db = Database(COLUMNS, rows())
        installer = mock.patch.object(publish, "INSTALL", side_effect=self.db.sv.install)
        installer.start()
        self.addCleanup(installer.stop)
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
        with mock.patch.object(store, "kit_home", return_value=self.home):
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

    def test_approve_writes_v1_current_and_publishes_the_semantic_model(self):
        doc = self.describe()["doc"]
        doc["slots"]["target"] = "ESCALATED"
        result = self.approve(doc)
        self.assertEqual(("approved", 1, MODEL), (result["status"], result["version"], result["published"]))
        v1 = store.read("SUPPORT.TICKETS", 1, self.home)
        self.assertEqual(v1, store.current("SUPPORT.TICKETS", self.home))
        self.assertIn('owner: "dana"', v1)
        self.assertIn('approved_at: "2026-11-03T10:14:00Z"', v1)
        self.assertIsNone(store.draft("SUPPORT.TICKETS", self.home))
        self.assertIsNotNone(store.read_profile("SUPPORT.TICKETS", 1, self.home))
        model = self.db.sv.models["support"]
        self.assertEqual(([("SUPPORT", "TICKETS")], "SEM_SUPPORT", True), (model["entities"], model["published_schema"], model["published"]))
        self.assertIn(semantic_model.MARK, model["description"])
        self.assertIn('GRANT SEMANTIC_USER TO "MCP_READONLY"', self.db.sent)
        self.assertIn('GRANT SELECT ON SCHEMA SEM_SUPPORT TO "MCP_READONLY"', self.db.sent)
        self.assertFalse(any(s.startswith("DROP SCHEMA") for s in self.db.sent), "no schema is ever dropped")
        definition = model["definitions"][0]
        self.assertIn("DIMENSION opened_on", definition)
        self.assertIn("DIMENSION channel", definition)
        self.assertNotIn("body", definition.lower().split("replace facts")[0])            # text is no dimension
        self.assertTrue((self.home / "semantic" / "support.json").is_file())

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
        self.assertEqual(MODEL, again["published"])
        self.assertIn(f"It is stored at {again['path']}; published as {MODEL}", again["message"])

    def test_an_unchanged_approval_never_names_a_model_that_is_gone(self):
        doc = self.describe()["doc"]
        self.approve(doc)
        self.db.sv.models.clear()
        again = self.approve(doc, publish=False)
        self.assertIsNone(again["published"])
        self.assertNotIn("published as", again["message"])

    def test_an_unchanged_approval_that_was_never_published_is_published_now(self):
        """A shipped dataset's descriptor the store adopted (or an approval whose publish failed) is approved but has
        no model: approving the same again writes no version and publishes it, so agents find its roles."""
        doc = self.describe()["doc"]
        self.approve(doc)
        self.db.sv.models.clear()
        again = self.approve(doc)
        self.assertEqual("unchanged", again["status"])
        self.assertTrue(again["published"].startswith("semantic model support"))
        self.assertIn("support", self.db.sv.models)
        self.assertEqual([1], store.versions("SUPPORT.TICKETS", self.home))
        self.assertIn("published as semantic model support", again["message"])
        self.db.sv.models.clear()
        self.db.fail_publish = True
        failed = self.approve(doc)
        self.assertEqual("unchanged", failed["status"], "the approval stands")
        self.assertIsNone(failed["published"])
        self.assertIn("PermissionError", failed["reason"])

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

    def test_an_approval_kept_without_its_profile_carries_every_role_over_while_the_table_is_the_same(self):
        # A shipped descriptor the store adopted has no profile beside it; re-describing the same table must not call
        # every column changed.
        doc = self.describe()["doc"]
        doc["columns"]["CHANNEL"] = dict(doc["columns"]["CHANNEL"], role="identifier")
        self.approve(doc)
        for kept in store.folder("SUPPORT.TICKETS", self.home).glob("v1.profile.json"):
            kept.unlink()
        found = self.describe(force=True)
        self.assertEqual([], found["changed"])
        self.assertEqual("identifier", found["doc"]["columns"]["CHANNEL"]["role"])

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
                                                   "published": MODEL, "warnings": []})], lines)

    def test_semantic_views_is_installed_first_when_the_database_lacks_it(self):
        self.db.sv.installed = False
        result = self.approve(self.describe()["doc"])
        self.assertEqual(("approved", MODEL), (result["status"], result["published"]))
        publish.INSTALL.assert_called_once()

    def test_an_install_that_fails_leaves_the_approval_standing_and_names_the_command(self):
        self.db.sv.installed = False
        publish.INSTALL.side_effect = lambda: False
        result = self.approve(self.describe()["doc"])
        self.assertEqual("approved, not published", result["status"])
        self.assertIn("exakit marketplace semantic-views", result["reason"])

    def test_a_model_of_that_name_the_kit_did_not_build_is_left_alone(self):
        self.db.sv.apply("EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('support', 'SEM_HAND', 'made by hand', NULL)")
        result = self.approve(self.describe()["doc"])
        self.assertEqual("approved, not published", result["status"])
        self.assertIn("the kit did not build it", result["reason"])
        self.assertEqual("SEM_HAND", self.db.sv.models["support"]["published_schema"])

    def test_a_rebuild_the_product_refuses_puts_the_last_published_model_back(self):
        doc = self.describe()["doc"]
        self.approve(doc)
        doc = self.describe(force=True)["doc"]
        doc["columns"]["CHANNEL"] = dict(doc["columns"]["CHANNEL"], role="identifier")
        doc["slots"]["category"] = None
        self.db.sv.refuse = "PUBLISH_MODEL"
        result = self.approve(doc)
        self.assertEqual("approved, not published", result["status"])
        self.assertIn("SEMANTIC_MODEL_030", result["reason"])
        self.db.sv.refuse = None


class SemanticModelTest(unittest.TestCase):
    """The model an approval builds: entities, keys, relationships, dimensions, facts and metrics, from roles."""

    ORDERS = {"columns": {"O_ORDERKEY": {"role": "key"}, "O_CUSTKEY": {"role": "identifier"},
                          "O_ORDERDATE": {"role": "time"}, "O_ORDERSTATUS": {"role": "category"},
                          "O_TOTALPRICE": {"role": "measure", "note": "Order value incl. tax"},
                          "O_SECRET": {"role": "measure", "sensitive": True}, "O_COMMENT": {"role": "text"}},
              "slots": {"key": "O_ORDERKEY"}, "grain": "one row per order"}
    CUSTOMER = {"columns": {"C_CUSTKEY": {"role": "key"}, "C_MKTSEGMENT": {"role": "category"},
                            "C_PHONE": {"role": "category", "sensitive": True}}, "slots": {"key": "C_CUSTKEY"}}
    COURIER = {"columns": {"STATE": {"role": "category"}, "DELIVERIES": {"role": "measure"}, "DAY": {"role": "time"}}}

    def spec(self):
        tables = [semantic_model.table_input("TPCH.ORDERS", self.ORDERS, {"O_TOTALPRICE": "DECIMAL(15,2)",
                                             "O_ORDERDATE": "DATE", "O_ORDERSTATUS": "CHAR(1) UTF8", "O_SECRET": "DOUBLE"},
                                             profile={"columns": [{"column": "O_ORDERSTATUS", "top": [["F", 9], ["O", 4]]}]}),
                  semantic_model.table_input("TPCH.CUSTOMER", self.CUSTOMER, {"C_MKTSEGMENT": "VARCHAR(10) UTF8"}),
                  semantic_model.table_input("VS_LOGISTICS.COURIER_DAILY", self.COURIER, {"DELIVERIES": "VARCHAR(20) UTF8",
                                             "DAY": "DATE"}, virtual=True)]
        return semantic_model.build(tables, [{"from": "TPCH.ORDERS.O_CUSTKEY", "to": "TPCH.CUSTOMER.C_CUSTKEY"}], "Sales 360")

    def test_one_model_spans_local_tables_and_an_external_source(self):
        spec = self.spec()
        self.assertEqual(("sales_360", "SEM_SALES_360", ["TPCH", "VS_LOGISTICS"]),
                         (spec["model"], spec["published_schema"], spec["schemas"]))
        self.assertEqual(["ORDERS", "COURIER_DAILY"], [o["name"] for o in spec["objects"]])   # the tables with measures
        orders = spec["objects"][0]
        names = [d["name"] for d in orders["dimensions"]]
        self.assertEqual(["o_orderdate", "o_orderdate_month", "o_orderstatus", "c_mktsegment"], names)
        self.assertNotIn("c_phone", " ".join(names))                       # a sensitive column is never a dimension
        self.assertEqual(["orders_count", "total_o_totalprice", "average_o_totalprice"], [m["name"] for m in orders["metrics"]])
        self.assertTrue(next(f for f in orders["facts"] if f.get("column") == "O_SECRET")["private"])
        courier = spec["objects"][1]
        self.assertEqual("CAST(t3.DELIVERIES AS DOUBLE)", courier["facts"][1]["expression"])   # a number sent as text
        self.assertEqual(["courier_daily_state", "courier_daily_day", "day_month"], [d["name"] for d in courier["dimensions"]])
        self.assertTrue(spec["entities"][2]["virtual"])

    def test_the_statements_create_the_model_then_publish_it(self):
        sent = semantic_model.statements(self.spec())
        self.assertTrue(sent[0].startswith("EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('sales_360', 'SEM_SALES_360', "))
        self.assertIn("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP('sales_360', 'orders_to_customer', 'orders', "
                      "'customer', 't1.O_CUSTKEY = t2.C_CUSTKEY', 'MANY_TO_ONE', 'LEFT', NULL)", sent)
        self.assertEqual("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales_360')", sent[-1])
        definition = next(s for s in sent if "ALTER SEMANTIC VIEW sales_360.ORDERS" in s)
        self.assertIn("COMMENT ''Order value incl. tax''", definition)        # a column note is the field's comment
        self.assertIn("AS total_o_totalprice / NULLIF(orders_count, 0)", definition)

    def test_an_ai_proposal_is_checked_before_it_is_used(self):
        spec = self.spec()
        labels, extra, refused = semantic_model.ai_accept(spec, {
            "model": "Orders and deliveries", "labels": {"o_totalprice": {"display": "Order value"}, "nope": {}},
            "metrics": [{"view": "ORDERS", "name": "open_order_value", "expression": "SUM(o_totalprice)",
                         "filter": "o_orderstatus = 'O'"},
                        {"view": "ORDERS", "name": "made_up", "expression": "SUM(o_orderstatus)", "filter": "o_orderstatus = 'Z'"},
                        {"view": "ORDERS", "name": "secret_sum", "expression": "SUM(o_secret)"},
                        {"view": "ORDERS", "name": "drop", "expression": "SUM(o_totalprice); DROP TABLE X"},
                        {"view": "ORDERS", "name": "orders_count", "expression": "SUM(o_totalprice)"}]})
        self.assertEqual({"o_totalprice": {"display": "Order value"}, "model": "Orders and deliveries"}, labels)
        self.assertEqual(1, len(extra))
        self.assertIn("FILTER (WHERE o_orderstatus = 'O')", extra[0][1])
        self.assertEqual(4, len(refused))

    def test_names_are_never_sql_keywords(self):
        for word in ("date", "order", "state", "year"):
            self.assertNotIn(semantic_model.identifier(word), semantic_model.RESERVED)


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
