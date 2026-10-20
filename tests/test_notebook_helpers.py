"""(run: python3 tests/test_notebook_helpers.py) The descriptor-driven explore notebook (PRD DS-3, DS-4): exakit_nb.dataset() against a fake connection, the trace
tags, the model switch, and the shipped notebook kept in step with its .py and free of any dataset's names."""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook" / "package"))

import importlib  # noqa: E402

import exakit_nb  # noqa: E402

nb_dataset = importlib.import_module("exakit_nb.dataset")    # the module; exakit_nb.dataset is the function

PHARMA = ["PHARMA.PHARMA_TRIALS." + c for c in ("NCT_ID", "LEAD_SPONSOR", "PHASE", "START_DATE", "TERMINATED", "BRIEF_SUMMARY")]


class FakeResult:
    def __init__(self, rows):
        self.rows = rows

    def fetchall(self):
        return self.rows


class FakeConn:
    """Answers the column listing and the label probe the way the database would."""

    def __init__(self, columns, labels=(("0",), ("1",))):
        self.columns, self.labels, self.statements = columns, list(labels), []

    def execute(self, statement):
        self.statements.append(statement)
        if "EXA_ALL_COLUMNS" in statement:
            return FakeResult([(nb_dataset._ANSWERED,), *[(c,) for c in self.columns]])
        return FakeResult(self.labels)


class DatasetTest(unittest.TestCase):
    def setUp(self):
        env = {"EXAKIT_NB_DATASETS": str(ROOT / "data" / "datasets")}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_a_kit_dataset_by_id_gives_its_roles_and_digest(self):
        ds = exakit_nb.dataset(FakeConn(PHARMA), "pharma_trials")
        self.assertEqual((ds.id, ds.fact_table, ds.col("label"), ds.col("category")), ("pharma_trials", "PHARMA.PHARMA_TRIALS", "TERMINATED", "PHASE"))
        self.assertEqual(ds.text_sql(), "COALESCE(BRIEF_SUMMARY, '')")
        self.assertEqual(len(ds.digest), 64)
        self.assertEqual(ds.tags(), {"exasol.dataset": "pharma_trials", "exasol.descriptor_sha256": ds.digest})

    def test_several_text_columns_join_into_one_expression(self):
        cols = ["BANKING.BANKING_COMPLAINTS." + c for c in ("COMPANY", "PRODUCT", "DATE_RECEIVED", "MONETARY_RELIEF", "ISSUE", "SUB_ISSUE",
                                                             "COMPANY_PUBLIC_RESPONSE")]
        ds = exakit_nb.dataset(FakeConn(cols), "banking_complaints")
        self.assertEqual(ds.text_sql(), "COALESCE(ISSUE, '') || ' ' || COALESCE(SUB_ISSUE, '') || ' ' || COALESCE(COMPANY_PUBLIC_RESPONSE, '')")

    def test_a_descriptor_file_of_your_own_is_one_assignment_away(self):
        with tempfile.TemporaryDirectory() as tmp:
            doc = {"schema_version": 1, "id": "tickets", "fact_table": "S.T",
                   "roles": {r: {"table": "S.T", "column": c} for r, c in
                             (("entity", "WHO"), ("category", "TEAM"), ("date", "ON_DAY"), ("label", "HOT"), ("text", "BODY"))}}
            (Path(tmp) / "descriptor.json").write_text(json.dumps(doc))
            ds = exakit_nb.dataset(FakeConn(["S.T." + c for c in ("WHO", "TEAM", "ON_DAY", "HOT", "BODY")]), tmp)
            self.assertEqual(ds.id, "tickets")
            with self.assertRaises(ValueError) as caught:
                exakit_nb.dataset(FakeConn(["S.T.WHO"]), tmp)
            self.assertIn("role 'category' points to column S.T.TEAM", str(caught.exception))
            self.assertIn("Load your file first", str(caught.exception))

    def test_a_missing_table_names_the_data_load_for_a_kit_dataset(self):
        with self.assertRaises(ValueError) as caught:
            exakit_nb.dataset(FakeConn([]), "pharma_trials")
        self.assertIn("exakit data-load pharma_trials", str(caught.exception))

    def test_an_unknown_name_lists_the_datasets_that_have_a_descriptor(self):
        with self.assertRaises(ValueError) as caught:
            exakit_nb.dataset(FakeConn(PHARMA), "no_such_set")
        self.assertIn("pharma_trials", str(caught.exception))
        self.assertIn("banking_complaints", str(caught.exception))

    def test_an_empty_table_or_a_label_that_is_not_0_or_1_is_refused(self):
        with self.assertRaises(ValueError) as caught:
            exakit_nb.dataset(FakeConn(PHARMA, labels=[]), "pharma_trials")
        self.assertIn("has no rows", str(caught.exception))
        with self.assertRaises(ValueError) as caught:
            exakit_nb.dataset(FakeConn(PHARMA, labels=[("0",), ("yes",)]), "pharma_trials")
        self.assertIn("must be 0 or 1", str(caught.exception))

    def test_the_kit_rules_decide_and_an_invalid_descriptor_says_why(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "descriptor.json").write_text(json.dumps({"schema_version": 1, "id": "x", "fact_table": "S.T", "roles": {}}))
            with self.assertRaises(Exception) as caught:
                exakit_nb.dataset(FakeConn([]), tmp)
            self.assertIn("entity", str(caught.exception))


class ModelAndTraceTest(unittest.TestCase):
    def test_no_model_name_skips_the_text_step_with_one_line(self):
        with mock.patch.dict(os.environ, {}, clear=True), redirect_stdout(io.StringIO()) as out:
            self.assertIsNone(exakit_nb.model_client())
        self.assertIn("EXAKIT_NB_MODEL not set", out.getvalue())

    def test_tracing_is_off_without_every_langfuse_variable(self):
        with mock.patch.dict(os.environ, {"LANGFUSE_PUBLIC_KEY": "pk", "LANGFUSE_HOST": "h"}, clear=True), redirect_stdout(io.StringIO()) as out:
            self.assertFalse(exakit_nb.tracing())
            with exakit_nb.trace(None, "step") as span:
                self.assertIsNone(span)
        self.assertIn("LANGFUSE_SECRET_KEY", out.getvalue())
        self.assertNotIn("pk", out.getvalue().replace("LANGFUSE_PUBLIC_KEY", ""))


class ShippedExploreTest(unittest.TestCase):
    NOTEBOOK = ROOT / "notebook" / "notebooks" / "explore.py"

    def test_the_ipynb_is_built_from_its_py(self):
        done = subprocess.run([sys.executable, str(ROOT / "tools" / "notebooks.py"), "--check"], capture_output=True, text=True, check=False)
        self.assertEqual(done.returncode, 0, done.stdout)
        self.assertTrue(self.NOTEBOOK.with_suffix(".ipynb").exists())

    def test_one_assignment_picks_the_data_and_no_dataset_is_named_in_the_sql(self):
        text = self.NOTEBOOK.read_text(encoding="utf-8")
        self.assertEqual(sum(1 for line in text.splitlines() if line.startswith("DATASET = ")), 1)
        code = "\n".join(line for line in text.splitlines() if not line.startswith(("#", "DATASET = ")))
        for name in ("PHARMA", "BANKING", "TERMINATED", "MONETARY_RELIEF", "BRIEF_SUMMARY", "LEAD_SPONSOR"):
            with self.subTest(name=name):
                self.assertNotIn(name, code, "the SQL comes from the descriptor's roles")

    def test_it_compiles(self):
        compile(self.NOTEBOOK.read_text(encoding="utf-8"), str(self.NOTEBOOK), "exec")


if __name__ == "__main__":
    unittest.main()
