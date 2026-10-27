"""Handoff-driven training plan on a fake Exasol connection (python3 tests/test_ml_train.py)."""
from __future__ import annotations

import copy
import contextlib
import io
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
sys.path.insert(0, str(ROOT / "tests"))

from test_handoff import FakeConn, FakeResult, _ds, handoff  # noqa: E402
from exakit_nb.ml_train import prepare_training  # noqa: E402


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


class TrainPlanTest(unittest.TestCase):
    def test_approved_handoff_creates_view_and_drops_constant_feature(self):
        ds, conn = _ds(), TrainConn()
        record = handoff.handoff_from(conn, ds)
        first = record["input_schema"][0]["name"]
        with contextlib.redirect_stdout(io.StringIO()):
            plan = prepare_training(conn, ds, record, seed=13, C=0.5)
        self.assertNotIn(first, plan.features)
        self.assertIn("CREATE OR REPLACE VIEW", conn.statements[-2])
        self.assertIn("CREATE OR REPLACE PYTHON3 SET SCRIPT EXASOL_MLFLOW.TRAIN_FROM_HANDOFF", plan.create_script)
        self.assertIn('GROUP BY "RUN_KEY"', plan.training_sql)
        self.assertEqual(plan.params["seed"], 13)
        self.assertEqual(plan.params["train_share"], 0.8)

    def test_changed_handoff_sql_is_refused_before_any_write(self):
        ds, conn = _ds(), TrainConn()
        record = handoff.handoff_from(conn, ds)
        forged = copy.deepcopy(record)
        forged["feature_view"]["sql"] += "\nDROP TABLE LAB.READINGS"
        with self.assertRaisesRegex(ValueError, "differs from the descriptor"):
            prepare_training(conn, ds, forged)
        self.assertFalse(any(statement.startswith("CREATE ") for statement in conn.statements))

    def test_stale_version_is_refused_before_any_write(self):
        ds, conn = _ds(), TrainConn()
        record = handoff.handoff_from(conn, ds)
        record["descriptor"]["version"] = 1
        with self.assertRaisesRegex(ValueError, "changed since the handoff"):
            prepare_training(conn, ds, record)
        self.assertFalse(any(statement.startswith("CREATE ") for statement in conn.statements))


if __name__ == "__main__":
    unittest.main()
