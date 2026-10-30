"""(run: python3 tests/test_describe_service.py) The profiler and drafter behind `exakit describe` (design 2.2,
AC-DS5.1/5.3/5.5): the role scoring on synthetic profiles - the five roles, ties, a missing date, all-null and
constant columns, quoted names; the profile from a virtual (sampled) and a regular table through a fake connection,
with the statement count; no model note without a model, one warning and an unchanged draft when the call fails;
the YAML the service writes round-trips through the descriptor reader; the shipped datasets' profiles
(test_data/describe, captured from the local database) draft the roles the shipped descriptors carry; and the approve
half (design 2.2/2.3, AC-DS5.2/5.4/5.5): the table digest (deterministic, order-independent, its SQL, a sample scope
for a virtual table), approve into the kit's store (v<n+1> + current, a shipped id as v2, idempotent, a conflict
retried once, the owner, bad roles named), the comment write-back (COMMENT ON COLUMN with the existing comment kept,
the view for a virtual table, a failure as a warning) and the row budget of a virtual table."""

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
    aggregates (computed from the rows) and the GROUPING SETS values; the digest statement (each row hashed here the
    way the database would, over the columns the statement names, the first LIMIT rows when it has one); the
    existing comments; and the DDL of the write-back (recorded, or refused when ``ddl_error`` is set). ``fetched``
    counts the rows handed out by statements that read the table's rows."""

    def __init__(self, columns: list[tuple[str, str]], rows: list[dict], virtual: bool = False, tuples: bool = False,
                 comments: dict | None = None, ddl_error: Exception | None = None):
        self.columns, self.rows, self.virtual, self.tuples = columns, rows, virtual, tuples
        self.comments, self.ddl_error = dict(comments or {}), ddl_error
        self.statements: list[str] = []
        self.fetched = 0

    def execute(self, sql: str):
        self.statements.append(sql)
        return FakeStatement(self._answer(sql), self.tuples)

    def close(self):
        pass

    def _answer(self, sql: str) -> list[dict]:
        if not sql.startswith("SELECT"):
            if self.ddl_error is not None:
                raise self.ddl_error
            done = re.fullmatch(r'COMMENT ON COLUMN "[^"]+"\."[^"]+"\."([^"]+)" IS \'((?:[^\']|\'\')*)\'', sql)
            if done:                                                                 # the comment takes, as in the database
                self.comments[done.group(1)] = done.group(2).replace("''", "'") or None
            return []
        if "EXA_ALL_COLUMNS" in sql:
            if "'NOPE'" in sql:
                return []
            if "COLUMN_COMMENT" in sql:
                return [{"COLUMN_NAME": n, "COLUMN_COMMENT": self.comments.get(n)} for n, _t in self.columns]
            return [{"COLUMN_NAME": n, "COLUMN_TYPE": t, "COLUMN_ORDINAL_POSITION": i, "IS_VIRTUAL": int(self.virtual)}
                    for i, (n, t) in enumerate(self.columns, 1)]
        if sql.startswith("SELECT COUNT(*) AS N, SUM(TO_NUMBER"):
            return [self._digest(sql)]
        if sql.startswith("SELECT COUNT(*) AS N"):
            return [{"N": len(self.rows)}]
        if "RANDOM()" in sql or re.search(r'FROM "[^"]+"\."[^"]+" LIMIT \d+$', sql):
            limit = int(re.search(r"LIMIT (\d+)", sql).group(1))
            self.fetched += min(limit, len(self.rows))
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
        self.fetched += len(self.rows)
        return [row]

    def _digest(self, sql: str) -> dict:
        import hashlib
        names = re.findall(r'(?:CAST|TO_CHAR)\("((?:[^"]|"")+)"', sql)
        limit = re.search(r"LIMIT (\d+)\)\)$", sql)
        rows = self.rows[:int(limit.group(1))] if limit else self.rows
        self.fetched += len(rows)
        sums = [0] * svc.DIGEST_SLICES
        for r in rows:
            text = "\x1f".join(svc.NULL_MARK if r.get(n) is None else str(r[n]) for n in names)
            h = hashlib.sha256(text.encode("utf-8")).hexdigest()
            for i in range(svc.DIGEST_SLICES):
                sums[i] += int(h[12 * i:12 * i + 12], 16)
        return dict({"N": len(rows)}, **{f"S{i}": str(v) for i, v in enumerate(sums)})


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
    def test_category_values_do_not_become_an_unusable_prediction_target(self):
        product = col("PRODUCT", distinct=3, **shares(0.5, 0.3, 0.2))
        product["values"] = [{"value": name, "share": share} for name, share in
                             [("Mortgage", 0.5), ("Credit card", 0.3), ("Savings", 0.2)]]
        doc = svc.draft(profile_of(product))
        self.assertNotIn("label", doc["roles"])
        self.assertEqual(doc["roles"]["category"]["column"], "PRODUCT")

    def test_a_two_value_category_is_offered_as_a_grouping(self):
        segment = col("SEGMENT", distinct=2, **shares(0.6, 0.4))
        segment["values"] = [{"value": "Retail", "share": 0.6}, {"value": "Business", "share": 0.4}]
        doc = svc.draft(profile_of(segment))
        self.assertNotIn("label", doc["roles"])
        self.assertEqual(doc["roles"]["category"]["column"], "SEGMENT")

    def test_a_target_name_cannot_turn_nonbinary_values_into_a_label(self):
        status = col("TARGET_STATUS", distinct=2, **shares(0.5, 0.5))
        status["values"] = [{"value": "Open", "share": 0.5}, {"value": "Closed", "share": 0.5}]
        self.assertIsNone(svc.score_label(status))

    def test_a_binary_outcome_with_some_missing_rows_remains_a_candidate(self):
        outcome = col("OUTCOME", "integer", distinct=2, null_rate=0.1, **shares(0.8, 0.2))
        outcome["values"] = [{"value": "0", "share": 0.8}, {"value": "1", "share": 0.2}]
        self.assertEqual(svc.score_label(outcome), 1.0)
        outcome["null_rate"] = 0.2
        self.assertIsNone(svc.score_label(outcome))

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

    def test_a_category_tie_prefers_a_grouping_name_then_the_earlier_column(self):
        label = col("TERMINATED", "boolean", distinct=2, **shares(0.8, 0.2))      # the label, so ALLOCATION is not it
        first = col("PHASE", distinct=4, **shares(0.43, 0.42, 0.12, 0.03))
        second = col("ALLOCATION", distinct=3, **shares(0.7, 0.2, 0.1))
        doc = svc.draft(profile_of(label, first, second))
        self.assertEqual(doc["roles"]["category"]["column"], "PHASE")
        self.assertEqual(doc["evidence"]["category"]["runner_up"], {"column": "ALLOCATION", "score": 1.0})
        swapped = profile_of(col("TERMINATED", "boolean", distinct=2, **shares(0.8, 0.2)),
                             col("ALLOCATION", distinct=3, **shares(0.7, 0.2, 0.1)), col("PHASE", distinct=4, **shares(0.43, 0.42, 0.12, 0.03)))
        self.assertEqual(svc.draft(swapped)["roles"]["category"]["column"], "PHASE")
        tied = profile_of(col("A", distinct=3, **shares(0.6, 0.3, 0.1)),
                          col("B", distinct=3, **shares(0.6, 0.3, 0.1)))
        self.assertEqual(svc.draft(tied)["roles"]["category"]["column"], "A")

    def test_a_small_company_list_does_not_displace_a_named_category(self):
        company = col("COMPANY", distinct=5, **shares(0.2, 0.2, 0.2, 0.2, 0.2))
        category = col("CATEGORY", distinct=2, **shares(0.5, 0.5))
        doc = svc.draft(profile_of(company, category))
        self.assertEqual(doc["roles"]["category"]["column"], "CATEGORY")

    def test_a_tiny_class_or_nulls_cost_a_category(self):
        self.assertEqual(svc.score_category(col("PURPOSE", distinct=9, **shares(0.9, 0.06, 0.02, 0.01, 0.005, 0.003, 0.001, 0.0005, 0.0005))), 0.8)
        self.assertEqual(svc.score_category(col("STATE", distinct=55, distinct_ratio=0.008)), None)
        self.assertEqual(svc.score_category(col("TAGS", distinct=3, null_rate=0.84, **shares(0.5, 0.3, 0.2))), None)
        self.assertEqual(svc.score_category(col("SIZE", distinct=20, null_rate=0.05, **shares(*[0.05] * 20))), 0.7)

    def test_the_label_column_is_not_offered_as_the_category(self):
        label = col("STATUS", distinct=2, **shares(0.8, 0.2))
        label["values"] = [{"value": "0", "share": 0.8}, {"value": "1", "share": 0.2}]
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
        # The draft refuses such names: the reader keeps a plain upper-case name only, the notebooks write it into
        # SQL unquoted, so a descriptor with "order date" could never run. The remedy is a view with plain names.
        with self.assertRaises(svc.Refused) as caught:
            svc.draft(prof)
        self.assertIn("my schema.order data is not named by plain upper-case SQL names", str(caught.exception))
        self.assertIn('CREATE VIEW STARTER_KIT.ORDER_DATA AS SELECT "order date" AS ORDER_DATE, "select" AS SELECT, "customer name" AS CUSTOMER_NAME, ... FROM "my schema"."order data"', str(caught.exception))
        self.assertIn("exakit describe STARTER_KIT.ORDER_DATA", str(caught.exception))

    def test_a_plain_table_with_a_role_column_that_needs_quotes_is_refused_naming_it(self):
        columns = [("ID", "DECIMAL(9,0)"), ("order date", "DATE"), ("KIND", "VARCHAR(20) UTF8"), ("ok", "BOOLEAN")]
        rows = [{"ID": n, "order date": f"2024-01-{1 + n % 28:02d}", "KIND": ["a", "b", "c"][n % 3], "ok": n % 5 == 0} for n in range(400)]
        prof = svc.profile(FakeConn(columns, rows), "LAB.READINGS")
        with self.assertRaises(svc.Refused) as caught:
            svc.draft(prof)
        self.assertIn('date -> "order date"', str(caught.exception))
        self.assertIn('label -> "ok"', str(caught.exception))
        self.assertIn('"order date" AS ORDER_DATE', str(caught.exception))
        self.assertEqual(caught.exception.code, 2)
        self.assertEqual(svc.parse_role("entity=name"), ("entity", ["NAME"]))
        for bad in ("entity=order date", "entity=1x", "owner=X", "entity=", "entity=A,B", "text="):
            with self.assertRaises(svc.Refused):
                svc.parse_role(bad)
        self.assertEqual(svc.parse_role("text=a, b"), ("text", ["A", "B"]))


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
        self.assertRegex(fetch, r'^SELECT "ID", "NAME", .* FROM "LAB"\."READINGS" LIMIT 300$')     # the first rows: no RANDOM() filter,
        self.assertNotIn("RANDOM", fetch)                                                           # which would read the source whole
        self.assertEqual((prof["sample_method"], conn.fetched), ("first rows", 300))
        by = {c["column"]: c for c in prof["columns"]}
        self.assertEqual((by["KIND"]["distinct"], by["ID"]["distinct_ratio"], by["EMPTY"]["all_null"]), (3, 1.0, True))
        self.assertEqual(by["TAKEN_ON"]["span_days"], 362)
        doc = svc.draft(prof)
        self.assertEqual((doc["source"], doc["evidence"]["table"]["sampled"], doc["evidence"]["table"]["statements"]), ("vs:LAB", True, 3))
        self.assertEqual(doc["evidence"]["table"]["sample_method"], "first rows")
        self.assertEqual(svc.draft_roles(doc)["entity"], "NAME")

    def test_a_huge_regular_table_is_sampled_too(self):
        class Huge(FakeConn):
            def _answer(self, sql):
                return [{"N": 6_000_000}] if sql.startswith("SELECT COUNT(*)") else super()._answer(sql)

        conn = Huge(self.COLUMNS, self.rows(50))
        prof = svc.profile(conn, "LAB.READINGS", sample=20)
        self.assertEqual((prof["rows"], prof["sampled"], prof["virtual"], prof["profiled_rows"]), (6_000_000, True, False, 20))
        self.assertIn("RANDOM() < 4e-06", conn.statements[-1])        # a local table: the random slice the design asks for
        self.assertEqual(prof["sample_method"], "random")

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
        with mock.patch.dict(os.environ, {"EXAKIT_MODEL_ID": "", "EXAKIT_PROVIDER_BASE_URL": ""}):
            self.assertIsNone(svc.model_notes(doc, prof))
        with mock.patch.dict(os.environ, {"EXAKIT_MODEL_ID": "llama", "EXAKIT_PROVIDER_BASE_URL": ""}):
            self.assertIsNone(svc.model_notes(doc, prof))
        with mock.patch.dict(os.environ, {"EXAKIT_MODEL_ID": "", "EXAKIT_PROVIDER_BASE_URL": "http://127.0.0.1:9"}):
            self.assertIsNone(svc.model_notes(doc, prof))
        self.assertNotIn("notes", doc)

    def test_failed_provider_messages_redact_key_and_header_values_even_when_empty(self):
        prof = typical()
        doc = svc.draft(prof)
        before = json.dumps(doc, sort_keys=True)
        env = {"EXAKIT_MODEL_ID": "m", "EXAKIT_PROVIDER_BASE_URL": "https://provider.example/v1",
               "EXAKIT_PROVIDER_API_KEY": "test-secret-key",
               "EXAKIT_PROVIDER_HEADERS": '{"anthropic-workspace-id":"private-workspace"}'}
        for message in ("test-secret-key private-workspace refused", ""):
            err = io.StringIO()
            with self.subTest(message=message), mock.patch.dict(os.environ, env, clear=True), \
                    mock.patch.dict(sys.modules, {"openai": fake_openai(error=RuntimeError(message))}), redirect_stderr(err):
                self.assertIsNone(svc.model_notes(doc, prof))
            self.assertEqual(err.getvalue().count("\n"), 1)
            self.assertNotIn("test-secret-key", err.getvalue())
            self.assertNotIn("private-workspace", err.getvalue())
            self.assertIn("draft is unchanged", err.getvalue())
            self.assertEqual(json.dumps(doc, sort_keys=True), before)

    def test_a_failed_call_is_one_warning_and_the_draft_stands(self):
        prof = typical()
        doc = svc.draft(prof)
        before = json.dumps(doc, sort_keys=True)
        err = io.StringIO()
        with mock.patch.dict(os.environ, {"EXAKIT_MODEL_ID": "llama", "EXAKIT_PROVIDER_BASE_URL": "http://127.0.0.1:9"}), \
                mock.patch.dict(sys.modules, {"openai": fake_openai(error=ConnectionError("refused"))}), redirect_stderr(err):
            self.assertIsNone(svc.model_notes(doc, prof))
        self.assertEqual(err.getvalue().count("\n"), 1)
        self.assertIn("Warning: no model notes (ConnectionError: refused)", err.getvalue())
        self.assertEqual(json.dumps(doc, sort_keys=True), before)

    def test_one_call_with_names_and_numbers_never_rows(self):
        prof = typical()
        doc = svc.draft(prof)
        module = fake_openai('Sure: {"CUSTOMER_NAME": "Who bought.", "SEGMENT": "The customer segment.", "GHOST": "x"}')
        with mock.patch.dict(os.environ, {"EXAKIT_MODEL_ID": "llama", "EXAKIT_PROVIDER_BASE_URL": "http://127.0.0.1:9"}), \
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


# --- the approve half ----------------------------------------------------------------------------------------------

def kit_home():
    """A temporary EXAKIT_HOME for the descriptor store (the owner fixed, no model)."""
    folder = tempfile.TemporaryDirectory()
    patch = mock.patch.dict(os.environ, {"EXAKIT_HOME": folder.name, "EXAKIT_DESCRIPTOR_OWNER": "dana", "EXAKIT_MODEL_ID": "", "EXAKIT_PROVIDER_BASE_URL": ""})
    return folder, patch


def readings_draft(conn=None) -> dict:
    conn = conn or FakeConn(Profiles.COLUMNS, Profiles.rows())
    return svc.draft(svc.profile(conn, "LAB.READINGS"), "LAB.READINGS", "readings")


class Digest(unittest.TestCase):
    ROLES = {"entity": "NAME", "category": "KIND", "date": "TAKEN_ON", "label": "ALARM", "text": ["NOTE"]}

    def test_the_digest_is_deterministic_and_order_independent_and_sees_a_change(self):
        rows = Profiles.rows()
        first = svc.digest(FakeConn(Profiles.COLUMNS, rows), "LAB.READINGS", self.ROLES)
        again = svc.digest(FakeConn(Profiles.COLUMNS, rows), "lab.readings", self.ROLES)
        shuffled = svc.digest(FakeConn(Profiles.COLUMNS, list(reversed(rows))), "LAB.READINGS", self.ROLES)
        self.assertEqual(first["digest"], again["digest"])
        self.assertEqual(first["digest"], shuffled["digest"])
        self.assertRegex(first["digest"], r"^sha256:[0-9a-f]{64}$")
        self.assertEqual((first["scope"], first["rows"], first["hashed_rows"], first["statements"]), ("full", 500, 500, 2))
        changed = [dict(r) for r in rows]
        changed[7]["KIND"] = "steam"
        self.assertNotEqual(first["digest"], svc.digest(FakeConn(Profiles.COLUMNS, changed), "LAB.READINGS", self.ROLES)["digest"])
        self.assertNotEqual(first["digest"], svc.digest(FakeConn(Profiles.COLUMNS, rows[:-1]), "LAB.READINGS", self.ROLES)["digest"])
        other = svc.digest(FakeConn(Profiles.COLUMNS, rows), "LAB.READINGS", dict(self.ROLES, entity="ID"))
        self.assertNotEqual(first["digest"], other["digest"])                      # the role columns are part of it
        self.assertEqual(first["digest"], svc.digest(FakeConn(Profiles.COLUMNS, rows), "LAB.READINGS",
                                                     {r: {"table": "LAB.READINGS", "column": c} for r, c in self.ROLES.items() if r != "text"}
                                                     | {"text": [{"table": "LAB.READINGS", "column": "NOTE"}]})["digest"])

    def test_the_digest_sql(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
        sql = svc.digest(conn, "LAB.READINGS", self.ROLES)["sql"]
        self.assertTrue(sql.startswith("SELECT COUNT(*) AS N, SUM(TO_NUMBER(SUBSTR(H, 1, 12), 'XXXXXXXXXXXX')) AS S0, "))
        self.assertIn("SUM(TO_NUMBER(SUBSTR(H, 49, 12), 'XXXXXXXXXXXX')) AS S4 FROM (SELECT HASH_SHA256(", sql)
        self.assertIn('COALESCE(CAST("NAME" AS VARCHAR(2000000)), \'<null>\') || CHR(31) || COALESCE(CAST("KIND" AS VARCHAR(2000000)), \'<null>\') '
                      '|| CHR(31) || COALESCE(TO_CHAR("TAKEN_ON", \'YYYY-MM-DD\'), \'<null>\') || CHR(31) || COALESCE(CAST("ALARM" AS VARCHAR(2000000)), \'<null>\') '
                      '|| CHR(31) || COALESCE(CAST("NOTE" AS VARCHAR(2000000)), \'<null>\')) AS H FROM "LAB"."READINGS")', sql)
        self.assertNotIn("ORDER BY", sql)
        self.assertNotIn("RANDOM", sql)
        self.assertEqual(sum(1 for s in conn.statements if s.startswith("SELECT COUNT(*) AS N, SUM")), 1)
        ts = svc.digest_sql('"A"."B"', [{"column": "AT", "kind": "timestamp", "type": "TIMESTAMP"}])
        self.assertIn("TO_CHAR(\"AT\", 'YYYY-MM-DD HH24:MI:SS.FF6')", ts)

    def test_a_virtual_table_is_hashed_over_its_first_sample_rows(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows(2000), virtual=True)
        out = svc.digest(conn, "LAB.READINGS", self.ROLES, sample=300)
        self.assertEqual((out["scope"], out["rows"], out["hashed_rows"], out["sample"], out["statements"]), ("sample", 2000, 300, 300, 3))
        self.assertTrue(out["sql"].endswith('FROM (SELECT "NAME", "KIND", "TAKEN_ON", "ALARM", "NOTE" FROM "LAB"."READINGS" LIMIT 300))'))
        self.assertEqual(conn.fetched, 300)
        self.assertEqual(out["digest"], svc.digest(FakeConn(Profiles.COLUMNS, Profiles.rows(2000), virtual=True), "LAB.READINGS", self.ROLES, sample=300)["digest"])

    def test_a_role_column_the_table_lacks_is_refused_naming_the_role(self):
        with self.assertRaises(svc.Refused) as caught:
            svc.digest(FakeConn(Profiles.COLUMNS, Profiles.rows()), "LAB.READINGS", dict(self.ROLES, entity="NOPE"))
        self.assertIn("no column NOPE (the entity role)", str(caught.exception))
        with self.assertRaises(svc.NotFound):
            svc.digest(FakeConn(Profiles.COLUMNS, []), "LAB.NOPE", self.ROLES)
        with self.assertRaises(svc.Refused):
            svc.digest(FakeConn(Profiles.COLUMNS, Profiles.rows()), "LAB.READINGS", {})


class Approve(unittest.TestCase):
    def setUp(self):
        self.folder, patch = kit_home()
        patch.start()
        self.addCleanup(patch.stop)
        self.addCleanup(self.folder.cleanup)
        self.home = Path(self.folder.name)

    def stored(self, id: str, n: int) -> dict:
        return svc.read_document(self.home / "descriptors" / id / f"v{n}.yaml")

    def test_the_first_approve_writes_v1_and_current(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
        draft = readings_draft(conn)
        before = len(conn.statements)
        result = svc.approve(conn, draft, comments=False)
        self.assertEqual((result["id"], result["version"], result["unchanged"], result["owner"], result["scope"], result["rows"]),
                         ("readings", 1, False, "dana", "full", 500))
        self.assertEqual(result["path"], str(self.home / "descriptors" / "readings" / "v1.yaml"))
        self.assertEqual((self.home / "descriptors" / "readings" / "current").read_text(), "1\n")
        self.assertEqual(svc.store_versions("readings"), [1])
        read = rules.read_descriptor(Path(result["path"]))
        self.assertEqual((read.status, read.version, read.owner, read.drafted_by, read.digest, read.source), ("approved", 1, "dana", "profile", result["digest"], "LAB.READINGS"))
        self.assertEqual(svc.shipped_roles(read), svc.draft_roles(draft))
        self.assertEqual(read.evidence["entity"]["column"], "NAME")                   # the draft's evidence is kept
        self.assertEqual(read.evidence["table"]["digest_scope"], "full")
        self.assertTrue(read.created and read.created.endswith("Z"))
        self.assertEqual(draft["status"], "draft", "the draft given is not changed")
        self.assertEqual([s for s in conn.statements[before:] if not s.startswith("SELECT")], [], "no comments on --no-comments")
        self.assertTrue(result["comments"]["skipped"])
        self.assertEqual(svc.show("readings")["version"], 1)

    def test_a_shipped_dataset_approves_as_v2_and_the_shipped_file_stays(self):
        prof = json.loads((FIXTURES / "pharma_trials.profile.json").read_text(encoding="utf-8"))
        columns = [(c["column"], c["type"]) for c in prof["columns"]]
        rows = [{c["column"]: (f"2017-0{1 + n % 9}-01" if c["kind"] == "date" else n % 2 if c["kind"] in ("integer", "number") else f"v{n % 7}")
                 for c in prof["columns"]} for n in range(40)]
        conn = FakeConn(columns, rows)
        doc, origin = svc.resolve_draft("pharma_trials", ROOT)
        self.assertEqual((origin, doc["version"], doc["status"]), ("shipped", 1, "approved"))
        self.assertEqual(svc.next_version("pharma_trials", ROOT), 2)
        result = svc.approve(conn, doc, root=ROOT)
        self.assertEqual((result["version"], result["unchanged"]), (2, False))
        self.assertEqual(svc.store_versions("pharma_trials"), [2])
        shipped = rules.read_descriptor(ROOT / "data" / "datasets" / "pharma_trials" / "descriptor.yaml")
        self.assertEqual((shipped.version, shipped.owner), (1, "kit"))
        read = rules.read_descriptor(Path(result["path"]))
        self.assertEqual((read.version, read.owner, read.drafted_by, read.source, shipped.roles), (2, "dana", "shipped", "pharma_trials", read.roles))
        listed = svc.versions("pharma_trials", ROOT)
        self.assertEqual([(e["version"], e["origin"], e["current"], e["owner"]) for e in listed], [(1, "shipped", False, "kit"), (2, "store", True, "dana")])
        self.assertEqual(svc.show("pharma_trials", 1, ROOT)["path"], str(ROOT / "data" / "datasets" / "pharma_trials" / "descriptor.yaml"))
        self.assertEqual(svc.show("pharma_trials", None, ROOT)["version"], 2)
        with self.assertRaises(svc.NotFound):
            svc.show("pharma_trials", 3, ROOT)
        self.assertIn('COMMENT ON COLUMN "PHARMA"."PHARMA_TRIALS"."PHASE" IS \'role: category (starter kit, descriptor pharma_trials v2)\'', conn.statements)

    def test_approving_the_same_roles_again_is_a_no_op(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
        draft = readings_draft(conn)
        svc.approve(conn, draft, comments=False)
        before = len(conn.statements)
        again = svc.approve(conn, draft, comments=False)
        self.assertEqual((again["unchanged"], again["version"], again["message"]), (True, 1, "v1 is already approved with these roles"))
        self.assertEqual(svc.store_versions("readings"), [1])
        self.assertEqual(len(conn.statements), before, "nothing is asked of the database")
        self.assertEqual(svc.approve(conn, draft, roles={"entity": ["NAME"]}, comments=False)["unchanged"], True)

    def test_a_correction_writes_the_next_version_and_the_old_one_stays_readable(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
        draft = readings_draft(conn)
        svc.approve(conn, draft, comments=False)
        result = svc.approve(conn, draft, roles={"category": ["NAME"], "entity": ["ID"], "text": ["NOTE", "KIND"]}, owner="lee", comments=False)
        self.assertEqual((result["version"], result["owner"], result["roles"]["category"], result["roles"]["text"]), (2, "lee", "NAME", ["NOTE", "KIND"]))
        self.assertEqual(svc.store_versions("readings"), [1, 2])
        self.assertEqual(svc.store_current("readings"), 2)
        v2 = rules.read_descriptor(Path(result["path"]))
        self.assertEqual((v2.evidence["category"]["set_by"], v2.evidence["category"]["column"], v2.evidence["text"]["set_by"]), ("user", "NAME", "user"))
        self.assertEqual(v2.evidence["category"]["type"], "VARCHAR(20) UTF8", "the draft's numbers for the role stay beside the correction")
        self.assertEqual(self.stored("readings", 1)["roles"]["category"]["column"], "KIND")
        self.assertNotEqual(self.stored("readings", 1)["digest"], v2.digest, "another set of role columns: another digest")
        third = svc.approve(conn, svc.resolve_draft("readings")[0], comments=False)
        self.assertEqual((third["unchanged"], third["version"]), (True, 2))

    def test_a_role_the_profiler_listed_as_missing_can_be_set(self):
        columns = [("ID", "DECIMAL(9,0)"), ("NAME", "VARCHAR(100) UTF8"), ("KIND", "VARCHAR(20) UTF8"), ("ALARM", "BOOLEAN"), ("NOTE", "VARCHAR(2000) UTF8"), ("WHEN_TXT", "VARCHAR(30) UTF8")]
        rows = [{k: v for k, v in r.items() if k in dict(columns)} | {"WHEN_TXT": f"day {i}"} for i, r in enumerate(Profiles.rows())]
        conn = FakeConn(columns, rows)
        draft = svc.draft(svc.profile(conn, "LAB.READINGS"), "LAB.READINGS", "readings")
        self.assertEqual([m["role"] for m in draft["missing"]], ["date"])
        result = svc.approve(conn, draft, roles={"date": ["WHEN_TXT"]}, comments=False)
        read = rules.read_descriptor(Path(result["path"]))
        self.assertEqual((read.missing, read.roles["date"][0].column), ((), "WHEN_TXT"))

    def test_bad_roles_are_refused_naming_the_role_and_the_reason(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
        draft = readings_draft(conn)
        with self.assertRaises(svc.Refused) as caught:
            svc.approve(conn, draft, roles={"entity": ["KIND"]}, comments=False)
        self.assertIn("column LAB.READINGS.KIND is assigned to more than one role (entity, category)", str(caught.exception))
        with self.assertRaises(svc.Refused) as caught:
            svc.approve(conn, draft, roles={"label": ["NOPE"]}, comments=False)
        self.assertIn("no column NOPE (the label role)", str(caught.exception))
        self.assertEqual(caught.exception.code, 2)
        bad = dict(draft, roles={})
        with self.assertRaises(svc.Refused) as caught:
            svc.approve(conn, bad, comments=False)
        self.assertIn("the 'entity' role is missing", str(caught.exception))
        self.assertEqual(svc.store_versions("readings"), [], "nothing was written")
        with self.assertRaises(svc.NotFound):
            svc.approve(FakeConn(Profiles.COLUMNS, []), dict(draft, fact_table="LAB.NOPE"), comments=False)
        with self.assertRaises(svc.NotFound) as caught:
            svc.resolve_draft("nowhere", ROOT)
        self.assertIn("exakit describe SCHEMA.TABLE --id nowhere", str(caught.exception))
        with self.assertRaises(svc.Refused):
            svc.resolve_draft("Not An Id", ROOT)

    def test_the_owner_is_the_environment_then_the_os_user_unless_given(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
        draft = dict(readings_draft(conn), owner="someone-else")
        self.assertEqual(svc.approve(conn, draft, comments=False)["owner"], "dana")
        with mock.patch.dict(os.environ, {"EXAKIT_DESCRIPTOR_OWNER": ""}), mock.patch.object(svc.getpass, "getuser", return_value="osuser"):
            self.assertEqual(svc.approve(conn, draft, roles={"entity": ["ID"]}, comments=False)["owner"], "osuser")
        self.assertEqual(svc.approve(conn, draft, roles={"entity": ["NAME"], "category": ["KIND"]}, owner="lee", comments=False)["owner"], "lee")

    def test_a_version_taken_meanwhile_is_retried_once_then_a_conflict(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
        draft = readings_draft(conn)
        folder = self.home / "descriptors" / "readings"
        real = svc.next_version
        collided = []

        def taken(id, root=None):
            number = real(id, root)
            if not collided:                                                                # once: the first retry succeeds
                collided.append(number)
                folder.mkdir(parents=True, exist_ok=True)
                (folder / f"v{number}.yaml").write_text("# someone else\n", encoding="utf-8")   # appears between the count and the create
            return number

        with mock.patch.object(svc, "next_version", side_effect=taken):
            result = svc.approve(conn, draft, comments=False)
        self.assertEqual(result["version"], 2, "v1 was taken, so the retry wrote v2")
        self.assertEqual((folder / "v1.yaml").read_text(), "# someone else\n")
        self.assertEqual(svc.store_current("readings"), 2)

        def always_taken(id, root=None):
            number = real(id, root)
            (folder / f"v{number}.yaml").write_text("# someone else\n", encoding="utf-8")
            return number

        with mock.patch.object(svc, "next_version", side_effect=always_taken):
            with self.assertRaises(svc.Conflict) as caught:
                svc.approve(conn, draft, roles={"entity": ["ID"]}, comments=False)
        self.assertEqual(caught.exception.code, 5)
        self.assertEqual(svc.store_current("readings"), 2, "current is untouched by a failed approve")

    def test_a_draft_file_is_approved_from_its_path(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
        path = self.home / "readings.yaml"
        path.write_text(svc.to_yaml(readings_draft(conn)), encoding="utf-8")
        doc, origin = svc.resolve_draft(str(path))
        self.assertEqual(origin, "file")
        self.assertEqual(svc.approve(conn, doc, comments=False)["version"], 1)
        self.assertEqual(svc.resolve_draft("readings")[1], "store")


class Comments(unittest.TestCase):
    def setUp(self):
        self.folder, patch = kit_home()
        patch.start()
        self.addCleanup(patch.stop)
        self.addCleanup(self.folder.cleanup)

    def test_comment_on_column_keeps_the_existing_comment_and_quotes_it(self):
        existing = {"KIND": "The reading's kind: gas, water or power", "NAME": None, "ID": "Primary key | role: entity (starter kit, descriptor readings v1)"}
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows(), comments=existing)
        result = svc.approve(conn, readings_draft(conn))
        ddl = [s for s in conn.statements if s.startswith("COMMENT")]
        self.assertEqual(ddl, [
            'COMMENT ON COLUMN "LAB"."READINGS"."ID" IS \'Primary key\'',                       # ID lost its role: the old tag goes, the text stays
            'COMMENT ON COLUMN "LAB"."READINGS"."NAME" IS \'role: entity (starter kit, descriptor readings v1)\'',
            'COMMENT ON COLUMN "LAB"."READINGS"."KIND" IS \'The reading\'\'s kind: gas, water or power | role: category (starter kit, descriptor readings v1)\'',
            'COMMENT ON COLUMN "LAB"."READINGS"."TAKEN_ON" IS \'role: date (starter kit, descriptor readings v1)\'',
            'COMMENT ON COLUMN "LAB"."READINGS"."ALARM" IS \'role: label (starter kit, descriptor readings v1)\'',
            'COMMENT ON COLUMN "LAB"."READINGS"."NOTE" IS \'role: text (starter kit, descriptor readings v1)\'',
        ])
        self.assertEqual((result["comments"]["written"], result["comments"]["warnings"]), (ddl, []))
        self.assertEqual(svc._tagged("Trial phase | role: category (starter kit, descriptor pharma_trials v2)", svc.role_tag("category", "pharma_trials", 3)),
                         "Trial phase | role: category (starter kit, descriptor pharma_trials v3)")
        self.assertIsNone(svc._tagged("role: date (starter kit, descriptor x v1)", None))

    def test_a_virtual_table_gets_a_view_in_starter_kit_with_the_comments(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows(2000), virtual=True)
        draft = svc.draft(svc.profile(conn, "VS_LAB.READINGS", sample=300), "VS_LAB.READINGS", "lab-readings")
        result = svc.approve(conn, draft, sample=300)
        ddl = [s for s in conn.statements if not s.startswith("SELECT")]
        self.assertEqual(ddl[0], 'CREATE SCHEMA IF NOT EXISTS "STARTER_KIT"')
        self.assertEqual(ddl[1], 'CREATE OR REPLACE VIEW "STARTER_KIT"."LAB_READINGS_DESCRIBED" ('
                         '"ID", "NAME" COMMENT IS \'role: entity (starter kit, descriptor lab-readings v1)\', '
                         '"KIND" COMMENT IS \'role: category (starter kit, descriptor lab-readings v1)\', '
                         '"TAKEN_ON" COMMENT IS \'role: date (starter kit, descriptor lab-readings v1)\', '
                         '"ALARM" COMMENT IS \'role: label (starter kit, descriptor lab-readings v1)\', '
                         '"NOTE" COMMENT IS \'role: text (starter kit, descriptor lab-readings v1)\', "EMPTY", "SHAPE") '
                         'AS SELECT "ID", "NAME", "KIND", "TAKEN_ON", "ALARM", "NOTE", "EMPTY", "SHAPE" FROM "VS_LAB"."READINGS" '
                         'COMMENT IS \'starter kit: descriptor lab-readings v1 of the virtual table VS_LAB.READINGS; roles: entity=NAME, category=KIND, date=TAKEN_ON, label=ALARM, text=NOTE\'')
        self.assertEqual(len(ddl), 2, "no COMMENT ON COLUMN: Exasol takes a view's comments only in CREATE VIEW")
        self.assertEqual((result["comments"]["view"], result["scope"], result["comments"]["warnings"]), ("STARTER_KIT.LAB_READINGS_DESCRIBED", "sample", []))
        self.assertEqual(rules.read_descriptor(Path(result["path"])).evidence["table"]["digest_scope"], "sample")

    def test_a_failed_comment_is_a_warning_and_the_descriptor_is_approved_all_the_same(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows(), ddl_error=RuntimeError("insufficient privileges for commenting on table LAB.READINGS"))
        result = svc.approve(conn, readings_draft(conn))
        self.assertEqual((result["version"], result["comments"]["written"]), (1, []))
        self.assertEqual(len(result["comments"]["warnings"]), 5)
        self.assertIn("insufficient privileges", result["comments"]["warnings"][0])
        self.assertIn("exakit describe readings --comments", result["comments"]["warnings"][0])
        self.assertEqual(svc.store_current("readings"), 1)
        # --comments writes them again, from the current version
        retry = FakeConn(Profiles.COLUMNS, Profiles.rows())
        again = svc.comments(retry, "readings")
        self.assertEqual((again["version"], len(again["written"]), again["warnings"]), (1, 5, []))
        self.assertIn("role: category (starter kit, descriptor readings v1)", again["written"][1])
        with self.assertRaises(svc.NotFound):
            svc.comments(retry, "nowhere")

    def test_comments_on_a_draft_are_refused(self):
        conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
        folder = Path(os.environ["EXAKIT_HOME"]) / "descriptors" / "readings"
        folder.mkdir(parents=True)
        (folder / "v1.yaml").write_text(svc.to_yaml(readings_draft(conn)), encoding="utf-8")
        (folder / "current").write_text("1\n")
        with self.assertRaises(svc.Refused) as caught:
            svc.comments(conn, "readings")
        self.assertIn("exakit describe readings --approve", str(caught.exception))


class Budget(unittest.TestCase):
    """AC-DS5.5: a virtual table is read no further than the sample - by the profile and by the digest."""

    def test_profiling_and_approving_a_virtual_table_read_at_most_the_sample(self):
        folder, patch = kit_home()
        with folder, patch:
            conn = FakeConn(Profiles.COLUMNS, Profiles.rows(5000), virtual=True)
            draft = svc.draft(svc.profile(conn, "VS_LAB.READINGS", sample=250), "VS_LAB.READINGS", "lab-readings")
            svc.approve(conn, draft, sample=250, comments=False)
        reads = [s for s in conn.statements if '"VS_LAB"."READINGS"' in s and not s.startswith("SELECT COUNT(*) AS N FROM")]
        self.assertEqual(len(reads), 2, "one sample fetch for the profile, one hash over the sample for the digest")
        for sql in reads:
            self.assertIn('FROM "VS_LAB"."READINGS" LIMIT 250', sql)
            self.assertNotIn("RANDOM", sql)
        self.assertEqual(conn.fetched, 500, "250 rows twice; the COUNT(*) statements fetch no row")


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
                                               env={"EXAKIT_MODEL_ID": "", "EXAKIT_PROVIDER_BASE_URL": ""})
            self.assertEqual((code, err), (0, ""))
            doc = json.loads(out)
            self.assertEqual((doc["id"], doc["status"], svc.draft_roles(doc)["category"]), ("lab-readings", "draft", "KIND"))
            self.assertEqual(rules.read_descriptor(target).roles["category"][0].column, "KIND")
            with mock.patch.object(svc, "connect", return_value=mock.Mock(execute=conn.execute, close=mock.Mock())):
                code, out, _err = self.run_main("draft", "LAB.READINGS", env={"EXAKIT_MODEL_ID": "", "EXAKIT_PROVIDER_BASE_URL": ""})
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

    def test_approve_show_versions_and_comments_on_the_command_line(self):
        folder, patch = kit_home()
        with folder, patch:
            conn = FakeConn(Profiles.COLUMNS, Profiles.rows(), comments={"KIND": "the kind"})
            path = Path(folder.name) / "readings.yaml"
            path.write_text(svc.to_yaml(readings_draft(conn)), encoding="utf-8")
            with mock.patch.object(svc, "connect", return_value=conn):
                code, out, err = self.run_main("approve", str(path), "--role", "entity=id", "--owner", "lee", "--json")
                self.assertEqual((code, err), (0, ""))
                result = json.loads(out)
                self.assertEqual((result["version"], result["owner"], result["roles"]["entity"], result["unchanged"]), (1, "lee", "ID", False))
                self.assertIn('COMMENT ON COLUMN "LAB"."READINGS"."KIND" IS \'the kind | role: category (starter kit, descriptor readings v1)\'', result["comments"]["written"])
                code, out, _err = self.run_main("approve", "readings", "--no-comments")
                self.assertEqual(code, 0)
                self.assertEqual(out.strip(), "v1 is already approved with these roles")
                code, out, _err = self.run_main("approve", "readings", "--role", "entity=NAME", "--no-comments")
                self.assertEqual(code, 0)
                self.assertIn("Approved readings v2 (owner dana, digest sha256:", out)
                self.assertIn("Column comments not written (--no-comments).", out)
                code, out, _err = self.run_main("comments", "readings", "--json")
                self.assertEqual((code, json.loads(out)["version"], len(json.loads(out)["written"])), (0, 2, 6))
                code, _out, err = self.run_main("approve", "readings", "--role", "entity=KIND")
                self.assertEqual(code, 2)
                self.assertIn("more than one role (entity, category)", err)
                for argv in (("approve",), ("approve", "readings", "--role", "owner=X"), ("approve", "readings", "--role"), ("approve", "readings", "--owner", ""),
                             ("approve", "readings", "--role", "entity=A", "--role", "entity=B"), ("show", "readings", "--version", "x"), ("versions",), ("show", "Not Id")):
                    with self.subTest(argv=argv):
                        self.assertEqual(self.run_main(*argv)[0], 2)
                code, _out, err = self.run_main("approve", "nowhere")
                self.assertEqual((code, "No descriptor 'nowhere'" in err), (3, True))
                code, _out, err = self.run_main("comments", "nowhere")
                self.assertEqual(code, 3)
                with mock.patch.object(svc, "_write_version", side_effect=svc.Conflict("taken twice")):
                    code, _out, err = self.run_main("approve", "readings", "--role", "entity=ID", "--no-comments")
                self.assertEqual((code, err.strip()), (5, "taken twice"))
            code, out, _err = self.run_main("versions", "readings")
            self.assertEqual(code, 0)
            self.assertRegex(out, r"^  v1   approved  owner lee .*\n\* v2   approved  owner dana")
            code, out, _err = self.run_main("versions", "readings", "--json")
            self.assertEqual([(e["version"], e["current"]) for e in json.loads(out)], [(1, False), (2, True)])
            code, out, _err = self.run_main("show", "readings")
            self.assertEqual(code, 0)
            self.assertIn("version: 2\nstatus: approved\nowner: dana", out)
            code, out, _err = self.run_main("show", "readings", "--version", "1", "--json")
            self.assertEqual((code, json.loads(out)["document"]["roles"]["entity"]["column"], json.loads(out)["owner"]), (0, "ID", "lee"))
            self.assertEqual(self.run_main("show", "readings", "--version", "9")[0], 3)
            code, _out, err = self.run_main("show", "nowhere")
            self.assertEqual(code, 3)
            code, _out, err = self.run_main("approve", "readings", env={"EXAKIT_PYX_DSN": "", "EXAKIT_PYX_PWFILE": ""})
            self.assertEqual(code, 4)


if __name__ == "__main__":
    unittest.main(verbosity=1)
