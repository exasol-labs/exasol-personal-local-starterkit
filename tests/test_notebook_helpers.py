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
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook" / "package"))

import importlib  # noqa: E402

import exakit_nb  # noqa: E402

nb_dataset = importlib.import_module("exakit_nb.dataset")    # the module; exakit_nb.dataset is the function

PHARMA = ["PHARMA.PHARMA_TRIALS." + c for c in ("NCT_ID", "LEAD_SPONSOR", "PHASE", "START_DATE", "TERMINATED", "BRIEF_SUMMARY",
                                                "ELIGIBILITY_CRITERIA")]


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
        self.assertEqual(ds.text_sql(), "COALESCE(BRIEF_SUMMARY, '') || ' ' || COALESCE(ELIGIBILITY_CRITERIA, '')")
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


sys.path.insert(0, str(ROOT / "notebook" / "kit"))
import notebooks as kit_notebooks  # noqa: E402  (notebook/kit/notebooks.py, the folder placer)


class PositronSettingsTest(unittest.TestCase):
    """notebook/kit/notebooks.py positron: VS Code's settings file as VS Code writes it."""

    PY, VENV = "/kit/notebook-venv/bin/python", "/kit/notebook-venv"

    def run_positron(self, text: str | None):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".vscode" / "settings.json"
            if text is not None:
                path.parent.mkdir()
                path.write_text(text, encoding="utf-8")
            try:
                kit_notebooks.positron(Path(tmp), self.PY, self.VENV)
                outcome = "ok"
            except kit_notebooks.SettingsError as err:
                outcome = f"refused: {err}"
            return outcome, path.read_text(encoding="utf-8") if path.exists() else None

    def test_a_blank_or_missing_file_becomes_the_two_settings(self):
        for text in (None, "", "  \n\t"):
            with self.subTest(text=text):
                outcome, written = self.run_positron(text)
                self.assertEqual(outcome, "ok")
                self.assertEqual(json.loads(written), {"python.defaultInterpreterPath": self.PY,
                                                       "python.interpreters.include": [self.VENV]})

    def test_trailing_commas_are_read_and_the_other_settings_kept(self):
        outcome, written = self.run_positron('{\n  "editor.fontSize": 14,\n  "files.exclude": {"a": true,},\n}\n')
        self.assertEqual(outcome, "ok")
        self.assertEqual(json.loads(written)["files.exclude"], {"a": True})

    def test_a_file_with_comments_is_never_rewritten(self):
        text = '{\n  // my font\n  "editor.fontSize": 14, /* big */\n  "url": "http://x//y"\n}\n'
        outcome, written = self.run_positron(text)
        self.assertTrue(outcome.startswith("refused: has comments"), outcome)
        self.assertIn("python.defaultInterpreterPath", outcome, "it says what to add by hand")
        self.assertEqual(written, text)

    def test_a_file_with_comments_that_already_names_the_kit_python_is_fine(self):
        text = (f'{{\n  // set by hand\n  "python.defaultInterpreterPath": "{self.PY}",\n'
                f'  "python.interpreters.include": ["{self.VENV}"],\n}}\n')
        self.assertEqual(self.run_positron(text), ("ok", text))

    def test_an_include_that_is_a_string_null_or_mixed_is_handled(self):
        for value, kept in (('"/other"', ["/other"]), ("null", []), ('["/a", null, 3, "/b"]', ["/a", "/b"])):
            with self.subTest(value=value):
                outcome, written = self.run_positron(f'{{"python.interpreters.include": {value}}}')
                self.assertEqual(outcome, "ok")
                self.assertEqual(json.loads(written)["python.interpreters.include"], [*kept, self.VENV])

    def test_what_is_not_json_or_not_an_object_is_left_alone(self):
        for text in ("{not json", "[1, 2]", "/* never closed"):
            with self.subTest(text=text):
                outcome, written = self.run_positron(text)
                self.assertTrue(outcome.startswith("refused"), outcome)
                self.assertEqual(written, text)

    def test_the_uninstall_takes_out_only_the_kits_two_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            kit_notebooks.positron(Path(tmp), self.PY, self.VENV)
            path = Path(tmp) / ".vscode" / "settings.json"
            doc = json.loads(path.read_text(encoding="utf-8"))
            doc["python.interpreters.include"].insert(0, "/mine")
            doc["editor.fontSize"] = 14
            path.write_text(json.dumps(doc), encoding="utf-8")
            self.assertEqual(kit_notebooks.positron_remove(Path(tmp), self.PY, self.VENV), "removed")
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")),
                             {"python.interpreters.include": ["/mine"], "editor.fontSize": 14})
            path.write_text(json.dumps({"python.defaultInterpreterPath": self.PY}), encoding="utf-8")
            self.assertEqual(kit_notebooks.positron_remove(Path(tmp), self.PY, self.VENV), "removed")
            self.assertFalse(path.exists(), "a file holding only the kit's settings goes")
            self.assertEqual(kit_notebooks.positron_remove(Path(tmp), self.PY, self.VENV), "absent")


class CopyTest(unittest.TestCase):
    """notebook/kit/notebooks.py copy: once, never over the user's, and a deleted one stays deleted."""

    def test_copied_once_then_the_users(self):
        with tempfile.TemporaryDirectory() as tmp:
            added, problems = kit_notebooks.copy("jupyter", ROOT, Path(tmp))
            self.assertIn("data-scientist/start_here.ipynb", added)
            self.assertEqual(problems, [])
            base = Path(tmp) / "starter-kit-notebooks"
            self.assertIn("data-scientist/start_here.ipynb", (base / ".kit-copied").read_text(encoding="utf-8").split())
            (base / "data-scientist" / "start_here.ipynb").unlink()
            self.assertEqual(kit_notebooks.copy("jupyter", ROOT, Path(tmp)), ([], []))
            self.assertFalse((base / "data-scientist" / "start_here.ipynb").exists(), "deleted by the user: not copied again")

    def test_a_kit_that_existed_before_the_record_counts_what_is_there(self):
        with tempfile.TemporaryDirectory() as tmp:
            kit_notebooks.copy("jupyter", ROOT, Path(tmp))
            base = Path(tmp) / "starter-kit-notebooks"
            (base / ".kit-copied").unlink()                       # a folder an older kit filled
            self.assertEqual(kit_notebooks.copy("jupyter", ROOT, Path(tmp)), ([], []))
            self.assertTrue((base / ".kit-copied").is_file())

    def test_one_that_cannot_be_copied_is_named_and_the_rest_still_come(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "starter-kit-notebooks"
            base.mkdir()
            (base / "ml-engineer").write_text("a file, not a folder", encoding="utf-8")
            added, problems = kit_notebooks.copy("jupyter", ROOT, Path(tmp))
            self.assertIn("data-scientist/start_here.ipynb", added)
            self.assertTrue(problems and all(p.startswith("ml-engineer/") and "is a file" in p for p in problems), problems)
            with redirect_stderr(io.StringIO()) as err:
                self.assertEqual(kit_notebooks.main(["copy", "jupyter", str(ROOT), tmp]), 1)
            self.assertIn("could not copy ml-engineer/train.ipynb", err.getvalue())

    def test_the_folder_must_be_named(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(kit_notebooks.main(["copy", "jupyter", str(ROOT)]), 2)


try:
    import pandas  # noqa: F401
    HAVE_PANDAS = True
except ImportError:                                               # the system Python; the kit's venv has it
    HAVE_PANDAS = False


class _OwnConn:
    """Answers what load_own_file asks: no such table yet, then the columns of what was imported."""

    def __init__(self):
        self.statements, self.comment, self.frame = [], None, None

    def execute(self, statement):
        self.statements.append(statement)
        if "EXA_ALL_TABLES" in statement:
            return FakeResult([] if self.comment is None else [(self.comment,)])
        if statement.startswith("COMMENT ON"):
            self.comment = statement.split(" IS '", 1)[1][:-1].replace("''", "'")
        if "EXA_ALL_COLUMNS" in statement:
            return FakeResult([(nb_dataset._ANSWERED,), *[(f"MY_DATA.T.{c}",) for c in self.frame.columns]])
        return FakeResult([("0",), ("1",)])

    def import_from_pandas(self, frame, target):
        self.frame = frame


@unittest.skipUnless(HAVE_PANDAS, "needs pandas (run with the notebook venv's Python)")
class OwnFileTest(unittest.TestCase):
    ROLES = {"entity": "ID", "category": "CAT", "date": "D", "label": "L", "text": ["MEMO"]}

    def load(self, name, frame, roles=None):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / name
            frame.to_parquet(path) if name.endswith(".parquet") else frame.to_csv(path, index=False)
            conn = _OwnConn()
            exakit_nb.load_own_file(path, "MY_DATA.T", roles or self.ROLES, conn=conn)
            return next(s for s in conn.statements if s.startswith("CREATE OR REPLACE TABLE"))

    def test_a_header_that_is_a_reserved_word_is_quoted(self):
        frame = pandas.DataFrame({"id": [1, 2], "cat": ["a", "b"], "date": ["2024-01-01", "2024-02-01"], "l": [0, 1],
                                  "memo": ["x", "y"], "select": [1, 2], "user": ["u", "v"]})
        ddl = self.load("f.csv", frame, {"entity": "ID", "category": "CAT", "date": "DATE", "label": "L", "text": ["MEMO"]})
        for column in ('"SELECT" DECIMAL(18,0)', '"USER" VARCHAR(1)', '"DATE" DATE'):
            self.assertIn(column, ddl)

    def test_a_text_column_with_no_value_at_all_loads(self):
        try:
            import pyarrow  # noqa: F401
        except ImportError:
            self.skipTest("needs pyarrow")
        frame = pandas.DataFrame({"ID": [1, 2], "CAT": ["a", "b"], "D": ["2024-01-01", "2024-02-01"], "L": [0, 1],
                                  "MEMO": ["x", "y"], "EMPTY": pandas.Series([None, None], dtype=object)})
        self.assertIn('"EMPTY" VARCHAR(1)', self.load("f.parquet", frame))


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
