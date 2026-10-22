"""tools/dataset_check.py and tools/dataset_live.py (run: python3 tests/test_dataset_check.py): every file defect is named before a load, and the live check
loads, verifies and cleans up - refusing a schema it did not create, dropping its own even when a step fails. The
dataset builders (tools/datasets) keep to their text rule and write exactly the tables the shipped datasets have."""

from __future__ import annotations

import hashlib
import json
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
        for builder in ("pharma_trials", "banking_complaints"):
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


DESCRIPTOR = """schema_version: 1
id: edge_demo
fact_table: EDGE_DEMO.EDGE_ITEMS
roles:
  entity:   {table: EDGE_DEMO.EDGE_ITEMS, column: ITEM_ID}
  category: {table: EDGE_DEMO.EDGE_ITEMS, column: NAME}
  date:     {table: EDGE_DEMO.EDGE_ITEMS, column: ADDED_ON}
  label:    {table: EDGE_DEMO.EDGE_ITEMS, column: FLAG}
  text:     [{table: EDGE_DEMO.EDGE_ITEMS, column: NOTE}]
"""
REF_CREATE = CREATE.replace("    ADDED_ON DATE,", "    ADDED_ON DATE,\n    FLAG     DECIMAL(1,0),\n    NOTE     VARCHAR(20),")
REF_CSV = "ITEM_ID,NAME,ADDED_ON,FLAG,NOTE\n1,a,2024-01-01,0,x\n2,b,2024-01-02,1,y\n3,c,2024-01-03,0,z\n"
README = """# edge_demo

## Data dictionary

`EDGE_ITEMS`: `ITEM_ID`, `NAME`, `ADDED_ON`, `FLAG`, `NOTE`.

## The descriptor

[`descriptor.yaml`](descriptor.yaml)
"""
EXAMPLES = "-- examples.sql - header, not a question.\n\n" + "\n".join(
    f"-- {n}. Question {n}?\nSELECT COUNT(*) FROM EDGE_DEMO.EDGE_ITEMS WHERE ITEM_ID > {n};\n" for n in range(1, 11))


class ReferenceTest(unittest.TestCase):
    """AC-DS2.2 offline: a reference dataset has a README with a data dictionary, at least ten example questions with
    reference SQL, a descriptor that validates, a manifest with source, terms, snapshot and rows - and an asset block
    that is the archive its CSVs make (tools/datasets/package.py)."""

    def setUp(self) -> None:
        sys.path.insert(0, str(ROOT / "tools" / "datasets"))
        import package
        self.package = package
        self.folder = Folder()
        self.addCleanup(self.folder.close)
        self.dist = Path(self.folder.tmp) / "dist"
        patch = mock.patch.object(package, "DIST", self.dist)
        patch.start()
        self.addCleanup(patch.stop)
        f = self.folder.path
        (f / "01_create_schema.sql").write_text(REF_CREATE)
        self.folder.csv.write_text(REF_CSV)
        (f / "descriptor.yaml").write_text(DESCRIPTOR)
        (f / "README.md").write_text(README)
        (f / "examples.sql").write_text(EXAMPLES)
        dataset_check.write_manifest(f)
        manifest = json.loads((f / "manifest.json").read_text())
        manifest.update(source={"name": "Edge", "url": "https://example.org"}, snapshot="2026-01-02",
                        terms={"url": "https://example.org/terms", "summary": "free", "confirmed": True})
        (f / "manifest.json").write_text(json.dumps(manifest, indent=2))
        self.asset = package.package(f, self.dist)

    def problems(self) -> str:
        return " | ".join(dataset_check.check(self.folder.path))

    def manifest(self, **changes) -> None:
        path = self.folder.path / "manifest.json"
        doc = json.loads(path.read_text())
        doc.update(changes)
        path.write_text(json.dumps(doc, indent=2))

    def test_a_complete_reference_dataset_passes(self):
        self.assertEqual(self.problems(), "")

    def test_the_data_dictionary_names_every_column(self):
        (self.folder.path / "README.md").write_text(README.replace(", `NOTE`", ""))
        self.assertIn("the data dictionary does not name EDGE_ITEMS.NOTE", self.problems())
        (self.folder.path / "README.md").write_text("# edge_demo\n")
        self.assertIn("no '## Data dictionary' section", self.problems())

    def test_every_example_has_a_question_and_there_are_ten(self):
        (self.folder.path / "examples.sql").write_text(EXAMPLES.replace("-- 4. Question 4?\n", ""))
        self.assertIn("query 4 has no question", self.problems())
        (self.folder.path / "examples.sql").write_text(EXAMPLES.split("-- 10.")[0])
        self.assertIn("examples.sql has 9 queries", self.problems())

    def test_the_manifest_names_source_terms_snapshot_and_rows(self):
        self.manifest(terms={"url": "https://x", "summary": "y"})
        self.assertIn("terms.confirmed must be true or false", self.problems())
        self.manifest(source={"url": "https://x"})
        self.assertIn("source.name is missing", self.problems())
        self.manifest(snapshot="last week")
        self.assertIn("snapshot must be a date", self.problems())

    def test_the_asset_is_the_archive_these_csvs_make(self):
        self.folder.csv.write_text(REF_CSV + "4,d,2024-01-04,0,w\n")
        dataset_check.write_manifest(self.folder.path)         # files updated, the asset not
        self.assertIn("tar_sha256 differs", self.problems())
        self.package.package(self.folder.path, self.dist)
        self.assertEqual(self.problems(), "")

    def test_the_asset_block_is_required_and_well_formed(self):
        path = self.folder.path / "manifest.json"
        doc = json.loads(path.read_text())
        asset = dict(doc["asset"])
        self.manifest(asset=dict(asset, url="http://example.org/" + asset["file"]))
        self.assertIn("asset.url must be", self.problems())
        self.manifest(asset=dict(asset, file="other.tar.gz"))
        self.assertIn("asset.file must be edge_demo-2026-01-02.tar.gz", self.problems())
        self.manifest(asset=dict(asset, sha256="nope"))
        self.assertIn("asset.sha256 is not a SHA-256", self.problems())
        doc.pop("asset")
        path.write_text(json.dumps(doc))
        self.assertIn("has no asset block", self.problems())

    def test_a_locally_built_archive_must_be_the_one_named(self):
        archive = self.dist / self.asset["file"]
        archive.write_bytes(archive.read_bytes() + b"x")
        self.assertIn("is not the archive manifest.json names", self.problems())
        archive.unlink()
        self.assertEqual(self.problems(), "")                # no local build: the CSVs alone decide

    def test_the_archive_is_deterministic(self):
        import gzip
        import tarfile
        first = (self.dist / self.asset["file"]).read_bytes()
        again = self.package.package(self.folder.path, self.dist)
        self.assertEqual(first, (self.dist / again["file"]).read_bytes())
        self.assertEqual(self.asset, again)
        self.assertEqual(first[4:8], b"\0\0\0\0")             # gzip header mtime 0
        with tarfile.open(self.dist / self.asset["file"]) as tar:
            members = tar.getmembers()
        self.assertEqual([m.name for m in members], ["data/edge_items.csv"])
        self.assertEqual({(m.uid, m.gid, m.uname, m.gname, m.mode) for m in members}, {(0, 0, "", "", 0o644)})
        self.assertEqual(hashlib.sha256(gzip.decompress(first)).hexdigest(), self.asset["tar_sha256"])

    def test_package_refuses_a_manifest_that_does_not_match(self):
        self.folder.csv.write_text(REF_CSV + "4,d,2024-01-04,0,w\n")
        with self.assertRaises(ValueError):
            self.package.package(self.folder.path, self.dist)

    def test_the_example_questions_are_read_as_written(self):
        found = dataset_check.example_questions(EXAMPLES)
        self.assertEqual(len(found), 10)
        self.assertEqual(found[0], ("1. Question 1?", "SELECT COUNT(*) FROM EDGE_DEMO.EDGE_ITEMS WHERE ITEM_ID > 1"))

    def test_the_shipped_reference_datasets_have_ten_questions_each(self):
        for name in ("pharma_trials", "banking_complaints"):
            with self.subTest(dataset=name):
                found = dataset_check.example_questions((ROOT / "data" / "datasets" / name / "examples.sql").read_text())
                self.assertGreaterEqual(len(found), 10)
                self.assertTrue(all(q for q, _sql in found))


class DescriptorDocsTest(unittest.TestCase):
    """AC-DS2.3: data/README.md documents the descriptor with one example per reference dataset and one for a user's
    own file - and every example there is a descriptor that validates, the reference ones the very files shipped."""

    def test_every_yaml_example_validates_and_the_reference_ones_are_the_shipped_files(self):
        import re
        from descriptor_rules import parse_descriptor, read_descriptor
        text = (ROOT / "data" / "README.md").read_text(encoding="utf-8")
        examples = [parse_descriptor(block, "data/README.md") for block in re.findall(r"```yaml\n(.*?)```", text, re.DOTALL)]
        ids = [d.id for d in examples]
        self.assertIn("pharma_trials", ids)
        self.assertIn("banking_complaints", ids)
        self.assertTrue(any(d.id not in ("pharma_trials", "banking_complaints") and d.source is None for d in examples),
                        "an example for a user's own file")
        self.assertTrue(any(d.source for d in examples), "an example with the optional source key")
        for d in examples:
            if d.id in ("pharma_trials", "banking_complaints"):
                with self.subTest(dataset=d.id):
                    self.assertEqual(d, read_descriptor(ROOT / "data" / "datasets" / d.id))


class LiveReferenceTest(unittest.TestCase):
    """The live check runs every example query of a reference dataset and wants rows back from each."""

    def test_every_example_runs_and_an_empty_answer_is_a_problem(self):
        class Answering(FakePump):
            def sql(self, text, what):
                self.calls.append(what)
                if what.startswith("examples.sql query"):
                    return "N\n0\n" if "> 3" not in text else ""
                return super().sql(text, what)

        folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, folder)
        (folder / "examples.sql").write_text(EXAMPLES)
        pump, report = Answering(), dataset_live.Report()
        dataset_live._run_examples(pump, folder, report)
        self.assertEqual(sum(1 for c in pump.calls if c.startswith("examples.sql query")), 10)
        self.assertEqual(report.problems, ["examples.sql query 3: returned no rows"])

    def test_the_reference_check_reads_the_label_from_the_descriptor(self):
        class Database(FakePump):
            def sql(self, text, what):
                self.calls.append(what)
                if what == "reading the columns":
                    return "T,C\n" + "".join(f"EDGE_DEMO.EDGE_ITEMS,{c}\n" for c in ("ITEM_ID", "NAME", "ADDED_ON", "FLAG", "NOTE"))
                if what == "reading the label":
                    return "V\n0\n1\n"
                if what.startswith("examples.sql query"):
                    return "N\n1\n"
                return super().sql(text, what)

        folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, folder)
        (folder / "descriptor.yaml").write_text(DESCRIPTOR)
        (folder / "examples.sql").write_text(EXAMPLES)
        report = dataset_live.Report()
        dataset_live._check_reference(Database(), folder, report)
        self.assertEqual(report.problems, [])
        self.assertIn("examples.sql: all 10 queries ran and returned rows", report.passed)


class AssetServiceTest(unittest.TestCase):
    """setup/lib/dataset_asset.py, the extraction both twins call: only plain data/<name>.csv members the manifest
    lists, each once, all of them, each with its digest - anything else is refused and nothing is cached."""

    def setUp(self) -> None:
        sys.path.insert(0, str(ROOT / "setup" / "lib"))
        import dataset_asset
        self.service = dataset_asset
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.folder = self.tmp / "demo"
        (self.folder / "data").mkdir(parents=True)
        self.cache = self.tmp / "cache"
        self.body = b"A,B\n1,2\n"

    def archive(self, members) -> Path:
        """An archive of (name, kind) members and a manifest that trusts it (right digest, files listed)."""
        import io
        import tarfile
        path = self.tmp / "demo.tar.gz"
        with tarfile.open(path, "w:gz") as tar:
            for name, kind in members:
                info = tarfile.TarInfo(name)
                if kind == "file":
                    info.size = len(self.body)
                    tar.addfile(info, io.BytesIO(self.body))
                elif kind == "hardlink":
                    info.type, info.linkname = tarfile.LNKTYPE, "data/a.csv"
                    tar.addfile(info)
                elif kind == "fifo":
                    info.type = tarfile.FIFOTYPE
                    tar.addfile(info)
        digest = hashlib.sha256(self.body).hexdigest()
        (self.folder / "manifest.json").write_text(json.dumps({
            "id": "demo", "snapshot": "2026-01-02",
            "asset": {"file": "demo.tar.gz", "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                      "size": path.stat().st_size, "url": "https://github.com/{repo}/x/demo.tar.gz"},
            "files": {"data/a.csv": {"rows": 1, "sha256": digest}, "data/b.csv": {"rows": 1, "sha256": digest}}}))
        return path

    def install(self, members):
        try:
            return self.service.install(self.folder, self.cache, self.archive(members))
        except self.service.Refused as err:
            return f"refused {err.code}: {err}"

    def test_a_good_archive_is_cached_and_then_reused(self):
        found = self.install([("data/a.csv", "file"), ("data/b.csv", "file")])
        self.assertTrue(found.startswith("dir\t"), found)
        self.assertEqual(self.service.resolve(self.folder, self.cache), found)
        self.assertFalse((self.tmp / "demo.tar.gz").exists())          # the download is deleted once used

    def test_unsafe_or_unlisted_members_are_refused(self):
        cases = {
            "../x.csv": [("data/a.csv", "file"), ("../x.csv", "file")],
            "/abs.csv": [("/abs.csv", "file")],
            "hardlink": [("data/a.csv", "file"), ("data/b.csv", "hardlink")],
            "fifo": [("data/a.csv", "fifo")],
            "unlisted": [("data/a.csv", "file"), ("data/c.csv", "file")],
            "twice": [("data/a.csv", "file"), ("data/a.csv", "file")],
            "missing": [("data/a.csv", "file")],
        }
        for case, members in cases.items():
            with self.subTest(case=case):
                shutil.rmtree(self.cache, ignore_errors=True)
                found = self.install(members)
                self.assertTrue(found.startswith("refused 4"), found)
                self.assertEqual(list((self.cache / "demo").iterdir()) if (self.cache / "demo").exists() else [], [])
                self.assertFalse((self.tmp / "x.csv").exists())

    def test_a_wrong_digest_is_refused_before_anything_is_read(self):
        path = self.archive([("data/a.csv", "file"), ("data/b.csv", "file")])
        path.write_bytes(path.read_bytes() + b"x")
        with self.assertRaises(self.service.Refused) as caught:
            self.service.install(self.folder, self.cache, path)
        self.assertEqual(caught.exception.code, 3)
        self.assertFalse(path.exists())
        self.assertFalse((self.cache / "demo").exists() and any((self.cache / "demo").iterdir()))

    def test_without_an_asset_block_the_kit_copy_is_used(self):
        (self.folder / "manifest.json").write_text(json.dumps({"id": "demo", "files": {}}))
        self.assertEqual(self.service.resolve(self.folder, self.cache), "kit")
        self.assertEqual(self.service.resolve(self.tmp / "no-such", self.cache), "kit")


if __name__ == "__main__":
    unittest.main()
