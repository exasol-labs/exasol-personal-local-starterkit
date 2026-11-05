"""model_config.redact_secrets: a provider's message never carries a configured secret back out (SEC-09)."""

from __future__ import annotations

import base64
import sys
import unittest
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook" / "package"))
from exakit_nb.model_config import ModelConfig, redact_secrets  # noqa: E402

KEY = "sk-abcd/1234+xyz"


class RedactSecretsTest(unittest.TestCase):
    def test_the_key_in_every_form_a_provider_echoes(self) -> None:
        for form in (KEY, urllib.parse.quote(KEY, safe=""), base64.b64encode(KEY.encode()).decode(),
                     base64.urlsafe_b64encode(KEY.encode()).decode().rstrip("=")):
            with self.subTest(form=form):
                self.assertEqual(redact_secrets(f"bad key {form}.", [KEY]), "bad key [redacted].")

    def test_custom_header_values_and_short_secrets(self) -> None:
        config = ModelConfig("m", "https://example.com/v1", "key-1", {"anthropic-workspace": "ws9"})
        self.assertEqual(config.redact("workspace ws9 refused key-1"), "workspace [redacted] refused [redacted]")

    def test_values_after_credential_labels(self) -> None:
        self.assertEqual(redact_secrets("Authorization: Bearer zz9999", []), "Authorization: Bearer [redacted]")
        self.assertEqual(redact_secrets("x-api-key: abcdef123", []), "x-api-key: [redacted]")
        self.assertEqual(redact_secrets("Basic dXNlcjpwYXNz", []), "Basic [redacted]")

    def test_ordinary_words_survive(self) -> None:
        self.assertEqual(redact_secrets("invalid token provided", []), "invalid token provided")


if __name__ == "__main__":
    unittest.main()
