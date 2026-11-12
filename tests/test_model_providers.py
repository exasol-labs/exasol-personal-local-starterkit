"""(run: python3 tests/test_model_providers.py) The model providers the notebooks offer: each has an address and a
docs section, the model list comes from the provider with the key (only chat models kept, a refused key said so,
the key never in a message), Claude's list from its own endpoint, and the effort setting is offered and sent only
where the provider documents it."""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook" / "package"))

from exakit_nb import model_config, providers  # noqa: E402

KEY = "sk-test-never-shown"


class _Server(BaseHTTPRequestHandler):
    seen: list = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        type(self).seen.append((self.path, dict(self.headers)))
        if self.headers.get("Authorization") == "Bearer wrong" or self.headers.get("x-api-key") == "wrong":
            self.send_response(401)
            self.end_headers()
            return
        body = json.dumps({"data": [{"id": "models/gemini-2.5-pro"}, {"id": "gpt-5.5"}, {"id": "text-embedding-3-large"},
                                    {"id": "whisper-1"}, {"id": "o4-mini"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)


class ProvidersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _Server)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}/v1/"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        _Server.seen.clear()

    def test_every_provider_has_an_address_a_key_rule_and_a_docs_section(self):
        page = (ROOT / "notebook/docs/content/docs/data-scientist/set-up/ai-and-langfuse.mdx").read_text(encoding="utf-8")
        anchors = {re.sub(r"[^\w\- ]", "", h.lower()).replace(" ", "-")
                   for h in re.findall(r"^#{2,3} (.+)$", page, re.M)}
        for p in providers.model_providers():
            with self.subTest(provider=p["id"]):
                self.assertIn(p["key"], ("required", "optional", "none"))
                self.assertIn(p["docs_anchor"], anchors, "its How do I get this? link lands on a heading")
                if p["id"] != "other":
                    self.assertTrue(p["base_url"].endswith("/"))
                    self.assertTrue(p["base_url"].startswith("https://") or p["local"])

    def test_the_models_come_from_the_provider_with_the_key_and_only_chat_models_are_kept(self):
        found = providers.provider_models("other", KEY, base_url=self.base)
        self.assertEqual(["gemini-2.5-pro", "gpt-5.5", "o4-mini"], found)
        path, headers = _Server.seen[0]
        self.assertEqual("/v1/models", path)
        self.assertEqual(f"Bearer {KEY}", headers.get("Authorization"))

    def test_a_refused_key_is_said_and_never_shown(self):
        with self.assertRaises(ValueError) as caught:
            providers.provider_models("other", "wrong", base_url=self.base)
        self.assertIn("refused the key", str(caught.exception))
        self.assertNotIn("wrong", str(caught.exception))

    def test_claude_is_listed_from_its_own_endpoint(self):
        p = providers.provider("anthropic")
        with mock.patch.object(providers, "_get", return_value={"data": [{"id": "claude-opus-5-5"}]}) as get:
            self.assertEqual(["claude-opus-5-5"], providers.provider_models("anthropic", KEY))
        url, headers, _key = get.call_args[0]
        self.assertEqual(p["models_url"], url)
        self.assertEqual(KEY, headers["x-api-key"])
        self.assertIn("anthropic-version", headers)

    def test_a_required_key_is_asked_for_in_a_hidden_prompt(self):
        with mock.patch.object(providers, "_get", return_value={"data": []}) as get:
            providers.provider_models("openai", ask=lambda _q: KEY)
        self.assertEqual(f"Bearer {KEY}", get.call_args[0][1]["Authorization"])
        with self.assertRaisesRegex(ValueError, "needs an API key"):
            providers.provider_models("openai", "")

    def test_a_key_never_goes_over_plain_http_to_another_computer(self):
        with self.assertRaisesRegex(ValueError, "clear text"):
            providers.provider_models("other", KEY, base_url="http://models.example.com/v1/")

    def test_effort_is_offered_only_where_the_provider_documents_it(self):
        self.assertEqual(["low", "medium", "high"], providers.effort_levels("openai", "o4-mini"))
        self.assertEqual(["low", "medium", "high"], providers.effort_levels("gemini", "gemini-2.5-flash"))
        self.assertEqual([], providers.effort_levels("openai", "gpt-4.1"))
        self.assertEqual([], providers.effort_levels("anthropic", "claude-opus-5-5"))      # the compat layer ignores it
        self.assertEqual([], providers.effort_levels("lmstudio", "qwen3-8b"))

    def test_the_effort_is_sent_only_when_chosen(self):
        self.assertEqual({}, model_config.sampling({}))
        self.assertEqual({"reasoning_effort": "high"}, model_config.sampling({model_config.EFFORT: "high"}))
        self.assertEqual({"reasoning_effort": "low", "temperature": 0.0},
                         model_config.sampling({model_config.EFFORT: "low", model_config.TEMPERATURE: "0"}))
        with self.assertRaisesRegex(ValueError, "EXAKIT_MODEL_EFFORT"):
            model_config.sampling({model_config.EFFORT: "extreme"})

    def test_use_model_sets_and_clears_the_effort(self):
        from exakit_nb import setup_env

        with mock.patch.dict(os.environ, {}, clear=False):
            for name in (model_config.EFFORT, model_config.MODEL_ID, model_config.BASE_URL, model_config.API_KEY):
                os.environ.pop(name, None)
            with mock.patch("sys.stdout"):
                setup_env.use_model("o4-mini", "https://api.openai.com/v1/", effort="high", ask=lambda _q: KEY)
            self.assertEqual("high", os.environ[model_config.EFFORT])
            with mock.patch("sys.stdout"):
                setup_env.use_model(effort="")
            self.assertNotIn(model_config.EFFORT, os.environ)
            with self.assertRaisesRegex(ValueError, "effort must be one of"):
                setup_env.use_model(effort="huge")


if __name__ == "__main__":
    unittest.main()
