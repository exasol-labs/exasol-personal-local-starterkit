"""Role review and no-descriptor file loading (python3 tests/test_role_picker.py)."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
from exakit_nb.describe import Draft  # noqa: E402
from exakit_nb.own_file import LoadedTable, load_own_file  # noqa: E402
from exakit_nb.role_picker import RoleReview  # noqa: E402


class ReviewTest(unittest.TestCase):
    def draft(self):
        doc = {"id": "example", "fact_table": "S.T", "roles": {
            "entity": {"table": "S.T", "column": "A"}, "category": {"table": "S.T", "column": "B"}},
            "missing": [{"role": "date", "reason": "no dates"}], "evidence": {"entity": {"score": 8}}}
        profile = {"columns": [{"column": name} for name in ("A", "B", "C")]}
        return Draft(doc, profile)

    def test_corrections_approve_without_editing_a_file(self):
        review = RoleReview(self.draft(), object())
        self.assertEqual(review.suggestions(), {"A": "entity", "B": "category", "C": None})
        with self.assertRaisesRegex(RuntimeError, "Approve descriptor"):
            review.dataset()
        with mock.patch.object(Draft, "approve", autospec=True, side_effect=lambda draft, **kw: draft.to_dict()):
            result = review.approve({"A": "entity", "B": None, "C": "text"})
        self.assertEqual(result["roles"]["text"][0]["column"], "C")
        self.assertEqual(result["evidence"]["entity"], {"score": 8})
        self.assertIn("category", [entry["role"] for entry in result["missing"]])
        self.assertIs(review.dataset(), result)

    def test_two_columns_cannot_claim_a_single_role(self):
        with self.assertRaisesRegex(ValueError, "category role has two columns"):
            RoleReview(self.draft(), object()).approve({"A": "category", "B": "category"})

    def test_headless_approval_uses_proposed_roles(self):
        review = RoleReview(self.draft(), object())
        with mock.patch.dict("os.environ", {"EXAKIT_NB_AUTO_APPROVE": "1"}), \
                mock.patch.object(Draft, "approve", autospec=True, side_effect=lambda draft, **kw: draft.to_dict()):
            self.assertIs(review.show(), review)
        self.assertEqual(review.dataset()["roles"]["entity"]["column"], "A")


class FileWithoutRolesTest(unittest.TestCase):
    def test_loads_file_then_returns_table_for_profiler(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "new-data.csv"
            source.write_text("A,B\n1,2\n", encoding="utf-8")
            with mock.patch("exakit_nb.own_file._comment", return_value=None), \
                    mock.patch("exakit_nb.own_file._read", return_value=object()), \
                    mock.patch("exakit_nb.own_file._prepare", return_value=[("A", "DECIMAL(18,0)")]) as prepare, \
                    mock.patch("exakit_nb.own_file._load"):
                loaded = load_own_file(source, "S.T", conn=object())
            self.assertIsInstance(loaded, LoadedTable)
            self.assertEqual((loaded.id, loaded.fact_table), ("s_t", "S.T"))
            self.assertIsNone(prepare.call_args.args[1])

    def test_approval_writes_descriptor_beside_own_file_for_reopen(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "my-data.csv"
            source.write_text("A,B\n1,2\n", encoding="utf-8")
            review = RoleReview(ReviewTest().draft(), object(), source)
            with mock.patch.object(Draft, "approve", autospec=True, return_value=object()), \
                    mock.patch.object(Draft, "save", autospec=True) as save:
                review.approve()
            self.assertEqual(save.call_args.args[1], source.parent / "my-data.descriptor.yaml")


if __name__ == "__main__":
    unittest.main()
