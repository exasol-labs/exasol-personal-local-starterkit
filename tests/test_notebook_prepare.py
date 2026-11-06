"""The typed view (exakit_nb.prepare): what it proposes from the data, and that nothing is created before create().
The SQL is answered by a stand-in, so no database is needed; the live behaviour was checked on a running kit."""

from __future__ import annotations

import re
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

try:
    import pandas as pd
except ImportError:                                  # the kit's notebook environment has it; a bare Python may not
    pd = None

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
import exakit_nb  # noqa: E402
from exakit_nb import prepare  # noqa: E402

COLUMNS = [("ORDER_NO", "VARCHAR(10) UTF8"), ("AMOUNT", "VARCHAR(20) UTF8"), ("ORDERED", "VARCHAR(20) UTF8"),
           ("POSTCODE", "VARCHAR(6) UTF8"), ("CHANNEL", "VARCHAR(20) UTF8"), ("QTY", "DECIMAL(5,0)"),
           ("RETURNED", "VARCHAR(1) UTF8")]
# Per text column: values present, numbers, exponents, leading zeros, integer digits, scale, booleans, dates by format.
FOUND = {"ORDER_NO": dict(N=5, NUM=0), "AMOUNT": dict(N=4, NUM=4, INT=4, SC=2), "ORDERED": dict(N=5, D0=5),
         "POSTCODE": dict(N=5, NUM=5, LZ=1, INT=5), "CHANNEL": dict(N=5), "RETURNED": dict(N=5, NUM=5, INT=1)}


def dataset(key="ORDER_NO"):
    roles = {"ORDER_NO": "identifier", "AMOUNT": "measure", "ORDERED": "other", "POSTCODE": "other", "CHANNEL": "category",
             "QTY": "measure", "RETURNED": "flag"}
    descriptor = types.SimpleNamespace(columns={c: {"role": r} for c, r in roles.items()},
                                       slots={"key": key, "time": None, "target": "RETURNED", "category": "CHANNEL"})
    return types.SimpleNamespace(id="orders", fact_table="SHOP.ORDERS", descriptor=descriptor,
                                 has=lambda role: role in ("label", "category"),
                                 col=lambda role: {"label": '"RETURNED"', "category": '"CHANNEL"'}[role])


class Answers:
    """Answers each statement the proposal sends, and records them."""

    def __init__(self, total=5, distinct=4):
        self.sent, self.total, self.distinct = [], total, distinct

    def __call__(self, conn, statement):
        self.sent.append(statement)
        if "EXA_ALL_COLUMNS" in statement:
            return pd.DataFrame(COLUMNS, columns=["NAME_", "TYPE_"])
        if "AS N0" in statement:
            text = [c for c, t in COLUMNS if t.startswith("VARCHAR")]
            row = {}
            for i, column in enumerate(text):
                got = FOUND[column]
                row.update({f"N{i}": got["N"], f"NUM{i}": got.get("NUM", 0), f"EXP{i}": 0, f"LZ{i}": got.get("LZ", 0),
                            f"INT{i}": got.get("INT", 0), f"SC{i}": got.get("SC", 0), f"B{i}": 0})
                row.update({f"D{i}_{k}": got.get(f"D{k}", 0) for k in range(len(prepare.DATE_FORMATS))})
                row.update({f"T{i}_{k}": 0 for k in range(len(prepare.TIMESTAMP_FORMATS))})
            return pd.DataFrame([row])
        if "GROUP BY 1" in statement:
            column = re.search(r'SELECT "([A-Z_]+)" AS VALUE_', statement).group(1)
            values = {"CHANNEL": [("web", 3), ("Unknown", 1), ("shop", 1)], "RETURNED": [("0", 3), ("1", 2)]}[column]
            return pd.DataFrame(values, columns=["VALUE_", "N"])
        if "SELECT DISTINCT" in statement:
            return pd.DataFrame({"N": [self.distinct]})
        if "COUNT(*) AS N FROM" in statement:
            return pd.DataFrame({"N": [self.total]})
        raise AssertionError(f"unexpected statement: {statement}")


@unittest.skipIf(pd is None, "needs pandas (the kit's notebook environment)")
class TypedViewTest(unittest.TestCase):
    def propose(self, **kw):
        answers = Answers(**{k: v for k, v in kw.items() if k in ("total", "distinct")})
        conn = mock.Mock()
        with mock.patch.object(exakit_nb, "sql", side_effect=answers):
            view = exakit_nb.typed_view(conn, dataset(kw.get("key", "ORDER_NO")))
        return view, answers, conn

    def test_types_come_from_the_values_and_codes_stay_text(self):
        view, _, _ = self.propose()
        changed = {c.column: c.after for c in view.changes}
        self.assertEqual("DECIMAL(6,2)", changed["AMOUNT"])
        self.assertEqual("DATE", changed["ORDERED"])
        self.assertEqual("DECIMAL(1,0)", changed["RETURNED"])
        self.assertNotIn("ORDER_NO", changed, "an identifier stays text")
        self.assertNotIn("POSTCODE", changed, "a leading zero, and a code's name, keep it text")
        self.assertNotIn("QTY", changed, "a typed column is left as it is")
        self.assertIn("TO_DATE(NULLIF(TRIM(\"ORDERED\"), ''), 'YYYY-MM-DD')", view.sql)

    def test_placeholders_become_null_and_copies_are_dropped_by_the_key(self):
        view, _, _ = self.propose()
        self.assertIn("CASE WHEN TRIM(\"CHANNEL\") IN ('Unknown') THEN NULL", view.sql)
        self.assertIn('ROW_NUMBER() OVER (PARTITION BY', view.sql)
        self.assertIn('ORDER BY "ORDER_NO"', view.sql)
        self.assertTrue(any("1 rows that copy another row" in line for line in view.cleaning))

    def test_without_a_key_copies_go_with_distinct(self):
        view, _, _ = self.propose(key=None)
        self.assertIn("SELECT DISTINCT", view.sql)
        self.assertNotIn("ROW_NUMBER", view.sql)

    def test_nothing_is_created_before_create_and_only_selects_run(self):
        view, answers, conn = self.propose()
        conn.execute.assert_not_called()
        self.assertTrue(all(s.lstrip().upper().startswith("SELECT") for s in answers.sent))
        self.assertIn("Not created yet", str(view))
        self.assertTrue(view.sql.startswith('CREATE OR REPLACE VIEW EXAKIT_PREPARED."SHOP__ORDERS" AS'))

    def test_a_clean_typed_table_needs_no_view(self):
        global FOUND, COLUMNS
        saved = (FOUND, COLUMNS)
        try:
            COLUMNS = [("ORDER_NO", "VARCHAR(10) UTF8"), ("QTY", "DECIMAL(5,0)"), ("CHANNEL", "VARCHAR(20) UTF8")]
            FOUND = {"ORDER_NO": dict(N=5), "CHANNEL": dict(N=5)}
            answers = Answers(total=5, distinct=5)
            ds = dataset()
            ds.descriptor.columns = {"ORDER_NO": {"role": "identifier"}, "QTY": {"role": "measure"},
                                     "CHANNEL": {"role": "category"}}
            with mock.patch.object(exakit_nb, "sql", side_effect=answers), \
                    mock.patch("exakit_nb.data_checks.placeholders", return_value={}):
                view = exakit_nb.typed_view(mock.Mock(), ds)
            self.assertFalse(view.needed)
            self.assertIn("needs no typed view", str(view))
            self.assertIs(view.create(mock.Mock()), ds, "nothing to create: the dataset as it was")
        finally:
            FOUND, COLUMNS = saved


if __name__ == "__main__":
    unittest.main()
