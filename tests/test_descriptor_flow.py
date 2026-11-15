"""Steps 4 and 5 of the descriptor plan: describe and approve against a stand-in database, the store's versions,
the carry-over when a table changes, and the schema's Exasol Semantic Views model an approval rebuilds (DS5.2,
DS2.5, DS5.4)."""

from __future__ import annotations

import datetime as dt
import json
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
        self.assertIn('GRANT EXAKIT_SEMANTIC_READERS TO "MCP_READONLY"', self.db.sent)
        self.assertTrue(any("GRANT_MODEL_ROLE(" in sql and "'EXAKIT_SEMANTIC_READERS'" in sql for sql in self.db.sent),
                        "the model is granted the way Semantic Views grants it")
        self.assertFalse(any(s.startswith("DROP SCHEMA") for s in self.db.sent), "no schema is ever dropped")
        definition = model["definitions"][0]
        self.assertIn("DIMENSION opened_on", definition)
        self.assertIn("DIMENSION channel", definition)
        self.assertNotIn("body", definition.lower().split("replace facts")[0])            # text is no dimension
        self.assertTrue((self.home / "semantic" / "support.json").is_file())

    def test_a_changed_column_map_changes_the_model_in_place_and_a_rebuild_keeps_verified_questions(self):
        """The second approval changes the published model with a few statements - no drop, so the product keeps what
        people added to it - and a rebuild (forced by a key change) puts the kept verified questions back."""
        off = mock.patch.dict("os.environ", {"EXAKIT_ALL_DATA_MODEL": "0"})     # one model here: the schema's
        off.start()
        self.addCleanup(off.stop)
        doc = self.describe()["doc"]
        self.approve(doc)
        first = list(self.db.sv.scripts)
        self.assertIn("CREATE_MODEL", first)
        self.assertTrue(any("'column_map_v1'" in x for x in self.db.sent), "the approved column map is in the model")
        kept_file = self.home / "semantic" / "support.json"
        kept = json.loads(kept_file.read_text(encoding="utf-8"))
        kept["verified"] = [{"object": "TICKETS", "name": "Tickets by channel", "question": "How many tickets per channel?",
                             "request": {"model": "support", "object": "TICKETS", "metrics": ["tickets_count"],
                                         "dimensions": ["channel"]}}]
        kept_file.write_text(json.dumps(kept), encoding="utf-8")
        doc = self.describe(force=True)["doc"]
        doc["columns"]["CHANNEL"] = dict(doc["columns"]["CHANNEL"], note="Where the ticket came in")
        self.db.sv.scripts.clear()
        self.approve(doc)
        self.assertEqual(["ADD_CUSTOM_EXTENSION", "APPLY_SEMANTIC_DEFINITION_OR_FAIL", "PUBLISH_MODEL", "GRANT_MODEL_ROLE",
                          "ADD_CUSTOM_EXTENSION"], self.db.sv.scripts,
                         "the new column map version goes into the model, the changed view is replaced, one publish, the "
                         "grant, and the data map's next version kept in the model")
        version_2 = [x for x in self.db.sent if "ADD_CUSTOM_EXTENSION" in x and "'ENTITY'" in x][-1]
        self.assertIn("'column_map_v2'", version_2)
        self.assertIn("Where the ticket came in", version_2, "the approved text itself, as the store holds it")
        self.assertEqual("Tickets by channel", json.loads(kept_file.read_text(encoding="utf-8"))["verified"][0]["name"],
                         "what people added stays beside the model")
        doc = self.describe(force=True)["doc"]
        doc["columns"]["TICKET_ID"] = dict(doc["columns"]["TICKET_ID"], role="identifier")
        doc["slots"]["key"] = None
        self.db.sv.scripts.clear()
        self.approve(doc)
        self.assertIn("DROP_MODEL_IF_EXISTS", self.db.sv.scripts, "a key change needs a rebuild")
        self.assertIn("ADD_VERIFIED_QUERY", self.db.sv.scripts, "and the verified question is put back")
        self.assertLess(self.db.sv.scripts.index("DROP_MODEL_IF_EXISTS"), self.db.sv.scripts.index("ADD_VERIFIED_QUERY"))

    def test_the_statements_are_planned_shown_and_your_edited_ones_run_instead(self):
        """A model's statements can be read before they run (planned: the change in place, else the whole model after
        a drop) and run as a person edited them (run_statements): only Semantic Views' own statements, a model of
        someone else's is left alone, and an edited model is built again from the column maps by the next approval."""
        off = mock.patch.dict("os.environ", {"EXAKIT_ALL_DATA_MODEL": "0"})
        off.start()
        self.addCleanup(off.stop)
        doc = self.describe()["doc"]
        spec = publish.build_model(self.db.run, ["SUPPORT.TICKETS"], [], "support", docs={"SUPPORT.TICKETS": doc}, home=self.home)
        fresh = publish.planned(self.db.run, spec, self.home)
        self.assertTrue(fresh[0].startswith("EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('support'"), "nothing there: the whole model")
        self.approve(doc)
        self.assertEqual([], publish.planned(self.db.run, publish.kept("support", self.home)["spec"], self.home),
                         "published and unchanged: nothing to run")
        mine = [s for s in fresh if "ADD_AGENT_INSTRUCTION" not in s]
        self.db.sv.scripts.clear()
        with mock.patch.object(store, "kit_home", return_value=self.home):
            done = publish.run_statements(self.db.execute, self.db.run, "support", ["EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL_IF_EXISTS('support')"] + mine,
                                          "MCP_READONLY", self.home)
        self.assertEqual(("your statements", len(mine) + 1), (done["mode"], done["statements"]))
        self.assertEqual("DROP_MODEL_IF_EXISTS", self.db.sv.scripts[0])
        self.assertTrue(publish.kept("support", self.home)["spec"]["edited"], "marked edited by hand")
        with self.assertRaisesRegex(semantic_model.ModelRefused, "Only Semantic Views"):
            publish.run_statements(self.db.execute, self.db.run, "support", ["DROP TABLE SUPPORT.TICKETS"], None, self.home)
        self.db.sv.scripts.clear()
        doc = self.describe(force=True)["doc"]
        doc["columns"]["CHANNEL"] = dict(doc["columns"]["CHANNEL"], note="Where it came in")
        self.approve(doc)
        self.assertIn("DROP_MODEL_IF_EXISTS", self.db.sv.scripts, "an edited model is built again, not changed in place")

    def test_every_approval_also_updates_the_one_model_of_all_your_data(self):
        doc = self.describe()["doc"]
        result = self.approve(doc)
        self.assertIn("all_data", self.db.sv.models, "the model of all your data is built with the first approval")
        self.assertEqual([("SUPPORT", "TICKETS")], self.db.sv.models["all_data"]["entities"])
        self.assertTrue(json.loads((self.home / "semantic" / "all_data.json").read_text(encoding="utf-8"))["inputs"]["all"])
        self.assertFalse(any("all_data" in w for w in result.get("warnings") or []), result.get("warnings"))

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
        self.assertEqual(["o_orderkey", "o_custkey", "o_orderdate", "o_orderdate_month", "o_orderstatus", "c_custkey",
                          "c_mktsegment"], names, "keys and identifiers are dimensions too: filter and join on them")
        self.assertIn("Used as the key", next(d for d in orders["dimensions"] if d["name"] == "o_orderkey")["comment"])
        self.assertNotIn("c_phone", " ".join(names))                       # a sensitive column is never a dimension
        self.assertEqual(["orders_count", "total_o_totalprice", "average_o_totalprice"], [m["name"] for m in orders["metrics"]])
        self.assertTrue(next(f for f in orders["facts"] if f.get("column") == "O_SECRET")["private"])
        courier = spec["objects"][1]
        self.assertEqual("CAST(t3.DELIVERIES AS DOUBLE)", courier["facts"][1]["expression"])   # a number sent as text
        self.assertEqual(["courier_daily_state", "courier_daily_day", "day_month"], [d["name"] for d in courier["dimensions"]])
        self.assertTrue(spec["entities"][2]["virtual"])
        self.assertIn("read live where it lives", spec["entities"][2]["description"])
        kinds = {(i["entity"], i["kind"]) for i in spec["instructions"]}
        self.assertIn(("courier_daily", "PRECONDITION"), kinds, "a table read live says so to an agent")
        self.assertTrue(any(k == "SAFETY" for _e, k in kinds), "a personal-data column is a safety rule")

    def test_the_statements_create_the_model_then_publish_it(self):
        sent = semantic_model.statements(self.spec())
        self.assertTrue(sent[0].startswith("EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('sales_360', 'SEM_SALES_360', "))
        self.assertIn("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP('sales_360', 'orders_to_customer', 'orders', "
                      "'customer', 't1.O_CUSTKEY = t2.C_CUSTKEY', 'MANY_TO_ONE', 'LEFT', NULL)", sent)
        published = sent.index("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales_360')")
        self.assertTrue(all("ADD_AGENT_INSTRUCTION" in x for x in sent[published + 1:]), "instructions follow the publish")
        definition = next(s for s in sent if "ALTER SEMANTIC VIEW sales_360.ORDERS" in s)
        self.assertIn("COMMENT ''Order value incl. tax. Used as a number: add it up or average it", definition)   # note + why
        self.assertIn("AS total_o_totalprice / NULLIF(orders_count, 0)", definition)

    def test_a_link_found_from_the_values_is_declared_unique_and_keeps_its_evidence(self):
        """A link ends on a column that is unique but is not the column map's key (a state name): Semantic Views
        refuses the relationship unless that column is a declared unique key (SEMANTIC_MODEL_033, met live)."""
        states = {"columns": {"STATE_CODE": {"role": "key"}, "STATE_NAME": {"role": "category"}, "REGION": {"role": "category"}},
                  "slots": {"key": "STATE_CODE"}}
        evidence = {"proposed_by": "values", "rows": {"rows": 128942, "matched": 128921, "unmatched": 21}}
        spec = semantic_model.build(
            [semantic_model.table_input("TPCH.ORDERS", self.ORDERS, {"O_TOTALPRICE": "DECIMAL(15,2)", "O_ORDERDATE": "DATE"}),
             semantic_model.table_input("GEO.STATES", states, {})],
            [{"from": "TPCH.ORDERS.O_ORDERSTATUS", "to": "GEO.STATES.STATE_NAME", "evidence": evidence}], "orders by state")
        sent = semantic_model.statements(spec)
        self.assertTrue(any("ADD_UNIQUE_KEY_WITH_COLUMNS('orders_by_state', 'states', 'states_state_name_uk', 'UNIQUE'" in s
                            for s in sent), "the link's target is a declared unique key")
        stored = next(s for s in sent if "ADD_CUSTOM_EXTENSION" in s and "'RELATIONSHIP'" in s)
        self.assertIn("'orders_to_states', 'exakit'", stored)
        self.assertIn('"matched": 128921', stored)                       # why the link is there, kept in the model
        sources = next(s for s in sent if "ADD_CUSTOM_EXTENSION" in s and "'MODEL'" in s)
        self.assertIn('"table": "GEO.STATES"', sources)
        self.assertLess(sent.index(stored), sent.index(next(s for s in sent if "ADD_SEMANTIC_OBJECT" in s)))

    def test_a_link_unique_on_both_sides_is_one_to_one_and_a_change_rebuilds(self):
        """A pointer that is unique as well (its table's key, or measured unique by the link check) makes the link
        ONE_TO_ONE, declared unique on both ends; a link whose kind changes is not changed in place."""
        invoices = {"columns": {"ORDER_REF": {"role": "key"}, "TAX": {"role": "measure"}}, "slots": {"key": "ORDER_REF"}}
        tables = [semantic_model.table_input("TPCH.ORDERS", self.ORDERS, {"O_TOTALPRICE": "DECIMAL(15,2)", "O_ORDERDATE": "DATE"}),
                  semantic_model.table_input("BILL.INVOICES", invoices, {"TAX": "DECIMAL(15,2)"})]
        one = semantic_model.build(tables, [{"from": "BILL.INVOICES.ORDER_REF", "to": "TPCH.ORDERS.O_ORDERKEY"}], "bills")
        self.assertEqual(["ONE_TO_ONE"], [r["cardinality"] for r in one["relationships"]])
        self.assertTrue(any("'ONE_TO_ONE', 'LEFT'" in x for x in semantic_model.statements(one)))
        measured = semantic_model.build(tables, [{"from": "TPCH.ORDERS.O_CUSTKEY", "to": "BILL.INVOICES.ORDER_REF",
                                                  "evidence": {"from_unique": True}}], "bills")
        self.assertEqual("ONE_TO_ONE", measured["relationships"][0]["cardinality"])
        self.assertIn("O_CUSTKEY", next(e for e in measured["entities"] if e["table"] == "ORDERS")["unique"],
                      "the pointer is a declared unique key too")
        many = semantic_model.build(tables, [{"from": "TPCH.ORDERS.O_CUSTKEY", "to": "BILL.INVOICES.ORDER_REF"}], "bills")
        self.assertEqual("MANY_TO_ONE", many["relationships"][0]["cardinality"])
        step = semantic_model.changes(many, measured)
        self.assertEqual(["ADD_UNIQUE_KEY_WITH_COLUMNS", "SET_RELATIONSHIP", "PUBLISH_MODEL"],
                         [re.search(r"SEMANTIC_ADMIN\.(\w+)", x).group(1) for x in step],
                         "a link turned one-to-one is changed in place by Semantic Views, after the key it needs")
        self.assertIn("'ONE_TO_ONE'", step[1])
        back = semantic_model.changes(measured, many)
        self.assertEqual(["SET_RELATIONSHIP", "REMOVE_UNIQUE_KEY_WITH_COLUMNS", "PUBLISH_MODEL"],
                         [re.search(r"SEMANTIC_ADMIN\.(\w+)", x).group(1) for x in back], "and back, the key taken away in place")
        gone = semantic_model.changes(many, dict(many, relationships=[], objects=[o for o in many["objects"] if o["name"] != "INVOICES"]))
        self.assertEqual(["REMOVE_SEMANTIC_OBJECT", "REMOVE_RELATIONSHIP_KEY_MAPPING", "REMOVE_RELATIONSHIP"],
                         [re.search(r"SEMANTIC_ADMIN\.(\w+)", x).group(1) for x in gone][:3], "a view and a link taken away, in place")

    def test_what_you_say_goes_into_the_model_as_semantic_views_definitions(self):
        """Your grain, where questions start, metrics with a condition and rules for AI tools become Semantic Views'
        own definitions; a name that is not in the data map is refused with the reason, never guessed at."""
        tables = [semantic_model.table_input("TPCH.ORDERS", self.ORDERS, {"O_TOTALPRICE": "DECIMAL(15,2)", "O_ORDERDATE": "DATE"}),
                  semantic_model.table_input("TPCH.CUSTOMER", self.CUSTOMER, {})]
        spec = semantic_model.build(tables, [{"from": "TPCH.ORDERS.O_CUSTKEY", "to": "TPCH.CUSTOMER.C_CUSTKEY"}], "shop",
                                    grains={"tpch.customer": "one  customer"}, starts=["TPCH.CUSTOMER"])
        self.assertEqual("one customer", next(e for e in spec["entities"] if e["table"] == "CUSTOMER")["grain"])
        self.assertEqual(["CUSTOMER", "ORDERS"], [o["name"] for o in spec["objects"]],
                         "the table you said questions start from first; one it does not reach keeps a view of its own")
        spec = semantic_model.build(tables, [{"from": "TPCH.ORDERS.O_CUSTKEY", "to": "TPCH.CUSTOMER.C_CUSTKEY"}], "shop")
        extra, refused = semantic_model.user_metrics(spec, [
            {"table": "TPCH.ORDERS", "name": "Open value", "how": "sum", "column": "O_TOTALPRICE",
             "where": {"column": "O_ORDERSTATUS", "values": ["O", "P's"]}, "about": "Value of open orders"},
            {"table": "TPCH.ORDERS", "name": "open_orders", "how": "count", "where": {"column": "O_ORDERSTATUS", "values": ["O"]}},
            {"table": "TPCH.ORDERS", "name": "avg_value", "how": "average", "column": "O_TOTALPRICE"},
            {"table": "TPCH.ORDERS", "name": "bad", "how": "sum", "column": "O_ORDERSTATUS"},
            {"table": "TPCH.NOPE", "name": "nope", "how": "sum", "column": "X"},
            {"table": "TPCH.ORDERS", "name": "cond", "how": "count", "where": {"column": "O_ORDERSTATUS", "values": []}}])
        ddl = [d for _v, d in extra]
        self.assertIn("ADD OR REPLACE METRIC open_value\n  AS SUM(", ddl[0])
        self.assertIn("FILTER (WHERE o_orderstatus IN ('O', 'P''s'))", ddl[0])
        self.assertIn("COMMENT 'Value of open orders'", ddl[0])
        self.assertIn("FILTER (WHERE o_orderstatus = 'O')", ddl[1])
        self.assertEqual(["avg_value_total", "avg_value_rows", "avg_value"], [re.search(r"METRIC (\w+)", d).group(1) for d in ddl[2:5]])
        self.assertIn("AS avg_value_total / NULLIF(avg_value_rows, 0)", ddl[4])
        self.assertEqual(["metric bad: O_ORDERSTATUS is not an amount of TPCH.ORDERS",
                          "metric nope: TPCH.NOPE is not a starting point of the data map",
                          "metric cond: name the values of O_ORDERSTATUS that count"], refused)
        rules = semantic_model.user_instructions(spec, ["Value includes tax.", {"table": "TPCH.CUSTOMER", "text": "Segments are 2024's."}, ""])
        self.assertEqual([("MODEL", None), ("ENTITY", "customer")], [(r["scope"], r["entity"]) for r in rules])
        sent = semantic_model.instruction_statements("shop", rules)
        self.assertTrue(sent[0].startswith("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION('shop', 'MODEL', NULL, 'GENERAL'"))

    def test_a_hidden_column_gets_semantic_views_mask_and_is_cleared_when_shown_again(self):
        tables = [semantic_model.table_input("TPCH.ORDERS", self.ORDERS, {"O_TOTALPRICE": "DECIMAL(15,2)", "O_ORDERDATE": "DATE"}),
                  semantic_model.table_input("TPCH.CUSTOMER", self.CUSTOMER, {})]
        spec = semantic_model.build(tables, [{"from": "TPCH.ORDERS.O_CUSTKEY", "to": "TPCH.CUSTOMER.C_CUSTKEY"}], "shop")
        found, refused = semantic_model.field_policies(spec, {"TPCH.CUSTOMER": ["C_MKTSEGMENT", "C_PHONE"]})
        self.assertEqual([("ORDERS", "c_mktsegment")], [(x["object"], x["field"]) for x in found], "every view that shows it")
        self.assertEqual(["hide TPCH.CUSTOMER.C_PHONE: it is not a column to group by in your data map"], refused,
                         "a personal-data column of a column map is not in the model at all")
        sent = []
        spec["policies"] = found
        with mock.patch.object(semantic_model, "existing", return_value=None):
            semantic_model.apply(sent.append, lambda sql: [], spec)
        self.assertIn("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_FIELD_POLICY('shop', 'ORDERS', 'c_mktsegment', 'MASK', 'personal data')", sent)
        previous = dict(spec)
        shown = dict(spec, policies=[])
        sent.clear()
        with mock.patch.object(semantic_model, "existing", return_value={"name": "shop", "kit": True}), \
                mock.patch.object(semantic_model, "changes", return_value=[]):
            semantic_model.apply(sent.append, lambda sql: [], shown, previous=previous)
        self.assertIn("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_FIELD_POLICY('shop', 'ORDERS', 'c_mktsegment', NULL, NULL)", sent,
                      "shown again: the policy is cleared")

    def test_the_model_is_the_record_with_its_versions(self):
        """Each save that changes what was said adds the next data_map_v<N> to the model - the inputs and the model as
        Semantic Views exports it; an unchanged save adds nothing; a rebuild (which drops a model's extensions) puts
        every version back first. All of it read with GET_CUSTOM_EXTENSIONS."""
        v1 = {"version": 1, "saved_at": "2026-11-01T10:00:00Z", "inputs": {"tables": ["A.B"], "links": []}, "definition": []}
        kept_rows = [{"SCOPE_TYPE": "MODEL", "SCOPE_NAME": None, "EXTENSION_NAME": "data_map_v1", "DATA_JSON": json.dumps(v1)},
                     {"SCOPE_TYPE": "ENTITY", "SCOPE_NAME": "orders", "EXTENSION_NAME": "column_map_v2", "DATA_JSON": json.dumps({"version": 2})},
                     {"SCOPE_TYPE": "MODEL", "SCOPE_NAME": None, "EXTENSION_NAME": "sources", "DATA_JSON": "[]"}]
        rows = lambda sql: (kept_rows if "GET_CUSTOM_EXTENSIONS" in sql else
                            [{"DEFINITION_KIND": "MODEL", "DEFINITION_SQL": "CREATE SEMANTIC MODEL shop"}] if "EXPORT_SEMANTIC_DEFINITION" in sql else [])
        carried = publish.extensions(rows, "shop", r"(data_map|column_map)_v\d+")
        self.assertEqual(["data_map_v1", "column_map_v2"], [x["name"] for x in carried])
        sent = []
        self.assertEqual((1, []), publish._versioned(sent.append, rows, "shop", {"tables": ["A.B"], "links": []}, carried, False))
        self.assertEqual([], sent, "nothing changed: no new version")
        number, _said = publish._versioned(sent.append, rows, "shop", {"tables": ["A.B"], "links": [{"from": "x", "to": "y"}]}, carried, True)
        self.assertEqual(2, number)
        self.assertEqual(["data_map_v1", "column_map_v2", "data_map_v2"], [re.findall(r"'(\w+_v\d+)'\)$", x)[0] for x in sent],
                         "rebuilt: the history first, then the new version")
        self.assertIn("'ENTITY', 'orders'", sent[1])
        self.assertIn("CREATE SEMANTIC MODEL shop", sent[2], "the whole model as Semantic Views exports it")

    def test_join_rules_and_your_words_go_to_semantic_views(self):
        tables = [semantic_model.table_input("TPCH.ORDERS", self.ORDERS, {"O_TOTALPRICE": "DECIMAL(15,2)", "O_ORDERDATE": "DATE"}),
                  semantic_model.table_input("TPCH.CUSTOMER", self.CUSTOMER, {})]
        link = {"from": "TPCH.ORDERS.O_CUSTKEY", "to": "TPCH.CUSTOMER.C_CUSTKEY"}
        left = semantic_model.build(tables, [link], "shop")
        inner = semantic_model.build(tables, [dict(link, join_type="INNER", fanout="REFERENCE_ONLY")], "shop")
        self.assertTrue(any("'MANY_TO_ONE', 'INNER', 'REFERENCE_ONLY')" in x for x in semantic_model.statements(inner)))
        step = semantic_model.changes(left, inner)
        self.assertIn("SET_RELATIONSHIP('shop', 'orders_to_customer', NULL, 'MANY_TO_ONE', 'INNER', 'REFERENCE_ONLY')", " ".join(step),
                      "join rules change in place")
        back = semantic_model.changes(inner, left)
        self.assertIn("'MANY_TO_ONE', 'LEFT', 'NONE')", " ".join(back), "a fanout policy taken away is cleared")
        calls, refused = semantic_model.user_synonyms(left, {"total_o_totalprice": ["sales", "revenue"], "open_value": ["open"], "nope": ["x"]},
                                                      [{"name": "open_value"}])
        metric = next(m for m in left["objects"][0]["metrics"] if m["name"] == "total_o_totalprice")
        self.assertEqual(["sales", "revenue"], metric["synonyms"][-2:], "in the field's own definition, after the ones it had")
        self.assertIn("'sales', 'revenue')", semantic_model.definition(left, left["objects"][0]))
        self.assertEqual([{"type": "METRIC", "name": "open_value", "synonym": "open"}], calls, "a metric of yours: ADD_SYNONYM")
        self.assertEqual(["synonyms for nope: no field of that name in your data map"], refused)

    def test_the_ai_draft_keeps_only_real_names_and_reads_no_row(self):
        """One call drafts the data map from the approved column maps on this computer; whatever names no real table
        or column is dropped and said. The prompt holds names, roles, notes and known values only."""
        with tempfile.TemporaryDirectory() as home:
            base = Path(home)
            docs = {"TPCH.ORDERS": self.ORDERS, "TPCH.CUSTOMER": self.CUSTOMER}
            seen = []
            answer = {"description": "Orders.", "grains": {"TPCH.ORDERS": "one order", "X.Y": "no"},
                      "links": [{"from": "TPCH.ORDERS.O_CUSTKEY", "to": "TPCH.CUSTOMER.C_CUSTKEY", "type": "many-to-one"},
                                {"from": "TPCH.ORDERS.NOPE", "to": "TPCH.CUSTOMER.C_CUSTKEY"}],
                      "starts": ["TPCH.ORDERS", "X.Y"],
                      "metrics": [{"table": "TPCH.ORDERS", "name": "Open value", "how": "sum", "column": "O_TOTALPRICE",
                                   "where": {"column": "O_ORDERSTATUS", "values": ["O"]}},
                                  {"table": "TPCH.ORDERS", "name": "x", "how": "sum", "column": "O_COMMENT"}],
                      "instructions": ["Value includes tax."]}
            with mock.patch.object(store, "current", side_effect=lambda t, h=None: t if t in docs else None), \
                    mock.patch.object(publish, "_load", side_effect=lambda text: dict(docs[text], version=1)), \
                    mock.patch.object(store, "read_profile", return_value=None):
                found = publish.draft_data_map(["TPCH.ORDERS", "TPCH.CUSTOMER"], lambda prompt: seen.append(prompt) or json.dumps(answer),
                                               home=base)
                facts = publish.data_map_inputs(["TPCH.ORDERS", "TPCH.NOPE"], home=base)
        self.assertEqual(({"TPCH.ORDERS": "one order"}, ["TPCH.ORDERS"], "Orders.", ["Value includes tax."]),
                         (found["grains"], found["starts"], found["description"], found["instructions"]))
        self.assertEqual([("TPCH.ORDERS.O_CUSTKEY", "TPCH.CUSTOMER.C_CUSTKEY", "MANY_TO_ONE", "ai")],
                         [(l["from"], l["to"], l["type"], l["by"]) for l in found["links"]])
        self.assertEqual([("open_value", "O_TOTALPRICE", {"column": "O_ORDERSTATUS", "values": ["O"]})],
                         [(m["name"], m["column"], m["where"]) for m in found["metrics"]])
        self.assertEqual(2, len(found["refused"]))
        self.assertNotIn("O_SECRET", seen[0], "a personal-data column is never shown")
        self.assertEqual((["TPCH.ORDERS"], ["TPCH.NOPE"], False), (list(facts["tables"]), facts["missing"], facts["saved"]))

    def test_an_ai_proposal_is_checked_before_it_is_used(self):
        spec = self.spec()
        labels, extra, refused = semantic_model.ai_accept(spec, {
            "model": "Orders and deliveries", "labels": {"o_totalprice": {"display": "Order value"}, "nope": {}},
            "metrics": [{"view": "ORDERS", "name": "open_order_value", "expression": "SUM(o_totalprice)",
                         "filter": "o_orderstatus = 'O'"},
                        {"view": "ORDERS", "name": "made_up", "expression": "SUM(o_orderstatus)", "filter": "o_orderstatus = 'Z'"},
                        {"view": "ORDERS", "name": "secret_sum", "expression": "SUM(o_secret)"},
                        {"view": "ORDERS", "name": "drop", "expression": "SUM(o_totalprice); DROP TABLE X"},
                        {"view": "ORDERS", "name": "orders_count", "expression": "SUM(o_totalprice)"},
                        {"view": "ORDERS", "name": "open_share", "expression": "open_order_value / NULLIF(total_o_totalprice, 0)"}]})
        self.assertEqual({"o_totalprice": {"display": "Order value"}, "model": "Orders and deliveries"}, labels)
        self.assertEqual(2, len(extra))                    # open_share builds on the open_order_value accepted before it
        self.assertIn("FILTER (WHERE o_orderstatus = 'O')", extra[0][1])
        self.assertIn("RATIO PUBLIC", extra[1][1])
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
