"""Execute the shipped Explore text cell: endpoint use is an explicit notebook choice."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import types
import unittest
from pathlib import Path
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("story_notebook_builder", ROOT / "tools/notebooks.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class TextFrame(dict):
    def __len__(self):
        return len(self["TEXT_"])


class OptionalThemesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = ROOT / "notebook/notebooks/data-scientist/01_explore.py"
        cells = json.loads(builder.build(path))["cells"]
        code = ["".join(c["source"]) for c in cells if c["cell_type"] == "code"]
        cls.settings = next(c for c in code if c.startswith("DATASET = "))
        cls.themes = next(c for c in code if c.startswith("SAMPLE_TEXTS = "))

    def run_cell(self, *, enable=None, configured=True, allow=True, roles=("category", "text", "label", "date")):
        frame = TextFrame(LABEL_=[1, 0], TEXT_=["First description", "Second description"])
        endpoint = Mock(return_value=(Mock(), "configured-model") if configured else None)
        helper = types.SimpleNamespace(sql=Mock(return_value=frame), show_sql=Mock(), model_client=endpoint,
                                       confirm_send=Mock(return_value=allow), themes=Mock(return_value="the themes"))
        roles = set(roles)
        namespace = {"nb": helper, "conn": object(), "missing_line": "",
                     "ENTITY": None, "TEXT": '"DESCRIPTION"', "DATE": '"DATE"' if "date" in roles else None,
                     "LABEL": '"LABEL"' if "label" in roles else None,
                     "ds": types.SimpleNamespace(has=lambda role: role in roles,
                                                 col=lambda role: f'"{role.upper()}"', fact_table="EXAMPLE.RECORDS")}
        exec(self.settings, namespace)
        if enable is not None:
            namespace["USE_AI_THEMES"] = enable
        with contextlib.redirect_stdout(io.StringIO()):
            exec(self.themes, namespace)
        return namespace, helper

    def test_default_path_shows_the_sample_and_never_asks_for_an_endpoint(self):
        namespace, helper = self.run_cell()
        helper.model_client.assert_not_called()
        helper.themes.assert_not_called()
        helper.sql.assert_called_once()  # the SQL sample still runs
        self.assertIsNone(namespace["themes"])

    def test_opt_in_sorts_both_sides_in_one_helper_call(self):
        namespace, helper = self.run_cell(enable=True)
        helper.model_client.assert_called_once()
        helper.themes.assert_called_once()
        conn, ds, sample, endpoint = helper.themes.call_args.args
        self.assertIs(sample, helper.sql.return_value)
        self.assertEqual("configured-model", endpoint[1])
        self.assertEqual(helper.sql.call_args.args[1], helper.themes.call_args.kwargs["sql"], "the trace names the SQL")
        self.assertEqual("the themes", namespace["themes"])

    def test_the_sample_is_the_newest_texts_on_each_side_of_the_label(self):
        _, helper = self.run_cell()
        sql = helper.sql.call_args.args[1]
        self.assertIn('SELECT "LABEL" AS LABEL_, "DESCRIPTION" AS TEXT_', sql)
        self.assertIn('AND "LABEL" IS NOT NULL', sql)
        self.assertIn('QUALIFY ROW_NUMBER() OVER (PARTITION BY "LABEL" ORDER BY "DATE" DESC) <= 20', sql)

    def test_without_a_label_or_date_it_is_one_side(self):
        _, helper = self.run_cell(roles=("text",))
        sql = helper.sql.call_args.args[1]
        self.assertIn("SELECT NULL AS LABEL_", sql)
        self.assertIn("QUALIFY ROW_NUMBER() OVER (ORDER BY 1) <= 20", sql)
        self.assertNotIn("IS NOT NULL", sql)

    def test_missing_endpoint_or_a_declined_sample_calls_no_model(self):
        for kwargs in ({"configured": False}, {"allow": False}):
            with self.subTest(**kwargs):
                namespace, helper = self.run_cell(enable=True, **kwargs)
                helper.themes.assert_not_called()
                self.assertIsNone(namespace["themes"])


if __name__ == "__main__":
    unittest.main()
