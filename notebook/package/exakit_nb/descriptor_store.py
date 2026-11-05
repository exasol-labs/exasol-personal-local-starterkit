"""Where a user's approved descriptors live. Today: ``~/.exasol-starter-kit/descriptors/<SCHEMA>.<TABLE>/current.yaml``
(setup/lib/descriptor/store.py writes it; table_descriptor() finds it by its dataset id). Before that, and still read:
``~/.exasol-starter-kit/descriptors/<id>/`` (the kit's home, EXAKIT_HOME
when set) holds one ``v<n>.yaml`` per version and ``current``, a text file with the number of the approved version.
Read-only here: ``exakit describe <id> --approve`` and ``Draft.approve()`` write versions; ``Dataset`` reads the
current one before it falls back to a shipped descriptor.

    descriptor_store_dir("amazon_sales")   # ~/.exasol-starter-kit/descriptors/amazon_sales
    list_versions("amazon_sales")          # [1, 2]: every v<n>.yaml there, in order
    current_version("amazon_sales")        # 2, or None when nothing is approved there
    current_descriptor("amazon_sales")     # the v2.yaml path, or None
"""

from __future__ import annotations

import os
import re
from pathlib import Path

__all__ = ["current_descriptor", "current_version", "descriptor_store_dir", "kit_home", "list_versions", "table_descriptor"]

FOLDER = "descriptors"
CURRENT = "current"
_VERSION_FILE = re.compile(r"^v([1-9][0-9]*)\.yaml$")
_ID = re.compile(r"^[a-z0-9]+([-_][a-z0-9]+)*$")       # as descriptor_rules: a store folder is named by a dataset id


def kit_home() -> Path:
    """The kit's home folder: EXAKIT_HOME when set, else ~/.exasol-starter-kit (it need not exist yet)."""
    given = os.environ.get("EXAKIT_HOME")
    return Path(given).expanduser() if given else Path.home() / ".exasol-starter-kit"


def descriptor_store_dir(id: str) -> Path:
    """The folder that holds the versions of the descriptor ``id`` (whether or not it exists yet); an id that is not
    a dataset id is refused, so no path is built from it."""
    if not isinstance(id, str) or not _ID.match(id):
        raise ValueError(f"'{id}' is not a dataset id (lower-case letters and digits, joined by - or _).")
    return kit_home() / FOLDER / id


def list_versions(id: str) -> list[int]:
    """The version numbers stored for ``id`` (every v<n>.yaml), ascending; empty when none is stored."""
    folder = descriptor_store_dir(id)
    if not folder.is_dir():
        return []
    found = [int(m.group(1)) for p in folder.iterdir() if p.is_file() and (m := _VERSION_FILE.match(p.name))]
    return sorted(found)


def current_version(id: str) -> int | None:
    """The approved version's number from ``current``, or None when there is none (or the file does not hold one)."""
    path = descriptor_store_dir(id) / CURRENT
    try:
        text = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return int(text) if re.fullmatch(r"[1-9][0-9]*", text) else None


def current_descriptor(id: str) -> Path | None:
    """The approved version's file (``v<n>.yaml`` named by ``current``), else the role-per-column store's
    ``<SCHEMA>.<TABLE>/current.yaml`` whose dataset is ``id``; None when there is neither."""
    number = current_version(id)
    if number is not None:
        path = descriptor_store_dir(id) / f"v{number}.yaml"
        if path.is_file():
            return path
    return table_descriptor(id)


def table_descriptor(id: str) -> Path | None:
    """The role-per-column store (setup/lib/descriptor/store.py): ``descriptors/<SCHEMA>.<TABLE>/current.yaml`` naming
    ``dataset: <id>``; the most recently approved one when two tables carry the same id."""
    root = kit_home() / FOLDER
    if not isinstance(id, str) or not _ID.match(id) or not root.is_dir():
        return None
    found = []
    for path in root.glob("*.*/current.yaml"):
        try:
            head = path.read_text(encoding="utf-8")[:2000]
        except OSError:
            continue
        if re.search(rf'^dataset:\s*"?{re.escape(id)}"?\s*$', head, re.M):
            found.append(path)
    return max(found, key=lambda p: p.stat().st_mtime) if found else None
