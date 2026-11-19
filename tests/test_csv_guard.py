"""setup/lib/csv_guard.py - what the kit checks in a user's CSV before exapump loads it.

    python3 -m unittest tests.test_csv_guard
"""

import importlib.util
import os
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location("csv_guard", os.path.join(ROOT, "setup", "lib", "csv_guard.py"))
csv_guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(csv_guard)

DRY_RUN = """Columns:
  "Beleg Nr.": DECIMAL(36,0)
  "Menge": DOUBLE
  "Betrag": VARCHAR(2000000)

CREATE TABLE STARTER_KIT.SAP (
    "Beleg Nr." DECIMAL(36,0),
    "Menge" DOUBLE,
    "Betrag" VARCHAR(2000000)
);
"""


class CsvGuardTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def write(self, name, data):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as handle:
            handle.write(data)
        return path

    def test_crlf_record_ends_become_lf_and_quoted_crlf_stays(self):
        src = self.write("w.csv", b'\xef\xbb\xbfid,note\r\n1,"two\r\nlines"\r\n2,"say ""hi"""\r\n')
        dst = os.path.join(self.dir, "out.csv")
        csv_guard.to_lf(src, dst)
        with open(dst, "rb") as handle:
            self.assertEqual(handle.read(), b'\xef\xbb\xbfid,note\n1,"two\r\nlines"\n2,"say ""hi"""\n')

    def test_an_inch_mark_in_an_unquoted_field_does_not_keep_later_crs(self):
        src = self.write("inch.csv", b'sku,product,qty\r\n1,27" monitor,4\r\n2,USB cable,10\r\n3,mouse,7\r\n')
        dst = os.path.join(self.dir, "out.csv")
        self.assertTrue(csv_guard.to_lf(src, dst))
        with open(dst, "rb") as handle:
            self.assertEqual(handle.read(), b'sku,product,qty\n1,27" monitor,4\n2,USB cable,10\n3,mouse,7\n')

    def test_a_quoted_multi_line_field_after_an_inch_mark_keeps_its_crlf(self):
        src = self.write("mix.csv", b'id;note;qty\r\n1;5\'11" tall;2\r\n2;"two\r\nlines ""x""";3\r\n3;end;4\r\n')
        dst = os.path.join(self.dir, "out.csv")
        self.assertTrue(csv_guard.to_lf(src, dst, b";"))
        with open(dst, "rb") as handle:
            self.assertEqual(handle.read(), b'id;note;qty\n1;5\'11" tall;2\n2;"two\r\nlines ""x""";3\n3;end;4\n')

    def test_a_quote_that_never_closes_is_reported_and_the_cli_exits_3(self):
        src = self.write("open.csv", b'id,note\r\n1,"never closed\r\n2,x\r\n')
        dst = os.path.join(self.dir, "out.csv")
        self.assertFalse(csv_guard.to_lf(src, dst))
        self.assertEqual(csv_guard.main(["csv_guard.py", "lf", src, dst, ","]), 3)
        inch = self.write("inch.csv", b'a\tb\r\n1\t27" x\r\n2\ty\r\n')
        self.assertEqual(csv_guard.main(["csv_guard.py", "lf", inch, dst, "tab"]), 0)
        with open(dst, "rb") as handle:
            self.assertEqual(handle.read(), b'a\tb\n1\t27" x\n2\ty\n')

    def test_german_export_columns_are_named(self):
        src = self.write("sap.csv", "Beleg Nr.;Menge;Betrag;PLZ\n0000001237;1.234;1.234,56;01067\n4500001234;12.500;99,00;80331\n".encode())
        found = csv_guard.suspect_columns(src, ";")
        self.assertEqual([(p, n) for p, n, _ in found], [(1, "Beleg Nr."), (2, "Menge"), (4, "PLZ")])

    def test_a_comma_file_keeps_its_decimal_dots(self):
        src = self.write("en.csv", b"id,amount,zero\n1,1.234,0\n2,12.5,0.5\n")
        self.assertEqual(csv_guard.suspect_columns(src, ","), [])

    def test_leading_zeros_are_found_in_a_comma_file_too(self):
        src = self.write("codes.csv", b"id,code\n1,007\n")
        self.assertEqual([n for _, n, _ in csv_guard.suspect_columns(src, ",")], ["code"])

    def test_ddl_makes_only_inferred_numbers_text(self):
        ddl, changed = csv_guard.text_ddl(DRY_RUN, {1: "leading zeros", 2: "thousands dot", 3: "x"})
        self.assertIn('"Beleg Nr." VARCHAR(2000000),', ddl)
        self.assertIn('"Menge" VARCHAR(2000000),', ddl)
        self.assertTrue(ddl.startswith("CREATE TABLE STARTER_KIT.SAP ("))
        self.assertTrue(ddl.endswith(")"))
        self.assertEqual([n for n, _ in changed], ["Beleg Nr.", "Menge"])

    def test_ddl_is_nothing_when_nothing_changes(self):
        self.assertEqual(csv_guard.text_ddl(DRY_RUN, {3: "x"}), (None, []))


if __name__ == "__main__":
    unittest.main()
