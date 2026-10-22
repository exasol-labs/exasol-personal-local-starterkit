"""tools/dataset_check.py and tools/dataset_live.py (run: python3 tests/test_dataset_check.py): every file defect is named before a load, and the live check
loads, verifies and cleans up - refusing a schema it did not create, dropping its own even when a step fails. The
dataset builders (tools/datasets) keep to their text rule and write exactly the tables the shipped datasets have."""

from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import dataset_check  # noqa: E402
import dataset_live  # noqa: E402

REAL_ROWS = dataset_live.Pump.rows          # the CSV parsing the fake shares; Pump itself is patched in LiveTest

CREATE = """CREATE SCHEMA IF NOT EXISTS EDGE_DEMO;
OPEN SCHEMA EDGE_DEMO;

CREATE OR REPLACE TABLE EDGE_ITEMS (
    ITEM_ID  DECIMAL(9,0) NOT NULL,
    NAME     VARCHAR(20)  NOT NULL,
    ADDED_ON DATE,
    CONSTRAINT EDGE_ITEMS_PK PRIMARY KEY (ITEM_ID)
);
"""
CSV = "ITEM_ID,NAME,ADDED_ON\n1,a,2024-01-01\n2,b,2024-01-02\n3,c,2024-01-03\n"


class Folder:
    """A small, valid dataset folder in a temporary directory, to break one thing at a time."""

    def __init__(self) -> None:
        self.tmp = tempfile.mkdtemp()
        self.path = Path(self.tmp) / "edge_demo"
        (self.path / "data").mkdir(parents=True)
        (self.path / "dataset.conf").write_text("id=edge_demo\nlabel=Edge demo\nschema=EDGE_DEMO\nmarkers=EDGE_ITEMS\n")
        (self.path / "01_create_schema.sql").write_text(CREATE)
        (self.path / "03_verify_setup.sql").write_text("SELECT 'rows', CASE WHEN COUNT(*) = 3 THEN 'OK' ELSE 'FAIL' END, '' FROM EDGE_ITEMS;\n")
        self.csv = self.path / "data" / "edge_items.csv"
        self.csv.write_bytes(CSV.encode())

    def close(self) -> None:
        shutil.rmtree(self.tmp)


class OfflineTest(unittest.TestCase):
    def setUp(self) -> None:
        self.folder = Folder()
        self.addCleanup(self.folder.close)

    def problems(self) -> list[str]:
        return dataset_check.check(self.folder.path)

    def test_a_valid_folder_has_no_problem(self):
        self.assertEqual(self.problems(), [])

    def test_each_file_defect_is_named(self):
        f = self.folder
        cases = {
            "byte-order mark": lambda: f.csv.write_bytes(b"\xef\xbb\xbf" + CSV.encode()),
            "not UTF-8": lambda: f.csv.write_bytes(CSV.encode() + "4,caf\xe9,2024-01-04\n".encode("latin-1")),
            "header differs": lambda: f.csv.write_text(CSV.replace("ITEM_ID,NAME,ADDED_ON", "ITEM_ID,ADDED_ON,NAME")),
            "names a column twice": lambda: f.csv.write_text(CSV.replace("ITEM_ID,NAME,ADDED_ON", "ITEM_ID,NAME,NAME")),
            "2 fields, the header has 3": lambda: f.csv.write_text(CSV + "4,d\n"),
            "empty NOT NULL NAME": lambda: f.csv.write_text(CSV + "4,,2024-01-04\n"),
            "repeats an earlier row": lambda: f.csv.write_text(CSV + "3,dup,2024-01-04\n"),
            "reserved word": lambda: (f.csv.write_text(CSV.replace("NAME", "STATE")),
                                      (f.path / "01_create_schema.sql").write_text(CREATE.replace("NAME     ", "STATE    "))),
            "must create exactly the schema": lambda: (f.path / "01_create_schema.sql").write_text(CREATE.replace("EXISTS EDGE_DEMO", "EXISTS OTHER")),
            "no primary key": lambda: (f.path / "01_create_schema.sql").write_text(CREATE.replace(",\n    CONSTRAINT EDGE_ITEMS_PK PRIMARY KEY (ITEM_ID)", "")),
            "id must be the folder name": lambda: (f.path / "dataset.conf").write_text("id=other\nlabel=x\nmarkers=EDGE_ITEMS\nschema=EDGE_DEMO\n"),
            "marker NOPE": lambda: (f.path / "dataset.conf").write_text("id=edge_demo\nlabel=x\nmarkers=NOPE\nschema=EDGE_DEMO\n"),
            "does not check EDGE_ITEMS": lambda: (f.path / "03_verify_setup.sql").write_text("SELECT 1;\n"),
            "has no CREATE TABLE": lambda: (f.path / "data" / "extra.csv").write_text("A\n1\n"),
        }
        for reason, breaks in cases.items():
            with self.subTest(reason=reason):
                fresh = Folder()
                try:
                    f = fresh
                    breaks()
                    self.assertTrue(any(reason in p for p in dataset_check.check(fresh.path)), dataset_check.check(fresh.path))
                finally:
                    fresh.close()

    def test_a_reference_dataset_needs_its_manifest_readme_and_examples(self):
        (self.folder.path / "descriptor.json").write_text(
            '{"schema_version": 1, "id": "edge_demo", "fact_table": "EDGE_DEMO.EDGE_ITEMS", "roles": {'
            '"entity": {"table": "EDGE_DEMO.EDGE_ITEMS", "column": "ITEM_ID"}, "category": {"table": "EDGE_DEMO.EDGE_ITEMS", "column": "NAME"},'
            '"date": {"table": "EDGE_DEMO.EDGE_ITEMS", "column": "ADDED_ON"}, "label": {"table": "EDGE_DEMO.EDGE_ITEMS", "column": "LABEL"},'
            '"text": {"table": "EDGE_DEMO.EDGE_ITEMS", "column": "NAME2"}}}')
        found = " | ".join(self.problems())
        for reason in ("label names EDGE_DEMO.EDGE_ITEMS.LABEL", "manifest.json is missing", "README.md is missing", "examples.sql has 0"):
            self.assertIn(reason, found)
        dataset_check.write_manifest(self.folder.path)
        self.assertNotIn("files do not match", " | ".join(self.problems()))
        self.folder.csv.write_text(CSV + "4,d,2024-01-04\n")
        self.assertIn("files do not match", " | ".join(self.problems()))

    def test_the_command_line_refuses_what_it_does_not_know(self):
        self.assertEqual(dataset_check.main(["--frob"]), 2)
        self.assertEqual(dataset_check.main([]), 2)
        self.assertEqual(dataset_check.main([str(self.folder.path / "nope")]), 2)


class FakePump:
    """exapump in memory: answers the schema probe, records the scripts, fails the step it is told to."""

    def __init__(self, exists: bool = False, fail: str = "") -> None:
        self.exists, self.fail, self.calls = exists, fail, []

    def sql(self, text, what):
        self.calls.append(what)
        if self.fail and self.fail in what:
            raise dataset_live.LiveError(f"{what}: broken")
        if "EXA_SCHEMAS" in text:
            return f"N\n{1 if self.exists else 0}\n"
        if "COUNT(*) AS N" in text:
            return "N\n3\n"
        return "rows,OK,\n" if what == "03_verify_setup.sql" else ""

    def upload(self, path, table):
        self.calls.append(f"upload {path.name}")
        return 3

    def rows(self, query, what):
        return REAL_ROWS(self, query, what)


class LiveTest(unittest.TestCase):
    def setUp(self) -> None:
        self.folder = Folder()
        self.addCleanup(self.folder.close)

    def run_with(self, pump, **kwargs):
        with mock.patch.object(dataset_live, "Pump", lambda profile: pump):
            return dataset_live.live_check(self.folder.path, "EDGE_DEMO", ["EDGE_ITEMS"], profile="p", **kwargs)

    def test_a_clean_load_passes_and_drops_its_schema(self):
        pump = FakePump()
        report = self.run_with(pump)
        self.assertEqual(report.problems, [])
        self.assertEqual(pump.calls[-1], "dropping EDGE_DEMO")
        self.assertIn("upload edge_items.csv", pump.calls)

    def test_an_existing_schema_is_never_touched_without_replace(self):
        pump = FakePump(exists=True)
        with self.assertRaises(dataset_live.LiveError):
            self.run_with(pump)
        self.assertNotIn("01_create_schema.sql", pump.calls)

    def test_replace_reloads_an_existing_schema_and_leaves_it(self):
        pump = FakePump(exists=True)
        self.assertEqual(self.run_with(pump, replace=True).problems, [])
        self.assertNotIn("dropping EDGE_DEMO", pump.calls)

    def test_a_failed_step_is_reported_and_the_schema_still_dropped(self):
        pump = FakePump(fail="01_create_schema.sql")
        report = self.run_with(pump)
        self.assertEqual(report.problems, ["01_create_schema.sql: broken"])
        self.assertEqual(pump.calls[-1], "dropping EDGE_DEMO")

    def test_keep_leaves_the_load_in_place(self):
        pump = FakePump()
        self.run_with(pump, keep=True)
        self.assertNotIn("dropping EDGE_DEMO", pump.calls)


class BuilderTest(unittest.TestCase):
    """tools/datasets: the shared text rule, and every builder against the dataset it writes (no network)."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(ROOT / "tools" / "datasets"))

    def test_clean_never_exceeds_its_limit_and_cuts_on_a_word(self):
        from snapshot import clean
        self.assertEqual(clean("  one\n two  "), "one two")
        self.assertEqual(clean("short", 10), "short")
        self.assertEqual(clean("aaa bbb ccc", 9), "aaa bbb …")         # a space right after the room keeps the word
        self.assertEqual(clean("aaa bbbb ccc", 9), "aaa …")
        self.assertEqual(clean("abcdefghijkl", 6), "abcd …")            # one long word is cut inside it
        for limit in range(3, 40):
            for text in ("x " * 30, "word " * 12, "a bb ccc dddd eeeee " * 3, "y" * 50):
                cut = clean(text, limit)
                self.assertLessEqual(len(cut), limit, (text, limit, cut))
                if len(" ".join(text.split())) > limit:
                    self.assertTrue(cut.endswith(" …"))

    def test_each_builder_writes_the_tables_and_columns_the_dataset_ships(self):
        import csv
        import importlib
        for builder in ("pharma_trials", "banking_complaints", "fda_recalls", "bank_marketing"):
            folder = ROOT / "data" / "datasets" / builder
            built = importlib.import_module(builder).TABLES
            schema = dataset_check.tables(folder)
            shipped = {}
            for path in (folder / "data").glob("*.csv"):
                with path.open(encoding="utf-8") as handle:
                    shipped[path.stem.upper()] = next(csv.reader(handle))
            with self.subTest(builder=builder):
                self.assertEqual(built, schema)
                self.assertEqual(built, shipped)

    def test_fda_names_fit_their_columns_whole(self):
        import re
        import fda_recalls
        sql = (ROOT / "data" / "datasets" / "fda_recalls" / "01_create_schema.sql").read_text(encoding="utf-8")
        widths = {m.group(1): int(m.group(2)) for m in re.finditer(r"^\s+(\w+)\s+VARCHAR\((\d+)\)", sql, re.M)}
        self.assertEqual(fda_recalls.WIDTH, {c: widths[c] for c in fda_recalls.WIDTH})
        for column, limit in fda_recalls.TEXT.items():
            self.assertLessEqual(limit, widths[column], column)
        self.assertEqual(fda_recalls._name("FIRM_STATE", "N/A"), "")
        with self.assertRaises(SystemExit):
            fda_recalls._name("RECALL_STATUS", "x" * 21)


if __name__ == "__main__":
    unittest.main()
