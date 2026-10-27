"""The MLflow contract and failure recovery (python3 tests/test_exasol_mlflow.py)."""
from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
import socket
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages" / "exasol-mlflow"))
import exasol_mlflow  # noqa: E402
from exasol_mlflow import contract, records, tracking  # noqa: E402

COLUMNS = [contract.STATEMENT_COLUMN, *contract.COLUMNS]


def answer(blob=b"model-bytes", *, metrics=None, sha=None, statement="7", key="run-1", model_path=None):
    values = {"RUN_KEY": key, "PARAMS": json.dumps({"C": 1.0}),
              "METRICS": json.dumps(metrics if metrics is not None else {"roc_auc": 0.8}),
              "MODEL_B64": None if model_path else base64.b64encode(blob).decode(),
              "MODEL_PATH": model_path, "MODEL_SHA256": sha or hashlib.sha256(blob).hexdigest(),
              "LANGUAGE": "python", "CONTAINER_DIGEST": "container-123",
              "VERSIONS": json.dumps({"python": "3.12.3", "scikit-learn": "1.9.0"}),
              "EXTRAS": json.dumps({"coefficients": {"features": ["X"], "coef": [[1]], "intercept": [0], "classes": ["0", "1"]}})}
    return [(statement, *(values[name] for name in contract.COLUMNS))]


class ContractTest(unittest.TestCase):
    def test_valid_row(self):
        done, = contract.parse(COLUMNS, answer(b"x" * 5000))
        self.assertEqual((done.metrics, done.model_bytes, done.statement_id, done.run_key),
                         ({"roc_auc": 0.8}, b"x" * 5000, "7", "run-1"))

    def test_invalid_fields_name_the_problem(self):
        row = answer()[0]
        cases = {
            "metrics is not JSON": [(*row[:3], "{oops", *row[4:])],
            "model_sha256 does not match": answer(sha="0" * 64),
            "model_b64 is not base64": [(*row[:4], "***", *row[5:])],
            "run_key": answer(key="../escape"),
            "model_path": answer(model_path="/tmp/model.pkl"),
            "appears twice": [*answer(), *answer()],
            "more than one statement": [*answer(), *answer(statement="8", key="run-2")],
            "inline limit": answer(b"x" * (contract.INLINE_LIMIT + 1)),
        }
        for reason, rows in cases.items():
            with self.subTest(reason=reason), self.assertRaises(contract.ContractError) as caught:
                contract.parse(COLUMNS, rows)
            self.assertIn(reason, str(caught.exception))

    def test_no_model_needs_an_error(self):
        row = list(answer()[0])
        row[COLUMNS.index("MODEL_B64")] = None
        row[COLUMNS.index("MODEL_SHA256")] = None
        with self.assertRaisesRegex(contract.ContractError, "metrics.error"):
            contract.parse(COLUMNS, [tuple(row)])
        row[COLUMNS.index("METRICS")] = json.dumps({"error": "cannot train"})
        self.assertFalse(contract.parse(COLUMNS, [tuple(row)])[0].has_model)


class TrackingTest(unittest.TestCase):
    def test_remote_auth_is_read_only_in_the_client(self):
        with mock.patch.dict(os.environ, {"MLFLOW_TRACKING_USERNAME": "me", "MLFLOW_TRACKING_PASSWORD": "private",
                                           "MLFLOW_TRACKING_TOKEN": "other"}, clear=True):
            headers = tracking._auth_headers()
            self.assertEqual(base64.b64decode(headers["Authorization"].split()[1]), b"me:private")
            self.assertNotIn("other", str(headers))
        with mock.patch.dict(os.environ, {"MLFLOW_TRACKING_TOKEN": "other"}, clear=True):
            self.assertEqual(tracking._auth_headers()["Authorization"], "Bearer other")
        self.assertEqual(tracking.redacted("https://me:private@example.invalid:5000"), "https://example.invalid:5000")


class FakeResult:
    def __init__(self, columns, rows):
        self.columns, self.rows = columns, rows
    def column_names(self):
        return self.columns
    def fetchall(self):
        return self.rows


class FakeConn:
    def __init__(self, rows=None, failure=None):
        self.rows, self.failure, self.statements = rows if rows is not None else answer(), failure, []
    def execute(self, sql):
        self.statements.append(sql)
        if "EXA_METADATA" in sql:
            return FakeResult(["PARAM_NAME", "PARAM_VALUE"], [("databaseProductName", "EXASolution"),
                                                               ("databaseProductVersion", "2026.2.0")])
        if self.failure:
            raise self.failure
        return FakeResult(COLUMNS, self.rows)
    def session_id(self):
        return 4242


def fake_mlflow(log):
    run = types.SimpleNamespace(info=types.SimpleNamespace(run_id="r1", experiment_id="e1", artifact_uri="file:///a"))
    class Started:
        info = run.info
        def __enter__(self):
            log.append(("start",))
            return run
        def __exit__(self, *exc):
            log.append(("end",))
            return False
    m = types.ModuleType("mlflow")
    m.set_tracking_uri = lambda uri: log.append(("uri", uri))
    m.get_experiment_by_name = lambda name: None
    m.create_experiment = lambda name, artifact_location: log.append(("create", name, artifact_location))
    m.set_experiment = lambda name: log.append(("experiment", name))
    m.start_run = lambda run_name=None: Started()
    m.end_run = lambda status="FINISHED": log.append(("end_run", status))
    m.log_params = lambda p: log.append(("params", p))
    m.log_metrics = lambda p: log.append(("metrics", p))
    m.set_tags = lambda p: log.append(("tags", p))
    m.log_text = lambda p, name: log.append(("text", name, p))
    m.log_artifact = lambda path, artifact_path=None: log.append(("artifact", artifact_path, Path(path).read_bytes()))
    m.log_dict = lambda p, name: log.append(("dict", name, p))
    return m


class RunTest(unittest.TestCase):
    def test_run_logs_model_sql_metrics_and_lineage(self):
        log, conn = [], FakeConn()
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(sys.modules, {"mlflow": fake_mlflow(log)}), \
                mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}, clear=True):
            run = exasol_mlflow.log_training(conn, "SELECT X FROM S.T;", experiment="exp", tracking_dir=tmp,
                handoff={"descriptor": {"id": "d", "version": 2}, "data_digest": "abc"})
            self.assertEqual(records.pending(), [])
        self.assertEqual(run.run_id, "r1")
        self.assertTrue(any("CURRENT_STATEMENT AS EXASOL_STATEMENT_ID" in sql for sql in conn.statements))
        self.assertIn(("metrics", {"roc_auc": 0.8}), log)
        self.assertIn(("artifact", "model", b"model-bytes"), log)
        self.assertIn(("text", "training.sql", "SELECT X FROM S.T;\n"), log)
        tags = next(entry[1] for entry in log if entry[0] == "tags")
        self.assertEqual((tags["exasol.descriptor_version"], tags["exasol.data_digest"]), ("2", "abc"))

    def test_grouped_statement_ends_each_run_before_the_next(self):
        log = []
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(sys.modules, {"mlflow": fake_mlflow(log)}), \
                mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}, clear=True):
            with exasol_mlflow.start_run(FakeConn([*answer(), *answer(key="run-2")]), experiment="exp",
                                         tracking_dir=tmp) as run:
                run.execute("SELECT 1")
                self.assertEqual([entry.run_key for entry in run.runs], ["run-1", "run-2"])
        events = [e[0] for e in log if e[0] in ("start", "end")]
        self.assertEqual(events, ["start", "end", "start", "end"])

    def test_large_model_is_read_from_bucket_and_digest_checked(self):
        log = []
        blob = b"x" * (contract.INLINE_LIMIT + 1)
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(sys.modules, {"mlflow": fake_mlflow(log)}), \
                mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}, clear=True), \
                mock.patch.object(exasol_mlflow, "bucket_mapping", return_value=(Path(tmp), "/buckets/bfsdefault/default")):
            model = Path(tmp) / "models" / "large.pkl"
            model.parent.mkdir()
            model.write_bytes(blob)
            path = "/buckets/bfsdefault/default/models/large.pkl"
            row = answer(blob, model_path=path)
            run = exasol_mlflow.log_training(FakeConn(row), "SELECT 1", experiment="exp", tracking_dir=tmp)
            self.assertEqual(run.metrics["roc_auc"], 0.8)
            self.assertIn(("artifact", "model", blob), log)
            model.write_bytes(b"changed")
            with self.assertRaisesRegex(contract.ContractError, "model_sha256"):
                exasol_mlflow.log_training(FakeConn(row), "SELECT 1", experiment="exp", tracking_dir=tmp)

    def test_server_offline_stops_before_sql(self):
        conn = FakeConn()
        with mock.patch.dict(os.environ, {"MLFLOW_TRACKING_URI": "http://unreachable.invalid:5000"}), \
                mock.patch.object(tracking, "urlopen", side_effect=OSError("offline")), \
                self.assertRaises(tracking.TrackingUnavailable):
            with exasol_mlflow.start_run(conn):
                pass
        self.assertEqual(conn.statements, [])

    def test_database_restart_marks_failed_without_spool(self):
        log = []
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(sys.modules, {"mlflow": fake_mlflow(log)}), \
                mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}, clear=True), \
                mock.patch.object(records, "write_spool") as spool, \
                self.assertRaises(exasol_mlflow.DatabaseRestarted):
            exasol_mlflow.log_training(FakeConn(failure=ConnectionError("database closed")), "SELECT 1",
                                       experiment="exp", tracking_dir=tmp)
        spool.assert_not_called()
        self.assertIn(("end_run", "FAILED"), log)

    def test_logging_failure_spools_and_replay_clears_it(self):
        log, broken = [], fake_mlflow([])
        broken.log_metrics = lambda p: (_ for _ in ()).throw(OSError("server stopped"))
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}, clear=True):
            with mock.patch.dict(sys.modules, {"mlflow": broken}), self.assertRaises(tracking.TrackingUnavailable):
                exasol_mlflow.log_training(FakeConn(), "SELECT 1", experiment="exp", tracking_dir=tmp)
            self.assertEqual(len(records.pending()), 1)
            self.assertTrue(records.pending()[0].name.startswith("run-1-"))
            with mock.patch.dict(sys.modules, {"mlflow": fake_mlflow(log)}):
                self.assertEqual(records.replay(tracking_dir=tmp), ["r1"])
            self.assertEqual(records.pending(), [])

    def test_two_offline_attempts_keep_both_results(self):
        broken = fake_mlflow([])
        broken.log_metrics = lambda p: (_ for _ in ()).throw(OSError("server stopped"))
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp}, clear=True), \
                mock.patch.dict(sys.modules, {"mlflow": broken}):
            for _ in range(2):
                with self.assertRaises(tracking.TrackingUnavailable):
                    exasol_mlflow.log_training(FakeConn(), "SELECT 1", experiment="exp", tracking_dir=tmp)
            self.assertEqual(len(records.pending()), 2)


class UdfTest(unittest.TestCase):
    def test_both_udfs_emit_the_contract_without_network(self):
        script = exasol_mlflow.create_script("ml")
        self.assertIn("EMITS (RUN_KEY VARCHAR(64)", script)
        body = script.split(" AS\n", 1)[1]
        compile(body, "udf", "exec")
        for word in ("requests", "urllib", "socket", "http", "password"):
            self.assertNotIn(word, body.lower())
        template = (ROOT / "udf/templates/train_model.sql").read_text()
        self.assertIn("MODEL_SHA256 VARCHAR(64)", template)
        self.assertNotIn("import mlflow", template)

    def test_train_template_renders_and_validates_handoff_inputs(self):
        path = ROOT / "udf/templates/render.py"
        spec = importlib.util.spec_from_file_location("exakit_udf_render", path)
        renderer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(renderer)
        create = renderer.render_train(schema="STARTER_KIT", name="TRAIN_TEST", features=["YEAR", "MONTH"],
                                       label="IS_POSITIVE", positive="1", seed=11)
        self.assertIn("f0 DOUBLE, f1 DOUBLE", create)
        self.assertNotIn("{{", create)
        compile(create.split(" AS\n", 1)[1], "train-model", "exec")
        sql = renderer.train_sql(schema="STARTER_KIT", name="TRAIN_TEST",
                                 training_sql="SELECT * FROM STARTER_KIT.FEATURES",
                                 run_key="test-v1", label="IS_POSITIVE", features=["YEAR", "MONTH"])
        self.assertIn('GROUP BY "RUN_KEY"', sql)
        self.assertIn('CAST("YEAR" AS DOUBLE)', sql)
        with self.assertRaises(renderer.Refused):
            renderer.train_sql(schema="STARTER_KIT", name="TRAIN_TEST", training_sql="DROP TABLE T",
                               run_key="test-v1", label="IS_POSITIVE", features=["YEAR"])

    @unittest.skipUnless(importlib.util.find_spec("sklearn"), "scikit-learn is not installed here")
    def test_training_udf_emits_a_model_with_outbound_network_disabled(self):
        path = ROOT / "udf/templates/render.py"
        spec = importlib.util.spec_from_file_location("exakit_udf_render", path)
        renderer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(renderer)
        script = renderer.render_train(schema="STARTER_KIT", name="TRAIN_TEST", features=["F0"],
                                       label="LABEL", positive="1")
        namespace = {}
        exec(script.split(" AS\n", 1)[1], namespace)
        rows = [("train", str(i % 2), float(i % 2)) for i in range(20)]
        rows += [("test", str(i % 2), float(i % 2)) for i in range(10)]
        class Ctx:
            def __init__(self):
                self.index = 0
                self.emitted = []
            @property
            def run_key(self):
                return "network-off"
            @property
            def split_(self):
                return rows[self.index][0]
            @property
            def label(self):
                return rows[self.index][1]
            @property
            def f0(self):
                return rows[self.index][2]
            def next(self):
                self.index += 1
                return self.index < len(rows)
            def emit(self, *values):
                self.emitted.append(values)
        ctx = Ctx()
        with mock.patch.object(socket, "socket", side_effect=AssertionError("outbound network from the UDF")):
            namespace["run"](ctx)
        self.assertEqual(len(ctx.emitted), 1)
        result = contract.parse(COLUMNS, [("7", *ctx.emitted[0])])[0]
        self.assertTrue(result.has_model)
        self.assertEqual(result.metrics["rows_train"], 20.0)


@unittest.skipUnless(importlib.util.find_spec("mlflow") and importlib.util.find_spec("sqlalchemy"),
                     "MLflow and SQLite dependencies are not installed here")
class RealMlflowTest(unittest.TestCase):
    def test_local_store_has_metrics_model_and_lineage(self):
        import mlflow
        from mlflow import MlflowClient
        self.assertEqual(int(mlflow.__version__.split(".")[0]), 3)
        env = {k: v for k, v in os.environ.items() if not k.startswith("MLFLOW_")}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {**env, "EXAKIT_HOME": tmp}, clear=True):
            run = exasol_mlflow.log_training(FakeConn(), "SELECT 1", experiment="pins", tracking_dir=tmp)
            client = MlflowClient(tracking_uri=run.tracking_uri)
            logged = client.get_run(run.run_id)
            self.assertEqual(logged.data.metrics["roc_auc"], 0.8)
            self.assertEqual(logged.data.tags["exasol.container_digest"], "container-123")
            paths = [a.path for a in client.list_artifacts(run.run_id, "model")]
            self.assertIn("model/model.pkl", paths)


if __name__ == "__main__":
    unittest.main()
