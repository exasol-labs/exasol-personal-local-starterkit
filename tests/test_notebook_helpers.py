"""(run: python3 tests/test_notebook_helpers.py) The descriptor-driven notebooks and their helpers (DS-1 to DS-4, ML-3):
exakit.nb.dataset() against a fake connection, the exakit.nb / exakit_nb alias, own files (CSV, Parquet, JSON) and
their descriptors (YAML), the quickstarts' shared steps and the ML Engineer's checks, the trace tags and the question
before a live source's rows go to a model, the swap test (AC-DS3.2: the SQL is byte-identical apart from descriptor
values on Pharma, Banking and a synthetic file), and the shipped explore notebook kept in step with its .py."""

from __future__ import annotations

import ast
import contextlib
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook" / "package"))
sys.path.insert(0, str(ROOT / "packages" / "exasol-mlflow"))

import importlib
import importlib.util  # noqa: E402

import exakit_nb  # noqa: E402
from exakit_nb.dataset import Dataset  # noqa: E402

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
        self.assertEqual(ds.tags(), {"exasol.dataset": "pharma_trials", "exasol.descriptor": ds.digest})
        self.assertEqual((ds.status, ds.version, ds.owner, ds.source, ds.source_ref, ds.descriptor_origin),
                         ("approved", 1, "kit", None, "pharma_trials", "shipped"), "shipped: approved by the kit, not a live source")
        self.assertIs(ds.require_approved("training"), ds)

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
            self.assertIn("data-scientist/00_quickstart.ipynb", added)
            self.assertEqual(problems, [])
            base = Path(tmp) / "starter-kit-notebooks"
            self.assertIn("data-scientist/00_quickstart.ipynb", (base / ".kit-copied").read_text(encoding="utf-8").split())
            (base / "data-scientist" / "00_quickstart.ipynb").unlink()
            self.assertEqual(kit_notebooks.copy("jupyter", ROOT, Path(tmp)), ([], []))
            self.assertFalse((base / "data-scientist" / "00_quickstart.ipynb").exists(), "deleted by the user: not copied again")

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
            self.assertIn("data-scientist/00_quickstart.ipynb", added)
            self.assertTrue(problems and all(p.startswith("ml-engineer/") and "is a file" in p for p in problems), problems)
            with redirect_stderr(io.StringIO()) as err:
                self.assertEqual(kit_notebooks.main(["copy", "jupyter", str(ROOT), tmp]), 1)
            self.assertIn("could not copy ml-engineer/01_train.ipynb", err.getvalue())

    def test_the_folder_must_be_named(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(kit_notebooks.main(["copy", "jupyter", str(ROOT)]), 2)

    def test_retired_utility_slots_remove_only_unchanged_copies(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "starter-kit-notebooks"
            old = base / "data-scientist/04_old.ipynb"
            old.parent.mkdir(parents=True)
            old.write_text("the kit copy")
            (base / ".kit-copied").write_text("data-scientist/04_old.ipynb\n")
            doc = kit_notebooks.catalog(ROOT)
            entry = doc["examples"][0]
            entry["previous"]["jupyter"] = {"path": "data-scientist/04_old.ipynb",
                "sha256": hashlib.sha256(old.read_bytes()).hexdigest()}
            with mock.patch.object(kit_notebooks, "catalog", return_value=doc):
                added, problems = kit_notebooks.copy("jupyter", ROOT, Path(tmp))
            self.assertEqual(problems, [])
            self.assertFalse(old.exists())
            self.assertIn(entry["folder"]+"/"+entry["jupyter"], added)
            old.write_text("my edited lesson")
            (base / ".kit-copied").write_text((base / ".kit-copied").read_text()+"data-scientist/04_old.ipynb\n")
            with mock.patch.object(kit_notebooks, "catalog", return_value=doc):
                kit_notebooks.copy("jupyter", ROOT, Path(tmp))
            self.assertEqual(old.read_text(), "my edited lesson")

    def test_retired_copy_inside_a_linked_folder_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            base, outside = Path(tmp) / "starter-kit-notebooks", Path(tmp) / "outside"
            base.mkdir(); outside.mkdir()
            old = outside / "04_old.ipynb"
            old.write_text("the kit copy")
            (base / "data-scientist").symlink_to(outside, target_is_directory=True)
            key = "data-scientist/04_old.ipynb"
            (base / ".kit-copied").write_text(key + "\n")
            doc = kit_notebooks.catalog(ROOT)
            doc["examples"][0]["previous"]["jupyter"] = {"path": key,
                "sha256": hashlib.sha256(old.read_bytes()).hexdigest()}
            with mock.patch.object(kit_notebooks, "catalog", return_value=doc):
                kit_notebooks.copy("jupyter", ROOT, Path(tmp))
            self.assertEqual(old.read_text(), "the kit copy")


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

    def test_personal_release_version_is_normalized_only_during_import(self):
        class PersonalConn(_OwnConn):
            def __init__(self, fail=False):
                super().__init__()
                self.login_info = {"releaseVersion": "2026.2.0-nano.3"}
                self.import_version = None
                self.fail = fail

            def import_from_pandas(self, frame, target):
                self.import_version = self.login_info["releaseVersion"]
                if self.fail:
                    raise RuntimeError("import failed")
                super().import_from_pandas(frame, target)

        conn = PersonalConn()
        frame = pandas.DataFrame({"ID": [1]})
        own_file._load(conn, frame, [("ID", "DECIMAL(18,0)")], "MY_DATA.T", "scratch")
        self.assertEqual(conn.import_version, "2026.2.0")
        self.assertEqual(conn.login_info["releaseVersion"], "2026.2.0-nano.3")
        self.assertEqual(conn.frame["ID"].tolist(), [1])
        failed = PersonalConn(fail=True)
        with self.assertRaisesRegex(RuntimeError, "import failed"):
            own_file._load(failed, frame, [("ID", "DECIMAL(18,0)")], "MY_DATA.T", "scratch")
        self.assertEqual(failed.login_info["releaseVersion"], "2026.2.0-nano.3")

    def load(self, name, frame, roles=None):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / name
            frame.to_parquet(path) if name.endswith(".parquet") else frame.to_csv(path, index=False)
            conn = _OwnConn()
            with redirect_stdout(io.StringIO()):
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
    NOTEBOOK = ROOT / "notebook" / "notebooks" / "data-scientist" / "01_explore.py"

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


rules = importlib.import_module("exakit_nb.descriptor_rules")
own_file = importlib.import_module("exakit_nb.own_file")
quickstart = importlib.import_module("exakit_nb.quickstart")
checks = importlib.import_module("exakit_nb.checks")
NOTEBOOKS = ROOT / "notebook" / "notebooks"
SYNTHETIC = """# A file that resembles neither vertical: sensor readings.
schema_version: 1
id: sensor_readings
fact_table: LAB.READINGS
roles:
  entity:   {table: LAB.READINGS, column: DEVICE}
  category: {table: LAB.READINGS, column: KIND}
  date:     {table: LAB.READINGS, column: TAKEN_ON}
  label:    {table: LAB.READINGS, column: ALARM}
  text:
    - {table: LAB.READINGS, column: NOTE}
    - {table: LAB.READINGS, column: OPERATOR_COMMENT}
"""


def _descriptors():
    """(name, Descriptor) for the two reference datasets and the synthetic file."""
    return [("pharma", rules.read_descriptor(ROOT / "data" / "datasets" / "pharma_trials")),
            ("banking", rules.read_descriptor(ROOT / "data" / "datasets" / "banking_complaints")),
            ("synthetic", rules.parse_descriptor(SYNTHETIC))]


class SwapTest(unittest.TestCase):
    """AC-DS3.2: a notebook's SQL rendered for Pharma, Banking and a synthetic file is byte-identical apart from the
    values the descriptor gives - so switching the data is the one DATASET assignment and no SQL."""

    EXTRA = {"SAMPLE": 20000, "SAMPLE_TEXTS": 5, "period": "MONTH", "UDF_SCHEMA": "EXASOL_MLFLOW", "PARAMS": {"C": 1.0},
             "UDF": "EXAKIT_MODELS.SCORE_MODEL", "where": "1 = 1", "limit": 10, "extra": ""}

    def render(self, notebook: Path, descriptor) -> list[str]:
        """Every SQL f-string of the notebook, evaluated with its own role assignments on ``descriptor``."""
        import exasol_mlflow  # noqa: F401  (packages/exasol-mlflow, on the path below)

        tree = ast.parse(notebook.read_text(encoding="utf-8"))
        ds = Dataset(descriptor.id, Path("descriptor.yaml"), "0" * 64, descriptor)
        namespace = {"ds": ds, "json": json, "exasol_mlflow": sys.modules["exasol_mlflow"], **self.EXTRA}
        for node in tree.body:                                    # the roles cell: ENTITY, ... = ds.col(...), TEXT = ...
            if isinstance(node, ast.Assign) and "ds." in ast.unparse(node.value) and "nb." not in ast.unparse(node.value):
                exec(compile(ast.Module([node], []), "roles", "exec"), namespace)
        sql = [node for node in ast.walk(tree) if isinstance(node, ast.JoinedStr)
               and any("FROM" in str(part.value) for part in node.values if isinstance(part, ast.Constant))]
        self.assertTrue(sql, f"{notebook.name} has no SQL f-string")
        return [eval(compile(ast.Expression(node), "sql", "eval"), namespace) for node in sql]

    @staticmethod
    def placeholders(text: str, descriptor) -> str:
        """The rendered SQL with every value the descriptor gave replaced by its role's name."""
        ds = Dataset(descriptor.id, Path("d"), "0" * 64, descriptor)
        text = text.replace(ds.text_sql(), "<text>").replace(descriptor.fact_table, "<fact_table>")
        for role in ("entity", "category", "date", "label"):
            text = re.sub(rf"\b{re.escape(ds.col(role))}\b", f"<{role}>", text)
        return text

    def test_the_sql_differs_only_in_descriptor_values(self):
        sys.path.insert(0, str(ROOT / "packages" / "exasol-mlflow"))
        for notebook in sorted(NOTEBOOKS.glob("**/0*.py")):
            if notebook.name in ("01_train.py", "02_decision_tree_udf.py"):
                # Its SQL is produced from the handoff by exakit_nb.ml_train; test_ml_train and test_handoff
                # pin that path. It deliberately has no inline SQL f-string to substitute here.
                self.assertIn("nb.prepare_training(conn, ds, handoff", notebook.read_text(encoding="utf-8"))
                continue
            if notebook.name == "01_udf_package_check.py":
                # The package diagnostic's SQL is independent of the reference dataset.
                self.assertIn("ds = nb.dataset(conn, DATASET).require_approved", notebook.read_text())
                self.assertIn("SELECT EXAKIT_EXAMPLES.ML_PACKAGES(1)", notebook.read_text())
                continue
            if notebook.name == "02_rust_score.py":
                # Its SQL is the handoff's training SQL over the deployed Rust UDF: no role is rendered inline.
                self.assertIn('handoff["training_sql"]', notebook.read_text(encoding="utf-8"))
                continue
            if "[include]" in notebook.read_text(encoding="utf-8") and "ds." not in notebook.read_text(encoding="utf-8"):
                continue
            with self.subTest(notebook=notebook.relative_to(NOTEBOOKS).as_posix()):
                rendered = {name: self.render(notebook, d) for name, d in _descriptors()}
                self.assertNotEqual(rendered["pharma"], rendered["banking"], "the values do differ")
                templated = {name: [self.placeholders(s, d) for s in rendered[name]] for name, d in _descriptors()}
                self.assertEqual(templated["pharma"], templated["banking"])
                self.assertEqual(templated["pharma"], templated["synthetic"])

    def test_one_assignment_switches_the_data(self):
        for name in ("data-scientist/01_explore.py", "ml-engineer/01_train.py"):
            with self.subTest(notebook=name):
                lines = (NOTEBOOKS / name).read_text(encoding="utf-8").splitlines()
                self.assertEqual([l.split("#")[0].strip() for l in lines if l.startswith("DATASET = ")], ['DATASET = "pharma_trials"'])
                # train opens the descriptor; explore opens it through the review, so a file with no roles beside it
                # is loaded and drafted right there instead of stopping (T8b)
                opened = "nb.review_roles(conn, DATASET)" if name.startswith("data-scientist") else "nb.dataset(conn, DATASET)"
                self.assertIn(opened, "\n".join(lines))


class AliasTest(unittest.TestCase):
    """exakit.nb is the helpers' name; exakit_nb keeps working - one module under both names."""

    def test_every_spelling_reaches_the_one_module(self):
        import exakit
        import exakit.nb as nb
        from exakit import nb as also

        self.assertIs(nb, exakit_nb)
        self.assertIs(also, exakit_nb)
        self.assertIs(exakit.nb, exakit_nb)
        self.assertIs(exakit.nb.trace, exakit_nb.trace)
        self.assertIs(exakit.nb.load_own_file, exakit_nb.load_own_file)
        self.assertIs(exakit.nb.show_sql, exakit_nb.show_sql)

    def test_the_submodules_are_not_second_copies(self):
        import exakit.nb.dataset  # noqa: F401
        import exakit.nb.own_file  # noqa: F401

        self.assertIs(sys.modules["exakit.nb.own_file"], own_file)
        self.assertIs(sys.modules["exakit.nb.dataset"].Dataset, Dataset)
        self.assertIs(sys.modules["exakit.nb.descriptor_rules"], rules)


class DescriptorFileTest(unittest.TestCase):
    """load_own_file and dataset() read a YAML (or JSON) descriptor file; the roles of a file are kept beside it."""

    def test_a_yaml_descriptor_path_and_a_dataset_folder_read(self):
        doc = own_file._descriptor_doc(ROOT / "data" / "datasets" / "pharma_trials" / "descriptor.yaml", None)
        self.assertEqual(doc["fact_table"], "PHARMA.PHARMA_TRIALS")
        self.assertEqual(own_file._descriptor_doc(ROOT / "data" / "datasets" / "banking_complaints", None)["id"], "banking_complaints")
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "d.json").write_text(json.dumps(doc), encoding="utf-8")
            self.assertEqual(own_file._descriptor_doc(Path(tmp) / "d.json", None), doc)

    def test_roles_need_a_table(self):
        with self.assertRaises(ValueError):
            own_file._descriptor_doc({"entity": "A"}, None)

    def test_saved_roles_read_back_the_same(self):
        """Written as schema_version 2: a draft, version 1, by the user (tests/test_descriptor_v2.py has the rest)."""
        with mock.patch.dict(os.environ, {"EXAKIT_DESCRIPTOR_OWNER": "tester"}):
            doc = own_file._descriptor_doc({"entity": "ID", "category": "CAT", "date": "D", "label": "L", "text": ["MEMO", "BODY"]},
                                           "MY_DATA.T", Path("/data/t.csv"))
        with tempfile.TemporaryDirectory() as tmp:
            path = own_file.save_descriptor(doc, Path(tmp) / "t.descriptor.yaml", "a test")
            text = path.read_text(encoding="utf-8")
            self.assertTrue(text.startswith("# a test\nschema_version: 2\nid: t\nfact_table: MY_DATA.T\nsource: \"file:/data/t.csv\"\n"
                                            "version: 1\nstatus: draft\nowner: tester\ncreated: "), text)
            self.assertIn("\ndrafted_by: user\ndigest: null\nroles:\n", text)
            again = rules.read_descriptor(path)
            self.assertEqual((again.id, again.fact_table, [r.column for r in again.roles["text"]]), ("t", "MY_DATA.T", ["MEMO", "BODY"]))
            self.assertEqual((again.schema_version, again.version, again.status, again.owner, again.drafted_by, again.live_source),
                             (2, 1, "draft", "tester", "user", None))
            self.assertEqual(own_file.descriptor_beside(Path(tmp) / "t.csv"), path)
            self.assertIsNone(own_file.descriptor_beside(Path(tmp) / "other.csv"))

    def test_the_rules_shipped_with_the_helpers_are_the_tools_copy(self):
        self.assertEqual((ROOT / "notebook" / "package" / "exakit_nb" / "descriptor_rules.py").read_bytes(),
                         (ROOT / "tools" / "descriptor_rules.py").read_bytes(), "keep tools/descriptor_rules.py byte-identical")

    def test_a_missing_file_is_skipped_with_one_line_when_asked(self):
        with redirect_stdout(io.StringIO()) as out:
            self.assertIsNone(exakit_nb.load_own_file("/no/such/file.csv", "S.T", {"entity": "A"}, conn=object(), missing_ok=True))
        self.assertIn("skipped", out.getvalue())
        with self.assertRaises(ValueError):
            exakit_nb.load_own_file("/no/such/file.csv", "S.T", {"entity": "A"}, conn=object())

    def test_dataset_names_a_data_file_with_its_roles_beside_it(self):
        """DATASET = "<your file>": the descriptor beside it says the table; a file already loaded is not read again."""
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "readings.csv"
            data.write_text("DEVICE,KIND,TAKEN_ON,ALARM,NOTE,OPERATOR_COMMENT\nd1,a,2024-01-01,0,x,y\n", encoding="utf-8")
            (Path(tmp) / "readings.descriptor.yaml").write_text(SYNTHETIC, encoding="utf-8")
            mark = f"{own_file.MARK}{own_file._digest(data)} file={data.name}"

            class Loaded(FakeConn):
                def execute(self, statement):
                    if "EXA_ALL_TABLES" in statement:
                        self.statements.append(statement)
                        return FakeResult([(mark,)])
                    return super().execute(statement)

            conn = Loaded(["LAB.READINGS." + c for c in ("DEVICE", "KIND", "TAKEN_ON", "ALARM", "NOTE", "OPERATOR_COMMENT")])
            ds = exakit_nb.dataset(conn, str(data))
            self.assertEqual((ds.id, ds.fact_table, ds.col("label")), ("sensor_readings", "LAB.READINGS", "ALARM"))
            self.assertEqual((ds.descriptor_origin, ds.descriptor_path, ds.path), ("beside", Path(tmp) / "readings.descriptor.yaml", data))
            self.assertEqual((ds.version, ds.status, ds.owner), (1, "approved", "kit"), "a schema_version 1 file")
            self.assertFalse([s for s in conn.statements if s.startswith(("CREATE", "COMMENT"))], "nothing reloaded")
            with self.assertRaises(ValueError) as caught:
                exakit_nb.dataset(conn, _undescribed(tmp))
            self.assertIn("no descriptor beside it", str(caught.exception))


def _undescribed(folder: str) -> str:
    """A data file in a folder of its own with no descriptor."""
    path = Path(folder) / "alone" / "x.json"
    path.parent.mkdir()
    path.write_text("[]", encoding="utf-8")
    return str(path)


@unittest.skipUnless(HAVE_PANDAS, "needs pandas (run with the notebook venv's Python)")
class OwnJsonFileTest(unittest.TestCase):
    """A JSON file - an array of records, or one record per line - loads like a CSV; nested values as JSON text."""

    ROLES = {"entity": "ID", "category": "CAT", "date": "D", "label": "L", "text": ["MEMO"]}
    RECORDS = [{"id": 1, "cat": "a", "d": "2024-01-01", "l": True, "memo": "x", "extra": {"k": [1, 2]}},
               {"id": 2, "cat": "b", "d": "2024-02-01", "l": False, "memo": "yy", "extra": None}]

    def load(self, name: str, text: str):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / name
            path.write_text(text, encoding="utf-8")
            conn = _OwnConn()
            with redirect_stdout(io.StringIO()) as out:
                ds = exakit_nb.load_own_file(path, "MY_DATA.T", self.ROLES, conn=conn)
            saved = (Path(tmp) / f"{path.stem}.descriptor.yaml").read_text(encoding="utf-8")
            ddl = next(s for s in conn.statements if s.startswith("CREATE OR REPLACE TABLE"))
            return ds, ddl, conn.frame, saved, out.getvalue()

    def test_an_array_of_records(self):
        ds, ddl, frame, saved, said = self.load("f.json", json.dumps(self.RECORDS))
        self.assertEqual(ds.fact_table, "MY_DATA.T")
        for column in ('"ID" DECIMAL(18,0)', '"D" DATE', '"L" DECIMAL(1,0)', '"MEMO" VARCHAR(2)', '"EXTRA" VARCHAR'):
            self.assertIn(column, ddl)
        self.assertEqual(frame["EXTRA"][0], '{"k": [1, 2]}')
        kept = rules.parse_descriptor(saved)
        self.assertEqual((kept.fact_table, kept.schema_version, kept.status, kept.version, kept.drafted_by), ("MY_DATA.T", 2, "draft", 1, "user"))
        self.assertTrue(kept.source.startswith("file:") and kept.source.endswith("f.json"), kept.source)
        self.assertEqual((ds.status, ds.source, ds.source_ref), ("draft", None, kept.source), "the Dataset is the draft that was written")
        self.assertIn("DATASET = ", said)

    def test_one_record_per_line(self):
        for name in ("f.jsonl", "f.json"):
            with self.subTest(name=name):
                _, ddl, frame, _, _ = self.load(name, "\n".join(json.dumps(r) for r in self.RECORDS) + "\n")
                self.assertEqual(len(frame), 2)
                self.assertIn('"CAT" VARCHAR(1)', ddl)


class _Frame(dict):
    """Enough of a DataFrame for the helpers' printing: columns by name."""


class QuickstartTest(unittest.TestCase):
    """The shared quickstart steps, against a fake connection (nb.sql stubbed: no pandas needed)."""

    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"EXAKIT_NB_DATASETS": str(ROOT / "data" / "datasets")})
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_sql(self, answers):
        """Patch the steps' SQL: each statement answered by the first (needle, frame) whose needle it holds."""
        def answer(conn, statement):
            return next(frame for needle, frame in answers if needle in statement)
        return mock.patch.object(quickstart, "_sql", side_effect=answer)

    def test_a_loaded_sample_is_used_as_it_is(self):
        with mock.patch.object(quickstart, "_run_exakit") as run, redirect_stdout(io.StringIO()) as out:
            ds = exakit_nb.load_sample(FakeConn(PHARMA), "pharma_trials")
        run.assert_not_called()
        self.assertEqual(ds.id, "pharma_trials")
        self.assertIn("is loaded", out.getvalue())

    def test_a_sample_not_loaded_runs_data_load_and_waits(self):
        conn = FakeConn([])
        def loaded(*args):
            conn.columns = PHARMA
            return 0
        with mock.patch.object(quickstart, "_run_exakit", side_effect=loaded) as run, redirect_stdout(io.StringIO()):
            ds = exakit_nb.load_sample(conn, "pharma_trials")
        run.assert_called_once_with("data-load", "pharma_trials")
        self.assertEqual(ds.fact_table, "PHARMA.PHARMA_TRIALS")
        with mock.patch.object(quickstart, "_run_exakit", return_value=1), redirect_stdout(io.StringIO()), \
                self.assertRaises(RuntimeError):
            exakit_nb.load_sample(FakeConn([]), "pharma_trials")

    def test_none_skips_and_an_unknown_id_names_the_ones_there_are(self):
        with redirect_stdout(io.StringIO()) as out:
            self.assertIsNone(exakit_nb.load_sample(None, None))
        self.assertIn("skipped", out.getvalue())
        with self.assertRaises(ValueError) as caught:
            exakit_nb.load_sample(FakeConn(PHARMA), "no_such_set")
        self.assertIn("banking_complaints", str(caught.exception))

    def test_no_connected_source_says_so_and_skips(self):
        with self.run_sql([("EXA_ALL_VIRTUAL_SCHEMAS", _Frame(SCHEMA_NAME=[]))]), redirect_stdout(io.StringIO()) as out:
            self.assertIsNone(exakit_nb.load_source(object(), "~/x.descriptor.yaml"))
        self.assertIn("No external source is connected", out.getvalue())
        with self.run_sql([("EXA_ALL_VIRTUAL_SCHEMAS", _Frame(SCHEMA_NAME=["CRM"]))]), redirect_stdout(io.StringIO()) as out:
            self.assertIsNone(exakit_nb.load_source(object(), None))
        self.assertIn("Connected sources: CRM", out.getvalue())

    def test_a_connected_source_is_named_as_live(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "orders.descriptor.yaml"
            path.write_text(SYNTHETIC.replace("LAB.", "CRM.") + "source: crm_postgres\n", encoding="utf-8")
            conn = FakeConn(["CRM.READINGS." + c for c in ("DEVICE", "KIND", "TAKEN_ON", "ALARM", "NOTE", "OPERATOR_COMMENT")])
            with self.run_sql([("EXA_ALL_VIRTUAL_SCHEMAS", _Frame(SCHEMA_NAME=["CRM"]))]), redirect_stdout(io.StringIO()) as out:
                ds = exakit_nb.load_source(conn, str(path))
        self.assertEqual((ds.source, ds.tags()["exasol.source"]), ("crm_postgres", "crm_postgres"))
        self.assertIn("is a live source (crm_postgres)", out.getvalue())

    def test_the_first_loaded_wins_and_its_roles_print(self):
        ds = exakit_nb.dataset(FakeConn(PHARMA), "pharma_trials")
        self.assertIs(exakit_nb.first(None, None, ds), ds)
        with self.assertRaises(ValueError):
            exakit_nb.first(None, None)
        with redirect_stdout(io.StringIO()) as out:
            exakit_nb.show_roles(ds)
        self.assertIn("label     PHARMA.PHARMA_TRIALS.TERMINATED", out.getvalue())

    def test_the_connection_check_names_no_user_or_host(self):
        frame = _Frame(NOW=["t"], SESSION_ID=["42"], DATABASE_VERSION=["2025.1.8"])
        with self.run_sql([("EXA_METADATA", frame)]) as sql, redirect_stdout(io.StringIO()) as out:
            exakit_nb.check_connection(object())
        self.assertEqual(out.getvalue().strip(), "Connected: Exasol 2025.1.8, session 42.")
        self.assertNotIn("CURRENT_USER", sql.call_args[0][1])


class ChecksTest(unittest.TestCase):
    """The ML Engineer's three checks: one line each, ok or FAIL with the fix, never an exception."""

    class ProbeConn:
        def __init__(self, rows=None, fail=None):
            self.rows, self.fail, self.statements = rows or [], fail, []

        def execute(self, statement):
            self.statements.append(statement)
            if self.fail and "CREATE OR REPLACE" in statement:
                raise RuntimeError(self.fail)
            return FakeResult(self.rows)

    def said(self, call):
        with redirect_stdout(io.StringIO()) as out:
            result = call()
        return result, out.getvalue().strip()

    def test_the_container(self):
        good = [("python", "3.12.3"), ("scikit-learn", "1.7.2"), ("pandas", "2.2.3"), ("numpy", "2.1.0")]
        ok, line = self.said(lambda: exakit_nb.check_container(self.ProbeConn(good), alias="PYTHON3"))
        self.assertTrue(ok)
        self.assertTrue(line.startswith("ok   container:") and "scikit-learn 1.7.2" in line, line)
        self.assertIn("answers on PYTHON3:", line, "the alias probed is named")
        ok, line = self.said(lambda: exakit_nb.check_container(self.ProbeConn([("python", "3.12.3"), ("scikit-learn", "MISSING")]), alias="PYTHON3"))
        self.assertFalse(ok)
        self.assertIn("on PYTHON3 lacks scikit-learn", line)
        self.assertIn("Fix: exakit udf-use default", line)
        self.assertIn('CONTAINER = "PYTHON3_ML"', line, "the notebook must then switch its alias")
        ok, line = self.said(lambda: exakit_nb.check_container(self.ProbeConn(fail="script language PYTHON3 not found"), alias="PYTHON3"))
        self.assertFalse(ok)
        self.assertIn("Fix: exakit udf-setup", line)

    def test_the_container_fix_names_the_alias_it_probed(self):
        """G2 C2: the fix installs the very alias the check probed - udf-use default for PYTHON3_ML, udf-setup for
        PYTHON3 - and the CREATE SCRIPT goes to that alias."""
        conn = self.ProbeConn(fail="script language PYTHON3_ML not found")
        ok, line = self.said(lambda: exakit_nb.check_container(conn, alias="PYTHON3_ML"))
        self.assertFalse(ok)
        self.assertIn("the smoke UDF on PYTHON3_ML did not run", line)
        self.assertIn("Fix: exakit udf-use default installs the pre-built PYTHON3_ML container", line)
        self.assertNotIn("udf-setup", line)
        self.assertTrue(any(s.startswith("CREATE OR REPLACE PYTHON3_ML SCALAR SCRIPT") for s in conn.statements))
        ok, line = self.said(lambda: exakit_nb.check_container(self.ProbeConn(fail="not found"), alias="PYTHON3"))
        self.assertIn("Fix: exakit udf-setup installs the official PYTHON3 container", line)
        self.assertNotIn("udf-use", line)
        ok, line = self.said(lambda: exakit_nb.check_container(self.ProbeConn(fail="not found"), alias="MY_SKLEARN"))
        self.assertIn("on MY_SKLEARN did not run", line)
        self.assertIn("Fix: exakit udf-use <tarball>", line)
        ok, line = self.said(lambda: exakit_nb.check_container(self.ProbeConn([("python", "3.12.3"), ("numpy", "MISSING")]), alias="PYTHON3_ML"))
        self.assertIn("on PYTHON3_ML lacks scikit-learn, pandas, numpy", line)
        self.assertIn("Fix: exakit udf-use default again", line)

    def test_without_an_alias_the_check_resolves_the_notebooks_default(self):
        """alias None: ml_train.udf_container() - the override, else the manifest; none installed is a FAIL line with
        the fix, not an exception (EXAKIT_NB_STRICT raises it, as for every check)."""
        from exakit_nb import ml_train
        good = [("python", "3.12.3"), ("scikit-learn", "1.9.0"), ("pandas", "2.3.3"), ("numpy", "2.4.6")]
        with mock.patch.dict(os.environ, {ml_train.CONTAINER_VARIABLE: "python3_ml"}):
            conn = self.ProbeConn(good)
            ok, line = self.said(lambda: exakit_nb.check_container(conn))
        self.assertTrue(ok)
        self.assertIn("answers on PYTHON3_ML:", line)
        self.assertTrue(conn.statements[1].startswith("CREATE OR REPLACE PYTHON3_ML SCALAR SCRIPT"), conn.statements)
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop(ml_train.CONTAINER_VARIABLE, None)
            with mock.patch.object(ml_train, "_udf_devkit_record", return_value={"languages": "rust"}):
                conn = self.ProbeConn(good)
                ok, line = self.said(lambda: exakit_nb.check_container(conn))
                self.assertFalse(ok)
                self.assertTrue(line.startswith("FAIL container: No Python UDF container for training is installed"), line)
                self.assertIn("Fix: exakit udf-use default installs the pre-built PYTHON3_ML container", line)
                self.assertEqual(conn.statements, [], "nothing probed")
                with mock.patch.dict(os.environ, {"EXAKIT_NB_STRICT": "1"}):
                    with self.assertRaisesRegex(RuntimeError, "Fix: exakit udf-use default"):
                        self.said(lambda: exakit_nb.check_container(self.ProbeConn(good)))
            with mock.patch.object(ml_train, "_udf_devkit_record", return_value={"validated": True}):
                conn = self.ProbeConn(good)
                ok, line = self.said(lambda: exakit_nb.check_container(conn))
                self.assertTrue(ok)
                self.assertIn("answers on PYTHON3:", line, "a pre-matrix record is the official container")

    def test_mlflow(self):
        with tempfile.TemporaryDirectory() as kit_home, mock.patch.dict(sys.modules, {"mlflow": types.ModuleType("mlflow")}):
            with mock.patch.dict(os.environ, {"EXAKIT_HOME": kit_home}, clear=True):
                ok, line = self.said(exakit_nb.check_mlflow)
                self.assertTrue(ok)
                self.assertIn("local store", line)
                with mock.patch.dict(os.environ, {"MLFLOW_TRACKING_URI": "http://me:s3cret@127.0.0.1:9"}):
                    ok, line = self.said(lambda: exakit_nb.check_mlflow(timeout=2))
                self.assertFalse(ok)
                self.assertIn("does not answer", line)
                self.assertIn("Fix:", line)
                self.assertNotIn("s3cret", line)
                self.assertNotIn("me:", line)
        with mock.patch.dict(sys.modules, {"mlflow": None}):
            ok, line = self.said(exakit_nb.check_mlflow)
        self.assertFalse(ok)
        self.assertIn("exakit update notebook", line)

    def test_strict_check_fails_the_headless_run(self):
        with mock.patch.dict(os.environ, {"EXAKIT_NB_STRICT": "1"}):
            with self.assertRaisesRegex(RuntimeError, "Fix: exakit udf-setup"):
                self.said(lambda: exakit_nb.check_container(self.ProbeConn(fail="script language PYTHON3 not found"), alias="PYTHON3"))

    def test_the_bucket_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            doc = {"bucket_dir": tmp, "udf_root": "/buckets/bfsdefault/default", "models": [{"name": "m.pkl"}]}
            with mock.patch.object(checks, "model_list", return_value=doc):
                ok, line = self.said(exakit_nb.check_bucket)
                self.assertTrue(ok)
                self.assertIn("1 model file(s)", line)
                ok, line = self.said(lambda: exakit_nb.check_bucket(self.ProbeConn([("path", "folder")])))
                self.assertTrue(ok)
                self.assertIn("a UDF sees it", line)
                ok, line = self.said(lambda: exakit_nb.check_bucket(self.ProbeConn([("path", "missing")])))
                self.assertFalse(ok)
            with mock.patch.object(checks, "model_list", return_value={**doc, "bucket_dir": str(Path(tmp) / "gone")}):
                ok, line = self.said(exakit_nb.check_bucket)
                self.assertFalse(ok)
                self.assertIn("Fix: exakit start", line)
        with mock.patch.object(checks, "model_list", side_effect=RuntimeError("exakit model list exited 2")):
            ok, line = self.said(exakit_nb.check_bucket)
        self.assertFalse(ok)
        self.assertIn("exakit model list", line)

    def test_model_list_reads_the_json_and_refuses_what_is_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "exakit"
            fake.write_text('#!/bin/sh\necho \'{"bucket_dir": "/b", "udf_root": "/buckets/s/b", "models": []}\'\n', encoding="utf-8")
            fake.chmod(0o755)
            with mock.patch.object(checks, "exakit_command", return_value=[str(fake)]):
                self.assertEqual(checks.model_list()["udf_root"], "/buckets/s/b")
            fake.write_text("#!/bin/sh\necho no >&2\nexit 2\n", encoding="utf-8")
            with mock.patch.object(checks, "exakit_command", return_value=[str(fake)]), self.assertRaises(RuntimeError) as caught:
                checks.model_list()
            self.assertIn("exited 2: no", str(caught.exception))


class TextStepTest(unittest.TestCase):
    """DS-4: what a trace carries, and the question before rows of a live source go to a model."""

    class Conn:
        def session_id(self):
            return 4711

    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"EXAKIT_NB_DATASETS": str(ROOT / "data" / "datasets")})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_the_trace_tags(self):
        ds = exakit_nb.dataset(FakeConn(PHARMA), "pharma_trials")
        tags = exakit_nb.trace_tags(self.Conn(), ds, "SELECT 1 FROM T")
        self.assertEqual(tags, {"exasol.session_id": "4711", "exasol.sql": "SELECT 1 FROM T",
                                "exasol.sql_digest": hashlib.sha256(b"SELECT 1 FROM T").hexdigest(), "exasol.dataset": "pharma_trials",
                                "exasol.descriptor": ds.digest, "exasol.descriptor_id": "pharma_trials", "exasol.descriptor_version": "1"})

    def test_tracing_off_is_one_line_and_the_block_runs(self):
        ran = []
        with mock.patch.dict(os.environ, {}, clear=True), redirect_stdout(io.StringIO()) as out:
            with exakit_nb.trace(self.Conn()) as span:
                ran.append(span)
        self.assertEqual(ran, [None])
        self.assertEqual(len(out.getvalue().strip().splitlines()), 1)

    def test_a_live_source_asks_before_rows_are_sent(self):
        table = exakit_nb.dataset(FakeConn(PHARMA), "pharma_trials")
        self.assertTrue(exakit_nb.confirm_send(table, 5))
        live = Dataset("x", Path("d"), "0" * 64, rules.parse_descriptor(SYNTHETIC + "source: crm\n"))
        with redirect_stdout(io.StringIO()) as out:
            self.assertFalse(exakit_nb.confirm_send(live, 5, answer="n"))
            self.assertTrue(exakit_nb.confirm_send(live, 5, answer="yes"))
            with mock.patch("builtins.input", side_effect=EOFError):
                self.assertFalse(exakit_nb.confirm_send(live, 5))
        self.assertIn("live source (crm)", out.getvalue())



def fake_langfuse(log: list):
    """A stand-in for the Langfuse SDK 5 surface trace() uses - ``Langfuse(public_key=, secret_key=, base_url=)``,
    ``start_as_current_observation``, ``get_current_trace_id``, ``flush``, the module function ``propagate_attributes``
    and the ``langfuse.openai`` drop-in - recording each call. (langfuse, langfuse.openai) for sys.modules."""
    span = types.SimpleNamespace(trace_id="trace-1")

    class Langfuse:
        def __init__(self, **kwargs):
            log.append(("client", kwargs))

        @contextlib.contextmanager
        def start_as_current_observation(self, *, name, as_type="span", **_):
            log.append(("observation", as_type, name))
            yield span
            log.append(("observation-end", name))

        def get_current_trace_id(self):
            return span.trace_id

        def flush(self):
            log.append(("flush",))

    @contextlib.contextmanager
    def propagate_attributes(**kwargs):
        log.append(("propagate", kwargs))
        yield

    module = types.ModuleType("langfuse")
    module.__version__ = "5.0.4"
    module.Langfuse, module.propagate_attributes = Langfuse, propagate_attributes
    drop_in = types.ModuleType("langfuse.openai")
    drop_in.OpenAI = lambda **kwargs: ("langfuse.openai", kwargs)
    module.openai = drop_in
    return module, drop_in


def fake_openai():
    module = types.ModuleType("openai")
    module.OpenAI = lambda **kwargs: ("openai", kwargs)
    return module


class TraceSdk5Test(unittest.TestCase):
    """DS-4 on Langfuse SDK 5: one observation with the trace attributes propagated into it, the SDK 3 variable name
    still accepted, the secret key in no output, the workflow id and descriptor version as tags, metadata within the
    SDK's 200-character rule, and the OpenAI drop-in only when tracing is on."""

    SECRET = "sk-lf-SECRET-9f3a7c"
    ENV = {"LANGFUSE_PUBLIC_KEY": "pk-lf-public", "LANGFUSE_SECRET_KEY": SECRET, "LANGFUSE_BASE_URL": "https://langfuse.example",
           "EXAKIT_NB_DATASETS": str(ROOT / "data" / "datasets")}

    class Conn:
        def session_id(self):
            return 4711

    def setUp(self):
        from exakit_nb import _kit

        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        _kit.SESSION.clear()
        self.addCleanup(_kit.SESSION.clear)
        self.log = []
        self.langfuse, drop_in = fake_langfuse(self.log)
        self.openai = fake_openai()
        patcher = mock.patch.dict(sys.modules, {"langfuse": self.langfuse, "langfuse.openai": drop_in, "openai": self.openai})
        patcher.start()
        self.addCleanup(patcher.stop)

    def _trace(self, env: dict, **kwargs):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {**env, "EXAKIT_HOME": self.home.name}, clear=True), redirect_stdout(out), redirect_stderr(err):
            with exakit_nb.trace(self.Conn(), **kwargs) as span:
                inside = exakit_nb.model_client() if os.environ.get("EXAKIT_NB_MODEL") else None
        return span, inside, out.getvalue() + err.getvalue()

    def test_one_observation_with_the_attributes_propagated_and_the_workflow_logged(self):
        ds = exakit_nb.dataset(FakeConn(PHARMA), "pharma_trials")
        env = {**self.ENV, "EXAKIT_WORKFLOW_ID": "wf-20261027-abcdef"}
        span, _, output = self._trace(env, name="explore-text-step", dataset=ds, sql="SELECT 1 FROM T", step="text")
        self.assertEqual(span.trace_id, "trace-1")
        self.assertEqual(output, "traced: trace-1 (https://langfuse.example, project in your Langfuse)\n")   # the one success line
        self.assertEqual([entry[0] for entry in self.log], ["client", "observation", "propagate", "observation-end", "flush"])
        self.assertEqual(self.log[0][1], {"public_key": "pk-lf-public", "secret_key": self.SECRET, "base_url": "https://langfuse.example"})
        self.assertEqual(self.log[1], ("observation", "span", "explore-text-step"))
        propagated = self.log[2][1]
        self.assertEqual(propagated["trace_name"], "explore-text-step")
        self.assertEqual(propagated["session_id"], "4711")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(propagated["metadata"], exakit_nb.trace_tags(self.Conn(), ds, "SELECT 1 FROM T", step="text"))
        self.assertEqual(propagated["metadata"]["exasol.workflow_id"], "wf-20261027-abcdef")
        self.assertEqual(propagated["metadata"]["exasol.descriptor_version"], "1")
        self.assertEqual(propagated["metadata"]["step"], "text")
        for label in ("exasol-starter-kit", "exasol.dataset=pharma_trials", "exasol.descriptor_id=pharma_trials",
                      "exasol.descriptor_version=1", "exasol.session_id=4711", "exasol.workflow_id=wf-20261027-abcdef",
                      f"exasol.descriptor={ds.digest}"):
            self.assertIn(label, propagated["tags"])
        lines = [json.loads(line) for line in (Path(self.home.name) / "workflows" / "wf-20261027-abcdef.jsonl").read_text().splitlines()]
        self.assertEqual([(line["kind"], line["trace_id"], line["name"]) for line in lines], [("trace", "trace-1", "explore-text-step")])

    def test_no_workflow_no_dataset_means_no_such_tags(self):
        self._trace(self.ENV, sql="SELECT 2")
        propagated = self.log[2][1]
        self.assertEqual(set(propagated["metadata"]), {"exasol.session_id", "exasol.sql", "exasol.sql_digest"})
        self.assertEqual(propagated["tags"], ["exasol-starter-kit", "exasol.session_id=4711"])
        self.assertFalse(list((Path(self.home.name) / "workflows").glob("*")) if (Path(self.home.name) / "workflows").exists() else [])

    def test_langfuse_host_still_counts_as_the_base_url_with_one_line(self):
        env = {k: v for k, v in self.ENV.items() if k != "LANGFUSE_BASE_URL"}
        env["LANGFUSE_HOST"] = "https://old.example"
        with mock.patch.dict(os.environ, env, clear=True):
            self.assertTrue(exakit_nb.tracing())
        _, _, output = self._trace(env)
        self.assertEqual(self.log[0][1]["base_url"], "https://old.example")
        note, traced = output.strip().splitlines()                          # the note, then the success line
        self.assertIn("LANGFUSE_HOST", note)
        self.assertIn("LANGFUSE_BASE_URL", note)
        self.assertNotIn("old.example", note)
        self.assertEqual(traced, "traced: trace-1 (https://old.example, project in your Langfuse)")

    def test_the_secret_key_is_in_no_output_tag_or_log(self):
        ds = exakit_nb.dataset(FakeConn(PHARMA), "pharma_trials")
        env = {**self.ENV, "EXAKIT_WORKFLOW_ID": "wf-20261027-abcdef", "EXAKIT_NB_MODEL": "m", "LANGFUSE_HOST": "https://h"}
        _, _, output = self._trace(env, dataset=ds)
        self.assertNotIn(self.SECRET, output)
        self.assertNotIn(self.SECRET, repr(self.log[1:]))                      # only the client constructor gets it
        self.assertNotIn(self.SECRET, repr(exakit_nb.trace_tags(self.Conn(), ds)))
        for path in (Path(self.home.name) / "workflows").glob("*.jsonl"):
            self.assertNotIn(self.SECRET, path.read_text())
        self.assertNotIn(self.SECRET, repr(self.langfuse.openai.OpenAI(api_key="k")))

    def test_tracing_off_names_the_three_variables_and_uses_the_plain_client(self):
        env = {"LANGFUSE_PUBLIC_KEY": "pk", "LANGFUSE_SECRET_KEY": self.SECRET, "EXAKIT_NB_MODEL": "m"}
        span, inside, output = self._trace(env)
        self.assertIsNone(span)
        self.assertEqual(self.log, [])
        self.assertEqual(output.strip(), "tracing is off (set LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY and LANGFUSE_BASE_URL before "
                                         "exakit notebook); the cell runs as usual.")
        self.assertEqual(inside[0][0], "openai")

    def test_tracing_on_uses_the_langfuse_drop_in(self):
        _, inside, _ = self._trace({**self.ENV, "EXAKIT_NB_MODEL": "m", "OPENAI_API_KEY": "key"})
        self.assertEqual(inside, (("langfuse.openai", {"api_key": "key"}), "m"))

    def test_the_success_line_is_the_trace_url_when_the_sdk_builds_one(self):
        """AC-DS4.5: SDK 5's Langfuse.get_trace_url() gives the trace's page (it asks the server for the project id);
        when it answers, the line carries that URL; when it is None or fails, the id and the base URL."""
        url = "https://langfuse.example/project/p-1/traces/trace-1"
        self.langfuse.Langfuse.get_trace_url = lambda self, *, trace_id=None: f"https://langfuse.example/project/p-1/traces/{trace_id}"
        _, _, output = self._trace(self.ENV)
        self.assertEqual(output, f"traced: trace-1 ({url})\n")
        self.assertEqual([entry[0] for entry in self.log][-2:], ["observation-end", "flush"])    # printed after the flush

        def failing(self, *, trace_id=None):
            raise ConnectionError("no answer")

        self.langfuse.Langfuse.get_trace_url = failing
        _, _, output = self._trace(self.ENV)
        self.assertEqual(output, "traced: trace-1 (https://langfuse.example, project in your Langfuse)\n")
        self.langfuse.Langfuse.get_trace_url = lambda self, *, trace_id=None: None
        _, _, output = self._trace(self.ENV)
        self.assertEqual(output, "traced: trace-1 (https://langfuse.example, project in your Langfuse)\n")

    def test_a_failing_block_prints_no_success_line(self):
        out = io.StringIO()
        with mock.patch.dict(os.environ, {**self.ENV, "EXAKIT_HOME": self.home.name}, clear=True), redirect_stdout(out):
            with self.assertRaises(RuntimeError):
                with exakit_nb.trace(self.Conn()):
                    raise RuntimeError("the cell failed")
        self.assertEqual(out.getvalue(), "")

    def test_long_sql_is_clipped_to_the_propagation_limit_and_digested_whole(self):
        statement = "SELECT " + ", ".join(f'"COL_{i}"' for i in range(60)) + "\nFROM \"S\".\"T\"\nWHERE X = 'y'"
        tags = exakit_nb.trace_tags(self.Conn(), None, statement)
        self.assertTrue(tags["exasol.sql"].endswith("..."))
        self.assertTrue(statement.startswith(tags["exasol.sql"][:-3]))
        self.assertEqual(tags["exasol.sql_digest"], hashlib.sha256(statement.encode()).hexdigest())
        for key, value in tags.items():
            self.assertLessEqual(len(json.dumps(value, ensure_ascii=False, separators=(",", ":"))), 200, key)
        self.assertEqual(exakit_nb.trace_tags(self.Conn(), None, "x" * 198)["exasol.sql"], "x" * 198)     # 200 encoded: kept whole
        self.assertTrue(exakit_nb.trace_tags(self.Conn(), None, "x" * 199)["exasol.sql"].endswith("..."))  # 201 encoded: cut


@unittest.skipUnless(importlib.util.find_spec("langfuse"), "the Langfuse SDK is not installed here")
class RealLangfuseTest(unittest.TestCase):
    """With the SDK installed (the kit's notebook venv, CI): it is major 5 and has the surface trace() relies on."""

    def test_the_installed_sdk_has_the_shape_trace_uses(self):
        import inspect

        import langfuse
        from langfuse import Langfuse, propagate_attributes

        self.assertEqual(int(langfuse.__version__.split(".")[0]), 5, langfuse.__version__)
        self.assertIn("base_url", inspect.signature(Langfuse.__init__).parameters)
        for method in ("start_as_current_observation", "get_current_trace_id", "get_trace_url", "flush"):
            self.assertTrue(callable(getattr(Langfuse, method)), method)
        self.assertEqual({"trace_name", "session_id", "tags", "metadata"} - set(inspect.signature(propagate_attributes).parameters), set())
        self.assertTrue(callable(importlib.import_module("langfuse.openai").OpenAI))


class ProbeTest(unittest.TestCase):
    """The ML Engineer quickstart's container check: its probe UDF must be valid Exasol SQL, and a failure must say why.
    It used VALUE and PATH - both reserved - so CREATE SCRIPT failed, and the check printed an empty reason."""

    def setUp(self):
        from exakit_nb import checks
        self.checks = checks
        self.reserved = {w.strip().upper() for w in (ROOT / "tools" / "exasol_reserved_words.txt").read_text().splitlines() if w.strip()}

    def test_no_reserved_word_names_a_parameter_or_column(self):
        head = self.checks.probe_script("PYTHON3", ("scikit-learn", "pandas")).split(" AS\n")[0]
        names = re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s+VARCHAR", head)
        self.assertEqual(sorted(names), ["DETAIL", "ITEM", "probe_path"])
        self.assertEqual([n for n in names if n.upper() in self.reserved], [])

    def test_the_body_reads_the_parameter_it_declares(self):
        sql = self.checks.probe_script("PYTHON3", ("pandas",))
        self.assertIn("ctx.probe_path", sql)
        self.assertNotIn("ctx.path", sql)

    def test_a_pyexasol_error_is_reported_by_its_message(self):
        class ExaQueryError(Exception):
            message = "syntax error, unexpected VALUE_ [line 1, column 80]"
        err = ExaQueryError("\n(\n    message => syntax error, unexpected VALUE_ [line 1, column 80]\n    dsn => x\n)")
        self.assertEqual(self.checks._reason(err), "syntax error, unexpected VALUE_ [line 1, column 80]")

    def test_a_plain_error_text_that_starts_blank_still_says_something(self):
        self.assertEqual(self.checks._reason(RuntimeError("\n\nconnection lost\nmore")), "connection lost")
        self.assertEqual(self.checks._reason(RuntimeError("")), "RuntimeError")

_spec = importlib.util.spec_from_file_location("exakit_build_tool", ROOT / "tools" / "notebooks.py")
build_tool = importlib.util.module_from_spec(_spec)         # tools/notebooks.py: the .ipynb built from a .py, cell by cell
_spec.loader.exec_module(build_tool)


def _code_cells(py: Path) -> list[str]:
    return ["".join(c["source"]) for c in json.loads(build_tool.build(py))["cells"] if c["cell_type"] == "code"]


class NotebookWorkflowTest(unittest.TestCase):
    """T-new-15 (AC-X1.1): the quickstarts' first cell starts a workflow and prints its id with the exakit workflow
    show line, or continues the one EXAKIT_WORKFLOW_ID names; explore does the same before it opens the data. The
    cells are the built notebooks' own, run with the real workflow helper on a temporary kit home."""

    QUICKSTARTS = {"data-scientist": "data-scientist-quickstart", "ml-engineer": "ml-engineer-quickstart"}

    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        env = mock.patch.dict(os.environ, {"EXAKIT_HOME": self.home.name})
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("EXAKIT_WORKFLOW_ID", None)
        kit = importlib.import_module("exakit_nb._kit")
        kit.SESSION.pop("workflow_id", None)
        self.addCleanup(lambda: (kit.SESSION.pop("workflow_id", None), os.environ.pop("EXAKIT_WORKFLOW_ID", None)))

    def run_cell(self, source: str, namespace: dict | None = None) -> tuple[dict, str]:
        namespace = namespace if namespace is not None else {}
        with redirect_stdout(io.StringIO()) as out:
            exec(compile(source, "cell", "exec"), namespace)
        return namespace, out.getvalue()

    def log(self, workflow_id: str) -> list[dict]:
        path = Path(self.home.name) / "workflows" / f"{workflow_id}.jsonl"
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def test_the_quickstarts_first_cell_starts_a_workflow_and_prints_how_to_show_it(self):
        for persona, name in self.QUICKSTARTS.items():
            with self.subTest(persona=persona):
                os.environ.pop("EXAKIT_WORKFLOW_ID", None)
                importlib.import_module("exakit_nb._kit").SESSION.pop("workflow_id", None)
                first = _code_cells(NOTEBOOKS / persona / "00_quickstart.py")[0]
                self.assertIn(f'nb.workflow("{name}"', first)
                namespace, out = self.run_cell(first)
                wid = namespace["wid"]
                self.assertRegex(wid, r"^wf-\d{8}-[0-9a-f]{6}$")
                self.assertIn(f"exakit workflow show {wid}", out)
                self.assertEqual(os.environ["EXAKIT_WORKFLOW_ID"], wid, "a child process inherits it")
                self.assertEqual([(e["kind"], e.get("name")) for e in self.log(wid)], [("start", name)])

    def test_a_kernel_started_under_a_workflow_continues_it(self):
        first = _code_cells(NOTEBOOKS / "data-scientist" / "00_quickstart.py")[0]
        namespace, _ = self.run_cell(first)
        started = namespace["wid"]
        importlib.import_module("exakit_nb._kit").SESSION.pop("workflow_id", None)       # another kernel, same environment
        os.environ["EXAKIT_WORKFLOW_ID"] = started
        for persona in self.QUICKSTARTS:
            with self.subTest(persona=persona):
                namespace, out = self.run_cell(_code_cells(NOTEBOOKS / persona / "00_quickstart.py")[0])
                self.assertEqual(namespace["wid"], started)
                self.assertIn(f"exakit workflow show {started}", out)
        self.assertEqual([e["kind"] for e in self.log(started)], ["start"], "resuming adds no second start line")

    def test_explore_continues_the_workflow_before_it_opens_the_data(self):
        first = _code_cells(NOTEBOOKS / "data-scientist" / "01_explore.py")[1]        # after DATASET = ...
        self.assertIn('nb.workflow("explore", resume=WORKFLOW_ID or os.environ.get("EXAKIT_WORKFLOW_ID"))', first)
        self.assertLess(first.index("nb.workflow("), first.index("nb.connect()"))
        ds = exakit_nb.dataset(FakeConn(PHARMA), "pharma_trials")
        review = mock.Mock(**{"dataset.return_value": ds})
        with mock.patch.object(exakit_nb, "connect", return_value=FakeConn(PHARMA)), \
                mock.patch.object(exakit_nb, "review_roles", return_value=review) as reviewed:
            namespace, out = self.run_cell(first, {"DATASET": "pharma_trials"})
        self.assertEqual([e["kind"] for e in self.log(namespace["wid"])], ["start"])
        reviewed.assert_called_once_with(mock.ANY, "pharma_trials")
        review.dataset.assert_called_once_with(draft_ok=True)
        self.assertEqual(namespace["LABEL"], "TERMINATED")
        importlib.import_module("exakit_nb._kit").SESSION.pop("workflow_id", None)
        os.environ["EXAKIT_WORKFLOW_ID"] = namespace["wid"]
        with mock.patch.object(exakit_nb, "connect", return_value=FakeConn(PHARMA)), \
                mock.patch.object(exakit_nb, "review_roles", return_value=review):
            again, _ = self.run_cell(first, {"DATASET": "pharma_trials"})
        self.assertEqual(again["wid"], namespace["wid"])


class MissingRoleTest(unittest.TestCase):
    """AC-DS5.3: the quickstart's first query does not guess a role no column fits - without a category it counts
    per entity, without a label it leaves the rate out - and says which steps skip, with the profiler's reason."""

    def descriptor(self, roles: dict, missing: list):
        doc = {"schema_version": 2, "id": "readings", "fact_table": "LAB.READINGS", "version": 1, "status": "draft",
               "owner": "me", "created": "2026-10-27T10:00:00Z",
               "roles": {role: ([{"table": "LAB.READINGS", "column": c} for c in column] if role == "text"
                                else {"table": "LAB.READINGS", "column": column}) for role, column in roles.items()},
               "missing": missing}
        parsed = rules.parse_descriptor(json.dumps(doc))
        return Dataset(parsed.id, Path("d"), "0" * 64, parsed)

    def query_cell(self) -> str:
        cells = ["".join(c["source"]) for c in json.loads(build_tool.build(NOTEBOOKS / "data-scientist" / "00_quickstart.py"))["cells"]]
        return next(c for c in cells if "first_rows = nb.sql(" in c)

    def run_query(self, ds) -> tuple[str, str]:
        statements = []
        fake_nb = types.SimpleNamespace(sql=lambda conn, statement: statements.append(statement) or _Frame(),
                                        show_sql=lambda: None)
        with redirect_stdout(io.StringIO()) as out:
            exec(compile(self.query_cell(), "cell", "exec"), {"nb": fake_nb, "conn": object(), "ds": ds})
        return statements[0], out.getvalue()

    def test_every_role_present_is_the_full_query(self):
        ds = self.descriptor({"entity": "DEVICE", "category": "KIND", "date": "TAKEN_ON", "label": "ALARM", "text": ["NOTE"]}, [])
        sql, out = self.run_query(ds)
        self.assertIn("SELECT KIND AS CATEGORY", sql)
        self.assertIn("ROUND(100 * AVG(ALARM), 1) AS LABEL_1_PCT", sql)
        self.assertEqual(out, "")

    def test_a_missing_label_and_category_do_not_stop_the_query(self):
        ds = self.descriptor({"entity": "DEVICE", "date": "TAKEN_ON", "text": ["NOTE"]},
                             [{"role": "label", "reason": "no 0/1 column"}, {"role": "category", "reason": "no column with 3-50 values"}])
        self.assertFalse(ds.has("label"))
        sql, out = self.run_query(ds)
        self.assertIn("SELECT DEVICE AS CATEGORY", sql)
        self.assertIn("GROUP BY DEVICE", sql)
        self.assertNotIn("AVG", sql)
        self.assertIn("No category role (no column with 3-50 values): rows are counted per entity", out)
        self.assertIn("No label role (no 0/1 column): the label rate is left out", out)


if __name__ == "__main__":
    unittest.main()
