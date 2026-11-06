"""The optional settings cell (exakit_nb.setup_env): the model, Langfuse and MLflow set from a notebook, the keys asked
for in a hidden prompt and kept in the kernel's environment only. No network, no real key."""

from __future__ import annotations

import contextlib
import io
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
import exakit_nb as nb  # noqa: E402
from exakit_nb import setup_env  # noqa: E402

SOURCES = ROOT / "notebook" / "notebooks"
KEY = "sk-test-0123456789abcdef"


class Prompts:
    """Answers the hidden prompts in order and remembers what was asked."""

    def __init__(self, *answers: str):
        self.answers, self.asked = list(answers), []

    def __call__(self, prompt: str) -> str:
        self.asked.append(prompt)
        return self.answers.pop(0)


def quiet(call):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        result = call()
    return result, out.getvalue()


class SetupEnvTest(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, {}, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_left_empty_the_cell_changes_nothing_and_asks_nothing(self):
        ask = Prompts()
        (summary, out) = quiet(lambda: nb.use_model("", "", "", ask=ask))
        self.assertEqual([], ask.asked)
        self.assertEqual({}, dict(os.environ))
        self.assertFalse(summary["model"] or summary["tracing"])
        self.assertIn("model: off", out)
        (_, out) = quiet(lambda: nb.use_mlflow("", False, ask=ask))
        self.assertEqual({}, dict(os.environ))
        self.assertIn("the kit's own MLflow", out)

    def test_the_model_is_set_and_its_key_asked_for_never_shown(self):
        ask = Prompts(KEY)
        (summary, out) = quiet(lambda: nb.use_model("claude-opus-5-5", "https://api.anthropic.com/v1/", ask=ask))
        self.assertEqual(1, len(ask.asked))
        self.assertIn("hidden", ask.asked[0])
        self.assertEqual(("claude-opus-5-5", "https://api.anthropic.com/v1/", KEY),
                         (os.environ["EXAKIT_MODEL_ID"], os.environ["EXAKIT_PROVIDER_BASE_URL"],
                          os.environ["EXAKIT_PROVIDER_API_KEY"]))
        self.assertTrue(summary["model"])
        self.assertIn("API key set", out)
        self.assertNotIn(KEY, out + repr(summary))

    def test_a_key_already_set_is_not_asked_again_unless_the_endpoint_changes(self):
        os.environ.update(EXAKIT_MODEL_ID="m", EXAKIT_PROVIDER_BASE_URL="https://a.example/v1/",
                          EXAKIT_PROVIDER_API_KEY="from-the-shell")
        ask = Prompts()
        quiet(lambda: nb.use_model("m", "https://a.example/v1/", ask=ask))
        self.assertEqual(([], "from-the-shell"), (ask.asked, os.environ["EXAKIT_PROVIDER_API_KEY"]))
        ask = Prompts("new-key")
        quiet(lambda: nb.use_model("m", "https://b.example/v1/", ask=ask))
        self.assertEqual("new-key", os.environ["EXAKIT_PROVIDER_API_KEY"], "a key belongs to the endpoint it was for")

    def test_enter_means_no_key_for_a_local_server(self):
        quiet(lambda: nb.use_model("llama3", "http://127.0.0.1:11434/v1/", ask=Prompts("")))
        self.assertNotIn("EXAKIT_PROVIDER_API_KEY", os.environ)
        self.assertEqual("llama3", nb.model_settings()["model_id"])

    def test_no_key_is_asked_for_plain_http_to_a_remote_host(self):
        ask = Prompts()
        (_, out) = quiet(lambda: nb.use_model("m", "http://api.example.com/v1/", ask=ask))
        self.assertEqual([], ask.asked)
        self.assertIn("clear text", out)

    def test_langfuse_asks_its_two_keys_and_traces(self):
        ask = Prompts("pk-lf-1", "sk-lf-2")
        (summary, out) = quiet(lambda: nb.use_model(langfuse_base_url="https://cloud.langfuse.com", ask=ask))
        self.assertEqual(2, len(ask.asked))
        self.assertTrue(summary["tracing"] and nb.tracing())
        self.assertIn("Langfuse: tracing to https://cloud.langfuse.com", out)
        self.assertNotIn("sk-lf-2", out)

    def test_a_front_end_without_prompts_says_so_instead_of_failing(self):
        def no_stdin(prompt):
            raise NotImplementedError("raw_input was called, but this frontend does not support input requests")
        (summary, out) = quiet(lambda: nb.use_model("m", "https://a.example/v1/", ask=no_stdin))
        self.assertIn("could not be asked for here", out)
        self.assertNotIn("EXAKIT_PROVIDER_API_KEY", os.environ)
        self.assertTrue(summary["model"], "the model is set; only its key is missing")

    def test_mlflow_uri_and_login_without_echoing_the_password(self):
        ask = Prompts("dana", "s3cret-pw")
        (summary, out) = quiet(lambda: nb.use_mlflow("https://mlflow.example.com", True, ask=ask))
        self.assertEqual(("https://mlflow.example.com", "dana", "s3cret-pw"),
                         (os.environ["MLFLOW_TRACKING_URI"], os.environ["MLFLOW_TRACKING_USERNAME"],
                          os.environ["MLFLOW_TRACKING_PASSWORD"]))
        self.assertIn("as dana", out)
        self.assertNotIn("s3cret-pw", out + repr(summary))

    def test_a_password_in_the_uri_is_not_printed(self):
        (_, out) = quiet(lambda: nb.use_mlflow("https://dana:pw-in-uri@mlflow.example.com", ask=Prompts()))
        self.assertNotIn("pw-in-uri", out)


class NotebookCellsTest(unittest.TestCase):
    """The cells ship empty, so a headless run and a user who skips them see no prompt and no change."""

    CELLS = {"data-scientist/01_explore.py": "nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)",
             "data-scientist/02_ask_your_data.py": "nb.use_model(MODEL_ID, PROVIDER_BASE_URL, LANGFUSE_BASE_URL)",
             "ml-engineer/00_quickstart.py": "nb.use_mlflow(MLFLOW_TRACKING_URI, MLFLOW_SERVER_LOGIN)",
             "ml-engineer/01_train.py": "nb.use_mlflow(MLFLOW_TRACKING_URI, MLFLOW_SERVER_LOGIN)"}

    def test_each_notebook_carries_its_cell_empty(self):
        for relative, call in self.CELLS.items():
            with self.subTest(notebook=relative):
                text = (SOURCES / relative).read_text(encoding="utf-8")
                self.assertIn(call, text)
                for name in ("MODEL_ID", "PROVIDER_BASE_URL", "LANGFUSE_BASE_URL", "MLFLOW_TRACKING_URI"):
                    if f"\n{name} = " in text:
                        self.assertIn(f'\n{name} = ""', text, f"{name} ships empty")
                self.assertNotIn("API_KEY =", text, "no key is ever a cell value")


if __name__ == "__main__":
    unittest.main()
