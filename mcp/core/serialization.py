"""Serialization helpers shared across the subsystem."""

from __future__ import annotations

from dataclasses import asdict, is_dataclass
from enum import Enum
import hashlib
import json
from pathlib import Path
from typing import Any


def to_primitive(value: Any) -> Any:
    """Convert rich Python objects into JSON-serializable primitives."""

    if is_dataclass(value):
        return to_primitive(asdict(value))
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, dict):
        return {str(key): to_primitive(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [to_primitive(item) for item in value]
    return value


def canonical_json(value: Any) -> str:
    """Render a stable JSON representation suitable for hashing."""

    return json.dumps(to_primitive(value), sort_keys=True, separators=(",", ":"))


def sha256_text(text: str) -> str:
    """Return a stable sha256 text hash string."""

    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return f"sha256:{digest}"


def sha256_json(value: Any) -> str:
    """Return a stable sha256 hash for a JSON-compatible structure."""

    return sha256_text(canonical_json(value))
