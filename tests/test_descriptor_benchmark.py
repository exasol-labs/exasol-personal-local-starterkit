"""The descriptor's first draft, scored (tools/descriptor_benchmark.py): roles, slots and sensitive marks on the
kit's datasets and on held-out tables the rules were never tuned to, each over its floor - a rule change that drafts
worse fails here, with the columns it got wrong."""

from __future__ import annotations

import contextlib
import io
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import descriptor_benchmark as benchmark  # noqa: E402


class BenchmarkTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        docs = benchmark.drafts()
        cls.tuned, cls.held_out = benchmark.score(docs), benchmark.score(docs, benchmark.HELD_OUT)

    def check(self, result):
        for key, floor in benchmark.FLOORS.items():
            self.assertGreaterEqual(result[key], floor, f"{key}: {benchmark.report(result)}")

    def test_the_kits_datasets_and_the_synthetic_tables(self):
        self.check(self.tuned)
        self.assertEqual((19, 183), (self.tuned["tables"], self.tuned["columns"]))

    def test_the_held_out_tables(self):
        self.check(self.held_out)
        self.assertEqual((5, 54), (self.held_out["tables"], self.held_out["columns"]))

    def test_every_wrong_role_is_marked_low_so_a_reviewer_reads_it_first(self):
        self.assertEqual(1.0, self.tuned["caught"])
        self.assertEqual(1.0, self.held_out["caught"])

    def test_the_command_checks_both_and_keeps_the_held_out_first_score(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(0, benchmark.main(["--check"]))
        self.assertIn("their first run: roles 98.1%", out.getvalue())


if __name__ == "__main__":
    unittest.main()
