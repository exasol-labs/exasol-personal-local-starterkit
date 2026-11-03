"""Steps 1-3 of the descriptor plan: the role rules with every threshold pinned, the profile computed from rows,
and a deterministic draft (DS2.3, DS5.1's determinism half)."""

from __future__ import annotations

import datetime as dt
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "setup" / "lib"))
from descriptor import draft, profile, roles  # noqa: E402


def column(kind: str = "string", rows: int = 1000, non_null: int | None = None, distinct: int = 10, **extra) -> dict:
    found = {"column": extra.pop("name", "C"), "type": extra.pop("type", kind.upper()), "kind": kind, "rows": rows,
             "non_null": rows if non_null is None else non_null, "approx_distinct": distinct}
    found.update(extra)
    return found


def classify(**kw) -> dict:
    return roles.classify(column(**kw))


class ThresholdTest(unittest.TestCase):
    """Each constant, pinned at its boundary."""

    def test_the_constants(self):
        self.assertEqual((0.90, 0.98, 40, 0.5, 50, 0.02, 0.9, 0.10),
                         (roles.SENSITIVE_SHARE, roles.DATE_SHARE, roles.TEXT_AVG_LENGTH, roles.TEXT_DISTINCT_RATIO,
                          roles.CATEGORY_DISTINCT, roles.CATEGORY_RATIO, roles.IDENTIFIER_RATIO, roles.NEAR))
        self.assertEqual(8, len(roles.ROLES))

    def test_sensitive_at_90_percent(self):
        self.assertTrue(classify(distinct=800, patterns={"email": 900}).get("sensitive"))
        self.assertFalse(classify(distinct=800, patterns={"email": 899}).get("sensitive"))

    def test_date_strings_at_98_percent(self):
        self.assertEqual("time", classify(distinct=900, patterns={"iso": 980})["role"])
        self.assertNotEqual("time", classify(distinct=900, patterns={"iso": 979})["role"])

    def test_text_at_avg_40_and_half_distinct(self):
        self.assertEqual("text", classify(distinct=500, avg_length=40)["role"])
        self.assertNotEqual("text", classify(distinct=500, avg_length=39.9)["role"])
        self.assertNotEqual("text", classify(distinct=499, avg_length=80)["role"])

    def test_category_at_50_distinct_and_2_percent(self):
        self.assertEqual("category", classify(kind="integer", distinct=50)["role"])
        self.assertEqual("measure", classify(kind="integer", distinct=51)["role"])
        self.assertEqual("category", classify(rows=10000, distinct=200)["role"])
        self.assertEqual("other", classify(rows=10000, distinct=201)["role"])

    def test_string_identifier_at_90_percent_distinct(self):
        self.assertEqual("identifier", classify(non_null=990, distinct=900)["role"])
        self.assertEqual("other", classify(non_null=990, distinct=899)["role"])

    def test_low_confidence_within_10_percent(self):
        self.assertEqual("low", classify(kind="integer", distinct=46)["confidence"])
        self.assertEqual("high", classify(kind="integer", distinct=44)["confidence"])
        self.assertEqual("low", classify(distinct=500, avg_length=43)["confidence"])
        self.assertEqual("high", classify(distinct=600, avg_length=45)["confidence"])
        self.assertEqual("low", classify(distinct=900, patterns={"iso": 981})["confidence"])
        self.assertEqual("high", classify(distinct=900, patterns={"iso": 1000})["confidence"])


class RuleOrderTest(unittest.TestCase):
    def test_all_null_is_other(self):
        self.assertEqual({"role": "other", "confidence": "high", "evidence": "every value is null"},
                         classify(non_null=0, distinct=0))

    def test_unique_timestamps_are_time_not_key(self):
        self.assertEqual("time", classify(kind="timestamp", distinct=1000, exact_distinct=1000)["role"])

    def test_unique_free_text_is_text_not_key(self):
        self.assertEqual("text", classify(distinct=1000, exact_distinct=1000, avg_length=200)["role"])

    def test_key_needs_the_exact_count(self):
        self.assertEqual("key", classify(kind="integer", distinct=1000, exact_distinct=1000)["role"])
        self.assertNotEqual("key", classify(kind="integer", distinct=1000)["role"])
        self.assertNotEqual("key", classify(kind="decimal", distinct=1000, exact_distinct=1000)["role"])

    def test_a_unique_email_is_a_sensitive_key(self):
        found = classify(distinct=1000, exact_distinct=1000, patterns={"email": 1000})
        self.assertEqual(("key", True), (found["role"], found["sensitive"]))

    def test_sensitive_beats_category_however_few_values(self):
        found = classify(distinct=30, patterns={"email": 1000})
        self.assertEqual(("identifier", True), (found["role"], found["sensitive"]))

    def test_flag_takes_the_exact_two_values(self):
        found = classify(distinct=2, top=[["Yes", 978], ["No", 22]])
        self.assertEqual(("flag", "Yes 97.8%, No 2.2%"), (found["role"], found["evidence"]))
        self.assertEqual("category", classify(distinct=2, top=[["Yes", 978], ["No", 20]])["role"])

    def test_slash_dates_tell_their_order_or_stay_low(self):
        self.assertIn("DD/MM", classify(distinct=900, patterns={"slash": 1000, "slash_first_over_12": 40})["evidence"])
        self.assertIn("MM/DD", classify(distinct=900, patterns={"slash": 1000, "slash_second_over_12": 40})["evidence"])
        self.assertEqual("low", classify(distinct=900, patterns={"slash": 1000})["confidence"])
        self.assertNotEqual("time", classify(distinct=900, patterns={"slash": 1000, "slash_first_over_12": 1,
                                                                        "slash_second_over_12": 1})["role"])

    def test_name_hints_settle_only_the_integer_line(self):
        self.assertEqual(["customer", "no"], roles.name_tokens("CustomerNo"))
        self.assertEqual(["customer", "no"], roles.name_tokens("CUSTOMER_NO"))
        self.assertEqual("identifier", classify(kind="integer", distinct=400, name="CUSTOMER_NO")["role"])
        self.assertEqual("measure", classify(kind="integer", distinct=400, name="PAID_AMOUNT")["role"])
        self.assertEqual("measure", classify(kind="decimal", distinct=400, name="CUSTOMER_ID")["role"])
        self.assertEqual("measure", classify(kind="integer", distinct=400, name="NOTICE")["role"])   # no whole token


COLUMNS = [("ORDER_ID", "DECIMAL(18,0)"), ("ORDERED_AT", "TIMESTAMP"), ("SHIPPED_ON", "VARCHAR(10) UTF8"),
           ("DELIVERED", "VARCHAR(10) UTF8"), ("NOTE", "VARCHAR(400) UTF8"), ("CUSTOMER_EMAIL", "VARCHAR(100) UTF8"),
           ("ZIP", "VARCHAR(5) UTF8"), ("CHANNEL", "VARCHAR(10) UTF8"), ("PAID", "BOOLEAN"), ("RETURNED", "VARCHAR(1) UTF8"),
           ("AMOUNT", "DECIMAL(12,2)"), ("QUANTITY", "DECIMAL(9,0)"), ("STORE_ID", "DECIMAL(9,0)"),
           ("EMPTY", "VARCHAR(20) UTF8"), ("SKU", "VARCHAR(20) UTF8")]
EXPECTED = {"ORDER_ID": "key", "ORDERED_AT": "time", "SHIPPED_ON": "time", "DELIVERED": "time", "NOTE": "text",
            "CUSTOMER_EMAIL": "identifier", "ZIP": "identifier", "CHANNEL": "category", "PAID": "flag",
            "RETURNED": "flag", "AMOUNT": "measure", "QUANTITY": "measure", "STORE_ID": "identifier",
            "EMPTY": "other", "SKU": "identifier"}


def synthetic_rows(n: int = 300) -> list[list]:
    start = dt.datetime(2024, 1, 1, 8, 0, 0)
    words = ["late", "parcel", "damaged", "refund", "courier", "box", "label", "address", "weekend", "invoice"]
    rows = []
    for i in range(n):
        day = dt.date(2024, 1, 1) + dt.timedelta(days=i % 200)
        rows.append([
            1000 + i, (start + dt.timedelta(minutes=37 * i)).isoformat(sep=" "), day.isoformat(),
            (day + dt.timedelta(days=3)).strftime("%d.%m.%Y"),
            f"Order {i}: " + " ".join(words[(i * k) % 10] for k in range(1, 9)) + f" ref {i * 7}",
            f"customer{i % 120}@example.org", f"{10000 + (i % 80) * 7:05d}", ["web", "shop", "phone", "app"][i % 4],
            "true" if i % 3 else "false", "Y" if i % 10 == 0 else "N", round(5 + (i * 13.37) % 400, 2),
            1 + (i * 7) % 90, 1 + (i * 11) % 60, None, None if i % 50 == 0 else f"SKU-{i:05d}"])
    return rows


class SyntheticTableTest(unittest.TestCase):
    """DS2.3: every role on one table, from its profile."""

    @classmethod
    def setUpClass(cls):
        cls.profile = profile.profile_rows(COLUMNS, synthetic_rows(), "SHOP.ORDERS")
        cls.found = {c["column"]: roles.classify(c) for c in cls.profile["columns"]}

    def test_every_column_gets_its_role(self):
        self.assertEqual(EXPECTED, {name: entry["role"] for name, entry in self.found.items()})

    def test_the_email_and_the_postcode_are_sensitive(self):
        self.assertEqual({"CUSTOMER_EMAIL", "ZIP"}, {n for n, e in self.found.items() if e.get("sensitive")})

    def test_a_sensitive_column_keeps_counts_only(self):
        email = next(c for c in self.profile["columns"] if c["column"] == "CUSTOMER_EMAIL")
        self.assertNotIn("top", email)
        self.assertNotIn("min", email)

    def test_an_integer_id_that_looks_like_a_count_is_an_identifier_by_name(self):
        self.assertEqual(("identifier", "high"), (self.found["STORE_ID"]["role"], self.found["STORE_ID"]["confidence"]))
        self.assertEqual(("measure", "low"), (self.found["QUANTITY"]["role"], self.found["QUANTITY"]["confidence"]))

    def test_date_strings_carry_their_range(self):
        self.assertIn("2024-01-04 to", self.found["DELIVERED"]["evidence"])

    def test_the_digest_follows_names_and_types_in_order(self):
        self.assertEqual(self.profile["source"]["schema_digest"],
                         profile.profile_rows(COLUMNS, [], "X.Y")["source"]["schema_digest"])
        swapped = [COLUMNS[1], COLUMNS[0], *COLUMNS[2:]]
        self.assertNotEqual(self.profile["source"]["schema_digest"],
                            profile.profile_rows(swapped, [], "X.Y")["source"]["schema_digest"])


class DraftTest(unittest.TestCase):
    def setUp(self):
        self.profile = profile.profile_rows(COLUMNS, synthetic_rows(), "SHOP.ORDERS")

    def test_slots_key_widest_time_longest_text_and_no_target(self):
        doc = draft.draft(self.profile, "shop_orders")
        self.assertEqual({"key": "ORDER_ID", "time": "SHIPPED_ON", "text": "NOTE", "target": None, "category": "CHANNEL",
                          "entity": None}, doc["slots"])
        self.assertEqual("set by the user; never drafted", doc["slot_evidence"]["target"])

    def test_the_same_profile_gives_the_same_bytes(self):
        first = draft.to_yaml(draft.draft(self.profile, "shop_orders"))
        again = draft.to_yaml(draft.draft(profile.profile_rows(COLUMNS, synthetic_rows(), "SHOP.ORDERS"), "shop_orders"))
        self.assertEqual(first, again)
        self.assertNotIn(str(dt.date.today().year), first.split("columns:")[0].replace("2024", ""))

    def test_columns_in_table_order_and_no_key_says_why(self):
        doc = draft.draft(profile.profile_rows(COLUMNS[1:], [r[1:] for r in synthetic_rows()], "SHOP.ORDERS"), "x")
        self.assertEqual([name for name, _ in COLUMNS[1:]], list(doc["columns"]))
        self.assertEqual((None, "no single unique column"), (doc["slots"]["key"], doc["slot_evidence"]["key"]))

    def test_the_identifier_named_key_comes_first(self):
        cols = [("SEQ", "DECIMAL(9,0)"), ("ORDER_NO", "DECIMAL(9,0)")]
        doc = draft.draft(profile.profile_rows(cols, [[i, 5000 + i] for i in range(100)], "S.T"), "x")
        self.assertEqual("ORDER_NO", doc["slots"]["key"])

    def test_a_virtual_table_says_first_10000_rows(self):
        found = profile.profile_rows(COLUMNS, synthetic_rows(), "S.T", virtual=True)
        self.assertEqual("first 10,000 rows", draft.draft(found, "x")["source"]["profiled"])

    def test_yaml_quotes_every_string(self):
        text = draft.to_yaml(draft.draft(self.profile, "shop_orders"))
        self.assertIn('"RETURNED": {role: "flag", confidence: "high", evidence: "N 90%, Y 10%"}', text)
        self.assertIn("  target: null", text)


class GroupingSlotTest(unittest.TestCase):
    COLUMNS = [("ID", "DECIMAL(9,0)"), ("REGION", "VARCHAR(10) UTF8"), ("SHOP", "VARCHAR(30) UTF8"),
               ("EMAIL", "VARCHAR(60) UTF8")]

    def test_entity_has_the_most_values_and_category_is_another_small_grouping(self):
        rows = [[i, ["north", "south", "east"][i % 3], f"shop {i % 70}", f"u{i % 90}@example.org"] for i in range(400)]
        doc = draft.draft(profile.profile_rows(self.COLUMNS, rows, "S.T"), "x")
        self.assertEqual(("SHOP", "REGION"), (doc["slots"]["entity"], doc["slots"]["category"]))

    def test_a_sensitive_column_is_never_a_grouping(self):
        rows = [[i, "north", "x", f"u{i % 300}@example.org"] for i in range(400)]
        doc = draft.draft(profile.profile_rows(self.COLUMNS, rows, "S.T"), "x")
        self.assertNotIn("EMAIL", (doc["slots"]["entity"], doc["slots"]["category"]))


class SqlTest(unittest.TestCase):
    """The statements profile() sends, with a fake connection answering them."""

    def test_one_statement_per_40_columns_every_identifier_quoted(self):
        sent = []
        shape = [{"COLUMN_NAME": f"col {i}", "COLUMN_TYPE": "VARCHAR(10) UTF8", "IS_VIRTUAL": 0} for i in range(85)]

        def run(sql):
            sent.append(sql)
            if "EXA_ALL_COLUMNS" in sql:
                return shape
            if "GROUPING SETS" in sql:
                return []
            return [{"N": 0}]

        found = profile.profile(None, "S.T", run=run)
        batches = [s for s in sent if "APPROXIMATE_COUNT_DISTINCT" in s]
        self.assertEqual(3, len(batches))
        self.assertIn('COUNT("col 0")', batches[0])
        self.assertIn("REGEXP_LIKE '\\d{4}-\\d{2}-\\d{2}.*'", batches[0])
        self.assertEqual(len(sent), len(found["statements"]))

    def test_a_virtual_table_is_read_as_a_prefix(self):
        sent = []

        def run(sql):
            sent.append(sql)
            if "EXA_ALL_COLUMNS" in sql:
                return [{"COLUMN_NAME": "A", "COLUMN_TYPE": "DECIMAL(9,0)", "IS_VIRTUAL": 1}]
            return [] if "GROUPING SETS" in sql else [{"N": 0}]

        profile.profile(None, "VS.T", run=run)
        self.assertTrue(all('(SELECT * FROM "VS"."T" LIMIT 10000)' in s for s in sent[1:]))


if __name__ == "__main__":
    unittest.main()
