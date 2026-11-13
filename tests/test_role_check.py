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
            "STATUS": {"role": "category", "confidence": "high", "note": "The order's state."},
            "PLACED_ON": {"role": "time", "confidence": "high"}, "QTY": {"role": "measure", "confidence": "high"}}})

    def suggestions(self):
        return {c: e["role"] for c, e in self.draft.doc["columns"].items()}

    def slot_suggestions(self):
        return {"key": "ORDER_ID", "time": None, "text": None, "target": None, "category": None, "entity": None}

    def labels(self):
        return {"ORDER_ID": ("DECIMAL(18,0), key (high confidence): 5,000 distinct", ""),
                "ACCT_NO": ("DECIMAL(9,0), measure (low confidence): 400 distinct", "The customer's account."),
                "EMAIL": ("VARCHAR(200), identifier (high confidence): 4,990 distinct", ""),
                "STATUS": ("VARCHAR(20), category (high confidence): 4 distinct", "The order's state."),
                "PLACED_ON": ("DATE, time (high confidence)", ""), "QTY": ("DECIMAL(9,0), measure (high confidence)", "")}


class RoleCheckTest(unittest.TestCase):
    def test_the_model_is_shown_names_types_and_evidence_never_a_sensitive_column(self):
        shown = role_check.facts(Review())
        self.assertEqual("SHOP.ORDERS", shown["table"])
        self.assertEqual(["ORDER_ID", "ACCT_NO", "STATUS", "PLACED_ON", "QTY"], [c["column"] for c in shown["columns"]])
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
        self.assertEqual([], role_check.accept(json.dumps({"roles": [{"column": "ACCT_NO", "role": "key", "why": "unique"}]}), Review()),
                         "different in every row is measured, not read from a name")

    def test_slots_follow_the_kits_rules_and_never_touch_the_key_or_the_target(self):
        review = Review()
        roles = [{"column": "ACCT_NO", "kit_role": "measure", "role": "identifier", "why": ""}]
        answer = json.dumps({"slots": {"category": "status", "entity": "ACCT_NO", "time": "PLACED_ON", "text": "STATUS",
                                       "key": "ACCT_NO", "target": "STATUS"}})
        self.assertEqual({"category": "STATUS", "entity": "ACCT_NO", "time": "PLACED_ON"}, role_check.accept_slots(answer, review, roles),
                         "text needs a column marked text; the key and the target are not the model's")
        self.assertEqual({}, role_check.accept_slots(json.dumps({"slots": {"entity": "ACCT_NO"}}), review, []),
                         "an amount is not who a row is about: only once its role is changed")
        self.assertEqual({}, role_check.accept_slots(json.dumps({"slots": {"category": "ORDER_ID", "entity": "EMAIL", "time": "QTY"}}), review, []),
                         "the key keeps its slot, a sensitive column is never used, the date must be a time")
        for bad in ("", json.dumps({"slots": ["STATUS"]})):
            self.assertEqual({}, role_check.accept_slots(bad, review, []))

    def test_descriptions_fill_what_is_empty_for_columns_the_model_was_shown(self):
        answer = json.dumps({"notes": {"acct_no": "The customer's  account\nnumber.", "STATUS": "overwrites?", "EMAIL": "an address",
                                       "NOPE": "x", "QTY": "x" * 500, "PLACED_ON": ""}})
        notes = role_check.accept_notes(answer, Review())
        self.assertEqual({"ACCT_NO", "QTY"}, set(notes), "a column with a note keeps it; a sensitive or unknown one gets none")
        self.assertEqual("The customer's account number.", notes["ACCT_NO"])
        self.assertEqual(role_check.NOTE_LIMIT, len(notes["QTY"]))

    def test_it_asks_the_model_set_up_for_the_kit_and_changes_nothing(self):
        sent = []
        reply = types.SimpleNamespace(choices=[types.SimpleNamespace(message=types.SimpleNamespace(
            content=json.dumps({"roles": [{"column": "ACCT_NO", "role": "identifier", "why": "A code."}],
                                "slots": {"entity": "ACCT_NO", "time": "PLACED_ON"}, "notes": {"QTY": "How many were ordered."}})))])
        client = types.SimpleNamespace(close=lambda: None, chat=types.SimpleNamespace(completions=types.SimpleNamespace(
            create=lambda **kw: sent.append(kw) or reply)))
        config = types.SimpleNamespace(model_id="m1")
        review = Review()
        before = json.dumps(review.draft.doc, sort_keys=True)
        out = io.StringIO()
        with mock.patch.object(model_config, "resolve", return_value=config), \
                mock.patch.object(model_config, "create_client", return_value=client), redirect_stdout(out):
            found = role_check.fill_column_map(review)
            only_roles = role_check.check_roles(review, show=False)
        self.assertEqual({"roles": [{"column": "ACCT_NO", "kit_role": "measure", "role": "identifier", "why": "A code."}],
                          "slots": {"entity": "ACCT_NO", "time": "PLACED_ON"}, "notes": {"QTY": "How many were ordered."},
                          "same_as": []}, found)
        self.assertNotIn("other_tables", json.loads(sent[0]["messages"][1]["content"]), "one table: nothing beside it")
        self.assertEqual(found["roles"], only_roles)
        self.assertEqual(before, json.dumps(review.draft.doc, sort_keys=True), "a suggestion is not an approval")
        self.assertEqual("m1", sent[0]["model"])
        self.assertNotIn("EMAIL", json.dumps(sent[0]["messages"]))
        self.assertIn("ACCT_NO: measure -> identifier. A code.", out.getvalue())
        self.assertIn("Nothing was changed", out.getvalue())
        self.assertIn("slot entity: ACCT_NO", out.getvalue())
        self.assertIn("1 column descriptions written", out.getvalue())
        # several tables, from several sources, read together: the model sees the others' columns (no sensitive one)
        # and says which of this table's columns mean the same thing as one there - a reading, to check against the data
        other = Review()
        other.draft = types.SimpleNamespace(table="VS_CRM.CLIENTS", doc={"columns": {
            "CLIENT_ID": {"role": "key", "confidence": "high"}, "PHONE": {"role": "identifier", "sensitive": True}}})
        other.suggestions = lambda: {"CLIENT_ID": "key", "PHONE": "identifier"}
        other.labels = lambda: {"CLIENT_ID": ("DECIMAL(9,0), key (high confidence): 400 distinct", ""), "PHONE": ("VARCHAR(20)", "")}
        reply.choices[0].message.content = json.dumps({"roles": [], "notes": {}, "same_as": [
            {"column": "acct_no", "other": "vs_crm.clients.client_id"}, {"column": "ACCT_NO", "other": "VS_CRM.CLIENTS.PHONE"},
            {"column": "NOPE", "other": "VS_CRM.CLIENTS.CLIENT_ID"}, {"column": "QTY", "other": "SHOP.ORDERS.ORDER_ID"}]})
        sent.clear()
        with mock.patch.object(model_config, "resolve", return_value=config), \
                mock.patch.object(model_config, "create_client", return_value=client), redirect_stdout(io.StringIO()):
            found = role_check.fill_column_map(review, together=[review, other])
        asked = json.loads(sent[0]["messages"][1]["content"])
        self.assertEqual({"VS_CRM.CLIENTS": [{"column": "CLIENT_ID", "type": "DECIMAL(9,0)", "role": "key"}]}, asked["other_tables"])
        self.assertEqual([("SHOP.ORDERS.ACCT_NO", "VS_CRM.CLIENTS.CLIENT_ID")], found["same_as"],
                         "only a column of this table and a column it was shown of another table")
        with mock.patch.object(model_config, "resolve", return_value=None), self.assertRaisesRegex(ValueError, "No AI model is set up"):
            role_check.fill_column_map(review)


if __name__ == "__main__":
    unittest.main()
