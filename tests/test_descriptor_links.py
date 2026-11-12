"""(run: python3 tests/test_descriptor_links.py) Links across schemas, found from values (setup/lib/descriptor/links.py):
a text column whose rows are in another source's key is a link with its evidence; misspellings are counted by rows;
plain numbers that sit inside a 1..N key by chance are not links (the false positives measured on a live database);
a number link needs a name, an approved role or a model's proposal, and stays "low" until a person confirms it; every
statement is bounded. The database is a stand-in over rows held here."""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "setup" / "lib"))
from descriptor import links  # noqa: E402

STATES = [f"STATE_{i:02d}" for i in range(36)]


def tables():
    orders = [{"ORDER_LINE_ID": i, "SHIP_STATE": STATES[i % 36], "ACCT_NO": 1000 + (i % 400), "QTY": i % 9}
              for i in range(1, 5001)]
    for i, wrong in enumerate(("STATE_O1", "STAET_02", "state 03")):       # three misspelt rows
        orders[i]["SHIP_STATE"] = wrong
    return {
        "SHOP.ORDER_LINES": (False, {"ORDER_LINE_ID": "DECIMAL(18,0)", "SHIP_STATE": "VARCHAR(40) UTF8",
                                     "ACCT_NO": "DECIMAL(9,0)", "QTY": "DECIMAL(9,0)"}, orders),
        "VS_GEO.STATES": (True, {"STATE_NAME": "VARCHAR(40) UTF8", "PINCODES": "DECIMAL(9,0)"},
                          [{"STATE_NAME": s, "PINCODES": 100 + i} for i, s in enumerate(STATES)]),
        "CRM.CUSTOMERS": (False, {"CUSTOMER_ID": "DECIMAL(9,0)", "SEGMENT": "VARCHAR(20) UTF8"},
                          [{"CUSTOMER_ID": 1000 + i, "SEGMENT": "ABC"[i % 3]} for i in range(400)]),
        "IOT.METERS": (False, {"METER_ID": "DECIMAL(9,0)"}, [{"METER_ID": i} for i in range(1, 51)]),
    }


class Database:
    """Answers the statements links.py sends, from the rows above; records each one."""

    def __init__(self):
        self.tables, self.sent = tables(), []

    def rows_of(self, sql):
        schema, table = re.search(r'FROM "(\w+)"\."(\w+)"', sql).groups()
        return self.tables[f"{schema}.{table}"][2]

    def __call__(self, sql):
        self.sent.append(sql)
        if "EXA_ALL_COLUMNS" in sql:
            wanted = re.findall(r"'(\w+)'", sql.split("IN (")[1].split(")")[0])
            return [{"COLUMN_SCHEMA": t.split(".")[0], "COLUMN_TABLE": t.split(".")[1], "COLUMN_NAME": c, "COLUMN_TYPE": y}
                    for t, (_v, cols, _r) in self.tables.items() if t.split(".")[0] in wanted for c, y in cols.items()]
        if "EXA_SCHEMAS" in sql:
            return [{"SCHEMA_NAME": t.split(".")[0]} for t, (virtual, _c, _r) in self.tables.items() if virtual]
        if "EXA_ALL_CONSTRAINT_COLUMNS" in sql:
            return [{"CONSTRAINT_SCHEMA": "SHOP", "CONSTRAINT_TABLE": "ORDER_LINES", "CONSTRAINT_NAME": "PK",
                     "COLUMN_NAME": "ORDER_LINE_ID"}]
        data = self.rows_of(sql)
        if sql.startswith("SELECT COUNT(*) AS N_"):
            out = {"N_": len(data)}
            for i, col in enumerate(re.findall(r'COUNT\("(\w+)"\) AS P\d+', sql)):
                values = [r[col] for r in data if r[col] is not None]
                text = isinstance(values[0], str)
                out.update({f"P{i}": len(values), f"D{i}": len(set(values)),
                            f"A{i}": min(len(v) for v in values) if text else min(values),
                            f"B{i}": max(len(v) for v in values) if text else max(values)})
            return [out]
        if sql.startswith("SELECT DISTINCT"):
            col, limit = re.search(r'DISTINCT "(\w+)"', sql).group(1), int(re.search(r"LIMIT (\d+)", sql).group(1))
            return [{"V": v} for v in sorted({r[col] for r in data}, key=str)[:limit]]
        listed = None
        if " IN (" in sql:
            inner = sql.split(" IN (", 1)[1].rsplit(")", 1)[0] if "CASE WHEN" not in sql else sql.split(" IN (", 1)[1].split(") THEN")[0]
            inner = inner.split(") GROUP BY")[0]
            listed = {v.replace("''", "'") for v in re.findall(r"'((?:[^']|'')*)'", inner)} or {int(v) for v in re.findall(r"-?\d+", inner)}
        if sql.startswith("SELECT COUNT(DISTINCT"):
            col = re.search(r'DISTINCT "(\w+)"', sql).group(1)
            return [{"F": len({r[col] for r in data if r[col] in listed})}]
        if "SUM(CASE WHEN" in sql:
            col = re.search(r'COUNT\("(\w+)"\) AS N', sql).group(1)
            return [{"N": len(data), "M": sum(1 for r in data if r[col] in listed)}]
        if "NOT IN" in sql:
            col = re.search(r'SELECT "(\w+)" AS V', sql).group(1)
            counts = {}
            for r in data:
                if r[col] not in listed:
                    counts[r[col]] = counts.get(r[col], 0) + 1
            return [{"V": v, "N": n} for v, n in sorted(counts.items(), key=lambda x: -x[1])[:5]]
        if "COUNT(*) AS N, COUNT(" in sql:
            col = re.search(r'COUNT\(DISTINCT "(\w+)"\)', sql).group(1)
            values = [r[col] for r in data]
            return [{"N": len(values), "P": len(values), "D": len(set(values))}]
        raise AssertionError(f"unexpected statement: {sql[:120]}")


class LinksTest(unittest.TestCase):
    SCHEMAS = ["SHOP", "VS_GEO", "CRM", "IOT"]

    def find(self, **kw):
        self.db = Database()
        return links.find(self.db, self.SCHEMAS, **kw)

    def test_a_text_link_is_found_from_the_values_and_counted_by_rows(self):
        found = {(l["from"], l["to"]): l for l in self.find()["links"]}
        link = found[("SHOP.ORDER_LINES.SHIP_STATE", "VS_GEO.STATES.STATE_NAME")]      # the names differ: the values agree
        self.assertEqual(("high", True), (link["confidence"], link["to_live"]))
        self.assertEqual((5000, 4997, 3), (link["rows"]["rows"], link["rows"]["matched"], link["rows"]["unmatched"]))
        self.assertEqual({"STATE_O1", "STAET_02", "state 03"}, set(link["rows"]["unmatched_values"]))
        self.assertIn("4,997 of 5,000 rows", links.evidence_text(link))

    def test_numbers_inside_a_sequence_are_not_links(self):
        found = {(l["from"], l["to"]) for l in self.find()["links"]}
        # 1..50 and a quantity 0..8 sit inside ORDER_LINE_ID 1..5000 by chance: 18 such "links" were measured live
        self.assertFalse(any(to == "SHOP.ORDER_LINES.ORDER_LINE_ID" for _f, to in found), found)
        self.assertNotIn(("SHOP.ORDER_LINES.ACCT_NO", "CRM.CUSTOMERS.CUSTOMER_ID"), found,
                         "numbers with unlike names need a role or a proposal")

    def test_a_number_link_needs_a_role_or_a_proposal_and_stays_low(self):
        by_role = self.find(roles={"SHOP.ORDER_LINES.ACCT_NO": "identifier"})["links"]
        link = next(l for l in by_role if l["from"] == "SHOP.ORDER_LINES.ACCT_NO")
        self.assertEqual(("CRM.CUSTOMERS.CUSTOMER_ID", "low"), (link["to"], link["confidence"]))
        self.assertIn("CONFIRM THIS ONE", links.evidence_text(link))
        proposed = self.find(proposals=[("SHOP.ORDER_LINES.ACCT_NO", "CRM.CUSTOMERS.CUSTOMER_ID")])["links"]
        link = next(l for l in proposed if l["from"] == "SHOP.ORDER_LINES.ACCT_NO")
        self.assertEqual(("ai", "low"), (link["proposed_by"], link["confidence"]),
                         "a model's proposal between numbers is still unproven: the data can refute it, not confirm it")
        measure = self.find(roles={"SHOP.ORDER_LINES.ACCT_NO": "measure"},
                            proposals=[])["links"]
        self.assertFalse(any(l["from"] == "SHOP.ORDER_LINES.ACCT_NO" for l in measure), "a measure never points at a key")

    def test_a_proposal_the_data_does_not_back_is_dropped(self):
        found = self.find(proposals=[("IOT.METERS.METER_ID", "CRM.CUSTOMERS.CUSTOMER_ID")])["links"]
        self.assertFalse(any(l["from"] == "IOT.METERS.METER_ID" for l in found))

    def test_every_statement_is_bounded_and_only_reads(self):
        found = self.find()
        self.assertEqual(len(self.db.sent), found["statements"])
        for sql in self.db.sent:
            self.assertTrue(sql.lstrip().upper().startswith("SELECT"), sql[:60])
            if sql.startswith("SELECT DISTINCT"):
                self.assertRegex(sql, r"LIMIT \d+$")
        self.assertFalse(any(" JOIN " in s for s in self.db.sent), "no join between sources while searching")
        self.assertLess(found["statements"], 60)

    def test_ai_pairs_keep_only_real_columns_of_different_schemas(self):
        cols, _v = links.columns(Database(), self.SCHEMAS)
        pairs = links.ai_pairs({"links": [{"from": "shop.order_lines.acct_no", "to": "CRM.CUSTOMERS.CUSTOMER_ID"},
                                          {"from": "SHOP.ORDER_LINES.NOPE", "to": "CRM.CUSTOMERS.CUSTOMER_ID"},
                                          {"from": "SHOP.ORDER_LINES.QTY", "to": "SHOP.ORDER_LINES.ORDER_LINE_ID"}]}, cols)
        self.assertEqual([("SHOP.ORDER_LINES.ACCT_NO", "CRM.CUSTOMERS.CUSTOMER_ID")], pairs)
        facts = links.ai_facts(cols, {"CRM.CUSTOMERS.SEGMENT": "customer tier"})
        self.assertNotIn("STATE_00", str(facts), "a model is shown names, types and notes: never a value")


if __name__ == "__main__":
    unittest.main()
