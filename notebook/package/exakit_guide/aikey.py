"""The AI model chosen on Home, available in every guided step.

Each step runs in its own kernel, and the kit keeps the model settings in the kernel's memory only, so a key
entered on Home never reached Step 3. The guided view saves it once, beside the kit's own credentials and readable by
this user only (0600, like the kit's database passwords), and each step loads it when it starts. The key is never
printed, logged or written into a notebook. "Forget" on Home deletes it.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

MODEL_ID, BASE_URL, API_KEY = "EXAKIT_MODEL_ID", "EXAKIT_PROVIDER_BASE_URL", "EXAKIT_PROVIDER_API_KEY"
LANGFUSE_URL, LANGFUSE_PUBLIC, LANGFUSE_SECRET = "LANGFUSE_BASE_URL", "LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY"


def _dir() -> Path:
    return Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit").expanduser() / "credentials"


def _settings() -> Path:
    return _dir() / "guide_model.json"


def _key() -> Path:
    return _dir() / "guide_model_api_key"


def _write_private(path: Path, text: str) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _langfuse() -> Path:
    return _dir() / "guide_langfuse.json"


def _langfuse_key(which: str) -> Path:
    return _dir() / f"guide_langfuse_{which}_key"


def save_langfuse(url: str, public_key: str, secret_key: str) -> None:
    """Langfuse tracing for every guided step: its address, and its two keys in their own 0600 files."""
    _write_private(_langfuse(), json.dumps({"url": url}))
    for which, key in (("public", public_key), ("secret", secret_key)):
        if key:
            _write_private(_langfuse_key(which), key)
        else:
            _langfuse_key(which).unlink(missing_ok=True)


def load_langfuse() -> bool:
    """Put the saved Langfuse settings into this kernel, unless it already has them. True when tracing is set."""
    if os.environ.get(LANGFUSE_URL, "").strip():
        return True
    try:
        url = json.loads(_langfuse().read_text(encoding="utf-8")).get("url")
    except (OSError, ValueError):
        return False
    if not url:
        return False
    os.environ[LANGFUSE_URL] = url
    for which, name in (("public", LANGFUSE_PUBLIC), ("secret", LANGFUSE_SECRET)):
        try:
            key = _langfuse_key(which).read_text(encoding="utf-8").strip()
            if key:
                os.environ[name] = key
        except OSError:
            pass
    return True


def forget_langfuse() -> None:
    for p in (_langfuse(), _langfuse_key("public"), _langfuse_key("secret")):
        p.unlink(missing_ok=True)
    for name in (LANGFUSE_URL, LANGFUSE_PUBLIC, LANGFUSE_SECRET):
        os.environ.pop(name, None)


def langfuse_saved() -> bool:
    return _langfuse().is_file()


def save(model: str, url: str, key: str) -> None:
    _write_private(_settings(), json.dumps({"model": model, "url": url}))
    if key:
        _write_private(_key(), key)
    else:
        _key().unlink(missing_ok=True)


def load() -> bool:
    """Put the saved model (and Langfuse, when saved) into this kernel, unless this kernel already has one. True when
    a model is set."""
    load_langfuse()
    if os.environ.get(MODEL_ID, "").strip():
        return True
    try:
        s = json.loads(_settings().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    if not s.get("model") or not s.get("url"):
        return False
    os.environ[MODEL_ID], os.environ[BASE_URL] = s["model"], s["url"]
    try:
        key = _key().read_text(encoding="utf-8").strip()
        if key:
            os.environ[API_KEY] = key
    except OSError:
        pass
    return True


def forget() -> None:
    for p in (_settings(), _key()):
        p.unlink(missing_ok=True)
    for name in (MODEL_ID, BASE_URL, API_KEY):
        os.environ.pop(name, None)


def saved() -> bool:
    return _settings().is_file()
