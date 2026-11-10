"""The approve step's look at the data (setup/lib/descriptor/review.py): a key that repeats or has gaps and a target
that is not two-valued are refused; a column that gives the target away and the low-confidence roles nobody changed
are warned about, and the approval goes through. The database is the flow tests' stand-in, answering from rows."""

from __future__ import annotations

import datetime as dt
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "setup" / "lib"), str(ROOT / "tools"), str(ROOT / "tests")]
from descriptor import draft, flow, profile, review  # noqa: E402
from test_descriptor_flow import Database  # noqa: E402

COLUMNS = [("ORDER_ID", "DECIMAL(9,0)"), ("ORDERED_ON", "DATE"), ("CHANNEL", "VARCHAR(10) UTF8"),
           ("STATUS", "VARCHAR(12) UTF8"), ("STORE", "DECIMAL(2,0)"), ("CANCELLED", "DECIMAL(1,0)")]


def rows(n: int = 400) -> list[list]:
    found = []
    for i in range(n):
        cancelled = 1 if i % 5 == 0 else 0
        # STATUS is written after the outcome: 'Cancelled' exactly when the order was.
        found.append([i, (dt.date(2025, 1, 1) + dt.timedelta(days=i % 60)).isoformat(), ["web", "shop", "app"][i % 3],
                      "Cancelled" if cancelled else ["Shipped", "Delivered"][i % 2], 1 + i % 12, cancelled])
    return found


class ReviewTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.db = Database(COLUMNS, rows())
        patcher = mock.patch.object(profile, "profile", side_effect=lambda conn, table, *, run=None:
                                    profile.profile_rows(self.db.columns, self.db.data, table))
        patcher.start()
        self.addCleanup(patcher.stop)

    def drafted(self, **slots) -> dict:
        doc = flow.describe(self.db.run, "shop.orders", home=Path(self.temp.name))["doc"]
        return draft.with_slots(doc, **slots)

    def approve(self, doc) -> dict:
        return flow.approve(self.db.run, self.db.execute, doc, home=Path(self.temp.name), owner="dana", publish=False)

    def test_a_column_that_gives_the_target_away_is_warned_about_and_the_approval_stands(self):
        doc = self.drafted(target="CANCELLED")
        self.assertEqual(["STATUS gives CANCELLED away: CANCELLED is '1' whenever STATUS is 'Cancelled'"],
                         review.leaks(self.db.run, doc))
        result = self.approve(doc)
        self.assertEqual("approved", result["status"])
        self.assertIn("STATUS gives CANCELLED away: CANCELLED is '1' whenever STATUS is 'Cancelled'", result["warnings"])

    def test_the_low_confidence_roles_nobody_changed_are_named(self):
        doc = self.drafted(target="CANCELLED")
        self.assertEqual("low", doc["columns"]["STORE"]["confidence"])            # twelve values, nothing in its name
        warning = next(w for w in self.approve(doc)["warnings"] if "low confidence" in w)
        self.assertIn("STORE (category: 12 distinct)", warning)
        doc["columns"]["STORE"] = dict(doc["columns"]["STORE"], role="category", confidence="high", evidence="set by you")
        self.assertEqual([], review.unreviewed(doc))

    def test_a_key_that_repeats_is_refused(self):
        self.db.data[1][0] = 0
        doc = self.drafted(key="ORDER_ID")
        doc["columns"]["ORDER_ID"]["role"] = "key"
        with self.assertRaisesRegex(ValueError, r"slots.key: ORDER_ID repeats \(399 values in 400 rows\)"):
            self.approve(doc)

    def test_a_key_with_a_gap_is_refused(self):
        self.db.data[3][0] = None
        doc = self.drafted(key="ORDER_ID")
        doc["columns"]["ORDER_ID"]["role"] = "key"
        with self.assertRaisesRegex(ValueError, r"slots.key: ORDER_ID is empty in 1 of 400 rows"):
            self.approve(doc)

    def test_a_target_that_is_not_two_valued_is_refused(self):
        doc = self.drafted(target="CHANNEL", category=None)
        with self.assertRaisesRegex(ValueError, r"slots.target: CHANNEL holds 3 values; a target is a yes/no outcome"):
            self.approve(doc)

    def test_without_a_target_only_the_key_is_counted(self):
        doc = self.drafted()
        self.assertEqual({"refused": [], "leaks": []}, {k: v for k, v in review.review(self.db.run, doc).items()
                                                        if k != "unreviewed"})
        self.assertFalse(any("GROUPING SETS" in s for s in self.db.sent))


if __name__ == "__main__":
    unittest.main()
