"""(run: python3 tests/test_describe_service.py) The profiler and drafter behind `exakit describe` (design 2.2,
AC-DS5.1/5.3/5.5): the role scoring on synthetic profiles - the five roles, ties, a missing date, all-null and
constant columns, quoted names; the profile from a virtual (sampled) and a regular table through a fake connection,
with the statement count; no model note without a model, one warning and an unchanged draft when the call fails;
the YAML the service writes round-trips through the descriptor reader; and the shipped datasets' profiles
(test_data/describe, captured from the local database) draft the roles the shipped descriptors carry."""

from __future__ import annotations

import io
import json
import os
import re
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "setup" / "lib"))
sys.path.insert(0, str(ROOT / "notebook" / "package"))

import describe_service as svc  # noqa: E402
from exakit_nb import descriptor_rules as rules  # noqa: E402

FIXTURES = ROOT / "test_data" / "describe"
TABLE = "LAB.READINGS"


def col(name: str, kind: str = "text", position: int | None = None, **numbers) -> dict:
    """A column's profile record, as _column_record builds it, with the numbers given."""
    types_ = {"text": "VARCHAR(200) UTF8", "integer": "DECIMAL(9,0)", "number": "DOUBLE", "date": "DATE",
              "timestamp": "TIMESTAMP", "boolean": "BOOLEAN", "other": "GEOMETRY"}
    record = {"column": name, "position": position or 0, "type": numbers.pop("type", types_[kind]), "kind": kind,
              "width": None, "null_rate": 0.0, "distinct": 10, "distinct_ratio": 0.001, "all_null": False, "constant": False}
    record["width"] = svc.declared_width(record["type"])
    record.update(numbers)
    if record["distinct"] is not None and record["distinct"] <= 1 and not record["all_null"]:
        record["constant"] = True
    return record


def profile_of(*columns: dict, rows: int = 10000, virtual: bool = False, sampled: bool = False, statements: int = 4) -> dict:
    for n, c in enumerate(columns, 1):
        if not c["position"]:
            c["position"] = n
    return {"table": TABLE, "schema": "LAB", "name": "READINGS", "virtual": virtual, "rows": rows, "sampled": sampled,
            "sample": 10000, "profiled_rows": rows, "statements": statements, "columns": list(columns)}


def shares(*values: float) -> dict:
    vals = [{"value": f"v{i}", "share": s} for i, s in enumerate(values)]
    return {"values": vals, "min_share": min(values)}


def typical() -> dict:
    """A table with one clear column per role."""
    return profile_of(
        col("ID", "integer", distinct=10000, distinct_ratio=1.0),
        col("CUSTOMER_NAME", distinct=800, distinct_ratio=0.08, avg_len=14.0, max_len=40),
        col("SEGMENT", distinct=4, distinct_ratio=0.0004, **shares(0.5, 0.3, 0.15, 0.05)),
        col("ORDER_DATE", "date", distinct=700, distinct_ratio=0.07, min="2024-01-01", max="2025-12-31", span_days=730),
        col("CHURNED", "boolean", distinct=2, distinct_ratio=0.0002, **shares(0.8, 0.2)),
        col("REVIEW_TEXT", distinct=9000, distinct_ratio=0.9, avg_len=220.0, max_len=1900, type="VARCHAR(2000) UTF8"),
    )


class FakeStatement:
    def __init__(self, rows: list[dict], tuples: bool = False):
        self._rows, self._tuples = rows, tuples

    def column_names(self):
        return list(self._rows[0].keys()) if self._rows else []

    def fetchall(self):
        return [tuple(r.values()) for r in self._rows] if self._tuples else list(self._rows)


class FakeConn:
    """Answers the profiler's statements over rows held here: the column list, COUNT(*), the sample fetch, the
    aggregates (computed from the rows) and the GROUPING SETS values."""

    def __init__(self, columns: list[tuple[str, str]], rows: list[dict], virtual: bool = False, tuples: bool = False):
        self.columns, self.rows, self.virtual, self.tuples = columns, rows, virtual, tuples
        self.statements: list[str] = []

    def execute(self, sql: str):
        self.statements.append(sql)
        return FakeStatement(self._answer(sql), self.tuples)

    def _answer(self, sql: str) -> list[dict]:
        if "EXA_ALL_COLUMNS" in sql:
            if "'NOPE'" in sql:
                return []
            return [{"COLUMN_NAME": n, "COLUMN_TYPE": t, "COLUMN_ORDINAL_POSITION": i, "IS_VIRTUAL": int(self.virtual)}
                    for i, (n, t) in enumerate(self.columns, 1)]
        if sql.startswith("SELECT COUNT(*) AS N"):
            return [{"N": len(self.rows)}]
        if "RANDOM()" in sql:
            limit = int(re.search(r"LIMIT (\d+)", sql).group(1))
            return [dict(r) for r in self.rows[:limit]]
        if "GROUPING SETS" in sql:
            names = re.findall(r'GROUPING\("((?:[^"]|"")+)"\)', sql)
            out = []
            for i, name in enumerate(names):
                counts: dict = {}
                for r in self.rows:
                    counts[r.get(name)] = counts.get(r.get(name), 0) + 1
                for value, n in counts.items():
                    row = {f"G{j}": (0 if j == i else 1) for j in range(len(names))}
                    row.update({f"V{j}": (value if j == i else None) for j in range(len(names))})
                    row["N"] = n
                    out.append(row)
            return out
        row: dict = {}
        for i, name in enumerate(re.findall(r'COUNT\("((?:[^"]|"")+)"\) AS C\d+', sql)):
            present = [r.get(name) for r in self.rows if r.get(name) is not None]
            row[f"C{i}"] = len(present)
            row[f"D{i}"] = len(set(map(str, present)))
            if present and all(isinstance(v, (int, float)) for v in present):
                row[f"MN{i}"], row[f"MX{i}"] = str(min(present)), str(max(present))
            elif present:
                row[f"MN{i}"], row[f"MX{i}"] = min(map(str, present)), max(map(str, present))
            texts = [str(v) for v in present if isinstance(v, str)]
            if texts:
                row[f"AL{i}"] = sum(map(len, texts)) / len(texts)
                row[f"ML{i}"] = max(map(len, texts))
                row[f"P{i}"] = sum(1 for t in texts if svc._parses(t))
        return [row]


def fake_openai(answer: str | None = None, error: Exception | None = None) -> types.ModuleType:
    """An `openai` module whose one call returns ``answer`` or raises ``error``; what it was asked is kept."""
    module = types.ModuleType("openai")
    asked: list[dict] = []

    class _Completions:
        def create(self, **kw):
            asked.append(kw)
            if error:
                raise error
            return types.SimpleNamespace(choices=[types.SimpleNamespace(message=types.SimpleNamespace(content=answer))])

    class OpenAI:
        def __init__(self, **kw):
            self.chat = types.SimpleNamespace(completions=_Completions())

    module.OpenAI = OpenAI
    module.asked = asked
    return module


class Scoring(unittest.TestCase):
    def test_the_five_roles(self):
        doc = svc.draft(typical(), TABLE, "readings")
        self.assertEqual(svc.draft_roles(doc), {"date": "ORDER_DATE", "label": "CHURNED", "category": "SEGMENT",
                                                 "entity": "CUSTOMER_NAME", "text": ["REVIEW_TEXT"]})
        self.assertEqual(doc["missing"], [])
        self.assertEqual((doc["schema_version"], doc["version"], doc["status"], doc["drafted_by"], doc["digest"]), (2, 1, "draft", "profile", None))
        self.assertEqual(doc["source"], TABLE)                       # not a shipped dataset, not virtual
        self.assertRegex(doc["created"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(doc["evidence"]["entity"]["runner_up"], None)
        self.assertEqual(doc["evidence"]["table"]["statements"], 4)
        self.assertEqual(doc["evidence"]["label"]["top"][0], {"value": "v0", "share": 0.8})

    def test_owner_from_the_environment_else_the_user(self):
        with mock.patch.dict(os.environ, {"EXAKIT_DESCRIPTOR_OWNER": "ana"}):
            self.assertEqual(svc.draft(typical())["owner"], "ana")
        with mock.patch.dict(os.environ, {"EXAKIT_DESCRIPTOR_OWNER": ""}):
            self.assertTrue(svc.draft(typical())["owner"])

    def test_a_unique_key_is_no_entity(self):
        self.assertIsNone(svc.score_entity(col("ID", "integer", distinct=10000, distinct_ratio=1.0), 10000))
        self.assertEqual(svc.score_entity(col("CUSTOMER_ID", "integer", distinct=800, distinct_ratio=0.08), 800), 1.0)
        self.assertEqual(svc.score_entity(col("THING", distinct=400, distinct_ratio=0.04), 800), 0.65)

    def test_label_prefers_an_outcome_name_and_balanced_classes(self):
        outcome = col("TERMINATED", "integer", distinct=2, **shares(0.82, 0.18))
        outcome["values"] = [{"value": "0", "share": 0.82}, {"value": "1", "share": 0.18}]
        state = col("HAS_RESULTS", "integer", distinct=2, **shares(0.73, 0.27))
        state["values"] = [{"value": "0", "share": 0.73}, {"value": "1", "share": 0.27}]
        rare = col("TIMELY", "integer", distinct=2, **shares(0.996, 0.004))
        rare["values"] = [{"value": "1", "share": 0.996}, {"value": "0", "share": 0.004}]
        self.assertEqual((svc.score_label(outcome), svc.score_label(state), svc.score_label(rare)), (1.0, 0.9, 0.6))
        self.assertIsNone(svc.score_label(col("MANY", distinct=9, **shares(*[1 / 9] * 9))))
        self.assertIsNone(svc.score_label(col("SPARSE", distinct=2, null_rate=0.5, **shares(0.5, 0.5))))

    def test_date_prefers_the_event_date_over_a_follow_up(self):
        start = col("START_DATE", "date", span_days=1095)
        end = col("PRIMARY_COMPLETION_DATE", "date", span_days=3910)
        self.assertEqual((svc.score_date(start), svc.score_date(end)), (1.0, 0.6))
        doc = svc.draft(profile_of(end, start))
        self.assertEqual(doc["roles"]["date"]["column"], "START_DATE")
        self.assertEqual(doc["evidence"]["date"]["runner_up"], {"column": "PRIMARY_COMPLETION_DATE", "score": 0.6})
        parsed = col("WHEN", distinct=500, distinct_ratio=0.05, avg_len=10.0, max_len=10, date_parse_rate=0.98)
        self.assertEqual(svc.score_date(parsed), 0.69)
        self.assertIsNone(svc.score_date(col("NOTE", date_parse_rate=0.5)))

    def test_a_date_tie_takes_the_widest_span_then_the_earlier_column(self):
        a = col("A", "date", span_days=100)
        b = col("B", "date", span_days=400)
        self.assertEqual(svc.draft(profile_of(a, b))["roles"]["date"]["column"], "B")
        c = col("C", "date", span_days=400)
        d = col("D", "date", span_days=400)
        self.assertEqual(svc.draft(profile_of(d, c))["roles"]["date"]["column"], "D")      # positions 1 and 2

    def test_a_category_tie_takes_the_earlier_column(self):
        label = col("TERMINATED", "boolean", distinct=2, **shares(0.8, 0.2))      # the label, so ALLOCATION is not it
        first = col("PHASE", distinct=4, **shares(0.43, 0.42, 0.12, 0.03))
        second = col("ALLOCATION", distinct=3, **shares(0.7, 0.2, 0.1))
        doc = svc.draft(profile_of(label, first, second))
        self.assertEqual(doc["roles"]["category"]["column"], "PHASE")
        self.assertEqual(doc["evidence"]["category"]["runner_up"], {"column": "ALLOCATION", "score": 1.0})
        swapped = profile_of(col("TERMINATED", "boolean", distinct=2, **shares(0.8, 0.2)),
                             col("ALLOCATION", distinct=3, **shares(0.7, 0.2, 0.1)), col("PHASE", distinct=4, **shares(0.43, 0.42, 0.12, 0.03)))
        self.assertEqual(svc.draft(swapped)["roles"]["category"]["column"], "ALLOCATION")

    def test_a_tiny_class_or_nulls_cost_a_category(self):
        self.assertEqual(svc.score_category(col("PURPOSE", distinct=9, **shares(0.9, 0.06, 0.02, 0.01, 0.005, 0.003, 0.001, 0.0005, 0.0005))), 0.8)
        self.assertEqual(svc.score_category(col("STATE", distinct=55, distinct_ratio=0.008)), None)
        self.assertEqual(svc.score_category(col("TAGS", distinct=3, null_rate=0.84, **shares(0.5, 0.3, 0.2))), None)
        self.assertEqual(svc.score_category(col("SIZE", distinct=20, null_rate=0.05, **shares(*[0.05] * 20))), 0.7)

    def test_the_label_column_is_not_offered_as_the_category(self):
        label = col("STATUS", distinct=2, **shares(0.8, 0.2))
        other = col("KIND", distinct=3, **shares(0.5, 0.3, 0.2))
        doc = svc.draft(profile_of(label, other))
        self.assertEqual((doc["roles"]["label"]["column"], doc["roles"]["category"]["column"]), ("STATUS", "KIND"))

    def test_text_by_length_or_by_name(self):
        self.assertEqual(svc.score_text(col("COL7", distinct=900, avg_len=300.0, max_len=2000, type="VARCHAR(2100) UTF8")), 0.5)
        self.assertEqual(svc.score_text(col("BRIEF_TITLE", distinct=900, avg_len=112.0, max_len=300, type="VARCHAR(400) UTF8")), 0.3)
        self.assertEqual(svc.score_text(col("BRIEF_SUMMARY", distinct=900, avg_len=376.0, max_len=2000, type="VARCHAR(2100) UTF8")), 0.8)
        self.assertEqual(svc.score_text(col("ISSUE", distinct=24, avg_len=32.6, max_len=63, type="VARCHAR(120) UTF8")), 0.5)
        self.assertEqual(svc.score_text(col("SUB_PRODUCT", distinct=14, avg_len=29.5, max_len=42, type="VARCHAR(100) UTF8")), 0.0)
        self.assertIsNone(svc.score_text(col("N", "integer")))

    def test_text_columns_keep_the_table_order(self):
        a = col("ELIGIBILITY_CRITERIA", distinct=900, avg_len=1636.0, max_len=2000, type="VARCHAR(2100) UTF8", position=5)
        b = col("BRIEF_SUMMARY", distinct=900, avg_len=376.0, max_len=2000, type="VARCHAR(2100) UTF8", position=4)
        doc = svc.draft(profile_of(a, b))
        self.assertEqual([r["column"] for r in doc["roles"]["text"]], ["BRIEF_SUMMARY", "ELIGIBILITY_CRITERIA"])
        self.assertEqual(doc["evidence"]["text"]["columns"][0]["column"], "BRIEF_SUMMARY")

    def test_a_missing_date_is_named_with_its_reason(self):
        prof = typical()
        prof["columns"] = [c for c in prof["columns"] if c["column"] != "ORDER_DATE"]
        doc = svc.draft(prof, TABLE, "readings")
        self.assertNotIn("date", doc["roles"])
        self.assertEqual([m["role"] for m in doc["missing"]], ["date"])
        self.assertIn("95% parseable dates", doc["missing"][0]["reason"])
        self.assertEqual(rules.validate_descriptor(doc), [])                  # a missing role may be absent from roles
        self.assertEqual(rules.parse_descriptor(json.dumps(doc)).missing_reason("date"), doc["missing"][0]["reason"])

    def test_a_near_miss_is_named_in_the_reason(self):
        prof = profile_of(col("TITLE", distinct=900, distinct_ratio=0.9, avg_len=112.0, max_len=300, type="VARCHAR(400) UTF8"))
        doc = svc.draft(prof)
        text = next(m for m in doc["missing"] if m["role"] == "text")
        self.assertIn("best: TITLE at 0.3", text["reason"])
        self.assertEqual(len(doc["missing"]), 5)

    def test_all_null_and_constant_columns_are_excluded_with_a_reason(self):
        prof = typical()
        prof["columns"] += [col("EMPTY", "date", null_rate=1.0, distinct=0, all_null=True, position=7),
                            col("ONE", distinct=1, distinct_ratio=0.0001, avg_len=300.0, max_len=2000, type="VARCHAR(2000) UTF8", position=8)]
        doc = svc.draft(prof)
        self.assertEqual(doc["evidence"]["excluded"], {"EMPTY": "all values are NULL", "ONE": "one value in every row (constant)"})
        self.assertEqual(doc["roles"]["date"]["column"], "ORDER_DATE")
        self.assertEqual([r["column"] for r in doc["roles"]["text"]], ["REVIEW_TEXT"])
        only = profile_of(col("EMPTY", null_rate=1.0, distinct=0, all_null=True))
        self.assertEqual(len(svc.draft(only)["missing"]), 5)

    def test_the_id_and_the_source(self):
        self.assertEqual(svc.draft(typical())["id"], "readings")
        self.assertEqual(svc.draft(typical(), "LAB.My-Table 2")["id"], "my_table_2")
        self.assertEqual(svc.draft(typical(), TABLE, "lab-readings")["id"], "lab-readings")
        with self.assertRaises(svc.Refused):
            svc.draft(typical(), TABLE, "Not An Id")
        self.assertEqual(svc.draft(profile_of(*typical()["columns"], virtual=True, sampled=True))["source"], "vs:LAB")
        self.assertEqual(svc.draft(typical(), "PHARMA.PHARMA_TRIALS", root=ROOT)["source"], "pharma_trials")
        self.assertEqual(svc.shipped_source("BANKING.BANKING_COMPLAINTS", ROOT), "banking_complaints")
        self.assertIsNone(svc.shipped_source("LAB.READINGS", ROOT))

    def test_the_same_profile_gives_the_same_draft(self):
        a, b = svc.draft(typical()), svc.draft(typical())
        for key in ("roles", "evidence", "missing", "source", "id"):
            self.assertEqual(a[key], b[key])


class QuotedNames(unittest.TestCase):
    def test_identifiers_are_always_quoted(self):
        self.assertEqual(svc.quoted('order date'), '"order date"')
        self.assertEqual(svc.quoted('say "hi"'), '"say ""hi"""')
        self.assertEqual(svc.split_table("lab.readings"), ("LAB", "READINGS"))
        self.assertEqual(svc.split_table('"my schema"."order data"'), ("my schema", "order data"))
        self.assertEqual(svc.split_table('LAB."select"'), ("LAB", "select"))
        for bad in ("READINGS", "A.B.C", "", 'LAB."unclosed', "LAB.1X"):
            with self.assertRaises(svc.Refused):
                svc.split_table(bad)

    def test_a_profile_over_quoted_names(self):
        columns = [("order date", "DATE"), ("select", "VARCHAR(20) UTF8"), ("customer name", "VARCHAR(100) UTF8"), ("ok", "BOOLEAN")]
        rows = [{"order date": f"2024-01-{1 + n % 28:02d}", "select": ["a", "b", "c"][n % 3], "customer name": f"c{n % 40}", "ok": n % 5 == 0}
                for n in range(400)]
        conn = FakeConn(columns, rows)
        prof = svc.profile(conn, '"my schema"."order data"')
        self.assertEqual(prof["table"], "my schema.order data")
        aggregate = next(s for s in conn.statements if "COUNT(DISTINCT" in s)
        self.assertIn('COUNT("order date")', aggregate)
        self.assertIn('IS_DATE("select", \'YYYY-MM-DD\')', aggregate)
        self.assertIn('FROM "my schema"."order data"', aggregate)
        self.assertIn('GROUPING("select")', next(s for s in conn.statements if "GROUPING SETS" in s))
        doc = svc.draft(prof)
        self.assertEqual(doc["roles"]["date"], {"table": "my schema.order data", "column": "order date"})
        self.assertEqual(doc["roles"]["category"]["column"], "select")
        self.assertEqual(doc["roles"]["label"]["column"], "ok")
        text = svc.to_yaml(doc)
        self.assertIn('date: {table: "my schema.order data", column: "order date"}', text)
        self.assertEqual(rules.load_yaml(text)["roles"]["date"]["column"], "order date")


class Profiles(unittest.TestCase):
    COLUMNS = [("ID", "DECIMAL(9,0)"), ("NAME", "VARCHAR(100) UTF8"), ("KIND", "VARCHAR(20) UTF8"), ("TAKEN_ON", "DATE"),
               ("ALARM", "BOOLEAN"), ("NOTE", "VARCHAR(2000) UTF8"), ("EMPTY", "VARCHAR(10) UTF8"), ("SHAPE", "GEOMETRY")]

    @staticmethod
    def rows(n: int = 500) -> list[dict]:
        return [{"ID": i, "NAME": f"device {i % 60}", "KIND": ["gas", "water", "power"][i % 3], "TAKEN_ON": f"2024-{1 + i % 12:02d}-{1 + i % 28:02d}",
                 "ALARM": i % 4 == 0, "NOTE": ("the reading was taken on a quiet day and nothing stood out " * 5) + str(i),
                 "EMPTY": None, "SHAPE": "POINT(1 2)"} for i in range(n)]

    def test_a_regular_table_is_four_statements(self):
        conn = FakeConn(self.COLUMNS, self.rows())
        prof = svc.profile(conn, "lab.readings")
        self.assertEqual((prof["rows"], prof["sampled"], prof["virtual"], prof["statements"], len(conn.statements)), (500, False, False, 4, 4))
        by = {c["column"]: c for c in prof["columns"]}
        self.assertEqual((by["ID"]["kind"], by["ID"]["distinct"], by["ID"]["distinct_ratio"]), ("integer", 500, 1.0))
        self.assertEqual((by["KIND"]["distinct"], by["KIND"]["min_share"]), (3, 0.332))
        self.assertEqual(by["KIND"]["values"][0], {"value": "gas", "share": 0.334})
        self.assertEqual((by["EMPTY"]["all_null"], by["EMPTY"]["null_rate"]), (True, 1.0))
        self.assertEqual((by["SHAPE"]["kind"], by["SHAPE"]["distinct"]), ("other", None))
        self.assertEqual((by["TAKEN_ON"]["min"], by["TAKEN_ON"]["span_days"]), ("2024-01-01", 362))
        self.assertGreater(by["NOTE"]["avg_len"], 200)
        self.assertEqual(by["ALARM"]["values"], [{"value": "False", "share": 0.75}, {"value": "True", "share": 0.25}])
        doc = svc.draft(prof)
        self.assertEqual(svc.draft_roles(doc), {"date": "TAKEN_ON", "label": "ALARM", "category": "KIND", "entity": "NAME", "text": ["NOTE"]})
        self.assertEqual(doc["evidence"]["excluded"], {"EMPTY": "all values are NULL"})
        self.assertEqual(doc["evidence"]["table"]["statements"], 4)

    def test_a_virtual_table_is_sampled_in_three_statements(self):
        conn = FakeConn(self.COLUMNS, self.rows(2000), virtual=True)
        prof = svc.profile(conn, "LAB.READINGS", sample=300)
        self.assertEqual((prof["sampled"], prof["virtual"], prof["profiled_rows"], prof["statements"]), (True, True, 300, 3))
        fetch = conn.statements[-1]
        self.assertRegex(fetch, r'^SELECT "ID", "NAME", .* FROM "LAB"\."READINGS" WHERE RANDOM\(\) < 0\.18 LIMIT 300$')
        by = {c["column"]: c for c in prof["columns"]}
        self.assertEqual((by["KIND"]["distinct"], by["ID"]["distinct_ratio"], by["EMPTY"]["all_null"]), (3, 1.0, True))
        self.assertEqual(by["TAKEN_ON"]["span_days"], 362)
        doc = svc.draft(prof)
        self.assertEqual((doc["source"], doc["evidence"]["table"]["sampled"], doc["evidence"]["table"]["statements"]), ("vs:LAB", True, 3))
        self.assertEqual(svc.draft_roles(doc)["entity"], "NAME")

    def test_a_huge_regular_table_is_sampled_too(self):
        class Huge(FakeConn):
            def _answer(self, sql):
                return [{"N": 6_000_000}] if sql.startswith("SELECT COUNT(*)") else super()._answer(sql)

        conn = Huge(self.COLUMNS, self.rows(50))
        prof = svc.profile(conn, "LAB.READINGS", sample=20)
        self.assertEqual((prof["rows"], prof["sampled"], prof["virtual"], prof["profiled_rows"]), (6_000_000, True, False, 20))
        self.assertIn("RANDOM() < 4e-06", conn.statements[-1])

    def test_rows_as_tuples_read_the_same(self):
        conn = FakeConn(self.COLUMNS, self.rows(), tuples=True)
        prof = svc.profile(conn, "LAB.READINGS")
        self.assertEqual(next(c for c in prof["columns"] if c["column"] == "KIND")["distinct"], 3)

    def test_a_table_that_is_not_there(self):
        with self.assertRaises(svc.NotFound) as caught:
            svc.profile(FakeConn(self.COLUMNS, []), "LAB.NOPE")
        self.assertIn("No table LAB.NOPE", str(caught.exception))
        self.assertEqual(caught.exception.code, 3)

    def test_the_sample_must_be_a_positive_integer(self):
        for bad in (0, -1, "10", 2.5, True):
            with self.assertRaises(svc.Refused):
                svc.profile(FakeConn(self.COLUMNS, []), "LAB.READINGS", sample=bad)

    def test_kinds_and_widths(self):
        self.assertEqual([svc.column_kind(t) for t in ("VARCHAR(10) UTF8", "CHAR(2) ASCII", "DATE", "TIMESTAMP(3)", "BOOLEAN", "DECIMAL(18,0)", "DECIMAL(10,2)", "DOUBLE", "GEOMETRY")],
                         ["text", "text", "date", "timestamp", "boolean", "integer", "number", "number", "other"])
        self.assertEqual((svc.declared_width("VARCHAR(120) UTF8"), svc.declared_width("DATE")), (120, None))
        self.assertTrue(svc._parses("2024-01-02") and svc._parses("02.01.2024") and svc._parses("01/02/2024") and svc._parses("2024-01-02 10:00:00"))
        self.assertFalse(svc._parses("2024-13-02") or svc._parses("hello"))


class ModelNote(unittest.TestCase):
    def test_no_note_without_a_model(self):
        prof = typical()
        doc = svc.draft(prof)
        with mock.patch.dict(os.environ, {"EXAKIT_NB_MODEL": "", "OPENAI_BASE_URL": ""}):
            self.assertIsNone(svc.model_notes(doc, prof))
        with mock.patch.dict(os.environ, {"EXAKIT_NB_MODEL": "llama", "OPENAI_BASE_URL": ""}):
            self.assertIsNone(svc.model_notes(doc, prof))
        with mock.patch.dict(os.environ, {"EXAKIT_NB_MODEL": "", "OPENAI_BASE_URL": "http://127.0.0.1:9"}):
            self.assertIsNone(svc.model_notes(doc, prof))
        self.assertNotIn("notes", doc)

    def test_a_failed_call_is_one_warning_and_the_draft_stands(self):
        prof = typical()
        doc = svc.draft(prof)
        before = json.dumps(doc, sort_keys=True)
        err = io.StringIO()
        with mock.patch.dict(os.environ, {"EXAKIT_NB_MODEL": "llama", "OPENAI_BASE_URL": "http://127.0.0.1:9"}), \
                mock.patch.dict(sys.modules, {"openai": fake_openai(error=ConnectionError("refused"))}), redirect_stderr(err):
            self.assertIsNone(svc.model_notes(doc, prof))
        self.assertEqual(err.getvalue().count("\n"), 1)
        self.assertIn("Warning: no model notes (ConnectionError: refused)", err.getvalue())
        self.assertEqual(json.dumps(doc, sort_keys=True), before)

    def test_one_call_with_names_and_numbers_never_rows(self):
        prof = typical()
        doc = svc.draft(prof)
        module = fake_openai('Sure: {"CUSTOMER_NAME": "Who bought.", "SEGMENT": "The customer segment.", "GHOST": "x"}')
        with mock.patch.dict(os.environ, {"EXAKIT_NB_MODEL": "llama", "OPENAI_BASE_URL": "http://127.0.0.1:9"}), \
                mock.patch.dict(sys.modules, {"openai": module}):
            notes = svc.model_notes(doc, prof)
        self.assertEqual(notes, {"CUSTOMER_NAME": "Who bought.", "SEGMENT": "The customer segment."})
        self.assertEqual(len(module.asked), 1)
        prompt = module.asked[0]["messages"][0]["content"]
        self.assertIn("CUSTOMER_NAME", prompt)
        self.assertNotIn("v0", prompt)                                   # a value, not a number
        self.assertEqual(svc.draft_roles(svc.draft(prof)), svc.draft_roles(doc))   # AC-DS5.5: the roles are the same


class Yaml(unittest.TestCase):
    def test_scalars_read_back_as_written(self):
        self.assertEqual([svc._yaml_scalar(v) for v in (None, True, 3, 0.83, 1e-05, 5.0, "PHASE2", "order date", "null", "2024-01-01")],
                         ["null", "true", "3", "0.83", "0.00001", "5.0", "PHASE2", '"order date"', '"null"', "2024-01-01"])
        for value in (0.83, 1e-05, 5.0, 3, "order date", "PHASE2"):
            self.assertEqual(rules._scalar(svc._yaml_scalar(value), "t"), value)

    def test_the_draft_round_trips_through_the_descriptor_reader(self):
        prof = json.loads((FIXTURES / "pharma_trials.profile.json").read_text(encoding="utf-8"))
        doc = svc.draft(prof, root=ROOT)
        doc["notes"] = {"LEAD_SPONSOR": "Organisation funding the trial: it's \"the sponsor\"."}
        text = svc.to_yaml(doc)
        self.assertTrue(text.startswith("# Which column of PHARMA.PHARMA_TRIALS plays which role"))
        read = rules.parse_descriptor(text)
        self.assertEqual((read.id, read.fact_table, read.status, read.version, read.drafted_by, read.digest, read.source),
                         ("pharma_trials", "PHARMA.PHARMA_TRIALS", "draft", 1, "profile", None, "pharma_trials"))
        self.assertEqual(svc.shipped_roles(read), svc.draft_roles(doc))
        self.assertEqual(read.evidence, doc["evidence"])
        self.assertEqual(read.notes, doc["notes"])
        self.assertEqual(read.missing, ())
        self.assertEqual(rules.load_yaml(text), json.loads(json.dumps(doc)))   # every key, the same values
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "d.yaml"
            path.write_text(text, encoding="utf-8")
            self.assertEqual(rules.read_descriptor(path).roles, read.roles)

    def test_the_notebook_writer_writes_the_same_layout(self):
        from exakit_nb import own_file
        doc = svc.draft(typical(), TABLE, "readings")
        doc["missing"] = []
        with tempfile.TemporaryDirectory() as folder:
            own_file.save_descriptor(doc, Path(folder) / "d.yaml", "x")
            theirs = (Path(folder) / "d.yaml").read_text(encoding="utf-8")
        self.assertEqual(theirs.splitlines()[1:], svc.to_yaml(doc, "x").splitlines()[1:])


class ShippedDatasets(unittest.TestCase):
    """AC-DS5.1: for each shipped dataset, a fresh draft from its profile (captured from the local database into
    test_data/describe) proposes the roles the shipped descriptor carries, text columns in the same order."""

    def test_fresh_drafts_equal_the_shipped_roles(self):
        for fixture in sorted(FIXTURES.glob("*.profile.json")):
            with self.subTest(dataset=fixture.name):
                prof = json.loads(fixture.read_text(encoding="utf-8"))
                shipped = rules.read_descriptor(ROOT / "data" / "datasets" / fixture.name.split(".")[0] / "descriptor.yaml")
                doc = svc.draft(prof, shipped.fact_table, shipped.id, root=ROOT)
                self.assertEqual(svc.draft_roles(doc), svc.shipped_roles(shipped))
                self.assertEqual(doc["missing"], [])
                self.assertEqual(doc["source"], shipped.id)
                self.assertEqual(prof["statements"], 4)
                for role in ("date", "label", "category", "entity", "text"):          # the shipped evidence is this draft's
                    self.assertEqual(shipped.evidence[role], doc["evidence"][role], role)
                self.assertEqual(shipped.evidence["table"]["statements"], 4)


class CommandLine(unittest.TestCase):
    def run_main(self, *argv: str, env: dict | None = None) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env or {}, clear=False), mock.patch("sys.stdout", out), redirect_stderr(err):
            code = svc.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_bad_arguments_are_exit_2(self):
        for argv in ((), ("draft",), ("draft", "A.B", "C.D"), ("draft", "A.B", "--sample", "x"), ("draft", "A.B", "--sample"),
                     ("draft", "A.B", "--bogus"), ("draft", "A.B", "--id", "Bad Id"), ("draft", "NOTATABLE"), ("nope",),
                     ("evidence-check",), ("evidence-check", "/nowhere/d.yaml"), ("profile",)):
            with self.subTest(argv=argv):
                code, _out, err = self.run_main(*argv)
                self.assertEqual(code, 2)
                self.assertIn("usage:", err)

    def test_help_is_exit_0(self):
        code, out, _err = self.run_main("--help")
        self.assertEqual(code, 0)
        self.assertIn("evidence-check", out)

    def test_no_connection_settings_is_exit_4(self):
        code, _out, err = self.run_main("draft", "LAB.READINGS", env={"EXAKIT_PYX_DSN": "", "EXAKIT_PYX_PWFILE": ""})
        self.assertEqual(code, 4)
        self.assertIn("exakit status", err)
        code, _out, err = self.run_main("profile", "LAB.READINGS", env={"EXAKIT_PYX_DSN": "", "EXAKIT_PYX_PWFILE": ""})
        self.assertEqual(code, 4)

    def test_draft_json_and_write_through_a_fake_connection(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "readings.yaml"
            with mock.patch.object(svc, "connect", return_value=mock.Mock(execute=conn.execute, close=mock.Mock())):
                code, out, err = self.run_main("draft", "lab.readings", "--json", "--id", "lab-readings", "--write", str(target),
                                               env={"EXAKIT_NB_MODEL": "", "OPENAI_BASE_URL": ""})
            self.assertEqual((code, err), (0, ""))
            doc = json.loads(out)
            self.assertEqual((doc["id"], doc["status"], svc.draft_roles(doc)["category"]), ("lab-readings", "draft", "KIND"))
            self.assertEqual(rules.read_descriptor(target).roles["category"][0].column, "KIND")
            with mock.patch.object(svc, "connect", return_value=mock.Mock(execute=conn.execute, close=mock.Mock())):
                code, out, _err = self.run_main("draft", "LAB.READINGS", env={"EXAKIT_NB_MODEL": "", "OPENAI_BASE_URL": ""})
            self.assertEqual(code, 0)
            self.assertTrue(out.startswith("# Which column of LAB.READINGS"))

    def test_a_table_that_is_not_there_is_exit_3(self):
        conn = FakeConn(Profiles.COLUMNS, [])
        with mock.patch.object(svc, "connect", return_value=mock.Mock(execute=conn.execute, close=mock.Mock())):
            code, _out, err = self.run_main("draft", "LAB.NOPE")
        self.assertEqual(code, 3)
        self.assertIn("No table LAB.NOPE", err)

    def test_evidence_check_through_a_fake_connection(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "descriptor.yaml"
            doc = svc.draft(svc.profile(FakeConn(Profiles.COLUMNS, Profiles.rows()), "LAB.READINGS"), "LAB.READINGS", "readings")
            path.write_text(svc.to_yaml(doc), encoding="utf-8")
            with mock.patch.object(svc, "connect", return_value=mock.Mock(execute=conn.execute, close=mock.Mock())):
                code, out, _err = self.run_main("evidence-check", str(path))
            self.assertEqual(code, 0)
            self.assertIn("Every role agrees", out)
            doc["roles"]["entity"]["column"] = "KIND"
            doc["roles"]["category"]["column"] = "NAME"
            path.write_text(svc.to_yaml(doc), encoding="utf-8")
            with mock.patch.object(svc, "connect", return_value=mock.Mock(execute=conn.execute, close=mock.Mock())):
                code, out, _err = self.run_main("evidence-check", str(path), "--json")
            self.assertEqual(code, 1)
            self.assertEqual((json.loads(out)["ok"], json.loads(out)["roles"]["entity"]["same"], json.loads(out)["roles"]["date"]["same"]), (False, False, True))


if __name__ == "__main__":
    unittest.main(verbosity=1)
