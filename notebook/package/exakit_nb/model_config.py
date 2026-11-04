"""One provider-neutral text/chat configuration for notebooks and optional profiling notes.

The wire format is Chat Completions. Provider-specific native features are outside this
interface. No configuration is inferred from an SDK's ambient provider credentials.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import ipaddress
import json
import os
import re
from typing import Mapping
from urllib.parse import urlsplit

MODEL_ID = "EXAKIT_MODEL_ID"
BASE_URL = "EXAKIT_PROVIDER_BASE_URL"
API_KEY = "EXAKIT_PROVIDER_API_KEY"
HEADERS = "EXAKIT_PROVIDER_HEADERS"
TEMPERATURE = "EXAKIT_MODEL_TEMPERATURE"
_HEADER_NAME = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
_AUTH_HEADERS = {"authorization", "api-key", "x-api-key", "host"}


def clear_text_ok(url: str) -> bool:
    """Whether a key may travel to this URL: always over https, and over plain http only to this machine or a
    private network (localhost, a loopback, private or link-local address, a .local/.localhost/.internal name) -
    a local model server. A key sent over http to anywhere else crosses networks in clear text (audit SEC-08)."""
    parts = urlsplit(url)
    if parts.scheme == "https":
        return True
    host = (parts.hostname or "").lower().rstrip(".")
    if host == "localhost" or host.endswith((".localhost", ".local", ".internal")):
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    return address.is_loopback or address.is_private or address.is_link_local


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
    if key and not clear_text_ok(base):
        raise ValueError(f"{BASE_URL} is plain http:// to {url.hostname}, which would send {API_KEY} in clear text: "
                         "use its https:// address (plain http is for a model server on this machine or your own "
                         "network).")
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


def sampling(environ: Mapping[str, str] | None = None) -> dict:
    """Sampling settings to send, only when asked for. Claude Opus 4.7 and later refuse `temperature` (HTTP 400),
    and on the newest API version every model does, so the default sends none; a local model that should answer
    the same way twice takes EXAKIT_MODEL_TEMPERATURE=0."""
    env = os.environ if environ is None else environ
    raw = env.get(TEMPERATURE, "").strip()
    if not raw:
        return {}
    try:
        value = float(raw)
    except ValueError:
        value = -1.0
    if not 0 <= value <= 2:
        raise ValueError(f"{TEMPERATURE} must be a number from 0 to 2, or unset to send none.")
    return {"temperature": value}


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
