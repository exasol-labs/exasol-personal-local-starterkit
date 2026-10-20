"""(run: python3 tests/test_exasol_mlflow.py) exasol-mlflow (PRD ML-2, ML-3): the UDF result contract, logging against a fake mlflow, the UDF that needs no network,
and train.ipynb kept in step with its .py and free of any dataset's names."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages" / "exasol-mlflow"))

import exasol_mlflow  # noqa: E402
from exasol_mlflow import contract  # noqa: E402

COLUMNS = ["EXASOL_STATEMENT_ID", "PART", "CHUNK", "TRAINING_RESULT"]


def answer(blob: bytes = b"model-bytes", *, parts: int = 1, metrics=None, sha: str | None = None, statement="7"):
    """Rows a well-behaved training UDF returns, split into ``parts`` chunks."""
    text = base64.b64encode(blob).decode()
    size = max(1, -(-len(text) // parts))
    chunks = [text[i:i + size] for i in range(0, len(text), size)]
    doc = {"contract": 1, "metrics": metrics if metrics is not None else {"roc_auc": 0.8},
           "params": {"C": 1.0}, "model": {"format": "sklearn-pickle", "sha256": sha or hashlib.sha256(blob).hexdigest(),
                                           "parts": len(chunks), "python": "3.12.3", "sklearn": "1.7.2"}}
    return [(statement, i, c, json.dumps(doc) if i == 0 else None) for i, c in enumerate(chunks)]


class ContractTest(unittest.TestCase):
    def test_a_good_answer_gives_the_metrics_the_bytes_and_the_statement(self):
        done = contract.check(COLUMNS, answer(b"x" * 5000, parts=3))
        self.assertEqual((done.metrics, done.model_bytes, done.statement_id), ({"roc_auc": 0.8}, b"x" * 5000, "7"))

    def test_every_broken_answer_is_refused_with_its_reason(self):
        good = answer()
        cases = {
            "no TRAINING_RESULT column": (["EXASOL_STATEMENT_ID", "PART", "CHUNK"], [r[:3] for r in good]),
            "no rows": (COLUMNS, []),
            "exactly one row must carry": (COLUMNS, [*good, ("7", 1, "", good[0][3])]),
            "not JSON": (COLUMNS, [("7", 0, good[0][2], "{oops")]),
            "finite numbers": (COLUMNS, answer(metrics={"roc_auc": float("nan")})),
            "parts must be": (COLUMNS, [("7", 1, good[0][2], good[0][3])]),
            "do not match": (COLUMNS, answer(sha="0" * 64)),
            "not base64": (COLUMNS, [("7", 0, "***", good[0][3])]),
            "more than one statement": (COLUMNS, [("8", *r[1:]) if r[1] else r for r in answer(b"y" * 3000, parts=2)]),
        }
        for reason, (columns, rows) in cases.items():
            with self.subTest(reason=reason), self.assertRaises(exasol_mlflow.ResultContractError) as caught:
                contract.check(columns, rows)
            self.assertIn(reason, str(caught.exception))

    def test_a_metric_that_is_a_bool_or_text_is_refused(self):
        for bad in (True, "0.8"):
            with self.subTest(bad=bad), self.assertRaises(exasol_mlflow.ResultContractError):
                contract.check(COLUMNS, answer(metrics={"roc_auc": bad}))


class FakeResult:
    def __init__(self, columns, rows):
        self.columns, self.rows = columns, rows

    def column_names(self):
        return self.columns

    def fetchall(self):
        return self.rows


class FakeConn:
    def __init__(self, rows):
        self.rows, self.statements = rows, []

    def execute(self, sql):
        self.statements.append(sql)
        if "EXA_METADATA" in sql:
            return FakeResult(["PARAM_NAME", "PARAM_VALUE"], [("databaseProductName", "EXASolution"), ("databaseProductVersion", "2026.2.0")])
        return FakeResult(COLUMNS, self.rows)

    def session_id(self):
        return 4242


def fake_mlflow(log: list):
    """A stand-in for the mlflow module that records each call."""
    run = types.SimpleNamespace(info=types.SimpleNamespace(run_id="r1", experiment_id="e1", artifact_uri="file:///a"))

    class Started:
        def __enter__(self):
            return run

        def __exit__(self, *exc):
            return False

    module = types.ModuleType("mlflow")
    module.set_tracking_uri = lambda uri: log.append(("uri", uri))
    module.get_experiment_by_name = lambda name: None
    module.create_experiment = lambda name, artifact_location: log.append(("create", name, artifact_location))
    module.set_experiment = lambda name: log.append(("experiment", name))
    module.start_run = lambda run_name=None: Started()
    module.log_params = lambda p: log.append(("params", p))
    module.log_metrics = lambda m: log.append(("metrics", m))
    module.set_tags = lambda t: log.append(("tags", t))
    module.log_text = lambda text, name: log.append(("text", name, text))
    module.log_artifact = lambda path, artifact_path=None: log.append(("artifact", artifact_path, Path(path).read_bytes()))
    return module


class LogTrainingTest(unittest.TestCase):
    def test_one_run_carries_params_metrics_sql_model_and_lineage(self):
        log: list = []
        conn = FakeConn(answer(b"the-model"))
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(sys.modules, {"mlflow": fake_mlflow(log)}), \
                mock.patch.dict(os.environ, {}, clear=True):
            run = exasol_mlflow.log_training(conn, "SELECT X FROM S.T;", experiment="exp", params={"extra": 1}, tracking_dir=tmp)
            self.assertTrue(run.tracking_uri.startswith("sqlite:///") and run.tracking_uri.endswith("mlflow.db"))
        self.assertIn("CURRENT_STATEMENT AS EXASOL_STATEMENT_ID", conn.statements[0])
        self.assertTrue(conn.statements[0].rstrip().endswith(") T"), "the user's SQL runs inside the wrapper, its ; dropped")
        kinds = {entry[0]: entry[1:] for entry in log}
        self.assertEqual(kinds["params"], ({"C": 1.0, "extra": 1},))
        self.assertEqual(kinds["metrics"], ({"roc_auc": 0.8},))
        self.assertEqual(kinds["text"], ("training.sql", "SELECT X FROM S.T;\n"))
        self.assertEqual(kinds["artifact"], ("model", b"the-model"))
        tags = kinds["tags"][0]
        self.assertEqual((tags["exasol.session_id"], tags["exasol.statement_id"], tags["exasol.deployment"]), ("4242", "7", "exasolution 2026.2.0"))
        self.assertEqual(run.run_id, "r1")

    def test_a_tracking_server_in_the_environment_is_used_as_it_is(self):
        log: list = []
        with mock.patch.dict(sys.modules, {"mlflow": fake_mlflow(log)}), mock.patch.dict(os.environ, {"MLFLOW_TRACKING_URI": "http://mlflow.example:5000"}):
            run = exasol_mlflow.log_training(FakeConn(answer()), "SELECT 1", experiment="exp")
        self.assertEqual(run.tracking_uri, "http://mlflow.example:5000")
        self.assertNotIn("create", [e[0] for e in log])

    def test_a_broken_answer_logs_nothing(self):
        log: list = []
        with mock.patch.dict(sys.modules, {"mlflow": fake_mlflow(log)}), self.assertRaises(exasol_mlflow.ResultContractError):
            exasol_mlflow.log_training(FakeConn(answer(sha="0" * 64)), "SELECT 1", experiment="exp")
        self.assertEqual(log, [])


class UdfTest(unittest.TestCase):
    def test_the_udf_is_a_set_script_with_the_contract_columns_and_no_network(self):
        script = exasol_mlflow.create_script("ml")
        self.assertTrue(script.startswith("CREATE OR REPLACE PYTHON3 SET SCRIPT ML.EXASOL_MLFLOW_TRAIN_TEXT_CLASSIFIER("))
        self.assertIn("EMITS (PART DECIMAL(9,0), CHUNK VARCHAR(2000000), TRAINING_RESULT VARCHAR(2000000))", script)
        for word in ("mlflow", "requests", "urllib", "socket", "http", "password"):
            with self.subTest(word=word):
                self.assertNotIn(word, script.split(" AS", 1)[1].lower())
        compile(script.split(" AS", 1)[1], "udf", "exec")
        with self.assertRaises(ValueError):
            exasol_mlflow.create_script("ml; DROP")


class ShippedTrainTest(unittest.TestCase):
    NOTEBOOK = ROOT / "notebook" / "notebooks" / "train.py"

    def test_one_assignment_picks_the_data_and_no_dataset_is_named_in_the_code(self):
        text = self.NOTEBOOK.read_text(encoding="utf-8")
        self.assertEqual(sum(1 for line in text.splitlines() if line.startswith("DATASET = ")), 1)
        code = "\n".join(line for line in text.splitlines() if not line.startswith(("#", "DATASET = ")))
        for name in ("PHARMA", "BANKING", "TERMINATED", "MONETARY_RELIEF", "BRIEF_SUMMARY"):
            with self.subTest(name=name):
                self.assertNotIn(name, code)
        compile(text, str(self.NOTEBOOK), "exec")
        self.assertTrue(self.NOTEBOOK.with_suffix(".ipynb").exists())


if __name__ == "__main__":
    unittest.main()
