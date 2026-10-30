"""One provider-neutral text/chat configuration for notebooks and optional profiling notes.

The wire format is Chat Completions. Provider-specific native features are outside this
interface. No configuration is inferred from an SDK's ambient provider credentials.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import json
import os
import re
from typing import Mapping
from urllib.parse import urlsplit

MODEL_ID = "EXAKIT_MODEL_ID"
BASE_URL = "EXAKIT_PROVIDER_BASE_URL"
API_KEY = "EXAKIT_PROVIDER_API_KEY"
HEADERS = "EXAKIT_PROVIDER_HEADERS"
_HEADER_NAME = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
_AUTH_HEADERS = {"authorization", "api-key", "x-api-key", "host"}


@dataclass(frozen=True)
class ModelConfig:
    model_id: str
    base_url: str
    api_key: str = field(repr=False)
    headers: dict[str, str] = field(default_factory=dict, repr=False)

    def summary(self) -> dict:
        """Safe to display: neither the API key nor custom header values are returned."""
        return {"configured": True, "model_id": self.model_id, "provider_base_url": self.base_url,
                "api_key_configured": bool(self.api_key), "header_names": sorted(self.headers),
                "protocol": "chat-completions"}

    def redact(self, message: str) -> str:
        for secret in [self.api_key, *self.headers.values()]:
            if secret:
                message = message.replace(secret, "[redacted]")
        return message


def resolve(environ: Mapping[str, str] | None = None) -> ModelConfig | None:
    """An absent/blank model disables optional AI; a selected model needs an explicit base URL.

    A missing key is allowed for servers without authentication. Custom headers support
    routing such as an Anthropic workspace; authentication uses the API-key setting.
    """
    env = os.environ if environ is None else environ
    model = env.get(MODEL_ID, "").strip()
    if not model:
        return None
    base = env.get(BASE_URL, "").strip()
    if not base:
        raise ValueError(f"Set {BASE_URL} to the provider's API base URL before using {MODEL_ID}.")
    try:
        url = urlsplit(base)
        _ = url.port  # validate a supplied port without changing the provider path
        valid = (url.scheme in ("http", "https") and bool(url.hostname) and not url.username and not url.password
                 and not url.query and not url.fragment and not any(c.isspace() or ord(c) < 32 for c in base)
                 and not url.path.rstrip("/").endswith(("/chat/completions", "/messages", "/responses")))
    except ValueError:
        valid = False
    if not valid:
        raise ValueError(f"{BASE_URL} must be an HTTP(S) API base URL, without embedded credentials, query, fragment "
                         "or a request path such as /chat/completions.")
    key = env.get(API_KEY, "").strip()
    if "\r" in key or "\n" in key:
        raise ValueError(f"{API_KEY} must be a single-line value.")
    try:
        headers = json.loads(env.get(HEADERS) or "{}")
        if not isinstance(headers, dict) or any(
                not isinstance(name, str) or not _HEADER_NAME.fullmatch(name) or name.lower() in _AUTH_HEADERS
                or not isinstance(value, str) or "\r" in value or "\n" in value
                for name, value in headers.items()):
            raise ValueError()
    except (ValueError, TypeError):
        raise ValueError(f"{HEADERS} must be a JSON object of valid header names and single-line string values; "
                         f"put authentication in {API_KEY}.") from None
    return ModelConfig(model, base, key, headers)


def create_client(config: ModelConfig, *, traced: bool = False):
    """Pass every setting explicitly so an SDK cannot substitute another provider's key or URL."""
    if traced:
        from langfuse.openai import OpenAI
    else:
        from openai import OpenAI
    kwargs = {"api_key": config.api_key or "not-needed", "base_url": config.base_url}
    if config.headers:
        kwargs["default_headers"] = config.headers
    return OpenAI(**kwargs)
