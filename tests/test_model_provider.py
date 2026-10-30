"""Provider-neutral configuration and local HTTP contracts; no provider account or real API key.

Run with the kit's notebook Python for the SDK/HTTP cases. They prove our request contract,
not that a remote provider or a particular model has passed a live acceptance test.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
import exakit_nb as nb
from exakit_nb import model_config


class ModelSettingsTest(unittest.TestCase):
    def test_absent_or_blank_model_disables_the_optional_step(self):
        self.assertIsNone(model_config.resolve({}))
        self.assertIsNone(model_config.resolve({"EXAKIT_MODEL_ID": "  "}))

    def test_retired_notebook_setting_names_do_not_enable_the_model(self):
        old = {"EXAKIT_NB_MODEL": "old-model", "EXAKIT_NB_BASE_URL": "https://old.example/v1",
               "EXAKIT_NB_API_KEY": "old-secret"}
        self.assertIsNone(model_config.resolve(old))

    def test_model_requires_an_explicit_provider_base_url(self):
        with self.assertRaisesRegex(ValueError, "EXAKIT_PROVIDER_BASE_URL"):
            model_config.resolve({"EXAKIT_MODEL_ID": "chosen-model"})

    def test_settings_are_passed_explicitly_without_ambient_sdk_credentials(self):
        env = {"EXAKIT_MODEL_ID": "chosen-model", "EXAKIT_PROVIDER_BASE_URL": "https://provider.example/v1/",
               "EXAKIT_PROVIDER_API_KEY": "test-only-provider-secret", "OPENAI_API_KEY": "unrelated-key",
               "OPENAI_BASE_URL": "https://unrelated.example/v1"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.dict(sys.modules, {
                "openai": mock.Mock(OpenAI=mock.Mock(return_value="client"))}):
            client, name = nb.model_client()
            self.assertEqual((client, name), ("client", "chosen-model"))
            sys.modules["openai"].OpenAI.assert_called_once_with(
                api_key="test-only-provider-secret", base_url="https://provider.example/v1/")

    def test_keyless_server_does_not_reuse_an_unrelated_sdk_key(self):
        env = {"EXAKIT_MODEL_ID": "local-model", "EXAKIT_PROVIDER_BASE_URL": "http://local.example/v1",
               "OPENAI_API_KEY": "unrelated-secret"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.dict(sys.modules, {
                "openai": mock.Mock(OpenAI=mock.Mock())}):
            nb.model_client()
            self.assertEqual(sys.modules["openai"].OpenAI.call_args.kwargs["api_key"], "not-needed")

    def test_tracing_uses_the_same_explicit_provider_settings_and_routing_headers(self):
        config = model_config.resolve({"EXAKIT_MODEL_ID": "m", "EXAKIT_PROVIDER_BASE_URL": "https://provider.example/v1/",
                                       "EXAKIT_PROVIDER_API_KEY": "test-only-key",
                                       "EXAKIT_PROVIDER_HEADERS": '{"anthropic-workspace-id":"test-workspace"}'})
        sdk = mock.Mock(OpenAI=mock.Mock(return_value="traced-client"))
        with mock.patch.dict(sys.modules, {"langfuse.openai": sdk}):
            self.assertEqual(model_config.create_client(config, traced=True), "traced-client")
        sdk.OpenAI.assert_called_once_with(api_key="test-only-key", base_url="https://provider.example/v1/",
                                           default_headers={"anthropic-workspace-id": "test-workspace"})

    def test_model_and_header_secrets_are_not_in_settings_or_repr(self):
        env = {"EXAKIT_MODEL_ID": "m", "EXAKIT_PROVIDER_BASE_URL": "https://provider.example/v1",
               "EXAKIT_PROVIDER_API_KEY": "test-only-provider-secret",
               "EXAKIT_PROVIDER_HEADERS": '{"anthropic-workspace-id":"private-workspace"}'}
        config = model_config.resolve(env)
        self.assertNotIn("test-only-provider-secret", repr(config))
        self.assertNotIn("private-workspace", repr(config))
        with mock.patch.dict(os.environ, env, clear=True):
            shown = json.dumps(nb.model_settings())
        self.assertNotIn("test-only-provider-secret", shown)
        self.assertNotIn("private-workspace", shown)
        self.assertIn('"api_key_configured": true', shown)
        self.assertIn("anthropic-workspace-id", shown)

    def test_invalid_urls_fail_without_echoing_the_input(self):
        for base in ["file:///private/example", "https://user:secret@provider.example/v1",
                     "https://provider.example/v1?key=secret", "https://provider.example/v1#secret",
                     "https://provider.example/v1/chat/completions", "https://provider.example/v1/messages",
                     "https://provider.example/v1/responses", "https://provider.example:wrong/v1",
                     "https://provider.example/\nsecret"]:
            with self.subTest(base=base), self.assertRaises(ValueError) as caught:
                model_config.resolve({"EXAKIT_MODEL_ID": "m", "EXAKIT_PROVIDER_BASE_URL": base})
            self.assertNotIn("secret", str(caught.exception))

    def test_invalid_header_json_does_not_echo_its_contents(self):
        for raw in ['{"x":"private-header"', '["private-header"]', '{"x":7}',
                    '{"Authorization":"private-header"}', '{"x\\nheader":"private-header"}',
                    '{"x":"private-header\\n"}']:
            with self.subTest(raw=raw), self.assertRaises(ValueError) as caught:
                model_config.resolve({"EXAKIT_MODEL_ID": "m", "EXAKIT_PROVIDER_BASE_URL": "https://provider.example/v1",
                                      "EXAKIT_PROVIDER_HEADERS": raw})
            self.assertNotIn("private-header", str(caught.exception))

    def test_notebook_and_describe_notes_share_the_same_config(self):
        spec = importlib.util.spec_from_file_location("provider_describe", ROOT / "setup/lib/describe_service.py")
        service = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(service)
        answer = mock.Mock()
        answer.choices = [mock.Mock(message=mock.Mock(content='{"NOTE":"A description."}'))]
        client = mock.Mock()
        client.chat.completions.create.return_value = answer
        env = {"EXAKIT_MODEL_ID": "notes-model", "EXAKIT_PROVIDER_BASE_URL": "https://provider.example/v1/",
               "EXAKIT_PROVIDER_API_KEY": "test-only-secret"}
        profile = {"columns": [{"column": "NOTE", "type": "VARCHAR(200)", "distinct": 12}]}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.dict(sys.modules, {
                "openai": mock.Mock(OpenAI=mock.Mock(return_value=client))}):
            result = service.model_notes({"roles": {}, "fact_table": "S.T"}, profile)
            self.assertEqual(result, {"NOTE": "A description."})
            self.assertEqual(client.chat.completions.create.call_args.kwargs["model"], "notes-model")
            sys.modules["openai"].OpenAI.assert_called_once_with(
                api_key="test-only-secret", base_url="https://provider.example/v1/")


@unittest.skipUnless(importlib.util.find_spec("openai"), "the SDK HTTP contracts need the notebook environment")
class ProviderHttpContractTest(unittest.TestCase):
    """Each provider's documented base path, sent through the real SDK to a local fixture."""

    def setUp(self):
        self.requests = []
        requests = self.requests

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append({"path": self.path, "headers": dict(self.headers), "body": body})
                response = {"id": "local-contract", "object": "chat.completion", "created": 0, "model": body["model"],
                            "choices": [{"index": 0, "message": {"role": "assistant", "content": "test theme"},
                                         "finish_reason": "stop"}],
                            "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}}
                data = json.dumps(response).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def test_all_five_provider_contracts_preserve_model_path_messages_and_usage(self):
        cases = [("claude", "/v1/", True, {"anthropic-workspace-id": "test-workspace"}),
                 ("ollama", "/v1", False, {}), ("lm-studio", "/v1/", True, {}),
                 ("vllm", "/v1", True, {}), ("gemini", "/v1beta/openai/", True, {})]
        for provider, path, authenticated, headers in cases:
            with self.subTest(provider=provider):
                env = {"EXAKIT_MODEL_ID": provider + "-test-model",
                       "EXAKIT_PROVIDER_BASE_URL": f"http://127.0.0.1:{self.server.server_port}" + path,
                       "EXAKIT_PROVIDER_HEADERS": json.dumps(headers),
                       "OPENAI_API_KEY": "must-not-be-used", "OPENAI_BASE_URL": "https://must-not-be-used.invalid"}
                if authenticated:
                    env["EXAKIT_PROVIDER_API_KEY"] = "test-only-key"
                with mock.patch.dict(os.environ, env, clear=True):
                    client, model = nb.model_client()
                    with client:
                        answer = client.chat.completions.create(model=model, messages=[
                            {"role": "system", "content": "Give one theme."}, {"role": "user", "content": "Synthetic text."}])
                received = self.requests[-1]
                self.assertEqual(received["path"], path.rstrip("/") + "/chat/completions")
                self.assertEqual(received["body"]["model"], provider + "-test-model")
                self.assertEqual(received["body"]["messages"][1]["content"], "Synthetic text.")
                self.assertEqual(received["headers"]["Authorization"], "Bearer " + ("test-only-key" if authenticated else "not-needed"))
                if headers:
                    self.assertEqual(received["headers"]["anthropic-workspace-id"], "test-workspace")
                self.assertEqual(answer.choices[0].message.content, "test theme")
                self.assertEqual(answer.usage.total_tokens, 7)


if __name__ == "__main__":
    unittest.main()
