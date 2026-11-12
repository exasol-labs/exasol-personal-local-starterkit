"""The model providers the notebooks know, the models a key can use, and the effort each model takes.

    nb.model_providers()                          # OpenAI, Anthropic, Gemini, Mistral, Groq, Ollama, LM Studio, vLLM, other
    nb.provider_models("anthropic")               # asks for the key (hidden), returns the models it may use
    nb.effort_levels("openai", "o4-mini")         # ["low", "medium", "high"]; [] when the model takes no effort setting

Each provider is reached through its OpenAI-compatible Chat Completions address, the one the kit's client speaks
(model_config.py). Listing the models is one GET with the key, to the provider only (never anywhere else, never
over plain http to another computer); the key is not kept here. Effort is the provider's own ``reasoning_effort``:
offered only where the provider documents it for that model. Anthropic's OpenAI-compatible API ignores it, so a
Claude model is offered none.
"""

from __future__ import annotations

import getpass
import json
import re
import urllib.error
import urllib.request
from typing import Any

from . import model_config

__all__ = ["effort_levels", "model_providers", "provider", "provider_models"]

# The page of these docs that says how to get each provider's key or server (anchor on the AI set-up page).
DOCS_PAGE = "set-up/ai-and-langfuse"

PROVIDERS: list[dict[str, Any]] = [
    {"id": "openai", "docs_anchor": "openai", "name": "OpenAI", "base_url": "https://api.openai.com/v1/", "key": "required",
     "get_key": "https://platform.openai.com/api-keys", "local": False},
    {"id": "anthropic", "docs_anchor": "claude-anthropic", "name": "Anthropic (Claude)", "base_url": "https://api.anthropic.com/v1/", "key": "required",
     "get_key": "https://platform.claude.com/settings/keys", "local": False, "models_url": "https://api.anthropic.com/v1/models?limit=1000"},
    {"id": "gemini", "docs_anchor": "gemini-google", "name": "Google Gemini", "base_url": "https://generativelanguage.googleapis.com/v1beta/openai/",
     "key": "required", "get_key": "https://aistudio.google.com/apikey", "local": False},
    {"id": "mistral", "docs_anchor": "mistral", "name": "Mistral", "base_url": "https://api.mistral.ai/v1/", "key": "required",
     "get_key": "https://console.mistral.ai/", "local": False},
    {"id": "groq", "docs_anchor": "groq", "name": "Groq", "base_url": "https://api.groq.com/openai/v1/", "key": "required",
     "get_key": "https://console.groq.com/keys", "local": False},
    {"id": "ollama", "docs_anchor": "ollama-on-this-computer", "name": "Ollama (on this computer)", "base_url": "http://localhost:11434/v1/", "key": "none",
     "get_key": "https://ollama.com/download", "local": True},
    {"id": "lmstudio", "docs_anchor": "lm-studio-on-this-computer", "name": "LM Studio (on this computer)", "base_url": "http://localhost:1234/v1/", "key": "optional",
     "get_key": "https://lmstudio.ai/docs/developer/core/authentication", "local": True},
    {"id": "vllm", "docs_anchor": "vllm-on-your-own-server", "name": "vLLM server", "base_url": "http://localhost:8000/v1/", "key": "optional",
     "get_key": "https://docs.vllm.ai/en/latest/serving/online_serving/", "local": True},
    {"id": "other", "docs_anchor": "another-openai-compatible-server", "name": "Another OpenAI-compatible server", "base_url": "", "key": "optional", "get_key": "",
     "local": False},
]

# Not a chat model: left out of the list a person picks from (they can still type one with the pencil).
_NOT_CHAT = re.compile(r"(embed|tts|whisper|dall-e|davinci|babbage|moderation|image|audio|realtime|transcribe|"
                       r"search|speech|guard|rerank|ocr|veo|imagen|aqa|computer-use)", re.I)
LEVELS = ("low", "medium", "high")
# Models whose provider documents reasoning_effort for them (the rest are offered no effort setting).
_EFFORT = {
    "openai": re.compile(r"^(o\d|gpt-5|gpt-6)", re.I),
    "gemini": re.compile(r"^gemini-(2\.5|[3-9])", re.I),
    "groq": re.compile(r"(gpt-oss|qwen3)", re.I),
    "mistral": re.compile(r"magistral", re.I),
    "ollama": re.compile(r"(gpt-oss|qwen3|deepseek-r1|thinking|magistral)", re.I),
}


def model_providers() -> list[dict[str, Any]]:
    """Every provider the notebooks offer: id, name, the Chat Completions address, whether it needs a key
    ("required", "optional", "none"), where to get one, and whether it runs on this computer."""
    return [dict(p) for p in PROVIDERS]


def provider(provider_id: str) -> dict[str, Any]:
    found = next((p for p in PROVIDERS if p["id"] == str(provider_id).strip().lower()), None)
    if found is None:
        raise ValueError(f"No provider '{provider_id}' (the providers are: {', '.join(p['id'] for p in PROVIDERS)}).")
    return dict(found)


def provider_of(base_url: str) -> str:
    """The provider id an address belongs to ("other" when none matches)."""
    base = (base_url or "").strip().rstrip("/") + "/"
    return next((p["id"] for p in PROVIDERS if p["base_url"] and p["base_url"] == base), "other")


def effort_levels(provider_id: str, model_id: str) -> list[str]:
    """The effort levels this model takes (sent as reasoning_effort); [] when the provider documents none for it."""
    rule = _EFFORT.get(str(provider_id).lower())
    return list(LEVELS) if rule and rule.search(str(model_id or "")) else []


def _get(url: str, headers: dict[str, str], key: str) -> Any:
    request = urllib.request.Request(url, headers={"Accept": "application/json", **headers})
    try:
        with urllib.request.urlopen(request, timeout=20) as answer:          # noqa: S310 - https, or loopback http
            return json.loads(answer.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as err:
        if err.code in (401, 403):
            raise ValueError("The provider refused the key (HTTP %d): check it was copied whole and is active." % err.code) from None
        raise ValueError(model_config.redact_secrets(f"The provider answered HTTP {err.code} at {url}.", [key])) from None
    except urllib.error.URLError as err:
        reason = model_config.redact_secrets(str(getattr(err, "reason", err)), [key])
        raise ValueError(f"No answer from {url} ({reason}). For a server on this computer, start it first.") from None


def provider_models(provider_id: str, api_key: str | None = None, *, base_url: str = "",
                    headers: dict[str, str] | None = None, ask=None) -> list[str]:
    """The chat models this key may use, sorted, from the provider's own list (one GET to the provider). The key is
    asked for in a hidden prompt when the provider needs one and none is given; it is used for this call only."""
    p = provider(provider_id)
    base = (base_url or p["base_url"]).strip()
    if not base:
        raise ValueError("Give the server's address (base_url=...): this provider has none of its own.")
    if not base.endswith("/"):
        base += "/"
    key = api_key if api_key is not None else ""
    if api_key is None and p["key"] == "required":
        key = (ask or getpass.getpass)(f"API key for {p['name']} (hidden): ")
    key = (key or "").strip()
    if p["key"] == "required" and not key:
        raise ValueError(f"{p['name']} needs an API key.")
    if key and not model_config.clear_text_ok(base):
        raise ValueError(f"{base} is plain http:// to another computer: the key would travel in clear text. Use https://.")
    if p["id"] == "anthropic" and base.rstrip("/") == p["base_url"].rstrip("/"):
        # Claude's OpenAI-compatible API has no model list: its own one, at the same address.
        sent = {"x-api-key": key, "anthropic-version": "2023-06-01", **(headers or {})}
        data = _get(p["models_url"], sent, key)
    else:
        sent = ({"Authorization": f"Bearer {key}"} if key else {}) | (headers or {})
        data = _get(base + "models", sent, key)
    items = data.get("data") if isinstance(data, dict) else data
    if isinstance(data, dict) and items is None:
        items = data.get("models")
    names = []
    for item in items or []:
        name = item.get("id") or item.get("name") if isinstance(item, dict) else item
        if isinstance(name, str) and name.strip():
            name = name.strip().removeprefix("models/")
            if not _NOT_CHAT.search(name):
                names.append(name)
    return sorted(set(names), key=lambda n: n.lower())
