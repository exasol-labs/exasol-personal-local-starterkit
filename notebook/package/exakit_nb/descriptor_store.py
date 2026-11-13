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


# -- the role-per-column store (descriptors/<SCHEMA.TABLE>/vN.yaml, current.yaml naming its dataset) -------------------
def _yaml(path: Path) -> dict:
    from .descriptor_rules import load_yaml

    try:
        doc = load_yaml(path.read_text(encoding="utf-8"))
        return doc if isinstance(doc, dict) else {}
    except Exception:
        return {}


def _table_folders() -> list[tuple[Path, dict]]:
    root = kit_home() / "descriptors"
    out = []
    if root.is_dir():
        for folder in sorted(root.iterdir()):
            if folder.is_dir() and (folder / "current.yaml").is_file():
                out.append((folder, _yaml(folder / "current.yaml")))
    return out


def approved_datasets() -> list[dict]:
    """Every dataset with an approved column map, newest approval first: {id, table, version, approved_at}."""
    out = []
    for folder, doc in _table_folders():
        dataset_id = str(doc.get("dataset") or "")
        if not dataset_id or str(doc.get("status") or "approved") != "approved":
            continue
        out.append({"id": dataset_id, "table": str((doc.get("source") or {}).get("object") or folder.name),
                    "version": doc.get("version"), "approved_at": str(doc.get("approved_at") or "")})
    return sorted(out, key=lambda x: x["approved_at"], reverse=True)


def column_map_versions(id: str) -> list[dict]:
    """Every saved version of a dataset's column map, oldest first: {version, approved_at, roles, slots, evidence} -
    what approving one of them again (RoleReview.approve) would restore."""
    for folder, doc in _table_folders():
        if str(doc.get("dataset")) != id:
            continue
        out = []
        for path in folder.glob("v*.yaml"):
            found = _VERSION_FILE.match(path.name)
            if not found:
                continue
            version = _yaml(path)
            columns = version.get("columns") or {}
            out.append({"version": int(found.group(1)), "approved_at": version.get("approved_at"),
                        "roles": {c: (e or {}).get("role") for c, e in columns.items()},
                        "slots": dict(version.get("slots") or {}),
                        "evidence": {c: str((e or {}).get("evidence") or "") for c, e in columns.items()}})
        return sorted(out, key=lambda v: v["version"])
    return []
