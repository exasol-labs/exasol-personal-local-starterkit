"""The schema map (setup/lib/descriptor/schema.py): keys, links declared and found, the containment check that keeps a
name match from making a link on its own, approving (the schema's semantic model rebuilt with the links), and the
joined view's SQL. The database is a
stand-in that answers each statement the module sends, so no database is needed; the live behaviour was checked on
TPCH (8 tables, 9 links found, ORDERS joined to CUSTOMER, NATION and REGION with its 30,000 rows kept)."""

from __future__ import annotations

import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "setup/lib"))
from descriptor import schema  # noqa: E402
import describe_service as service  # noqa: E402

# SHOP: customers, orders, products, regions. ORDERS.CUSTOMER_ID holds customers' ID; ORDERS.PRODUCT_ID names
# PRODUCTS' key but half its values are not there; ORDERS.CLERK_ID names no table at all.
COLUMNS = {
    "CUSTOMERS": [("ID", "DECIMAL(9,0)"), ("NAME", "VARCHAR(40) UTF8"), ("REGION_ID", "DECIMAL(9,0)")],
    "ORDERS": [("ORDER_ID", "DECIMAL(9,0)"), ("CUSTOMER_ID", "DECIMAL(9,0)"), ("PRODUCT_ID", "DECIMAL(9,0)"),
               ("CLERK_ID", "DECIMAL(9,0)"), ("AMOUNT", "DECIMAL(9,2)")],
    "PRODUCTS": [("PRODUCT_ID", "DECIMAL(9,0)"), ("NAME", "VARCHAR(40) UTF8")],
    "REGIONS": [("ID", "DECIMAL(9,0)"), ("NAME", "VARCHAR(40) UTF8")],
}
ROWS = {"CUSTOMERS": 10, "ORDERS": 100, "PRODUCTS": 5, "REGIONS": 3}
NOT_UNIQUE = {("ORDERS", "CUSTOMER_ID"), ("ORDERS", "PRODUCT_ID"), ("ORDERS", "CLERK_ID"), ("CUSTOMERS", "REGION_ID")}
MISSING = {("ORDERS", "PRODUCT_ID", "PRODUCTS"): 50}


class Database:
    """Answers the module's statements for SHOP; ``declared`` are the constraint rows the database would list."""

    def __init__(self, declared=()):
        self.declared, self.sent = list(declared), []

    def __call__(self, sql):
        self.sent.append(sql)
        if "EXA_ALL_COLUMNS" in sql:
            return [{"T": t, "C": c, "Y": y} for t, cols in COLUMNS.items() for c, y in cols]
        if "EXA_ALL_CONSTRAINT_COLUMNS" in sql:
            return self.declared
        if " UNION ALL " in sql or re.match(r"SELECT '\w+' AS T, COUNT", sql):
            return [{"T": t, "N": ROWS[t]} for t in re.findall(r"SELECT '(\w+)' AS T", sql)]
        if "COUNT(DISTINCT" in sql:
            table = re.search(r'FROM "SHOP"\."(\w+)"', sql).group(1)
            row = {}
            for column in re.findall(r'AS "D_(\w+)"', sql):
                row[f"D_{column}"] = 2 if (table, column) in NOT_UNIQUE else ROWS[table]
                row[f"N_{column}"] = ROWS[table]
            return [row]
        if "LEFT JOIN" in sql:
            source, other = re.findall(r'"SHOP"\."(\w+)"', sql)
            column = re.search(r'WHERE S\."(\w+)" IS NOT NULL', sql).group(1)
            return [{"N": ROWS[source], "MISSING": MISSING.get((source, column, other), 0)}]
        raise AssertionError(f"unexpected statement: {sql}")


class SchemaMapTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.path = Path(self.home.name)

    def draft(self, declared=()):
        database = Database(declared)
        return schema.draft(database, "shop", self.path), database

    def links(self, doc):
        return {(l["from"], l["to"]) for l in doc["relations"]}

    def test_keys_are_unique_never_empty_key_named_columns(self):
        doc, _ = self.draft()
        self.assertEqual(["ID"], doc["tables"]["CUSTOMERS"]["key"])
        self.assertEqual(["ORDER_ID"], doc["tables"]["ORDERS"]["key"])
        self.assertEqual(100, doc["tables"]["ORDERS"]["rows"])
        self.assertEqual("draft", doc["status"])
        self.assertTrue((schema.folder("SHOP", self.path) / "draft.json").is_file())

    def test_a_link_needs_the_name_and_the_values(self):
        doc, database = self.draft()
        self.assertEqual({("ORDERS.CUSTOMER_ID", "CUSTOMERS.ID"), ("CUSTOMERS.REGION_ID", "REGIONS.ID")}, self.links(doc))
        self.assertTrue(any("LEFT JOIN" in s and "PRODUCTS" in s for s in database.sent),
                        "PRODUCT_ID names PRODUCTS' key, so its values were checked")
        self.assertNotIn("ORDERS.PRODUCT_ID", {l["from"] for l in doc["relations"]}, "half its values are missing")
        self.assertNotIn("ORDERS.CLERK_ID", {l["from"] for l in doc["relations"]}, "it names no table")
        self.assertTrue(all(s.lstrip().upper().startswith("SELECT") for s in database.sent), "a survey only reads")

    def test_a_declared_foreign_key_is_taken_as_it_is(self):
        declared = [{"T": "ORDERS", "K": "FOREIGN KEY", "C": "CLERK_ID", "RT": "CUSTOMERS", "RC": "ID"},
                    {"T": "PRODUCTS", "K": "PRIMARY KEY", "C": "NAME", "RT": None, "RC": None}]
        doc, _ = self.draft(declared)
        link = next(l for l in doc["relations"] if l["from"] == "ORDERS.CLERK_ID")
        self.assertEqual(("CUSTOMERS.ID", "declared foreign key"), (link["to"], link["evidence"]))
        self.assertEqual((["NAME"], "declared primary key"),
                         (doc["tables"]["PRODUCTS"]["key"], doc["tables"]["PRODUCTS"]["key_evidence"]))

    def test_approve_writes_a_version_rebuilds_the_semantic_model_and_says_when_nothing_changed(self):
        doc, database = self.draft()
        executed = []
        built = {"view": "semantic model shop (SEM_SHOP)", "model": "shop"}
        with mock.patch.object(schema.publishing, "publish_schema", return_value=built) as publish_schema:
            result = schema.approve(database, executed.append, doc, owner="analyst", reader="EXAKIT_READER", home=self.path)
        self.assertEqual((1, "approved", 2), (result["version"], result["status"], result["relations"]))
        self.assertEqual(("semantic model shop (SEM_SHOP)", "shop"), (result["published"], result["model"]))
        self.assertEqual(("SHOP", "EXAKIT_READER"), publish_schema.call_args.args[2:4])
        self.assertTrue((schema.folder("SHOP", self.path) / "v1.json").is_file())
        self.assertFalse((schema.folder("SHOP", self.path) / "draft.json").exists())
        self.assertEqual([], executed, "the links reach the model through publish_schema; nothing else is written")
        # the approved links are what the model's relationships are built from
        with mock.patch.object(schema.publishing.store, "kit_home", return_value=self.path):
            links = schema.publishing.schema_links("SHOP", self.path)
        self.assertIn({"from": "SHOP.ORDERS.CUSTOMER_ID", "to": "SHOP.CUSTOMERS.ID"}, links)
        again = schema.approve(database, executed.append, doc, owner="analyst", home=self.path)
        self.assertEqual("unchanged", again["status"])
        self.assertIn(str(schema.folder("SHOP", self.path) / "v1.json"), again["message"])

    def test_a_failed_publish_keeps_the_approval(self):
        doc, database = self.draft()
        with mock.patch.object(schema.publishing, "publish_schema", side_effect=RuntimeError("insufficient privileges")):
            result = schema.approve(database, lambda sql: None, doc, owner="analyst", home=self.path)
        self.assertEqual("approved, not published", result["status"])
        self.assertIn("insufficient privileges", result["reason"])
        self.assertEqual(1, schema.current("SHOP", self.path)["version"])

    def test_a_link_to_a_column_the_schema_lacks_is_refused(self):
        doc, database = self.draft()
        doc["relations"].append({"from": "ORDERS.NOPE", "to": "CUSTOMERS.ID", "kind": "many-to-one", "evidence": "x"})
        with self.assertRaisesRegex(ValueError, "ORDERS.NOPE"):
            schema.approve(database, lambda sql: None, doc, owner="analyst", home=self.path)

    def test_the_joined_view_follows_links_and_keeps_names_apart(self):
        doc, _ = self.draft()
        built = schema.joined_sql(doc, "SHOP.ORDERS")
        self.assertEqual(["CUSTOMERS", "REGIONS"], [j["table"] for j in built["joins"]])
        self.assertEqual('EXAKIT_PREPARED."SHOP__ORDERS__JOINED"', built["view"])
        self.assertIn('LEFT JOIN "SHOP"."CUSTOMERS" T1 ON T0."CUSTOMER_ID" = T1."ID"', built["sql"])
        self.assertIn('LEFT JOIN "SHOP"."REGIONS" T2 ON T1."REGION_ID" = T2."ID"', built["sql"])
        self.assertIn("CUSTOMERS_NAME", built["columns"])
        self.assertIn("REGIONS_NAME", built["columns"])
        self.assertNotIn("ID", built["columns"], "a joined table's key is held by the side it came from")
        self.assertEqual(len(built["columns"]), len(set(built["columns"])))
        self.assertEqual([], schema.joined_sql(doc, "REGIONS")["joins"], "a table that links nowhere joins nothing")
        with self.assertRaisesRegex(LookupError, "no table NOPE"):
            schema.joined_sql(doc, "NOPE")

    def test_a_table_reached_along_two_paths_is_joined_once_per_path(self):
        doc = {"schema": "S", "tables": {
            "LINES": {"columns": ["LINE_ID", "ORDER_ID", "SUPPLIER_ID"]},
            "ORDERS": {"columns": ["ORDER_ID", "COUNTRY_ID"]},
            "SUPPLIERS": {"columns": ["SUPPLIER_ID", "COUNTRY_ID"]},
            "COUNTRIES": {"columns": ["COUNTRY_ID", "NAME"]}},
            "relations": [{"from": "LINES.ORDER_ID", "to": "ORDERS.ORDER_ID"},
                          {"from": "LINES.SUPPLIER_ID", "to": "SUPPLIERS.SUPPLIER_ID"},
                          {"from": "ORDERS.COUNTRY_ID", "to": "COUNTRIES.COUNTRY_ID"},
                          {"from": "SUPPLIERS.COUNTRY_ID", "to": "COUNTRIES.COUNTRY_ID"}]}
        built = schema.joined_sql(doc, "LINES")
        self.assertEqual(2, [j["table"] for j in built["joins"]].count("COUNTRIES"))
        self.assertIn("ORDERS_COUNTRIES_NAME", built["columns"])
        self.assertIn("SUPPLIERS_COUNTRIES_NAME", built["columns"])
        self.assertEqual(len(built["columns"]), len(set(built["columns"])))
        self.assertEqual([], [j for j in schema.joined_sql(doc, "LINES", depth=1)["joins"] if j["table"] == "COUNTRIES"])

    def test_the_schema_name_is_checked(self):
        with self.assertRaises(ValueError):
            schema.schema_name("SHOP; DROP TABLE X")
        self.assertEqual("SHOP", schema.schema_name('"shop"'))


class EditLinksTest(unittest.TestCase):
    def doc(self):
        with tempfile.TemporaryDirectory() as home:
            return schema.draft(Database(), "SHOP", Path(home))

    def test_links_are_added_replaced_and_removed(self):
        doc = self.doc()
        edited = service.edit_links(doc, links=["orders.clerk_id=customers.id"], unlinks=["CUSTOMERS.REGION_ID"])
        found = {l["from"]: (l["to"], l["evidence"]) for l in edited["relations"]}
        self.assertEqual(("CUSTOMERS.ID", "set by you"), found["ORDERS.CLERK_ID"])
        self.assertNotIn("CUSTOMERS.REGION_ID", found)
        self.assertIn("CUSTOMERS.REGION_ID", {l["from"] for l in doc["relations"]}, "the map given is not changed")

    def test_wrong_corrections_are_refused_with_the_reason(self):
        doc = self.doc()
        for kwargs, needle in (({"links": ["ORDERS.CLERK_ID"]}, "TABLE.COLUMN=TABLE.KEY"),
                               ({"unlinks": ["ORDERS.AMOUNT"]}, "no link from ORDERS.AMOUNT"),
                               ({"links": ["ORDERS.NOPE=CUSTOMERS.ID"]}, "ORDERS.NOPE")):
            with self.subTest(kwargs=kwargs), self.assertRaisesRegex(service.Refused, re.escape(needle)):
                service.edit_links(doc, **kwargs)

    def test_approving_without_a_draft_says_how_to_make_one(self):
        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {"EXAKIT_HOME": home}):
            with self.assertRaisesRegex(service.NotFound, r"exakit describe --schema SHOP"):
                service.approve_schema(mock.Mock(), "shop")


class NotebookSchemaMapTest(unittest.TestCase):
    """exakit_nb.schema_map: the proposal shows its joins and SQL, nothing runs before create(), and create() approves
    the map, creates the view and gives it the main table's roles."""

    def setUp(self):
        sys.path.insert(0, str(ROOT / "notebook/package"))
        import exakit_nb
        from exakit_nb import schema_map as notebook_map
        self.exakit_nb, self.notebook_map = exakit_nb, notebook_map
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        patcher = mock.patch.dict(os.environ, {"EXAKIT_HOME": home.name})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.doc = schema.draft(Database(), "SHOP", Path(home.name))
        service_patch = mock.patch.object(notebook_map, "_service", return_value=service)
        service_patch.start()
        self.addCleanup(service_patch.stop)

    def source(self):
        descriptor = mock.Mock(columns={"ORDER_ID": {"role": "key"}, "AMOUNT": {"role": "measure"}},
                               slots={"key": "ORDER_ID", "category": "REGIONS_NAME"})
        return mock.Mock(id="orders", fact_table="SHOP.ORDERS", descriptor=descriptor, source=None)

    def test_the_proposal_shows_the_joins_and_runs_nothing(self):
        found = self.notebook_map.SchemaMap(self.doc)
        self.assertIn("draft schema map v1: 4 tables, 2 links", repr(found))
        connection = mock.Mock()
        proposal = found.joined_view(self.source())
        self.assertTrue(proposal.needed)
        self.assertIn('-> EXAKIT_PREPARED."SHOP__ORDERS__JOINED"', repr(proposal))
        self.assertIn("+ CUSTOMERS along ORDERS.CUSTOMER_ID", str(proposal))
        self.assertTrue(proposal.sql.startswith('CREATE OR REPLACE VIEW EXAKIT_PREPARED."SHOP__ORDERS__JOINED" AS'))
        self.assertIn("Not created yet", str(proposal))
        connection.execute.assert_not_called()
        alone = found.joined_view("SHOP.REGIONS")
        self.assertFalse(alone.needed)
        self.assertNotIn("->", str(alone), "no view is named when there is nothing to join")
        self.assertIsNone(alone.create(connection))
        connection.execute.assert_not_called()

    def test_create_approves_the_map_creates_the_view_and_carries_the_roles(self):
        found = self.notebook_map.SchemaMap(self.doc)
        proposal = found.joined_view(self.source())
        draft = mock.Mock(doc={"columns": {"ORDER_ID": {}, "AMOUNT": {}, "REGIONS_NAME": {}}})
        draft.approve.return_value = mock.Mock(status="approved", id="orders_joined")
        connection = mock.Mock()
        with mock.patch.object(service, "approve_schema", return_value={"schema": "SHOP", "version": 1, "relations": 2,
                                                                          "path": "v1.json"}) as approved, \
                mock.patch.object(self.exakit_nb, "describe", return_value=draft) as described, \
                mock.patch("exakit_nb.workflow.log_sql"), mock.patch("exakit_nb.dataset.remember_dataset") as remembered, \
                mock.patch("sys.stdout"):
            created = proposal.create(connection)
        approved.assert_called_once()
        self.assertEqual(1, found.approved_version)
        statements = [c.args[0] for c in connection.execute.call_args_list]
        self.assertEqual("CREATE SCHEMA IF NOT EXISTS EXAKIT_PREPARED", statements[0])
        self.assertEqual(proposal.sql, statements[1])
        described.assert_called_once()
        self.assertEqual("orders_joined", described.call_args.kwargs["id"])
        draft.set.assert_called_once_with(ORDER_ID="key", AMOUNT="measure")
        self.assertIn(mock.call(category="REGIONS_NAME", key="ORDER_ID"), draft.slot.call_args_list)
        remembered.assert_called_once_with(created)


if __name__ == "__main__":
    unittest.main()
