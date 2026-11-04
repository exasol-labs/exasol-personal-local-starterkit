"""The plain-language notes under a notebook's results (python3 -m unittest tests.test_notebook_readout).

What it pins: result columns are named after the data and never an SQL word; a row is called what the descriptor's
grain says; a note says what one line and each number mean, the overall figure, the highest and lowest groups from
groups big enough to compare, which groups are too small, that a difference is not a cause and where the label comes
from; a trend note and a model note say the same in words, and the model's score is never read as better than it is.
"""
from __future__ import annotations

import io
import sys
import types
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
from exakit_nb import readout  # noqa: E402


class Frame:
    def __init__(self, rows):
        self.rows = rows

    def to_dict(self, orient):
        return list(self.rows)


def dataset(grain="one row per post", label="IS_NEGATIVE"):
    return types.SimpleNamespace(descriptor=types.SimpleNamespace(grain=grain), has=lambda role: label is not None,
                                 col=lambda role: label)


def quiet(call, *args, **kwargs):
    with redirect_stdout(io.StringIO()):
        return call(*args, **kwargs)


class Names(unittest.TestCase):
    def test_result_columns_are_named_after_the_data(self):
        self.assertEqual("IS_NEGATIVE_PCT", readout.name("IS_NEGATIVE", "PCT"))
        self.assertEqual("ORDER_DATE", readout.name('"SALES"."order date"'))
        self.assertEqual("C_2024_TOTAL", readout.name("2024 total"))

    def test_a_row_is_called_what_the_grain_says(self):
        self.assertEqual(("posts", "post", "POSTS"), (readout.noun(dataset()), readout.noun(dataset(), one=True),
                                                      readout.count_name(dataset())))
        self.assertEqual("clients", readout.noun(dataset("one row per client the campaign phoned")))
        self.assertEqual("ROW_COUNT", readout.count_name(dataset(None)), "ROWS is an SQL word")


class Notes(unittest.TestCase):
    ROWS = [{"SOCIAL_NETWORK": "TV", "POSTS": 1234, "IS_NEGATIVE_PCT": 31.0},
            {"SOCIAL_NETWORK": "Twitter", "POSTS": 20111, "IS_NEGATIVE_PCT": 9.1},
            {"SOCIAL_NETWORK": "Radio", "POSTS": 7, "IS_NEGATIVE_PCT": 42.9}]

    def test_a_group_note_reads_the_result_in_words(self):
        text = quiet(readout.note_groups, Frame(self.ROWS), dataset(), "SOCIAL_NETWORK", "POSTS", "IS_NEGATIVE_PCT",
                     overall=(40987, 15.8))
        self.assertIn("one line per SOCIAL_NETWORK. POSTS = how many posts. IS_NEGATIVE_PCT = the % of those posts "
                      "where IS_NEGATIVE is 1.", text)
        self.assertIn("Overall: 15.8% of 40,987 posts have IS_NEGATIVE = 1.", text)
        self.assertIn("Highest: TV, 31.0% of 1,234 posts. Lowest: Twitter, 9.1% of 20,111 posts.", text,
                      "Radio's 42.9% is never the highest: 7 posts are too few to compare")
        self.assertIn("Too few posts to trust their %: Radio (7).", text)
        self.assertIn("Counts, not causes", text)
        self.assertIn("Check how it was produced", text)

    def test_two_columns_and_no_label(self):
        rows = [{"E": "a.com", "C": "TV", "POSTS": 50}, {"E": "b.com", "C": "Web", "POSTS": 90}]
        text = quiet(readout.note_groups, Frame(rows), dataset(label=None), ("E", "C"), "POSTS")
        self.assertIn("one line per E and C", text)
        self.assertIn("Largest: b.com / Web with 90 posts.", text)
        self.assertNotIn("%", text)

    def test_trend_and_model_notes(self):
        rows = [{"MONTH_START": "2024-01-01", "POSTS": 400, "IS_NEGATIVE_PCT": 12.0},
                {"MONTH_START": "2024-02-01", "POSTS": 900, "IS_NEGATIVE_PCT": 20.5}]
        text = quiet(readout.note_trend, Frame(rows), dataset(), "MONTH_START", "POSTS", "IS_NEGATIVE_PCT")
        self.assertIn("one line per month (MONTH_START is its first day)", text)
        self.assertIn("Busiest: 2024-02-01 with 900 posts.", text)
        self.assertIn("Highest %: 2024-02-01 (20.5%). Lowest %: 2024-01-01 (12.0%).", text)
        self.assertIn("not why", text)
        weak = quiet(readout.note_model, 0.55, dataset(), 20000, 0.158)
        self.assertIn("55% of the time (50% is guessing): about as good as guessing", weak)
        self.assertIn("too good to be true", quiet(readout.note_model, 0.97, dataset(), 20000))


if __name__ == "__main__":
    unittest.main()
