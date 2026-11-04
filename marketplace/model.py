"""Release-owned persona and add-on selection data. No installation side effects."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

ID = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*$")
# A GitHub owner/name and a repository name: plain path segments, interpolated into URLs.
REPO = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
REPO_NAME = re.compile(r"^[A-Za-z0-9._-]+$")
ABOUT_MAX = 300


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
    # The repository the add-on comes from, as tools/addon_github.py copied it from GitHub: repo, url, name, about.
    github: dict = field(default_factory=dict, compare=False)
    # Choices the backend still accepts but no screen offers ("visible": false), until they are fully supported.
    hidden_choices: tuple[str, ...] = ()


def display_name(name: str, addon_id: str) -> str:
    """The repository's name, with the id typed in commands beside it when the two differ."""
    return name if name == addon_id else f"{name} ({addon_id})"


def github_block(addon_id: str, block) -> dict:
    """The catalog's copy of the add-on's GitHub repository, refused unless every value is the safe shape: the
    repo and name go into URLs and file names, the About into a terminal."""
    if not isinstance(block, dict):
        raise CatalogError(f"{addon_id}: github must name the add-on's repository (tools/addon_github.py)")
    repo, url, name, about = (block.get(key) for key in ("repo", "url", "name", "about"))
    if not isinstance(repo, str) or not REPO.fullmatch(repo) or ".." in repo:
        raise CatalogError(f"{addon_id}: github.repo must be owner/name")
    if url != f"https://github.com/{repo}":
        raise CatalogError(f"{addon_id}: github.url must be https://github.com/{repo}")
    if not isinstance(name, str) or not REPO_NAME.fullmatch(name):
        raise CatalogError(f"{addon_id}: github.name must be the repository's name")
    if (not isinstance(about, str) or not about.strip() or len(about) > ABOUT_MAX
            or any(ord(c) < 32 or ord(c) == 127 for c in about)):
        raise CatalogError(f"{addon_id}: github.about must be the repository's About, one line")
    return {"repo": repo, "url": url, "name": name, "about": about}


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
        if "label" in row:
            raise CatalogError(f"{addon_id}: the name comes from GitHub (github.name), not a label")
        github = github_block(addon_id, row.get("github"))
        label = display_name(github["name"], addon_id)
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
        hidden_choices = []
        for choice in choices:
            if not isinstance(choice, dict) or not isinstance(choice.get("id"), str) or not ID.fullmatch(choice["id"]):
                raise CatalogError(f"{addon_id}: invalid choice")
            choice_id, choice_label = choice["id"], choice.get("label")
            if choice_id in choice_ids or not isinstance(choice_label, str) or not choice_label.strip() or any(c in choice_label for c in "\r\n|"):
                raise CatalogError(f"{addon_id}: invalid or repeated choice {choice_id!r}")
            choice_ids.add(choice_id)
            shown = choice.get("visible", True)
            if not isinstance(shown, bool):
                raise CatalogError(f"{addon_id}: choice {choice_id!r} visible must be true or false")
            if shown:
                validated_choices.append((choice_id, choice_label))
            else:
                hidden_choices.append(choice_id)
        seen.add(addon_id)
        addons.append(Addon(addon_id, label, row["backend"], version, fallback, visible,
                            tuple(validated_choices), github, tuple(hidden_choices)))
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


def parse_addon_answer(addons: list[Addon], raw: str) -> str:
    answer = raw.lower().replace(" ", "")
    if answer in ("all", "none"):
        return answer
    parts = answer.split(",")
    if any(not part for part in parts):
        raise CatalogError("empty add-on ID in EXAKIT_MARKETPLACE_ADDONS")
    known = {addon.id for addon in addons}
    for part in parts:
        if part not in known:
            raise CatalogError(f"Unknown marketplace add-on in EXAKIT_MARKETPLACE_ADDONS: '{part}' "
                               f"(known: {' '.join(addon.id for addon in addons)})")
    return ",".join(dict.fromkeys(parts))
