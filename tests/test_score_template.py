"""udf/templates/ (the scoring UDF template and its renderer) and the ML-4 notebook that uses them (run:
python3 tests/test_score_template.py). No database: the rendered UDF's Python body is run here against a stand-in
context, with stand-in pandas and onnxruntime modules, so what the database would execute is what is checked. Whether a
UDF really reads a file at its /buckets path is tests/model-live-check.sh (EXAKIT_LIVE_TESTS=1)."""

from __future__ import annotations

import ast
import importlib.util
import io
import pickle
import re
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / "udf" / "templates"
NOTEBOOK = ROOT / "notebook" / "notebooks" / "ml-engineer" / "03_score_external_model.py"

_spec = importlib.util.spec_from_file_location("exakit_udf_render", TEMPLATES / "render.py")
render = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(render)

GOOD = dict(schema="scoring", name="score_churn", model_path="/buckets/bfsdefault/default/models/churn.pkl",
            inputs=[("category", "VARCHAR(2000)"), ("doc_text", "varchar(2000000)", "text")],
            output="DOUBLE", method="predict_proba")


def body(sql: str) -> str:
    """The Python the database runs: everything after the CREATE statement's AS line."""
    return sql.split(" AS\n", 1)[1]


class StandInModel:
    """A picklable model: predict_proba answers from the frame, so the test sees which columns reached it."""

    def __init__(self):
        self.frames = []

    def predict_proba(self, frame):
        self.frames.append(frame)
        text = frame.data["text"][0]
        p = min(len(text) / 100.0, 1.0)
        return [[1.0 - p, p]]

    def predict(self, frame):
        self.frames.append(frame)
        return [7]


class StandInFrame:
    def __init__(self, rows, columns):
        self.data = {name: [row[i] for row in rows] for i, name in enumerate(columns)}
        self.columns = list(columns)


def run_udf(sql: str, model_file: Path, rows: list[dict], extra_modules: dict | None = None):
    """Run the rendered UDF body for each row the way the database would: one namespace (one UDF instance), run(ctx)
    per row. Returns (results, namespace)."""
    namespace: dict = {}
    modules = {"pandas": types.SimpleNamespace(DataFrame=StandInFrame)}
    modules.update(extra_modules or {})
    with mock.patch.dict(sys.modules, modules):
        exec(compile(body(sql), "<udf>", "exec"), namespace)
        namespace["MODEL_PATH"] = str(model_file)
        results = [namespace["run"](types.SimpleNamespace(**row)) for row in rows]
    return results, namespace


class RenderTest(unittest.TestCase):
    def test_a_filled_template_is_one_create_statement(self):
        sql = render.render(**GOOD)
        first = sql.splitlines()[0]
        self.assertEqual(first, "CREATE OR REPLACE PYTHON3 SCALAR SCRIPT SCORING.SCORE_CHURN"
                                "(category VARCHAR(2000), doc_text VARCHAR(2000000))")
        self.assertEqual(sql.splitlines()[1], "RETURNS DOUBLE AS")
        self.assertNotIn("{{", sql)
        self.assertFalse(sql.lstrip().startswith("--"), "the template's comment header is not part of the statement")
        self.assertNotIn("\n/\n", sql, "a driver sends the statement without the SQL client's '/'")
        compile(body(sql), "<udf>", "exec")
        self.assertIn("MODEL_PATH = '/buckets/bfsdefault/default/models/churn.pkl'", sql)
        self.assertIn("INPUTS = [('category', 'category'), ('doc_text', 'text')]", sql)

    def test_every_placeholder_is_refused_when_unfilled(self):
        for key, needle in (("schema", "SCHEMA"), ("name", "SCRIPT_NAME"), ("model_path", "MODEL_PATH"),
                            ("inputs", "INPUT_COLUMNS"), ("output", "OUTPUT_TYPE"), ("language", "LANGUAGE")):
            for empty in (None, ""):
                with self.subTest(placeholder=key, value=empty):
                    with self.assertRaises(render.Refused) as caught:
                        render.render(**{**GOOD, key: empty})
                    self.assertIn(needle, str(caught.exception))
                    self.assertIn("not filled", str(caught.exception))

    def test_values_that_do_not_belong_in_sql_are_refused(self):
        bad = {
            "a reserved word as a parameter": {"inputs": [("text", "VARCHAR(100)")]},
            "a statement as a type": {"output": "DOUBLE; DROP TABLE X"},
            "a word that is not a type": {"output": "DROP TABLE"},
            "a schema with a quote": {"schema": 'S"; DROP'},
            "a path outside /buckets": {"model_path": "/etc/passwd"},
            "a path climbing out": {"model_path": "/buckets/bfsdefault/default/../../etc/x"},
            "a path with a quote": {"model_path": "/buckets/bfsdefault/default/a'b.pkl"},
            "an unknown method": {"method": "transform"},
            "a feature with a quote": {"inputs": [("category", "VARCHAR(10)", "x'y")]},
            "a parameter named twice": {"inputs": [("a", "DOUBLE"), ("A", "DOUBLE")]},
            "an input that is not a pair": {"inputs": [("a",)]},
        }
        for label, change in bad.items():
            with self.subTest(label):
                with self.assertRaises(render.Refused):
                    render.render(**{**GOOD, **change})

    def test_a_placeholder_the_renderer_does_not_know_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            text = (TEMPLATES / "score_model.sql").read_text(encoding="utf-8").replace("RETURNS", "{{EXTRA}} RETURNS")
            Path(tmp, "score_model.sql").write_text(text, encoding="utf-8")
            with mock.patch.object(render, "HERE", Path(tmp)):
                with self.assertRaises(render.Refused) as caught:
                    render.render(**GOOD)
        self.assertIn("EXTRA", str(caught.exception))

    def test_the_command_line(self):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = render.main(["--schema", "S", "--name", "N", "--input", "a:DOUBLE"])
        self.assertEqual(code, 2)
        self.assertIn("MODEL_PATH is not filled", err.getvalue())
        out = io.StringIO()
        with redirect_stdout(out):
            code = render.main(["--schema", "S", "--name", "N", "--model-path", "/buckets/b/d/models/m.onnx",
                                "--input", "a:DOUBLE", "--input", "doc_text:VARCHAR(100):text", "--output", "DOUBLE"])
        self.assertEqual(code, 0)
        self.assertTrue(out.getvalue().endswith("\n/\n"), "a SQL client wants the closing '/'")
        out = io.StringIO()
        with redirect_stdout(out):
            render.main(["--placeholders"])
        self.assertEqual(out.getvalue().split(), render.placeholders())
        with redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as caught:
            render.main(["--help"])
        self.assertEqual(caught.exception.code, 0)


class UdfBodyTest(unittest.TestCase):
    def test_a_pickle_is_loaded_once_per_instance_and_scores_every_row(self):
        with tempfile.TemporaryDirectory() as tmp:
            model_file = Path(tmp, "churn.pkl")
            model_file.write_bytes(pickle.dumps(StandInModel()))
            real_load = pickle.load
            with mock.patch("pickle.load", side_effect=real_load) as loads:
                results, namespace = run_udf(render.render(**GOOD), model_file, [
                    {"category": "A", "doc_text": "x" * 10}, {"category": "B", "doc_text": "y" * 50},
                    {"category": "A", "doc_text": ""}])
            self.assertEqual(loads.call_count, 1, "the file is read once per UDF instance, not once per row")
        self.assertEqual(results, [0.1, 0.5, 0.0])
        frame = namespace["_model"].frames[0]
        self.assertEqual(frame.columns, ["category", "text"], "the parameters reach the model under its own names")
        self.assertEqual(frame.data, {"category": ["A"], "text": ["x" * 10]})

    def test_predict_returns_a_plain_value(self):
        with tempfile.TemporaryDirectory() as tmp:
            model_file = Path(tmp, "m.pkl")
            model_file.write_bytes(pickle.dumps(StandInModel()))
            results, _ = run_udf(render.render(**{**GOOD, "method": "predict", "output": "DECIMAL(18,0)"}),
                                 model_file, [{"category": "A", "doc_text": "t"}])
        self.assertEqual(results, [7])

    def test_a_missing_file_names_the_command_that_puts_it(self):
        with self.assertRaises(RuntimeError) as caught:
            run_udf(render.render(**GOOD), Path("/buckets/none/models/x.pkl"), [{"category": "A", "doc_text": "t"}])
        self.assertIn("exakit model put", str(caught.exception))

    def test_unreadable_pickle_names_bucket_path_and_versions(self):
        with tempfile.TemporaryDirectory() as tmp:
            model_file = Path(tmp, "bad.pkl")
            model_file.write_bytes(b"not a pickle")
            Path(str(model_file) + ".provenance.json").write_text('{"scikit-learn":"1.9.0"}')
            with self.assertRaises(RuntimeError) as caught:
                run_udf(render.render(**GOOD), model_file, [{"category": "A", "doc_text": "t"}])
            message = str(caught.exception)
            self.assertIn(str(model_file), message)
            self.assertIn("pickled with scikit-learn 1.9.0", message)
            self.assertIn("container has", message)

    def test_non_estimator_is_named(self):
        with tempfile.TemporaryDirectory() as tmp:
            model_file = Path(tmp, "list.pkl")
            model_file.write_bytes(pickle.dumps([1, 2, 3]))
            with self.assertRaises(RuntimeError) as caught:
                run_udf(render.render(**GOOD), model_file, [{"category": "A", "doc_text": "t"}])
            self.assertIn("not a scikit-learn estimator", str(caught.exception))

    def test_an_onnx_file_is_scored_through_onnxruntime(self):
        seen = {}

        class Input:
            def __init__(self, name, kind):
                self.name, self.type = name, kind

        class Session:
            def __init__(self, path, providers=None):
                seen["opened"] = seen.get("opened", 0) + 1

            def get_inputs(self):
                return [Input("category", "tensor(string)"), Input("text", "tensor(string)")]

            def run(self, outputs, feed):
                seen["feed"] = feed
                return [[1], [{0: 0.25, 1: 0.75}]]

        numpy = types.SimpleNamespace(array=lambda values, dtype=None: values, int64="int64", float64="float64",
                                      float32="float32")
        with tempfile.TemporaryDirectory() as tmp:
            model_file = Path(tmp, "m.onnx")
            model_file.write_bytes(b"onnx")
            results, _ = run_udf(render.render(**{**GOOD, "model_path": "/buckets/b/d/models/m.onnx"}), model_file,
                                 [{"category": "A", "doc_text": "t"}, {"category": "B", "doc_text": "u"}],
                                 extra_modules={"onnxruntime": types.SimpleNamespace(InferenceSession=Session),
                                                "numpy": numpy})
        self.assertEqual(results, [0.75, 0.75])
        self.assertEqual(seen["opened"], 1, "the session is created once per UDF instance")
        self.assertEqual(seen["feed"], {"category": [["B"]], "text": [["u"]]})

    @unittest.skipUnless(importlib.util.find_spec("sklearn") and importlib.util.find_spec("pandas"),
                         "scikit-learn and pandas are not installed here")
    def test_a_real_pipeline_scores_as_it_does_on_the_client(self):
        import pandas as pd
        from sklearn.compose import ColumnTransformer
        from sklearn.feature_extraction.text import TfidfVectorizer
        from sklearn.linear_model import LogisticRegression
        from sklearn.pipeline import Pipeline
        from sklearn.preprocessing import OneHotEncoder

        frame = pd.DataFrame({"category": ["a", "b", "a", "b"] * 5,
                              "text": ["late fee", "fraud card", "fee charged", "card stolen"] * 5})
        model = Pipeline([("features", ColumnTransformer([("text", TfidfVectorizer(), "text"),
                                                          ("category", OneHotEncoder(), ["category"])])),
                          ("classifier", LogisticRegression())]).fit(frame, [0, 1, 0, 1] * 5)
        rows = [{"category": c, "doc_text": t} for c, t in zip(frame["category"][:4], frame["text"][:4])]
        with tempfile.TemporaryDirectory() as tmp:
            model_file = Path(tmp, "m.pkl")
            model_file.write_bytes(pickle.dumps(model))
            namespace: dict = {}
            exec(compile(body(render.render(**GOOD)), "<udf>", "exec"), namespace)
            namespace["MODEL_PATH"] = str(model_file)
            there = [namespace["run"](types.SimpleNamespace(**row)) for row in rows]
        here = list(model.predict_proba(frame[:4])[:, 1])
        self.assertEqual(there, [float(p) for p in here])


class NotebookTest(unittest.TestCase):
    text = NOTEBOOK.read_text(encoding="utf-8")

    def test_it_is_python_in_the_percent_format_with_the_kits_header(self):
        tree = ast.parse(self.text)
        self.assertTrue(self.text.startswith("# ---\n# jupyter:\n#   kernelspec:\n"))
        self.assertIn("name: exasol-starter-kit", self.text)
        cells = re.split(r"^# %%", self.text, flags=re.M)[1:]
        self.assertTrue(cells[0].startswith(" [markdown]"), "the first cell says what the notebook needs")
        self.assertRegex(cells[0], r"(?s)What it needs.*Run time")
        self.assertTrue(any(isinstance(node, ast.Assign) and node.targets[0].id == "DATASET" for node in tree.body))

    def test_it_holds_no_connection_details(self):
        for needle in ("password", "127.0.0.1", "localhost", "8563", "dsn", "user="):
            with self.subTest(needle=needle):
                self.assertNotIn(needle, self.text.lower())

    def test_it_is_driven_by_the_descriptor_not_a_dataset(self):
        code = "\n".join(line for line in self.text.splitlines() if not line.startswith("#"))
        for table in ("PHARMA.", "BANKING.", "PHARMA_TRIALS", "TERMINATED", "MONETARY_RELIEF"):
            self.assertNotIn(table, code)
        self.assertIn("ds.col(", code)
        self.assertIn("ds.text_sql()", code)
        self.assertIn("import exakit.nb as nb", code)
        self.assertNotIn("import exakit_nb", code)       # the alias still imports, but notebooks use the name

    def test_it_names_only_commands_that_exist(self):
        cli = (ROOT / "setup" / "exakit").read_text(encoding="utf-8")
        dispatch = cli.split('case "${1:-help}" in\n')[-1].split("\nesac\n")[0]
        commands = {name for arm in re.findall(r"^    ([a-z0-9|-]+)\)", dispatch, flags=re.M) for name in arm.split("|")}
        module = (ROOT / "setup" / "lib" / "udf-devkit.sh").read_text(encoding="utf-8")
        model_subs = set(re.findall(r"^_cmd_model_([a-z]+)\(\)", module, flags=re.M))
        self.assertEqual(model_subs, {"put", "list", "rm", "prune", "template"})
        named = re.findall(r"`exakit ([a-z][a-z-]*)(?: ([a-z][a-z-]*))?", self.text)
        for node in ast.walk(ast.parse(self.text)):
            if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "exakit":
                words = [arg.value for arg in node.args if isinstance(arg, ast.Constant)]
                named.append((words[0], words[1] if len(words) > 1 else ""))
        self.assertTrue(named)
        self.assertIn(("model", "put"), named)
        for command, sub in named:
            with self.subTest(command=command, sub=sub):
                self.assertIn(command, commands)
                if command == "model":
                    self.assertIn(sub, model_subs)


if __name__ == "__main__":
    unittest.main()
