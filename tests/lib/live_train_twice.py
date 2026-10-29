"""AC-ML3.4, the live half: train twice in the database from the same handoff with the same seed and compare.

    ~/.exasol-starter-kit/notebook-venv/bin/python tests/lib/live_train_twice.py [--dataset pharma_trials] [--seed 0]

Runs ml-engineer/01_train's path twice against the local database - the handoff (explore's file, else one built from
the approved descriptor), prepare_training, the view, the UDF, exasol_mlflow.start_run - and fails unless the two
runs' accuracy, macro-F1, baseline and coefficients are identical and the coefficients written beside the handoff
equal the MLflow artefact's. The unit twin is tests/test_ml_train.py (DeterminismTest).

Not run by CI unless a database is there: without EXAKIT_REQUIRE_DB=1 a missing prerequisite (no kit store, no
connection, no exakit.nb, no container) is a skip (exit 0, says why); with it, a failure (exit 1). A mismatch is
always exit 1 with both runs' numbers. MLflow goes where 01_train's does (MLFLOW_TRACKING_URI, else the kit's
server when it runs, else the local store); the two runs are tagged ``exasol.check=live_train_twice``.
"""
from __future__ import annotations

import argparse
import json
import os
import sys


def skip(reason: str) -> int:
    required = os.environ.get("EXAKIT_REQUIRE_DB", "0") == "1"
    print(f"{'FAIL' if required else 'SKIP'}: {reason}" + ("" if required else " (set EXAKIT_REQUIRE_DB=1 to make this a failure)"))
    return 1 if required else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="train twice from the same handoff and compare (AC-ML3.4)")
    parser.add_argument("--dataset", default="pharma_trials")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--split", default=None, help='"random" for a descriptor without a date role')
    args = parser.parse_args(argv)
    try:
        import exakit.nb as nb
        import exasol_mlflow
    except ImportError as err:
        return skip(f"the notebook packages are not importable here ({err}); use the kit's notebook venv")
    try:
        conn = nb.connect()
    except Exception as err:  # noqa: BLE001 - whatever stops the connection is the reason to skip
        return skip(f"no database connection ({type(err).__name__}); run exakit status")
    ds = nb.dataset(conn, args.dataset).require_approved("training")
    handoff = nb.ml_train.training_handoff(conn, ds, split=args.split)
    plan = nb.prepare_training(conn, ds, handoff, seed=args.seed)
    conn.execute("CREATE SCHEMA IF NOT EXISTS EXASOL_MLFLOW")
    conn.execute(plan.create_script)
    runs = []
    for attempt in (1, 2):
        with exasol_mlflow.start_run(conn, params=plan.params, experiment="exasol-starter-kit",
                                     run_name=f"{ds.id}-v{ds.version}-twice-{attempt}",
                                     tags={**ds.tags(), "exasol.check": "live_train_twice"}, handoff=handoff) as run:
            run.execute(plan.training_sql)
        coefficients = nb.ml_train.coefficients_of(run)
        beside = json.loads(nb.ml_train.export_coefficients(run, handoff).read_text(encoding="utf-8"))
        runs.append({"run_id": run.run_id, "metrics": run.metrics, "coefficients": coefficients, "beside": beside})
        print(f"run {attempt}: {run.run_id} accuracy={run.metrics['accuracy']} macro_f1={run.metrics['macro_f1']} "
              f"baseline={run.metrics['baseline_macro_f1']} beats_baseline={run.metrics.get('beats_baseline')}")
    keys = ("accuracy", "macro_f1", "baseline_macro_f1", "beats_baseline", "rows_train", "rows_test")
    differ = [k for k in keys if runs[0]["metrics"].get(k) != runs[1]["metrics"].get(k)]
    if runs[0]["coefficients"] != runs[1]["coefficients"]:
        differ.append("coefficients")
    if runs[1]["beside"] != runs[1]["coefficients"]:
        differ.append("coefficients beside the handoff != MLflow artefact")
    if differ:
        print("FAIL: the two runs differ in " + ", ".join(differ))
        print(json.dumps({"seed": args.seed, "data_digest": handoff["data_digest"], "runs": runs}, indent=2, default=str))
        return 1
    if runs[0]["metrics"]["macro_f1"] <= runs[0]["metrics"]["baseline_macro_f1"]:
        print("FAIL: macro-F1 does not beat the majority baseline")
        return 1
    print(f"OK: identical metrics and coefficients on two runs (seed {args.seed}, data digest {handoff['data_digest']}); "
          f"macro-F1 {runs[0]['metrics']['macro_f1']} beats baseline {runs[0]['metrics']['baseline_macro_f1']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
