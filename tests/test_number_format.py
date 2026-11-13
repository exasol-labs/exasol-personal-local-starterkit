"""(run: python3 tests/test_number_format.py) Numbers in an answer are written the way a reader expects
(exakit_nb/number_format.py): money in the data's own currency (INR in Indian grouping), counts with separators,
shares as %, IDs and years as they are; text and the values themselves are left alone."""

from __future__ import annotations

import sys
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook" / "package"))

from exakit_nb import number_format as nf  # noqa: E402


def written(column, values, currency=None, dataset=None):
    fmt = nf.column_format(column, values, dataset, currency)
    return fmt["kind"], [nf.format_value(v, fmt) for v in values]


class NumberFormatTest(unittest.TestCase):
    def test_each_kind_of_number(self):
        self.assertEqual(("money", ["₹3,92,02,022.03", "₹1,234.50", "-₹5.00"]), written("TOTAL_AMOUNT", [39202022.03, 1234.5, -5], "INR"))
        self.assertEqual(("money", ["$25,012.49"]), written("AVG_TRANSACTION_AMOUNT", [25012.4871], "USD"))
        self.assertEqual(("money", ["7,498.12"]), written("C_ACCTBAL", [7498.12]), "no currency named: no symbol")
        self.assertEqual(("money", ["¥1,200"]), written("PRICE", [1200], "JPY"))
        self.assertEqual(("count", ["128,975", "3"]), written("ORDER_LINES", [128975, 3]))
        self.assertEqual(("percent", ["14.2%"]), written("CANCELLED_PCT", [14.2135]))
        self.assertEqual(("as_is", ["2022", "12345"]), written("ORDER_YEAR", [2022, 12345]))
        self.assertEqual(("as_is", ["12345"]), written("CUSTOMER_ID", [12345]))
        self.assertEqual(("number", ["1.04", "1,250.5"]), written("AVG_QTY", [1.04317, 1250.5]))
        self.assertEqual(("text", ["Set"]), written("CATEGORY", ["Set"]))
        self.assertEqual("", nf.format_value(None, {"kind": "money", "currency": "INR", "decimals": 2}))

    def test_a_measure_whose_note_says_money_is_money(self):
        ds = types.SimpleNamespace(descriptor=types.SimpleNamespace(columns={"VALUE": {"role": "measure", "note": "The order's value in rupees."}}))
        self.assertEqual("money", nf.column_format("TOTAL_VALUE", [10.0], ds, "INR")["kind"])
        self.assertEqual("number", nf.column_format("TOTAL_VALUE", [10.5])["kind"])

    def test_the_currency_is_the_tables_own_single_code(self):
        class Conn:
            def __init__(self, rows):
                self.rows, self.sent = rows, []

            def execute(self, sql):
                self.sent.append(sql)
                return types.SimpleNamespace(fetchall=lambda: self.rows)

        ds = types.SimpleNamespace(fact_table="AMAZON.ORDER_LINES",
                                   descriptor=types.SimpleNamespace(columns={"AMOUNT": {}, "CURRENCY": {}}))
        conn = Conn([("INR",)])
        self.assertEqual("INR", nf.currency_of(conn, ds))
        self.assertEqual('SELECT DISTINCT "CURRENCY" FROM "AMAZON"."ORDER_LINES" WHERE "CURRENCY" IS NOT NULL LIMIT 2', conn.sent[0])
        self.assertIsNone(nf.currency_of(Conn([("INR",), ("USD",)]), ds), "two codes: none is the currency")
        no_column = types.SimpleNamespace(fact_table="X.Y", descriptor=types.SimpleNamespace(columns={"AMOUNT": {}}))
        self.assertIsNone(nf.currency_of(Conn([("INR",)]), no_column))

    def test_formatted_writes_out_a_copy(self):
        import pandas as pd

        frame = pd.DataFrame({"CATEGORY": ["Set", "kurta"], "TOTAL_AMOUNT": [39202022.03, 21299013.7], "ORDER_LINES": [50281, 49874]})
        shown = nf.formatted(frame, None, "INR")
        self.assertEqual(["₹3,92,02,022.03", "₹2,12,99,013.70"], shown["TOTAL_AMOUNT"].tolist())
        self.assertEqual(["50,281", "49,874"], shown["ORDER_LINES"].tolist())
        self.assertEqual(39202022.03, frame["TOTAL_AMOUNT"].iloc[0], "the answer keeps its numbers")


if __name__ == "__main__":
    unittest.main()
