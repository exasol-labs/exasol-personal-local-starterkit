"""Evaluation must not confuse truncation, duplicates, column width or failed queries with a correct answer."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ask_benchmark", ROOT / "tools/ask_benchmark.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class BenchmarkTest(unittest.TestCase):
    def test_full_precision_numbers_and_signed_zero(self):
        left = {"columns":["N"],"rows":[[123456789012345678901234567890]]}
        right = {"columns":["N"],"rows":[[123456789012345678901234567891]]}
        self.assertNotEqual(bench.canonical_result(left), bench.canonical_result(right))
        self.assertEqual(bench.canonical_result({"columns":["N"],"rows":[[0]]}),
                         bench.canonical_result({"columns":["N"],"rows":[[-0.0]]}))

    def test_unordered_rows_and_numeric_representations_compare_equal(self):
        a = {"columns": ["count", "share"], "rows": [[2, 50.0], [1, 25.0]]}
        b = {"columns": ["N", "PCT"], "rows": [[1.0, 25], [2.0, 50]]}
        self.assertEqual(bench.canonical_result(a), bench.canonical_result(b))

    def test_duplicate_count_column_order_width_and_text_types_are_preserved(self):
        result = lambda cols, rows: bench.canonical_result({"columns": cols, "rows": rows})
        self.assertNotEqual(result(["x"], [[1], [1]]), result(["x"], [[1]]))
        self.assertNotEqual(result(["x", "y"], [[1, 2]]), result(["x", "y"], [[2, 1]]))
        self.assertNotEqual(result(["x"], []), result(["x", "y"], []))
        self.assertNotEqual(result(["x"], [["2"]]), result(["x"], [[2]]))

    def test_truncated_or_malformed_results_are_not_matches(self):
        for rows in ([[1]] * 1000, [[1, 2]], [[float("nan")]]):
            with self.subTest(rows=len(rows)), self.assertRaises(ValueError):
                bench.canonical_result({"columns": ["x"], "rows": rows})

    def test_execution_requires_explicit_authorization_before_connection(self):
        with mock.patch.object(sys, "argv", ["bench"]), self.assertRaises(SystemExit) as caught:
            bench.main(["--model", "local", "--output", "/tmp/unused-benchmark.json"])
        self.assertEqual(caught.exception.code, 2)

    def test_reference_errors_cannot_be_reported_as_correct_or_sent_to_model(self):
        execute, draft = mock.Mock(side_effect=RuntimeError("private connection")), mock.Mock()
        item = bench.evaluate_question(object(), "Question", "SELECT 1", execute=execute,
                                       draft=draft, description="Schema only")
        self.assertFalse(item["matched"])
        self.assertEqual(item["error_stage"], "reference")
        self.assertNotIn("private connection", str(item))
        draft.assert_not_called()


if __name__ == "__main__":
    unittest.main()
