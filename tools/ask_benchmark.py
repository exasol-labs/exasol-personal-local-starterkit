"""BRD DS6.4: score opted-in text models against shipped reference SQL on the read-only MCP identity.

No model receives reference SQL, result rows or credentials. Execution requires
--approve-proposals; without it the tool refuses before opening a connection.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
from functools import partial
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
sys.path.insert(0, str(ROOT / "tools"))
from dataset_check import example_questions


def canonical_result(result: dict) -> tuple[int, Counter]:
    """Compare complete rows independent of row order/aliases, preserving column position and duplicates."""
    rows = result["rows"]
    if len(rows) >= 1000:
        raise ValueError("The MCP row limit was reached; a truncated result cannot count as a match.")
    width = len(result["columns"])
    if any(len(row) != width for row in rows):
        raise ValueError("The result width does not match its columns.")
    def value(item):
        if isinstance(item, (int, float, Decimal)) and not isinstance(item, bool):
            numeric = Decimal(str(item))
            if not numeric.is_finite():
                raise ValueError("Non-finite result values cannot count as a match.")
            sign, digits, exponent = numeric.as_tuple()
            digits = list(digits)
            if not any(digits):
                return {"number": [0, [0], 0]}
            while digits[-1] == 0:
                digits.pop()
                exponent += 1
            return {"number": [sign, digits, exponent]}
        return item
    return width, Counter(json.dumps([value(v) for v in row], sort_keys=True, default=str,
                                    separators=(",", ":")) for row in rows)


def evaluate_question(dataset, question: str, reference: str, *, execute, draft, description: str) -> dict:
    """Reference and approved candidate both use the same read-only executor; never send the reference to draft."""
    item = {"question": question, "matched": False}
    stage = "reference"
    try:
        print("Reference SQL:\n" + reference, file=sys.stderr)
        expected = execute(reference)
        expected_rows = canonical_result(expected)
        stage = "draft"
        proposal = draft(dataset, question, table_description=description + "\nRequired output columns in order: " + ", ".join(expected["columns"]))
        item["sql"] = proposal.sql
        stage = "execute"
        proposal.approve()
        # Avoid a second draft: the exact approved proposal is what is scored.
        actual = proposal.run()
        actual = {"columns": list(actual.columns), "rows": [list(row) for row in actual.itertuples(index=False, name=None)]}
        item.update(matched=expected_rows == canonical_result(actual), reference_rows=len(expected["rows"]),
                    actual_rows=len(actual["rows"]))
    except Exception as err:
        # Engine/HTTP exception strings can contain connection details. Keep only classification.
        item.update(error_stage=stage, error_type=type(err).__name__)
    return item


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", action="append", required=True, help="exact provider model ID; repeat to compare models")
    parser.add_argument("--dataset", action="append", choices=("pharma_trials", "banking_complaints"),
                        help="reference dataset; repeat (default: both)")
    parser.add_argument("--output", type=Path, required=True, help="JSON scores without credentials or result rows")
    parser.add_argument("--approve-proposals", action="store_true", help="explicitly authorize generated read-only queries for this benchmark")
    parser.add_argument("--timeout", type=float, default=30, help="seconds per model request; no retries (default 30)")
    parser.add_argument("--max-output-tokens", type=int, default=1024, help="maximum generated tokens per proposal (default 1024)")
    args = parser.parse_args(argv)
    if args.timeout <= 0 or args.max_output_tokens <= 0:
        parser.error("timeout and max-output-tokens must be positive")
    args.model = [value.strip() for value in args.model]
    if not all(args.model):
        parser.error("model IDs cannot be blank")
    if not args.approve_proposals:
        parser.error("Use --approve-proposals only when you authorize this automated evaluation's read-only SQL.")
    import importlib
    import os
    import exakit.nb as nb
    ask = importlib.import_module("exakit_nb.ask")
    from exakit_nb import model_config
    report = {"created": datetime.now(timezone.utc).isoformat(), "kind": "live-model-benchmark", "protocol_version": 2,
              "prompt_metadata": "schema and required output column names; never reference SQL or result rows",
              "comparison": "complete unordered rows; column positions and duplicate counts preserved", "models": []}
    report["workflow_id"] = nb.workflow("ask-model-evaluation")
    original_model = os.environ.get(model_config.MODEL_ID)
    conn = nb.connect()
    try:
        for model in args.model:
            os.environ[model_config.MODEL_ID] = model
            model_config.resolve()  # fail before evaluating a misconfigured provider
            scored = {"model_id": model, "datasets": []}
            for name in args.dataset or ["pharma_trials", "banking_complaints"]:
                folder = ROOT / "data/datasets" / name
                ds = nb.dataset(conn, name).require_approved("ask benchmark")
                description = (folder / "01_create_schema.sql").read_text()
                cases = example_questions((folder / "examples.sql").read_text())[:10]
                if len(cases) != 10:
                    raise ValueError(f"{name} needs ten reference questions.")
                results = []
                for question, reference in cases:
                    results.append(evaluate_question(ds, question, reference, execute=ask._execute_mcp,
                                                    draft=partial(nb.ask, request_timeout=args.timeout, max_output_tokens=args.max_output_tokens), description=description))
                entry = {"dataset": name, "descriptor_version": ds.version, "descriptor_digest": ds.digest,
                         "reference_digest": hashlib.sha256((folder / "examples.sql").read_bytes()).hexdigest(),
                         "matched": sum(item["matched"] for item in results), "total": len(results), "questions": results}
                scored["datasets"].append(entry)
                print(f"{model} / {name}: {entry['matched']}/{entry['total']} matched", flush=True)
            scored["matched"] = sum(item["matched"] for item in scored["datasets"])
            scored["total"] = sum(item["total"] for item in scored["datasets"])
            report["models"].append(scored)
        maximum = max(item["matched"] for item in report["models"])
        report["best_scoring_models"] = [m["model_id"] for m in report["models"] if maximum > 0 and m["matched"] == maximum]
        report["valid_evaluation"] = not any(q.get("error_stage") == "reference" for m in report["models"] for d in m["datasets"] for q in d["questions"])
    finally:
        conn.close()
        if original_model is None:
            os.environ.pop(model_config.MODEL_ID, None)
        else:
            os.environ[model_config.MODEL_ID] = original_model
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report.get("valid_evaluation") else 1


if __name__ == "__main__":
    raise SystemExit(main())
