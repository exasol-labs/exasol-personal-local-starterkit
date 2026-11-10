"""exakit_nb.themes: what the texts on each side of the label are about (python3 -m unittest tests.test_notebook_themes).

What it pins, with a fake model and a fake trace: one call per side, named after it when traced; the model's JSON is
read even inside code fences or with markdown, a bad number or a repeat is dropped, an unreadable answer is a row that
says so; the table is theme, count, share and example per side; the trace gets the valid_json and texts_placed scores;
the note says what the table shows and that it is a sample to check.
"""
from __future__ import annotations

import contextlib
import io
import json
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
import exakit_nb  # noqa: E402
module = sys.modules["exakit_nb.themes"]   # the module (exakit_nb.themes is the function)


def reply(content):
    return types.SimpleNamespace(choices=[types.SimpleNamespace(message=types.SimpleNamespace(content=content))])


class Sample:
    def __init__(self, rows):
        self.rows = rows

    def to_dict(self, orient):
        return list(self.rows)


DS = types.SimpleNamespace(descriptor=types.SimpleNamespace(grain="one row per post"), has=lambda role: True,
                           col=lambda role: "IS_NEGATIVE")
SAMPLE = Sample([{"LABEL_": 1, "TEXT_": "My brother is dying"}, {"LABEL_": 1, "TEXT_": "Chemo again, so tired"},
                 {"LABEL_": 0, "TEXT_": "New study on early detection"}])


class Parse(unittest.TestCase):
    def test_fences_markdown_bad_numbers_and_repeats(self):
        found, ok = module.parse('```json\n{"themes": [{"theme": "**Grief**", "texts": [1, 1, 9]},'
                                 ' {"theme": "Treatment", "texts": ["2", 1]}]}\n```', 2)
        self.assertTrue(ok)
        self.assertEqual([("Grief", [1]), ("Treatment", [2])], found)
        self.assertEqual(([], False), module.parse("Sorry, I cannot help with that.", 2))


class Themes(unittest.TestCase):
    def run_themes(self, answers, traced=True):
        client = mock.Mock()
        client.chat.completions.create.side_effect = [reply(a) for a in answers]
        span = mock.Mock() if traced else None

        @contextlib.contextmanager
        def trace(conn, name, **kwargs):
            self.assertEqual("explore-themes", name)
            yield span

        with mock.patch.object(exakit_nb, "trace", trace), contextlib.redirect_stdout(io.StringIO()) as out, \
                mock.patch.dict(sys.modules, {"pandas": None}):
            table = module.themes(object(), DS, SAMPLE, (client, "claude-x"), sql="SELECT 1")
        return table, client, span, out.getvalue()

    def test_one_call_per_side_a_table_scores_and_a_note(self):
        table, client, span, out = self.run_themes([
            json.dumps({"themes": [{"theme": "Grief", "texts": [1]}, {"theme": "Treatment fatigue", "texts": [2]}]}),
            json.dumps({"themes": [{"theme": "Research news", "texts": [1]}]})])
        names = [call.kwargs["name"] for call in client.chat.completions.create.call_args_list]
        self.assertEqual(["themes where IS_NEGATIVE = 1", "themes where IS_NEGATIVE = 0"], names)
        self.assertEqual([(1, "Grief", 1, 50.0), (1, "Treatment fatigue", 1, 50.0), (0, "Research news", 1, 100.0)],
                         [(r["IS_NEGATIVE"], r["THEME"], r["POSTS"], r["SHARE_PCT"]) for r in table])
        self.assertEqual("My brother is dying", table[0]["EXAMPLE"])
        scores = {call.kwargs["name"]: call.kwargs["value"] for call in span.score_trace.call_args_list}
        self.assertEqual({"valid_json": 1.0, "texts_placed": 1.0}, scores)
        self.assertIn("(2 with IS_NEGATIVE = 1, 1 with IS_NEGATIVE = 0)", out)
        self.assertIn("A theme found only where IS_NEGATIVE is 1 is the clue", out)
        self.assertIn("not all of them", out)
        self.assertIn('the trace "explore-themes"', out)

    def test_an_unreadable_answer_is_said_and_scored(self):
        table, client, span, out = self.run_themes(["no json here", json.dumps({"themes": [{"theme": "News", "texts": [1]}]})])
        self.assertEqual("(the answer could not be read)", table[0]["THEME"])
        scores = {call.kwargs["name"]: call.kwargs["value"] for call in span.score_trace.call_args_list}
        self.assertEqual(0.5, scores["valid_json"])

    def test_untraced_calls_carry_no_langfuse_name(self):
        _, client, _, out = self.run_themes(['{"themes": [{"theme": "A", "texts": [1, 2]}]}',
                                             '{"themes": [{"theme": "B", "texts": [1]}]}'], traced=False)
        self.assertNotIn("name", client.chat.completions.create.call_args.kwargs)
        self.assertNotIn("In Langfuse", out)
        self.assertIsNone(module.themes(object(), DS, SAMPLE, None))


if __name__ == "__main__":
    unittest.main()
