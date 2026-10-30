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

    def run_cell(self, *, enable=None, configured=True, allow=True, entity=True):
        frame = TextFrame(TEXT_=["First description", "Second description"])
        client = Mock()
        client.chat.completions.create.return_value = types.SimpleNamespace(
            choices=[types.SimpleNamespace(message=types.SimpleNamespace(content="A suggested theme"))])
        endpoint = Mock(return_value=(client, "configured-model") if configured else None)
        helper = types.SimpleNamespace(sql=Mock(return_value=frame), show_sql=Mock(), model_client=endpoint,
                                       confirm_send=Mock(return_value=allow), trace=lambda *a, **k: contextlib.nullcontext())
        roles = {"category", "text"} | ({"entity"} if entity else set())
        namespace = {"nb": helper, "conn": object(), "ENTITY": '"COMPANY"' if entity else None, "TEXT": '"DESCRIPTION"',
                     "ds": types.SimpleNamespace(has=lambda role: role in roles,
                                                 col=lambda role: f'"{role.upper()}"', fact_table="EXAMPLE.RECORDS")}
        exec(self.settings, namespace)
        if enable is not None:
            namespace["USE_AI_THEMES"] = enable
        with contextlib.redirect_stdout(io.StringIO()):
            exec(self.themes, namespace)
        return frame, helper, client

    def test_default_path_does_not_request_an_endpoint_even_when_one_is_configured(self):
        frame, helper, client = self.run_cell()
        helper.model_client.assert_not_called()
        client.chat.completions.create.assert_not_called()
        self.assertNotIn("THEME", frame)
        helper.sql.assert_called_once()  # the SQL sample still runs

    def test_explicit_opt_in_summarises_each_selected_description(self):
        frame, helper, client = self.run_cell(enable=True)
        helper.model_client.assert_called_once()
        self.assertEqual(client.chat.completions.create.call_count, 2)
        self.assertEqual(frame["THEME"], ["A suggested theme", "A suggested theme"])
        self.assertEqual(client.chat.completions.create.call_args.kwargs["model"], "configured-model")

    def test_missing_endpoint_leaves_the_sql_sample_usable(self):
        frame, helper, client = self.run_cell(enable=True, configured=False)
        self.assertEqual(frame["TEXT_"], ["First description", "Second description"])
        client.chat.completions.create.assert_not_called()

    def test_declined_sample_does_not_call_the_model(self):
        frame, helper, client = self.run_cell(enable=True, allow=False)
        client.chat.completions.create.assert_not_called()
        self.assertNotIn("THEME", frame)

    def test_text_sample_without_entity_uses_sql_null(self):
        _, helper, _ = self.run_cell(entity=False)
        sql = helper.sql.call_args.args[1]
        self.assertIn("SELECT NULL AS ENTITY", sql)
        self.assertIn('ORDER BY "DESCRIPTION"', sql)


if __name__ == "__main__":
    unittest.main()
