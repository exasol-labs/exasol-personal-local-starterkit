"""(run: python3 tests/test_board.py) A dashboard of several pages: pinning approved answers to pages
(exakit_nb.board), the Dash app's files and lineage (exakit_nb.share.board_draft), what the insights say
(exakit_nb.insights), and the app itself (exakit_nb.board_template) - only the open tab's tiles are queried, in
parallel, a result is kept and filtered without querying again, and a slow query does not hold the page. The app
part needs dash (the kit's dashboard environment has it); it is skipped without."""

from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "notebook" / "package"), str(ROOT / "setup" / "lib")]

try:
    import pandas as pd
except ImportError:                              # pragma: no cover - the kit's notebook environment has it
    pd = None
try:
    import dash  # noqa: F401
    HAVE_DASH = True
except ImportError:
    HAVE_DASH = False


def proposal(question: str, sql: str, approved: bool = True):
    found = types.SimpleNamespace(question=question, sql=sql, request=None,
                                  dataset=types.SimpleNamespace(id="amazon_sales", version=3))
    found._approved_digest = hashlib.sha256(sql.encode("utf-8")).hexdigest() if approved else None
    return found


@unittest.skipUnless(pd is not None, "pandas is not installed here (the kit's notebook environment has it)")
class BoardTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        env = mock.patch.dict(os.environ, {"EXAKIT_HOME": self.temp.name})
        env.start()
        self.addCleanup(env.stop)
        import importlib
        self.board = importlib.import_module("exakit_nb.board")
        importlib.import_module("exakit_nb.workflow").workflow("board-test")

    def test_an_approved_answer_is_pinned_once_per_page_and_shown_as_its_shape(self):
        by_category = pd.DataFrame({"CATEGORY": ["a", "b"], "REVENUE": [3.0, 5.0]})
        over_time = pd.DataFrame({"MONTH": ["2026-01", "2026-02"], "ORDERS": [3, 4]})
        total = pd.DataFrame({"TOTAL": [12]})
        with self.assertRaisesRegex(RuntimeError, "Approve"):
            self.board.pin(proposal("q", "SELECT 1", approved=False), total)
        tile = self.board.pin(proposal("Revenue by category?", "SELECT CATEGORY, SUM(R) AS REVENUE FROM T GROUP BY 1"),
                              by_category, board="sales", page="Revenue")
        self.assertEqual(("bar", "Revenue by category", ["CATEGORY"]), (tile["kind"], tile["title"], tile["dimensions"]))
        self.board.pin(proposal("Orders per month?", "SELECT MONTH, COUNT(*) AS ORDERS FROM T GROUP BY 1"), over_time,
                       board="sales", page="Trend")
        self.board.pin(proposal("Total?", "SELECT COUNT(*) AS TOTAL FROM T"), total, board="sales", page="Revenue")
        self.board.pin(proposal("Revenue by category?", "SELECT CATEGORY, SUM(R) AS REVENUE FROM T GROUP BY 1"),
                       by_category, board="sales", page="Revenue")
        found = self.board.board("sales")
        self.assertEqual([("Revenue", ["bar", "kpi"]), ("Trend", ["line"])],
                         [(p["title"], sorted(t["kind"] for t in p["tiles"])) for p in found.pages], "the same SQL is one tile")
        self.assertEqual([{"name": "sales", "title": "Sales", "pages": 2, "tiles": 3}],
                         [{k: v for k, v in b.items() if k != "changed"} for b in self.board.boards()])
        self.assertEqual(["CATEGORY"], found.filters(found.pages[0]), "a KPI does not narrow a page's filters")
        found.move(tile["id"], "Trend").save()
        self.assertEqual(["Revenue", "Trend"], [p["title"] for p in self.board.board("sales").pages])
        self.assertEqual([], found.filters(found.pages[1]), "no column every tile of the page returns")
        found.remove(tile["id"]).remove(found.pages[0]["tiles"][0]["id"]).save()
        self.assertEqual(["Trend"], [p["title"] for p in self.board.board("sales").pages], "an empty page goes")

    def test_the_dash_app_carries_every_approved_sql_unchanged_and_its_lineage(self):
        from exakit_nb.share import board_draft
        sql = "SELECT CATEGORY, SUM(R) AS REVENUE FROM T GROUP BY 1"
        self.board.pin(proposal("Revenue by category?", sql), pd.DataFrame({"CATEGORY": ["a"], "REVENUE": [1.0]}),
                       board="sales", page="Revenue")
        with mock.patch("sys.stdout"):
            draft = self.board.board("sales").share()
        files = {f["path"]: f["content"] for f in draft.files}
        digest = hashlib.sha256(sql.encode("utf-8")).hexdigest()
        self.assertEqual(sql + "\n", files[f"queries/{digest[:8]}.sql"])
        spec = json.loads(files["BOARD.json"])
        self.assertEqual(["Revenue"], [p["title"] for p in spec["pages"]])
        self.assertEqual(digest, spec["pages"][0]["tiles"][0]["sql_digest"])
        lineage = json.loads(files["REVISION.json"])
        self.assertEqual(("sales", digest), (lineage["board"], lineage["tiles"][digest[:8]]["sql_digest"]))
        self.assertNotIn("password", json.dumps(files).lower())
        self.assertTrue(draft._owns(lineage) and not draft._owns({"board": "other", "workflow_id": "x"}))
        kept = self.board.board("sales")
        kept.pages[0]["tiles"][0]["sql"] = sql + " LIMIT 5"          # changed after it was approved
        with self.assertRaisesRegex(RuntimeError, "no longer matches"):
            board_draft(kept, "sales")

    def _dataset(self, table, columns, date=None, grain="one row per order"):
        roles = {"date": date} if date else {}
        ds = types.SimpleNamespace(id=table.split(".")[1].lower(), version=1, fact_table=table,
                                   descriptor=types.SimpleNamespace(columns=columns, grain=grain),
                                   has=lambda role: role in roles, col=lambda role: f'"{roles[role]}"')
        first = next((c for c, e in columns.items() if e.get("role") == "category"), None)
        ds.group_by = (lambda: ("category", f'"{first}"')) if first else (lambda: (_ for _ in ()).throw(ValueError("none")))
        return ds

    def test_a_starter_dashboard_has_a_page_per_table_and_follows_the_saved_links(self):
        orders = self._dataset("VS_SALES.ORDERS", {"ORDER_ID": {"role": "key"}, "CUSTOMER_ID": {"role": "identifier"},
                                                   "STATUS": {"role": "category"}, "AMOUNT": {"role": "measure"},
                                                   "EMAIL": {"role": "category", "sensitive": True},
                                                   "ORDER_DATE": {"role": "time"}}, date="ORDER_DATE")
        customers = self._dataset("CRM.CUSTOMERS", {"ID": {"role": "key"}, "SEGMENT": {"role": "category"}},
                                  grain="one row per customer")
        link = [{"from": "VS_SALES.ORDERS", "column": "CUSTOMER_ID", "to": "CRM.CUSTOMERS", "key": "ID"}]
        with mock.patch.object(self.board, "_starter_links", return_value=link), mock.patch("builtins.print"):
            made = self.board.starter_board(None, [orders, customers], name="overview")
        self.assertEqual(["Orders", "Customers"], [p["title"] for p in made.pages], "a page per table, named after it")
        titles = [t["title"] for t in made.pages[0]["tiles"]]
        self.assertEqual(["Number of orders", "Total amount", "Orders by status", "Total amount by status", "Orders over time",
                          "Orders by segment (customers)"], titles)
        joined = made.pages[0]["tiles"][-1]["sql"]
        self.assertIn('JOIN CRM.CUSTOMERS b ON a."CUSTOMER_ID" = b."ID"', joined)
        self.assertNotIn("EMAIL", json.dumps(made.pages), "a personal-data column is never used")
        self.assertEqual(["STATUS"], made.filters(made.pages[0]), "the two tiles by status share a filter")
        self.board.pin(proposal("Mine?", "SELECT 1 AS N"), pd.DataFrame({"N": [1]}), board="overview", page="Mine")
        with mock.patch.object(self.board, "_starter_links", return_value=[]), mock.patch("builtins.print"):
            again = self.board.starter_board(None, [orders], name="overview")
        self.assertEqual(["Orders", "Mine"], [p["title"] for p in again.pages], "made again: its pages replaced, yours kept")
        with mock.patch.object(self.board, "_starter_links", return_value=[]), mock.patch("builtins.print"), \
                self.assertRaisesRegex(ValueError, "Nothing to show"):
            self.board.starter_board(None, [self._dataset("A.B", {"ID": {"role": "key"}})], name="empty")

    def test_the_starter_rules_change_the_tiles(self):
        orders = self._dataset("VS_SALES.ORDERS", {"STATUS": {"role": "category"}, "REGION": {"role": "category"},
                                                   "ID": {"role": "identifier"}, "AMOUNT": {"role": "measure"},
                                                   "ORDER_DATE": {"role": "time"}}, date="ORDER_DATE")
        with mock.patch.object(self.board, "_starter_links", return_value=[]), mock.patch("builtins.print"):
            made = self.board.starter_board(None, [orders], name="ruled", rules={
                "GROUPS": 1, "TOP": 5, "PERIOD": "week", "MEASURE_SUM": "avg", "TOTAL_BY_GROUP": False,
                "GROUP_ROLES": ["category", "identifier"]})
        tiles = made.pages[0]["tiles"]
        self.assertEqual(["Number of orders", "Average amount", "Orders by status", "Orders over time"], [t["title"] for t in tiles])
        self.assertIn("LIMIT 5", tiles[2]["sql"])
        self.assertIn("AVG(\"AMOUNT\")", tiles[1]["sql"])
        self.assertIn("DATE_TRUNC('WEEK'", tiles[3]["sql"])
        for wrong in ({"GROUPS": "many"}, {"PERIOD": "DECADE"}, {"NOPE": 1}, {"TREND": "yes"}):
            with self.assertRaises(ValueError), mock.patch("builtins.print"):
                self.board.starter_board(None, [orders], name="ruled", rules=wrong)
        self.assertEqual(3, self.board.starter_rules()["GROUPS"])

    def test_a_table_is_compared_by_a_group_of_a_table_it_links_to(self):
        import importlib
        across = importlib.import_module("exakit_nb.across")
        orders = self._dataset("VS_SALES.ORDERS", {"CUSTOMER_ID": {"role": "identifier"}})
        doc = {"columns": {"ID": {"role": "key"}, "SEGMENT": {"role": "category"}, "PHONE": {"role": "category", "sensitive": True}}}
        service = types.SimpleNamespace(flow=types.SimpleNamespace(load=lambda text: doc), store=types.SimpleNamespace(current=lambda t: "x"))
        with mock.patch.object(across, "_links", return_value=[{"column": "CUSTOMER_ID", "to": "VS_CRM.CUSTOMERS", "key": "ID"}]), \
                mock.patch.object(across, "_service", return_value=service), \
                mock.patch.object(across, "_origins", return_value={"VS_CRM": {"connector_name": "MongoDB"}, "VS_SALES": {"connector_name": "Snowflake"}}), \
                mock.patch("exakit_nb.descriptor_store.approved_datasets", return_value=[{"table": "VS_CRM.CUSTOMERS"}]):
            groups = across.linked_groups(orders)
            self.assertEqual([("VS_CRM.CUSTOMERS::SEGMENT", "SEGMENT · from CUSTOMERS (MongoDB)")], [(g["value"], g["label"]) for g in groups])
            sql = across.across_sql(orders, groups[0])
            self.assertIn('JOIN VS_CRM.CUSTOMERS b ON a."CUSTOMER_ID" = b."ID"', sql)
            self.assertEqual(["Snowflake", "MongoDB"], across.read_from(sql))
            self.assertEqual(["this database"], across.read_from("SELECT 1 FROM MY_DATA.T"))
        with mock.patch.object(across, "_links", return_value=[]):
            self.assertEqual([], across.linked_groups(orders), "no saved link: nothing changes")

    def test_a_tile_says_whether_its_sql_orders_the_rows(self):
        frame = pd.DataFrame({"STATE": ["a"], "N": [1]})
        self.board.pin(proposal("By state?", "SELECT STATE, COUNT(*) AS N FROM T GROUP BY 1"), frame, board="sorted")
        self.board.pin(proposal("Top states?", "SELECT STATE, COUNT(*) AS N FROM T GROUP BY 1 order  by 2 DESC"), frame, board="sorted")
        tiles = self.board.board("sorted").spec()["pages"][0]["tiles"]
        self.assertEqual([False, True], [t["ordered"] for t in tiles],
                         "the dashboard sorts a bar chart largest first only when its SQL leaves the order open")

    def test_the_dashboard_rules_filters_and_your_own_app_are_used(self):
        self.board.pin(proposal("By state?", "SELECT STATE, COUNT(*) AS N FROM T GROUP BY 1"),
                       pd.DataFrame({"STATE": ["a"], "CAT": ["x"], "N": [1]}), board="ruled", page="Revenue")
        self.board.pin(proposal("By cat?", "SELECT CAT, COUNT(*) AS N FROM T GROUP BY 1"),
                       pd.DataFrame({"STATE": ["a"], "CAT": ["x"], "N": [1]}), board="ruled", page="Revenue")
        b = self.board.board("ruled")
        b.rules = {"CACHE_SECONDS": 60, "PARALLEL": 8, "FILTERS": 1}
        b.save()
        again = self.board.board("ruled")
        self.assertEqual(["STATE"], again.filters(again.pages[0]), "FILTERS 1: the first shared column")
        again.set_filters("Revenue", ["CAT"]).save()
        spec = self.board.board("ruled").spec()
        self.assertEqual(["CAT"], spec["pages"][0]["filters"], "chosen by you")
        self.assertEqual((60, 8), (spec["settings"]["CACHE_SECONDS"], spec["settings"]["PARALLEL"]))
        with self.assertRaisesRegex(ValueError, "returns NOPE"):
            again.set_filters("Revenue", ["NOPE"])
        with self.assertRaisesRegex(ValueError, "not a dashboard rule"):
            self.board.Board("x", rules={"NOPE": 1}).save()
        with mock.patch("sys.stdout"):
            mine = self.board.board("ruled").share(app="def create_dash_app(server, url_base_pathname, metadata):\n    return None\n")
            with self.assertRaisesRegex(ValueError, "create_dash_app"):
                self.board.board("ruled").share(app="print('hello')")
        files = {f["path"]: f["content"] for f in mine.files}
        self.assertTrue(files["app.py"].startswith("def create_dash_app"))
        self.assertTrue(json.loads(files["REVISION.json"])["app"].startswith("yours"))
        self.board._folder().joinpath("ruled.preview.json").write_text("{}", encoding="utf-8")
        self.assertEqual(["ruled"], [x["name"] for x in self.board.boards()], "a preview file is no dashboard")

    def test_insights_say_the_largest_the_share_and_the_change(self):
        from exakit_nb import insights
        said = insights(pd.DataFrame({"CATEGORY": list("abcdefghij"), "REVENUE": [5, 3, 9, 1, 2, 2, 3, 100, 4, 5]}))
        self.assertEqual("10 rows.", said[0])
        self.assertIn("h has the largest revenue: 100 (75% of the total).", said)
        self.assertIn("Far from the rest: h (100).", said)
        said = insights(pd.DataFrame({"MONTH": ["2026-01", "2026-02", "2026-03"], "ORDERS": [10, 12, 15]}))
        self.assertIn("orders went from 10 (2026-01) to 15 (2026-03): up 50%.", said)
        self.assertEqual(["0 rows."], insights(pd.DataFrame({"A": []})))


class AskFromTheModelTest(unittest.TestCase):
    """Ask answers from the semantic model: a verified question first (no model asked), else the model picks metric
    and dimension names and the semantic layer writes the SQL (COMPILE_REQUEST_JSON); an ambiguous request says the
    product's choices. Edited SQL drops the request, so it cannot be kept as verified."""

    def setUp(self):
        import importlib
        self.ask = importlib.import_module("exakit_nb.ask")
        self.semantic = {"model": "sales", "object": "ORDERS", "view": "SEM_SALES.ORDERS", "conn": object(),
                         "dimensions": [{"name": "state"}], "metrics": [{"name": "total_amount"}]}
        self.dataset = types.SimpleNamespace(id="amazon_sales", version=2, fact_table="AMAZON.ORDERS",
                                             require_approved=lambda _why: None)
        self.service = mock.Mock()
        patch = mock.patch("exakit_nb.semantic._service", return_value=self.service)
        patch.start()
        self.addCleanup(patch.stop)

    def test_a_verified_question_answers_with_no_model_call(self):
        self.service.verified_questions.return_value = [
            {"name": "Revenue by state", "question": "What is the revenue by state?", "object": "ORDERS",
             "request": {"metrics": ["total_amount"], "dimensions": ["state"]}}]
        self.service.compile_request.return_value = {"status": "ok", "sql": "SELECT 1"}
        found = self.ask._verified_answer(object(), self.semantic, "what is the REVENUE by state", self.dataset)
        self.assertEqual("SELECT 1", found.sql)
        self.assertEqual({"model": "sales", "object": "ORDERS", "metrics": ["total_amount"], "dimensions": ["state"]}, found.request)
        self.assertIsNone(self.ask._verified_answer(object(), self.semantic, "orders per month?", self.dataset))

    def test_the_model_picks_names_and_the_semantic_layer_writes_the_sql(self):
        said = json.dumps({"metrics": ["total_amount"], "dimensions": ["state"], "limit": 5000, "assumptions": ["a"], "doubts": []})
        client = mock.Mock()
        client.chat.completions.create.return_value = types.SimpleNamespace(
            choices=[types.SimpleNamespace(message=types.SimpleNamespace(content=said))])
        self.service.compile_request.return_value = {"status": "ok", "sql": "SELECT STATE, SUM(AMOUNT) FROM T GROUP BY 1"}
        request, sql, assumptions, _, _plan, _id = self.ask._ask_request(client, "m", {}, self.semantic, "revenue by state?")
        self.assertEqual(1000, request["limit"], "capped")
        self.assertEqual(("sales", "ORDERS"), (request["model"], request["object"]))
        self.assertTrue(sql.startswith("SELECT STATE"))
        self.service.compile_request.return_value = {"status": "error", "error": "SEMANTIC_REQUEST_031: ambiguous",
                                                     "clarification": {"choices": ["state", "ship_state"]}}
        with self.assertRaisesRegex(ValueError, "ship_state"):
            self.ask._ask_request(client, "m", {}, self.semantic, "revenue by state?")
        proposal = self.ask.Proposal(self.dataset, "q", "SELECT 1", request={"model": "sales", "object": "ORDERS"})
        proposal.edit("SELECT 2")
        self.assertIsNone(proposal.request, "edited by hand: no request to keep")
        with self.assertRaisesRegex(RuntimeError, "Approve"):
            proposal.verify(object())


class DataMapChecksTest(unittest.TestCase):
    """A large data map is searched before the AI picks names; the plan comes back in plain words; an answer says
    whether the data map checked it; a pinned tile is compiled again when the data map changes."""

    def setUp(self):
        import importlib
        self.ask = importlib.import_module("exakit_nb.ask")
        self.service = mock.Mock()
        patch = mock.patch("exakit_nb.semantic._service", return_value=self.service)
        patch.start()
        self.addCleanup(patch.stop)

    def test_the_ai_gets_semantic_views_own_request_format_and_the_question_travels_with_the_request(self):
        semantic = {"model": "sales", "object": "ORDERS", "view": "SEM.ORDERS", "conn": object(),
                    "dimensions": [{"name": "state"}], "metrics": [{"name": "total_amount"}]}
        client = mock.Mock()
        client.chat.completions.create.return_value = types.SimpleNamespace(choices=[types.SimpleNamespace(
            message=types.SimpleNamespace(content=json.dumps({"metrics": ["total_amount"], "dimensions": ["state"]})))])
        self.service.glossary.return_value = ""
        self.service.valid_combinations.return_value = []
        self.service.request_contract.return_value = [{"section": "FILTER_OPERATOR", "name": "IN", "about": "one of", "required": False},
                                                      {"section": "REQUEST_KEY", "name": "proof_mode", "about": "x", "required": False}]
        self.service.compile_request.return_value = {"status": "ok", "sql": "SELECT 1", "explained": [], "request_id": 1}
        request, *_rest = self.ask._ask_request(client, "m", {}, semantic, "Revenue by state?")
        prompt = json.loads(client.chat.completions.create.call_args.kwargs["messages"][1]["content"])
        self.assertEqual([{"section": "FILTER_OPERATOR", "name": "IN", "about": "one of", "required": False}], prompt["request_format"],
                         "the product's own format; planner-only keys left out")
        self.assertEqual(("Revenue by state?", "exakit Ask"), (request["natural_language_text"], request["purpose"]),
                         "the question is kept with the request in Semantic Views' history")

    def test_a_pair_semantic_views_refuses_goes_back_to_the_ai_once(self):
        semantic = {"model": "sales", "object": "ORDERS", "view": "SEM.ORDERS", "conn": object(),
                    "dimensions": [{"name": "state"}, {"name": "product"}], "metrics": [{"name": "order_cost"}]}
        answers = [json.dumps({"metrics": ["order_cost"], "dimensions": ["product"]}),
                   json.dumps({"metrics": ["order_cost"], "dimensions": ["state"]})]
        client = mock.Mock()
        client.chat.completions.create.side_effect = lambda **_k: types.SimpleNamespace(
            choices=[types.SimpleNamespace(message=types.SimpleNamespace(content=answers.pop(0)))])
        self.service.glossary.return_value = ""
        self.service.valid_combinations.return_value = [
            {"metric": "order_cost", "dimension": "product", "valid": False, "reason": "FANOUT"},
            {"metric": "order_cost", "dimension": "state", "valid": True, "reason": ""}]
        self.service.compile_request.return_value = {"status": "ok", "sql": "SELECT 1", "explained": [], "request_id": 3}
        request, *_rest = self.ask._ask_request(client, "m", {}, semantic, "order cost by product?")
        self.assertEqual(["state"], request["dimensions"], "the second answer, with an allowed pair")
        second = client.chat.completions.create.call_args.kwargs["messages"][-1]["content"]
        self.assertIn("FANOUT", second)
        self.assertIn('"order_cost": ["state"]', second, "what each metric may be grouped by")
        answers[:] = [json.dumps({"metrics": ["order_cost"], "dimensions": ["product"]})] * 2
        self.service.compile_request.reset_mock()
        with self.assertRaisesRegex(ValueError, "does not allow order_cost by product"):
            self.ask._ask_request(client, "m", {}, semantic, "order cost by product?")
        self.service.compile_request.assert_not_called()

    def test_a_large_data_map_is_searched_and_a_small_one_shown_whole(self):
        many = {"model": "all_data", "object": "ORDERS", "view": "SEM.ORDERS", "conn": object(),
                "metrics": [{"name": f"m{i}"} for i in range(20)] + [{"name": "total_revenue"}],
                "dimensions": [{"name": f"d{i}"} for i in range(20)] + [{"name": "customer_country"}]}
        self.service.search_fields.side_effect = lambda _c, word, _m: (
            [{"object": "ORDERS", "name": "total_revenue", "score": 90}, {"object": "CARTS", "name": "m3", "score": 99}]
            if word == "revenue" else [{"object": "ORDERS", "name": "customer_country", "score": 80}] if word == "country" else [])
        narrowed, said = self.ask._narrowed(many, "What is the revenue by country?", self.ask.ask_rules())
        self.assertEqual((["total_revenue"], ["customer_country"]),
                         ([m["name"] for m in narrowed["metrics"]], [d["name"] for d in narrowed["dimensions"]]))
        self.assertIn("2 of its 42 fields", said)
        small = dict(many, metrics=many["metrics"][:2], dimensions=many["dimensions"][:2])
        self.assertEqual((small, None), self.ask._narrowed(small, "revenue?", self.ask.ask_rules()))
        self.service.search_fields.side_effect = lambda *_a: []
        self.assertIsNone(self.ask._narrowed(many, "revenue?", self.ask.ask_rules())[1], "no match: every field")
        with self.assertRaisesRegex(ValueError, "SEARCH_WORDS"):
            self.ask._ask_rules({"SEARCH_WORDS": 0})

    def test_the_plan_in_plain_words_and_the_checked_line(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("repo_describe_service", ROOT / "setup" / "lib" / "describe_service.py")
        svc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(svc)
        lines = svc.plan_lines('SELECT a FROM "SALES"."ORDER_LINES" t1 LEFT JOIN SALES.ORDERS t2 ON t1.O = t2.O '
                               'LEFT JOIN "USERS"."USERS" t3 ON t2.U = t3.U',
                               {"logical_plan": {"warnings": [{"code": "RELATIONSHIP_PATH_ALTERNATIVES", "selected_path": "lines > orders > users"}]},
                                "selected_representations": [{"entity_name": "users", "representation_name": "crm_users",
                                                              "selection_reason": "BINDING_PRIORITY"},
                                                             {"entity_name": "orders", "selection_reason": "STATIC_PRIMARY"}]})
        self.assertEqual("Reads SALES.ORDER_LINES, SALES.ORDERS, USERS.USERS.", lines[0])
        self.assertIn("Joins 3 tables", lines[1])
        self.assertIn("users is read from crm_users", " ".join(lines))
        self.assertIn("the shortest was used (lines > orders > users)", " ".join(lines))
        ds = types.SimpleNamespace(id="x")
        self.assertIn("Not checked", self.ask.Proposal(ds, "q", "SELECT 1", checked=False).checked_line)
        mapped = self.ask.Proposal(ds, "q", "SELECT 1", plan=["Reads A.B."], checked=True)
        self.assertIn("Checked by your data map", str(mapped))
        self.assertIn("How it is put together", str(mapped))
        mapped.edit("SELECT 2")
        self.assertEqual((None, []), (mapped.checked, mapped.plan), "your own SQL: no longer the data map's")
        told = self.ask.Proposal(types.SimpleNamespace(id="x", version=1, require_approved=lambda _w: None), "q", "SELECT 1",
                                 request_id=7, conn=object())
        told.approve()
        self.service.record_feedback.assert_called_with(told.conn, 7, "ACCEPTED", "Approved to run as compiled.", None)
        told.edit("SELECT 3")
        self.assertEqual(("NEEDS_CHANGE", "SELECT 3"), (self.service.record_feedback.call_args.args[2], self.service.record_feedback.call_args.args[4]),
                         "your own SQL goes back to Semantic Views as the change it needed")
        self.assertIsNone(told.request_id)

    def test_a_pinned_tile_is_compiled_again_and_updated_only_when_asked(self):
        import importlib
        boards = importlib.import_module("exakit_nb.board")
        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {"EXAKIT_HOME": home}):
            b = boards.Board(name="ops", title="Ops", pages=[{"title": "Sales", "filters": None, "tiles": [
                {"id": "aaaa1111", "title": "Revenue", "sql": "SELECT 1", "sql_digest": "x", "kind": "bar",
                 "request": {"model": "all_data", "object": "ORDERS", "metrics": ["revenue"]}},
                {"id": "bbbb2222", "title": "Mine", "sql": "SELECT 2", "sql_digest": "y", "kind": "kpi", "request": None}]}])
            self.service.compile_request.return_value = {"status": "ok", "sql": "SELECT 1"}
            self.assertEqual(["same"], [t["state"] for t in b.recheck(object())], "hand-written tiles are left alone")
            self.service.compile_request.return_value = {"status": "ok", "sql": "SELECT 1 FROM T"}
            found = b.recheck(object())
            self.assertEqual(("changed", "SELECT 1"), (found[0]["state"], b.pages[0]["tiles"][0]["sql"]), "nothing changes unasked")
            b.recheck(object(), update=True)
            self.assertEqual("SELECT 1 FROM T", b.pages[0]["tiles"][0]["sql"])
            self.service.compile_request.side_effect = RuntimeError("SEMANTIC_ADMIN missing")
            self.assertEqual("refused", b.recheck(object())[0]["state"])
            # a tile that remembers Semantic Views' fingerprints of its fields: unchanged fields, no compile
            self.service.compile_request.side_effect = None
            self.service.compile_request.reset_mock()
            b.pages[0]["tiles"][0]["hashes"] = {"METRIC:revenue": "h1"}
            self.service.definition_hashes.return_value = {"MODEL": "m", "METRIC:revenue": "h1"}
            self.assertEqual("same", b.recheck(object())[0]["state"])
            self.service.compile_request.assert_not_called()
            self.service.definition_hashes.return_value = {"MODEL": "m2", "METRIC:revenue": "h2"}
            self.service.compile_request.return_value = {"status": "ok", "sql": "SELECT 2 FROM T"}
            self.assertEqual("changed", b.recheck(object(), update=True)[0]["state"], "a changed field is compiled again")
            self.assertEqual({"METRIC:revenue": "h2"}, b.pages[0]["tiles"][0]["hashes"])


class AskRulesTest(unittest.TestCase):
    """How a question is drafted can be read and changed: the order of the ways, every word the AI gets, the no-AI
    drafter's rules and the insight rules."""

    def setUp(self):
        import importlib
        self.ask = importlib.import_module("exakit_nb.ask")
        self.dataset = types.SimpleNamespace(id="orders", version=1, fact_table="SHOP.ORDERS", require_approved=lambda _w: None,
                                             descriptor=types.SimpleNamespace(columns={}, grain="one row per order", slots={}),
                                             roles=lambda: [])

    def test_the_order_and_the_prompts_are_the_ones_given(self):
        said = json.dumps({"sql": "SELECT 1 AS N FROM SHOP.ORDERS", "assumptions": [], "doubts": []})
        client = mock.Mock()
        client.chat.completions.create.return_value = types.SimpleNamespace(
            choices=[types.SimpleNamespace(message=types.SimpleNamespace(content=said))])
        with mock.patch("exakit_nb.model_client", return_value=(client, "m")), \
                mock.patch.object(self.ask, "described", return_value={"table": "SHOP.ORDERS"}), \
                mock.patch.object(self.ask, "semantic_context", return_value={"model": "all_data"}) as context, \
                mock.patch.object(self.ask, "_verified_answer") as trusted:
            proposal = self.ask.ask(self.dataset, "How many?", conn=object(),
                                    rules={"ORDER": ["column_map"], "COLUMN_MAP_SYSTEM": "Answer in JSON, briefly."})
        trusted.assert_not_called()
        self.assertEqual("SELECT 1 AS N FROM SHOP.ORDERS", proposal.sql)
        sent = client.chat.completions.create.call_args.kwargs["messages"]
        self.assertEqual("Answer in JSON, briefly.", sent[0]["content"], "the system words are the ones given")
        self.assertIn(self.ask.ASK_RULES["COLUMN_MAP_PROMPT"], sent[1]["content"])
        with self.assertRaisesRegex(ValueError, "not an ask rule"):
            self.ask.ask(self.dataset, "q", conn=object(), rules={"NOPE": 1})
        with self.assertRaisesRegex(ValueError, "ORDER lists ways"):
            self.ask.ask(self.dataset, "q", conn=object(), rules={"ORDER": ["guess"]})
        with mock.patch.object(self.ask, "semantic_context", return_value=None), \
                self.assertRaisesRegex(ValueError, "No way left"):
            self.ask.ask(self.dataset, "q", conn=object(), rules={"ORDER": ["trusted"]})

    def test_the_drafter_and_insight_rules_apply_for_one_call(self):
        import importlib
        rules_q = importlib.import_module("exakit_nb.question_rules")
        seen = {}

        def draft(_self, question):
            seen.update(rows=rules_q.MIN_GROUP_ROWS, amount=rules_q._SYNONYMS["amount"])
            return {"sql": "SELECT 1 FROM SHOP.ORDERS"}
        with mock.patch.object(rules_q, "context_for", return_value=None), mock.patch.object(rules_q.RuleDrafter, "__init__", lambda s, c: None), \
                mock.patch.object(rules_q.RuleDrafter, "draft", draft), mock.patch.object(self.ask, "ask", return_value="proposal"), \
                mock.patch("exakit_nb.ask.ask", return_value=types.SimpleNamespace(assumptions=[], doubts=[])):
            try:
                rules_q.draft_question(None, self.dataset, "q", rules={"MIN_GROUP_ROWS": 10, "SYNONYMS": {"amount": ["Turnover"]}})
            except Exception:
                pass
        self.assertEqual((10, ["turnover"]), (seen["rows"], seen["amount"]))
        self.assertEqual(30, rules_q.MIN_GROUP_ROWS, "back to the default")
        with self.assertRaisesRegex(ValueError, "not a drafter rule"):
            with rules_q._with_rules({"NOPE": 1}):
                pass
        from exakit_nb.insights import insights
        frame = pd.DataFrame({"CATEGORY": list("abcdefghij"), "REVENUE": [5, 3, 9, 1, 2, 2, 3, 100, 4, 5]})
        said = insights(frame, rules={"TOP": 2, "SENTENCES": 3})
        self.assertEqual(3, len(said))
        self.assertNotIn("Far from the rest: h (100).", insights(frame, rules={"OUTLIER_MIN_ROWS": 50}))
        with self.assertRaisesRegex(ValueError, "not an insight rule"):
            insights(frame, rules={"NOPE": 1})


@unittest.skipUnless(pd is not None, "pandas is not installed here (the kit's notebook environment has it)")
class LoadRulesTest(unittest.TestCase):
    """How a file is loaded, and how a table is read for its column map, can be changed for one load or one draft."""

    def test_the_load_rules_apply_to_one_load_and_come_back(self):
        import importlib
        own = importlib.import_module("exakit_nb.own_file")
        seen = {}

        def load(path, table, descriptor=None, *, conn=None, replace=False, missing_ok=False):
            frame = pd.DataFrame({"NOTE": ["a" * 40], "WHEN": ["2026-01-02"]})
            seen.update(types=own._prepare(frame), replace=replace, schema=own.LOAD_RULES["DEFAULT_SCHEMA"])
        with mock.patch.object(own, "_load_own_file", side_effect=load):
            own.load_own_file("x.csv", None, rules={"MAX_VARCHAR": 10, "REPLACE": True, "DEFAULT_SCHEMA": "SALES"})
        # MAX_VARCHAR caps the text column; a column of dates is kept as DATE (own_file._prepare: the first load
        # agrees with the column map that follows), so the cap does not touch it
        self.assertEqual(([("NOTE", "VARCHAR(10)"), ("WHEN", "DATE")], True, "SALES"), (seen["types"], seen["replace"], seen["schema"]))
        self.assertEqual(own.LOAD_RULES, own.load_rules(), "back to the defaults")
        self.assertEqual("MY_DATA", own.LOAD_RULES["DEFAULT_SCHEMA"])
        with self.assertRaisesRegex(ValueError, "not a load rule"):
            own.load_own_file("x.csv", None, rules={"NOPE": 1})

    def test_how_a_table_is_read_is_part_of_the_column_map_rules(self):
        sys.path.insert(0, str(ROOT / "setup" / "lib"))
        from descriptor import profile, rules
        self.assertEqual(10000, rules.role_rules()["VIRTUAL_ROWS"])
        with rules.using({"VIRTUAL_ROWS": 500, "CATEGORY_DISTINCT": 60}):
            self.assertEqual(500, profile.VIRTUAL_ROWS)
        self.assertEqual(10000, profile.VIRTUAL_ROWS)

@unittest.skipUnless(HAVE_DASH, "dash is not installed here (the dashboard's environment has it)")
class BoardAppTest(unittest.TestCase):
    """The uploaded app.py, run against a stand-in for Dash Server's helper that counts the queries."""

    def setUp(self):
        from exakit_nb.board_template import BOARD_APP
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        folder = Path(self.temp.name)
        (folder / "app.py").write_text(BOARD_APP, encoding="utf-8")
        (folder / "dash_server_exasol.py").write_text(
            "import threading, time\n"
            "CALLS, ROWS, SLOW = [], {}, set()\n"
            "def load_rows(server, metadata, here, path):\n"
            "    CALLS.append(path)\n"
            "    if path in SLOW: time.sleep(0.6)\n"
            "    return ROWS.get(path, [])\n"
            "def has_error(rows): return rows is None\n", encoding="utf-8")
        (folder / "BOARD.json").write_text(json.dumps({"title": "Sales", "pages": [
            {"id": "page-1", "title": "Revenue", "filters": ["STATE"], "tiles": [
                {"id": "t1", "title": "By state", "kind": "bar", "query": "queries/t1.sql"},
                {"id": "t2", "title": "Orders by state", "kind": "table", "query": "queries/t2.sql"}]},
            {"id": "page-2", "title": "Trend", "filters": [], "tiles": [
                {"id": "t3", "title": "Per month", "kind": "line", "query": "queries/t3.sql"}]}]}), encoding="utf-8")
        (folder / "REVISION.json").write_text(json.dumps({"workflow_id": "wf", "board": "sales", "query_digest": "x" * 16}),
                                              encoding="utf-8")
        import importlib.util
        spec = importlib.util.spec_from_file_location("board_app_under_test", folder / "app.py")
        self.app = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.app)
        self.helper = self.app.helper
        self.helper.ROWS.update({"queries/t1.sql": [{"STATE": "CA", "REVENUE": 5}, {"STATE": "NY", "REVENUE": 3}],
                                 "queries/t2.sql": [{"STATE": "CA", "ORDERS": 2}, {"STATE": "NY", "ORDERS": 1}],
                                 "queries/t3.sql": [{"MONTH": "2026-01", "ORDERS": 3}]})

    def test_only_the_open_tab_is_queried_and_a_kept_result_is_not_queried_again(self):
        tiles = self.app.tiles_of("page-1")
        found = self.app.results(tiles, None, {})
        self.assertEqual({"queries/t1.sql", "queries/t2.sql"}, set(self.helper.CALLS), "page 2's tile is not queried")
        self.assertEqual(2, len(found["t1"]["rows"]))
        self.app.results(tiles, None, {})
        self.assertEqual(2, len(self.helper.CALLS), "kept: no new query for the same tab")
        self.app.results(tiles, None, {}, fresh=True)
        self.assertEqual(4, len(self.helper.CALLS), "Refresh queries again")

    def test_filters_narrow_the_kept_rows_and_ignore_a_tile_without_that_column(self):
        rows = [{"STATE": "CA", "N": 1}, {"STATE": "NY", "N": 2}]
        self.assertEqual([{"STATE": "CA", "N": 1}], self.app.keep(rows, {"STATE": {"CA"}}))
        self.assertEqual([{"MONTH": "x"}], self.app.keep([{"MONTH": "x"}], {"STATE": {"CA"}}))
        view = self.app.tile_view(self.app.tiles_of("page-1")[0], {"rows": rows, "error": None}, {"STATE": {"NY"}})
        self.assertIn("1 of 2 rows", json.dumps(view.to_plotly_json(), default=str))

    def test_a_slow_query_leaves_its_tile_waiting_and_fills_it_when_it_comes(self):
        self.helper.SLOW.add("queries/t3.sql")
        with mock.patch.object(self.app, "WAIT_SECONDS", 0.1):
            found = self.app.results(self.app.tiles_of("page-2"), None, {})
        self.assertTrue(found["t3"].get("late"))
        view = self.app.tile_view(self.app.tiles_of("page-2")[0], found["t3"], {})
        self.assertIn("Still running", json.dumps(view.to_plotly_json(), default=str))
        time.sleep(0.8)
        self.assertEqual(1, len(self.app.results(self.app.tiles_of("page-2"), None, {})["t3"]["rows"]))
        self.assertEqual(1, self.helper.CALLS.count("queries/t3.sql"), "the query that was running is not sent twice")

    def test_the_app_is_built_with_a_tab_per_page(self):
        import flask
        app = self.app.create_dash_app(flask.Flask("t"), "/apps/sales/", {"title": "Sales"})
        layout = json.dumps(app.layout.to_plotly_json(), default=str)
        self.assertIn("label='Revenue'", layout)
        self.assertIn("label='Trend'", layout)


class PreparePreviewTest(unittest.TestCase):
    """A pin builds the board's preview in the background: one build at a time, the latest pins built after it,
    and nothing started when Dash Server is not running."""

    def setUp(self):
        import exakit_nb  # noqa: F401

        self.module = sys.modules["exakit_nb.board"]
        self.release = threading.Event()
        self.built: list[str] = []
        test = self

        class Draft:
            def __init__(self, name):
                self.name = name

            def preview(self, tools, building=False):
                assert building and tools == "tools"
                test.built.append(self.name)
                test.release.wait(5)
                return f"/preview/{self.name}/1"

        class Board:
            def __init__(self, name):
                self.name = name

            def share(self, show=True):
                assert not show, "the tiles' SQL is not printed from the background"
                return Draft(self.name)

        for patch in (mock.patch.object(self.module, "board", side_effect=Board),
                      mock.patch("exakit_nb.dash_mcp.dash_tools", return_value="tools"),
                      mock.patch.dict(self.module.PREPARED_PREVIEWS, clear=True),
                      mock.patch.dict(self.module._PREPARE_NEXT, clear=True)):
            patch.start()
            self.addCleanup(patch.stop)

    def wait_until(self, check):
        deadline = time.time() + 5
        while time.time() < deadline and not check():
            time.sleep(0.02)
        return check()

    def test_one_build_at_a_time_and_the_latest_pins_after_it(self):
        self.assertEqual("building", self.module.prepare_preview("sales"))
        self.assertTrue(self.wait_until(lambda: self.built == ["sales"]))
        self.assertEqual("building", self.module.prepare_preview("sales"))     # pinned again while it builds
        self.assertEqual("building", self.module.prepare_preview("sales"))
        self.release.set()
        self.assertTrue(self.wait_until(lambda: self.module.PREPARED_PREVIEWS.get("sales") == "/preview/sales/1"
                                        and len(self.built) == 2 and not self.module._PREPARE_NEXT))
        time.sleep(0.1)
        self.assertEqual(["sales", "sales"], self.built, "once more for the pins made while it built, not twice")

    def test_nothing_starts_when_dash_server_is_not_running(self):
        with mock.patch("exakit_nb.dash_mcp.dash_tools", side_effect=RuntimeError("Dash Server is stopped. Run exakit start")):
            said = self.module.prepare_preview("sales")
        self.assertEqual("Dash Server is stopped. Run exakit start", said)
        self.assertEqual([], self.built)


if __name__ == "__main__":
    unittest.main()
