"""(run: python3 tests/test_role_check.py) The AI's second look at a drafted column map (exakit_nb/role_check.py):
the model is shown names, types and the kit's evidence - never a sensitive column - and only an answer that names a
real column, one of the eight roles and a role other than the draft's is kept. The model is a stand-in."""

from __future__ import annotations

import io
import json
import sys
import types
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook" / "package"))

from exakit_nb import model_config, role_check  # noqa: E402


class Review:
    def __init__(self):
        self.draft = types.SimpleNamespace(table="SHOP.ORDERS", doc={"columns": {
            "ORDER_ID": {"role": "key", "confidence": "high"}, "ACCT_NO": {"role": "measure", "confidence": "low"},
            "EMAIL": {"role": "identifier", "confidence": "high", "sensitive": True},
            "STATUS": {"role": "category", "confidence": "high"}}})

    def suggestions(self):
        return {c: e["role"] for c, e in self.draft.doc["columns"].items()}

    def labels(self):
        return {"ORDER_ID": ("DECIMAL(18,0), key (high confidence): 5,000 distinct", ""),
                "ACCT_NO": ("DECIMAL(9,0), measure (low confidence): 400 distinct", "The customer's account."),
                "EMAIL": ("VARCHAR(200), identifier (high confidence): 4,990 distinct", ""),
                "STATUS": ("VARCHAR(20), category (high confidence): 4 distinct", "")}


class RoleCheckTest(unittest.TestCase):
    def test_the_model_is_shown_names_types_and_evidence_never_a_sensitive_column(self):
        shown = role_check.facts(Review())
        self.assertEqual("SHOP.ORDERS", shown["table"])
        self.assertEqual(["ORDER_ID", "ACCT_NO", "STATUS"], [c["column"] for c in shown["columns"]])
        self.assertNotIn("EMAIL", json.dumps(shown))
        self.assertEqual({"column": "ACCT_NO", "drafted_role": "measure", "confidence": "low",
                          "evidence": "DECIMAL(9,0), measure (low confidence): 400 distinct", "note": "The customer's account."},
                         shown["columns"][1])

    def test_only_a_real_column_a_real_role_and_a_change_is_kept(self):
        answer = "Here you go: " + json.dumps({"changes": [
            {"column": "acct_no", "role": "Identifier", "why": "An account   number is a code,\nnot an amount."},
            {"column": "ACCT_NO", "role": "key", "why": "twice"},                 # a column once
            {"column": "STATUS", "role": "category", "why": "same as the draft"},
            {"column": "NOPE", "role": "key", "why": "no such column"},
            {"column": "ORDER_ID", "role": "primary", "why": "not one of the eight"},
            {"column": "EMAIL", "role": "text", "why": "sensitive: never suggested"}, "noise"]})
        self.assertEqual([{"column": "ACCT_NO", "kit_role": "measure", "role": "identifier",
                           "why": "An account number is a code, not an amount."}], role_check.accept(answer, Review()))
        for bad in ("", "no json here", "{not json}", json.dumps({"changes": "none"})):
            self.assertEqual([], role_check.accept(bad, Review()))

    def test_it_asks_the_model_set_up_for_the_kit_and_changes_nothing(self):
        sent = []
        reply = types.SimpleNamespace(choices=[types.SimpleNamespace(message=types.SimpleNamespace(
            content=json.dumps({"changes": [{"column": "ACCT_NO", "role": "identifier", "why": "A code."}]})))])
        client = types.SimpleNamespace(close=lambda: None, chat=types.SimpleNamespace(completions=types.SimpleNamespace(
            create=lambda **kw: sent.append(kw) or reply)))
        config = types.SimpleNamespace(model_id="m1")
        review = Review()
        before = json.dumps(review.draft.doc, sort_keys=True)
        out = io.StringIO()
        with mock.patch.object(model_config, "resolve", return_value=config), \
                mock.patch.object(model_config, "create_client", return_value=client), redirect_stdout(out):
            found = role_check.check_roles(review)
        self.assertEqual([{"column": "ACCT_NO", "kit_role": "measure", "role": "identifier", "why": "A code."}], found)
        self.assertEqual(before, json.dumps(review.draft.doc, sort_keys=True), "a suggestion is not an approval")
        self.assertEqual("m1", sent[0]["model"])
        self.assertNotIn("EMAIL", json.dumps(sent[0]["messages"]))
        self.assertIn("ACCT_NO: measure -> identifier. A code.", out.getvalue())
        self.assertIn("Nothing was changed", out.getvalue())
        with mock.patch.object(model_config, "resolve", return_value=None), self.assertRaisesRegex(ValueError, "No AI model is set up"):
            role_check.check_roles(review)


if __name__ == "__main__":
    unittest.main()
