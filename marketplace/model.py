"""Release-owned persona and add-on selection data. No installation side effects."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

ID = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*$")


class CatalogError(ValueError):
    """Invalid release metadata; show this before displaying an install choice."""


@dataclass(frozen=True)
class Addon:
    id: str
    label: str
    backend: str
    version: str | None
    default_version: str
    visible: bool
    choices: tuple[tuple[str, str], ...]


def load_addons(root: Path) -> list[Addon]:
    """Join the marketplace catalog to the kit's single component version pin."""
    catalog = json.loads((root / "marketplace" / "catalog.json").read_text(encoding="utf-8"))
    versions = json.loads((root / "versions.json").read_text(encoding="utf-8"))
    if not isinstance(catalog, dict) or catalog.get("schema_version") != 1 or not isinstance(catalog.get("addons"), list):
        raise CatalogError("marketplace/catalog.json needs schema_version 1 and an addons list")
    if not isinstance(versions, dict) or not isinstance(versions.get("components"), dict):
        raise CatalogError("versions.json needs a components object")
    components = versions.get("components", {})
    seen: set[str] = set()
    addons = []
    for row in catalog["addons"]:
        if not isinstance(row, dict):
            raise CatalogError("each add-on must be an object")
        addon_id = row.get("id")
        if not isinstance(addon_id, str) or not ID.fullmatch(addon_id) or addon_id in seen:
            raise CatalogError(f"invalid or repeated add-on id: {addon_id!r}")
        if row.get("backend") != "python":
            raise CatalogError(f"{addon_id}: unsupported backend {row.get('backend')!r}")
        label = row.get("label")
        if not isinstance(label, str) or not label.strip() or any(c in label for c in "\r\n|"):
            raise CatalogError(f"{addon_id}: label must be one non-empty line")
        block = components.get(addon_id, {})
        if not isinstance(block, dict):
            raise CatalogError(f"{addon_id}: versions.json component must be an object")
        version = block.get("version")
        fallback = row.get("default_version")
        if not isinstance(fallback, str) or not VERSION.fullmatch(fallback):
            raise CatalogError(f"{addon_id}: missing default_version in marketplace/catalog.json")
        if version is not None and (not isinstance(version, str) or not VERSION.fullmatch(version)):
            raise CatalogError(f"{addon_id}: invalid version in versions.json")
        visible = row.get("visible", True)
        if not isinstance(visible, bool):
            raise CatalogError(f"{addon_id}: visible must be true or false")
        choices = row.get("choices", [])
        if not isinstance(choices, list):
            raise CatalogError(f"{addon_id}: choices must be a list")
        choice_ids: set[str] = set()
        validated_choices = []
        for choice in choices:
            if not isinstance(choice, dict) or not isinstance(choice.get("id"), str) or not ID.fullmatch(choice["id"]):
                raise CatalogError(f"{addon_id}: invalid choice")
            choice_id, choice_label = choice["id"], choice.get("label")
            if choice_id in choice_ids or not isinstance(choice_label, str) or not choice_label.strip() or any(c in choice_label for c in "\r\n|"):
                raise CatalogError(f"{addon_id}: invalid or repeated choice {choice_id!r}")
            choice_ids.add(choice_id)
            validated_choices.append((choice_id, choice_label))
        seen.add(addon_id)
        addons.append(Addon(addon_id, label, row["backend"], version, fallback, visible,
                            tuple(validated_choices)))
    return addons


def load_personas(root: Path) -> list[dict]:
    """Use the existing validated persona format; a new JSON needs no UI edit."""
    import sys

    sys.path.insert(0, str(root / "setup" / "lib"))
    try:
        from persona_service import load

        valid, invalid = load(root)
    finally:
        sys.path.pop(0)
    if invalid:
        name, reason = next(iter(invalid.items()))
        raise CatalogError(f"personas/{name}: {reason}")
    return [persona for persona in valid.values() if persona.get("picker") and persona.get("visible", True)]


def choose_personas(personas: list[dict], selected: list[str]) -> list[str]:
    known = {row["id"] for row in personas}
    if any(item not in known for item in selected):
        raise CatalogError("selection contains an unknown persona")
    return [row["id"] for row in personas if row["id"] in selected]


def choose_addons(addons: list[Addon], states: dict[str, dict], selected: list[str]) -> list[str]:
    known = {row.id for row in addons if row.visible}
    if any(item not in known for item in selected):
        raise CatalogError("selection contains an unknown add-on")
    unavailable = [item for item in selected if states.get(item, {}).get("status") != "available"]
    if unavailable:
        raise CatalogError(f"not available to install: {', '.join(unavailable)}")
    return [row.id for row in addons if row.id in selected]
