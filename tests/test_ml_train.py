"""exakit_nb.ml_train: the training plan from the handoff, on a fake Exasol connection (python3 -m unittest tests.test_ml_train).

What it pins: the plan refuses a draft descriptor, a stale handoff (the line names handoff_from(ds)), a forged view or
training SQL, and a random split the handoff does not mark as asked for (an explicit one trains); the plan is the same
on two builds and the rendered UDF trains to the same metrics and coefficients twice, rows shuffled, when scikit-learn
is installed here (AC-ML3.4; the live twin is tests/lib/live_train_twice.py); the coefficients land beside the handoff
as <id>-v<n>.coefficients.json, 0600, the very content of the MLflow artefact, read from a file store or through
mlflow's artefact download. The container alias (G2 C2): udf_container() takes EXAKIT_UDF_CONTAINER first, else the
manifest's installed aliases PYTHON3_ML before PYTHON3 (udf-setup records the language, not an alias; a pre-matrix
validated record is the official container), and names both fixes when none is installed; the plan creates the UDF on
the alias it is given (or resolves) and records it in the run's params.
"""
from __future__ import annotations

import copy
import contextlib
import importlib.util
import io
import json
import os
import random
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
sys.path.insert(0, str(ROOT / "tests"))

from test_handoff import NO_DATE, SYNTHETIC, FakeConn, FakeResult, HandoffCase, _ds, handoff  # noqa: E402
from exakit_nb import ml_train  # noqa: E402
from exakit_nb.dataset import DescriptorNotApproved  # noqa: E402
from exakit_nb.ml_train import prepare_training, training_handoff  # noqa: E402


class TrainConn(FakeConn):
    def execute(self, statement, params=None):
        if statement.startswith("CREATE "):
            self.statements.append(statement)
            return FakeResult([])
        if statement.startswith('SELECT MIN("'):
            self.statements.append(statement)
            n = len(re.findall(r'MIN\("', statement))
            return FakeResult([tuple(value for i in range(n) for value in (0, 0 if i == 0 else 1))])
        return super().execute(statement, params)


def _plan(conn, ds, record, **options):
    options.setdefault("container", "PYTHON3")                 # the alias given, so no test reads this machine's manifest
    with contextlib.redirect_stdout(io.StringIO()):
        return prepare_training(conn, ds, record, **options)


class ContainerTest(unittest.TestCase):
    """udf_container(): the alias the ML notebooks' CONTAINER assignment defaults to."""

    def setUp(self):
        self.env = mock.patch.dict(os.environ, {}, clear=False)
        self.env.start()
        os.environ.pop(ml_train.CONTAINER_VARIABLE, None)
        self.addCleanup(self.env.stop)

    def test_the_pre_built_container_wins_over_the_official_one(self):
        both = {"languages": "python", "containers": {"PYTHON3_ML": "https://example.invalid/x.tar.gz"}, "validated": True}
        self.assertEqual(ml_train.udf_container(both), "PYTHON3_ML")
        self.assertEqual(ml_train.installed_containers(both), ["PYTHON3_ML", "PYTHON3"])
        official_only = {"languages": "python", "validated": True}
        self.assertEqual(ml_train.udf_container(official_only), "PYTHON3")
        self.assertEqual(ml_train.installed_containers({"languages": "rust,python", "containers": {"RUST": "u"}}), ["RUST", "PYTHON3"])

    def test_a_record_from_before_the_matrix_is_the_official_container(self):
        self.assertEqual(ml_train.udf_container({"version": "0.1.0", "validated": True, "models": {}}), "PYTHON3")
        self.assertEqual(ml_train.installed_containers({"version": "0.1.0", "validated": False}), [])

    def test_the_environment_overrides_the_manifest(self):
        os.environ[ml_train.CONTAINER_VARIABLE] = "my_sklearn"
        self.assertEqual(ml_train.udf_container({"containers": {"PYTHON3_ML": "u"}}), "MY_SKLEARN")
        self.assertEqual(ml_train.udf_container(None), "MY_SKLEARN", "no manifest is read")
        os.environ[ml_train.CONTAINER_VARIABLE] = "no-dash"
        with self.assertRaisesRegex(ValueError, "EXAKIT_UDF_CONTAINER='no-dash' is not a container alias"):
            ml_train.udf_container({"containers": {"PYTHON3_ML": "u"}})

    def test_none_installed_names_both_fixes(self):
        for record in ({}, {"languages": "rust", "containers": {"RUST": "u"}}, {"validated": False}):
            with self.subTest(record=record), self.assertRaises(RuntimeError) as caught:
                ml_train.udf_container(record)
            said = str(caught.exception)
            self.assertIn("No Python UDF container for training is installed", said)
            self.assertIn("Fix: exakit udf-use default installs the pre-built PYTHON3_ML container", said)
            self.assertIn("exakit udf-setup the official PYTHON3", said)
            self.assertIn("exakit marketplace udf-devkit", said)
            self.assertIn("EXAKIT_UDF_CONTAINER", said)
        with self.assertRaisesRegex(RuntimeError, r"records: RUST\)"):
            ml_train.udf_container({"languages": "rust", "containers": {"RUST": "u"}})

    def test_the_manifest_is_read_from_the_kit_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / "kit").mkdir()
            with mock.patch.object(ml_train, "_home", return_value=home):
                self.assertEqual(ml_train.installed_containers(), [], "no manifest yet")
                with self.assertRaises(RuntimeError):
                    ml_train.udf_container()
                (home / "manifest.json").write_text(json.dumps({"components": {"udf_devkit": {
                    "languages": "python", "containers": {"PYTHON3_ML": "https://example.invalid/c.tar.gz"}}}}), encoding="utf-8")
                self.assertEqual(ml_train.udf_container(), "PYTHON3_ML")
                (home / "manifest.json").write_text(json.dumps({"components": {"notebook": {}}}), encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "records: none"):
                    ml_train.udf_container()
            with mock.patch.object(ml_train, "_home", return_value=None):
                self.assertEqual(ml_train.installed_containers(), [])

    def test_the_fix_names_the_command_for_the_alias(self):
        self.assertEqual(ml_train.container_fix("PYTHON3"), "exakit udf-setup installs the official PYTHON3 container (the udf-devkit add-on: exakit marketplace udf-devkit).")
        self.assertEqual(ml_train.container_fix("python3_ml"), "exakit udf-use default installs the pre-built PYTHON3_ML container (the udf-devkit add-on: exakit marketplace udf-devkit).")
        other = ml_train.container_fix("MY_SKLEARN")
        self.assertIn("exakit udf-use <tarball>", other)
        self.assertIn("MY_SKLEARN", other)
        self.assertIn("PYTHON3_ML (exakit udf-use default) and PYTHON3 (exakit udf-setup)", other)

    def test_the_plan_creates_the_udf_on_the_alias_and_records_it(self):
        ds = _ds()
        record = handoff.handoff_from(TrainConn(), ds)
        plan = _plan(TrainConn(), ds, record, container="python3_ml")
        self.assertIn("CREATE OR REPLACE PYTHON3_ML SET SCRIPT EXASOL_MLFLOW.TRAIN_FROM_HANDOFF", plan.create_script)
        self.assertEqual(plan.params["container"], "PYTHON3_ML")
        self.assertIn("ALIAS = 'PYTHON3_ML'", plan.create_script)
        os.environ[ml_train.CONTAINER_VARIABLE] = "PYTHON3_ML"
        with contextlib.redirect_stdout(io.StringIO()):
            resolved = prepare_training(TrainConn(), ds, record)          # container=None: udf_container()
        self.assertEqual(resolved.params["container"], "PYTHON3_ML")
        with self.assertRaisesRegex(ValueError, "container='PY THON' is not a container alias"):
            _plan(TrainConn(), ds, record, container="PY THON")

    def test_none_installed_refuses_the_plan_before_any_write(self):
        ds, conn = _ds(), TrainConn()
        record = handoff.handoff_from(conn, ds)
        before = len(conn.statements)
        with mock.patch.object(ml_train, "_udf_devkit_record", return_value={"languages": "rust"}):
            with self.assertRaisesRegex(RuntimeError, "Fix: exakit udf-use default"), contextlib.redirect_stdout(io.StringIO()):
                prepare_training(conn, ds, record)
        self.assertEqual(len(conn.statements), before, "nothing written")


class TrainPlanTest(HandoffCase):
    def test_approved_handoff_creates_view_and_drops_constant_feature(self):
        ds, conn = _ds(), TrainConn()
        record = handoff.handoff_from(conn, ds)
        first = record["input_schema"][0]["name"]
        plan = _plan(conn, ds, record, seed=13, C=0.5)
        self.assertNotIn(first, plan.features)
        self.assertEqual(list(plan.features), [f["name"] for f in record["input_schema"]][1:], "the handoff's order, kept")
        self.assertIn("CREATE OR REPLACE VIEW", conn.statements[-2])
        self.assertIn("CREATE OR REPLACE PYTHON3 SET SCRIPT EXASOL_MLFLOW.TRAIN_FROM_HANDOFF", plan.create_script)
        self.assertIn('GROUP BY "RUN_KEY"', plan.training_sql)
        self.assertEqual(plan.params["seed"], 13)
        self.assertEqual(plan.params["train_share"], 0.8)

    def test_a_draft_descriptor_is_refused_first(self):
        ds, conn = _ds(SYNTHETIC.replace("status: approved", "status: draft")), TrainConn()
        record = handoff.handoff_from(conn, _ds())
        with self.assertRaises(DescriptorNotApproved) as caught:
            prepare_training(conn, ds, record)
        self.assertIn("training needs an approved descriptor", str(caught.exception))
        self.assertFalse(any(statement.startswith("CREATE ") for statement in conn.statements))

    def test_changed_handoff_sql_is_refused_before_any_write(self):
        ds, conn = _ds(), TrainConn()
        record = handoff.handoff_from(conn, ds)
        forged = copy.deepcopy(record)
        forged["feature_view"]["sql"] += "\nDROP TABLE LAB.READINGS"
        with self.assertRaisesRegex(ValueError, "differs from the descriptor"):
            prepare_training(conn, ds, forged)
        self.assertFalse(any(statement.startswith("CREATE ") for statement in conn.statements))

    def test_stale_version_is_refused_before_any_write_and_names_the_fix(self):
        ds, conn = _ds(), TrainConn()
        record = handoff.handoff_from(conn, ds)
        record["descriptor"]["version"] = 1
        with self.assertRaises(ValueError) as caught:
            prepare_training(conn, ds, record)
        self.assertEqual(str(caught.exception), "descriptor sensor_readings changed since the handoff (v1 → v3): re-run 01_explore "
                                                "or build the handoff: handoff = exakit.nb.handoff_from(ds)")
        self.assertFalse(any(statement.startswith("CREATE ") for statement in conn.statements))
        with self.assertRaisesRegex(ValueError, r"the data of LAB\.READINGS changed since the handoff.*handoff_from\(ds\)"):
            prepare_training(TrainConn(rows=121), ds, handoff.handoff_from(conn, ds))


class TrainingHandoffTest(HandoffCase):
    """Requirements 2.2 step 4: 01_train starts from the handoff explore wrote, or from one built from the approved
    descriptor when there is no file (a fresh machine); a file that exists and is stale still refuses."""

    def test_without_a_file_the_handoff_is_built_from_the_approved_descriptor_and_said_so(self):
        ds = _ds()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            record = training_handoff(TrainConn(), ds)
        self.assertEqual(record["descriptor"]["version"], 3)
        self.assertEqual(record["written_by"], "01_train")
        self.assertEqual(out.getvalue().strip(),
                         "no handoff file for sensor_readings in " + str(self.home / "handoffs") + ": built from the approved "
                         "descriptor v3 (not from 01_explore; run data-scientist/01_explore to write one)")
        self.assertFalse((self.home / "handoffs").exists(), "built, not written")
        self.assertIsNone(handoff.handoff_is_stale(TrainConn(), record, ds))
        with contextlib.redirect_stdout(io.StringIO()):
            plan = _plan(TrainConn(), ds, record)
        self.assertIn("TRAIN_FROM_HANDOFF", plan.create_script)

    def test_a_file_that_exists_is_read_and_a_stale_one_still_refuses(self):
        ds = _ds()
        path = handoff.write_handoff(TrainConn(), ds)
        with contextlib.redirect_stdout(io.StringIO()) as out:
            record = training_handoff(TrainConn(), ds)
        self.assertEqual(record["written_by"], "01_explore")
        self.assertEqual(out.getvalue().strip(), f"handoff: {path}")
        older = _ds(SYNTHETIC.replace("version: 3", "version: 2"))
        handoff.write_handoff(TrainConn(), older)
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(training_handoff(TrainConn(), older, name="sensor_readings-v2")["descriptor"]["version"], 2)
        self.assertTrue(out.getvalue().strip().endswith("sensor_readings-v2.json"))
        with self.assertRaisesRegex(ValueError, r"changed since the handoff \(v2 → v3\).*handoff_from\(ds\)"):
            training_handoff(TrainConn(), ds, name="sensor_readings-v2")
        with self.assertRaisesRegex(ValueError, r"the data of LAB\.READINGS changed since the handoff"):
            training_handoff(TrainConn(rows=121), ds)
        with self.assertRaises(FileNotFoundError):
            training_handoff(TrainConn(), ds, name="sensor_readings-v9")

    def test_a_draft_or_a_missing_date_role_is_refused_the_same_way(self):
        with self.assertRaises(DescriptorNotApproved):
            training_handoff(TrainConn(), _ds(SYNTHETIC.replace("status: approved", "status: draft")))
        with self.assertRaisesRegex(ValueError, "has no date role .* split=\"random\""):
            training_handoff(TrainConn(), _ds(NO_DATE))
        with contextlib.redirect_stdout(io.StringIO()):
            record = training_handoff(TrainConn(), _ds(NO_DATE), split="random")
        self.assertEqual((record["split"]["kind"], record["split"]["explicit"]), ("random", True))


class SplitRuleTest(HandoffCase):
    """Design 7: refuse when no date role unless split.kind = random is explicit in the handoff."""

    def test_a_random_split_the_handoff_does_not_mark_as_asked_for_is_refused(self):
        ds, conn = _ds(NO_DATE), TrainConn()
        record = handoff.handoff_from(conn, ds, split="random")
        for silent in ({"explicit": False}, {"explicit": "true"}, {}):
            with self.subTest(split=silent):
                fallen = copy.deepcopy(record)
                fallen["split"].pop("explicit", None)
                fallen["split"].update(silent)
                with self.assertRaises(ValueError) as caught:
                    prepare_training(conn, ds, fallen)
                self.assertEqual(str(caught.exception),
                                 "the handoff's split is random without having been asked for (split.explicit is not true), "
                                 "and a time split needs a date role: write the handoff with the random split named - "
                                 "nb.write_handoff(conn, ds, split=\"random\") - or add a date role to the descriptor and "
                                 "approve it (exakit describe sensor_readings), then re-run 01_explore.")
        self.assertFalse(any(statement.startswith("CREATE ") for statement in conn.statements))

    def test_an_explicit_random_split_trains(self):
        ds, conn = _ds(NO_DATE), TrainConn()
        record = handoff.handoff_from(conn, ds, split="random")
        plan = _plan(conn, ds, record)
        self.assertIn("HASH_MD5(", plan.training_sql)
        self.assertTrue(any(statement.startswith("CREATE OR REPLACE VIEW") for statement in conn.statements))
        with_date = _ds()
        plan = _plan(TrainConn(), with_date, handoff.handoff_from(TrainConn(), with_date, split="random"))
        self.assertIn("HASH_MD5(", plan.training_sql, "asked for, so a date role does not force the time split")

    def test_an_unknown_split_kind_is_refused(self):
        ds, conn = _ds(), TrainConn()
        record = handoff.handoff_from(conn, ds)
        record["split"]["kind"] = "stratified"
        with self.assertRaisesRegex(ValueError, "split kind 'stratified' is not one of time, random"):
            prepare_training(conn, ds, record)


# --- AC-ML3.4: the same handoff, seed and data give the same model ----------------------------------------------------

class Ctx:
    """The UDF's ctx over rows of (split, label, features...): f0, f1, ... by position; next(); emit()."""

    def __init__(self, rows):
        self.rows, self.index, self.emitted = rows, 0, []

    run_key = "determinism"

    @property
    def split_(self):
        return self.rows[self.index][0]

    @property
    def label(self):
        return self.rows[self.index][1]

    def __getattr__(self, name):
        if name.startswith("f") and name[1:].isdigit():
            return self.rows[self.index][2 + int(name[1:])]
        raise AttributeError(name)

    def next(self):
        self.index += 1
        return self.index < len(self.rows)

    def emit(self, *values):
        self.emitted.append(values)


def _rows(n: int = 240, features: int = 4, seed: int = 11) -> list[tuple]:
    """Whole-number features (what the view computes) with a label that depends on two of them and some noise."""
    rng = random.Random(seed)
    rows = []
    for index in range(n):
        values = [float(rng.randint(0, 30)) for _ in range(features)]
        logit = 0.3 * values[0] - 0.2 * values[1] + rng.gauss(0, 2) - 1.5
        rows.append(("train" if index < n * 0.8 else "test", "1" if logit > 0 else "0", *values))
    return rows


class DeterminismTest(HandoffCase):
    def test_the_plan_is_the_same_on_two_builds(self):
        ds = _ds()
        record = handoff.handoff_from(TrainConn(), ds)
        one, two = _plan(TrainConn(), ds, record, seed=3), _plan(TrainConn(), ds, copy.deepcopy(record), seed=3)
        self.assertEqual(one, two)
        self.assertNotEqual(one.create_script, _plan(TrainConn(), ds, record, seed=4).create_script, "the seed is in the UDF")

    @unittest.skipUnless(importlib.util.find_spec("sklearn"), "scikit-learn is not installed here (the kit's notebook venv has it)")
    def test_the_rendered_udf_trains_to_the_same_metrics_and_coefficients_twice(self):
        """The UDF body runs here twice, in a fresh namespace each time, over the same rows in two different orders:
        the metrics, the coefficients and the pickled model are identical."""
        ds = _ds()
        record = handoff.handoff_from(TrainConn(), ds)
        plan = _plan(TrainConn(), ds, record, seed=7)
        body = plan.create_script.split(" AS\n", 1)[1]
        rows = _rows(features=len(plan.features))
        results = []
        for order in (rows, random.Random(5).sample(rows, len(rows))):
            namespace = {}
            exec(body, namespace)
            ctx = Ctx(order)
            namespace["run"](ctx)
            (_key, _params, metrics, model_b64, _path, sha, _language, _digest, _versions, extras), = ctx.emitted
            results.append((json.loads(metrics), json.loads(extras)["coefficients"], sha, model_b64))
        self.assertEqual(results[0][0], results[1][0], "the metrics are identical")
        self.assertEqual(results[0][1], results[1][1], "the coefficients are identical")
        self.assertEqual(results[0][2], results[1][2], "the pickled model is byte-identical")
        self.assertEqual(results[0][3], results[1][3])
        metrics, coefficients = results[0][0], results[0][1]
        self.assertNotIn("error", metrics)
        self.assertGreater(metrics["macro_f1"], metrics["baseline_macro_f1"], "a learnable label beats the majority baseline")
        self.assertEqual(coefficients["features"], list(plan.features), "the coefficient vector follows the handoff's order")


# --- the coefficients beside the handoff ------------------------------------------------------------------------------

COEFFICIENTS = {"features": ["DATE_MONTH", "CAT_TEMP"], "coef": [[0.25, -1.5]], "intercept": [0.125], "classes": ["0", "1"],
                "positive_class": "1", "formula": "sigmoid(intercept + coef . x)"}


class FakeRun:
    def __init__(self, artifact_uri):
        self.artifact_uri = artifact_uri


class CoefficientsTest(HandoffCase):
    def _run(self, coefficients=COEFFICIENTS):
        store = self.home / "mlflow" / "0" / "abc" / "artifacts"
        store.mkdir(parents=True)
        (store / "coefficients.json").write_text(json.dumps(coefficients), encoding="utf-8")
        return FakeRun(store.as_uri())

    def test_export_writes_the_artefacts_content_beside_the_handoff_0600(self):
        record = handoff.handoff_from(FakeConn(), _ds())
        path = ml_train.export_coefficients(self._run(), record)
        self.assertEqual(path, self.home / "handoffs" / "sensor_readings-v3.coefficients.json")
        self.assertEqual(path, ml_train.coefficients_path(record))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(json.loads(path.read_text(encoding="utf-8")), COEFFICIENTS, "the very content of the MLflow artefact")
        self.assertEqual([p.name for p in path.parent.iterdir()], [path.name], "no temporary file is left")
        text = path.read_text(encoding="utf-8")
        for needle in ("127.0.0.1", "localhost", "password", "://"):
            self.assertNotIn(needle, text)

    def test_a_rerun_replaces_the_file_whole(self):
        record = handoff.handoff_from(FakeConn(), _ds())
        ml_train.export_coefficients(self._run(), record)
        changed = {**COEFFICIENTS, "coef": [[0.5, -1.0]]}
        path = ml_train.write_coefficients(record, changed)
        self.assertEqual(json.loads(path.read_text(encoding="utf-8")), changed)

    def test_a_remote_store_goes_through_mlflow(self):
        record = handoff.handoff_from(FakeConn(), _ds())
        local = self.home / "downloaded.json"
        local.parent.mkdir(parents=True, exist_ok=True)
        local.write_text(json.dumps(COEFFICIENTS), encoding="utf-8")
        download = mock.Mock(return_value=str(local))
        fake_mlflow = mock.Mock(artifacts=mock.Mock(download_artifacts=download))
        with mock.patch.dict(sys.modules, {"mlflow": fake_mlflow, "mlflow.artifacts": fake_mlflow.artifacts}):
            found = ml_train.coefficients_of(FakeRun("mlflow-artifacts:/1/run/artifacts"))
        self.assertEqual(found, COEFFICIENTS)
        download.assert_called_once_with(artifact_uri="mlflow-artifacts:/1/run/artifacts/coefficients.json")
        self.assertEqual(ml_train.write_coefficients(record, found).name, "sensor_readings-v3.coefficients.json")

    def test_what_is_not_a_coefficient_record_is_refused(self):
        record = handoff.handoff_from(FakeConn(), _ds())
        with self.assertRaisesRegex(ValueError, "features, coef, intercept, classes"):
            ml_train.write_coefficients(record, {"coef": []})
        with self.assertRaisesRegex(ValueError, "one weight per feature"):
            ml_train.write_coefficients(record, {**COEFFICIENTS, "coef": [[1.0]]})
        with self.assertRaises(FileNotFoundError):
            ml_train.coefficients_of(FakeRun((self.home / "empty").as_uri()))
        with self.assertRaisesRegex(ValueError, "run.execute"):
            ml_train.coefficients_of(FakeRun(""))
        with self.assertRaisesRegex(ValueError, "names no descriptor"):
            ml_train.coefficients_path({"descriptor": {"id": "Bad Id", "version": 1}})
        self.assertFalse((self.home / "handoffs").exists())


if __name__ == "__main__":
    unittest.main()
