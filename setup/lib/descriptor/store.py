"""Step 4 of the descriptor plan, on disk: one folder per table version history in the kit's store.

    ~/.exasol-starter-kit/descriptors/<SCHEMA>.<TABLE>/v<n>.yaml          every version, never rewritten
                                                     /current.yaml        a copy of the approved one
                                                     /draft.yaml          the latest draft, until it is approved
                                                     /profile.json        the profile that draft came from
                                                     /v<n>.profile.json   the profile an approved version came from

EXAKIT_HOME moves the kit's home. A version file is created exclusively, so v(n) is never touched; current.yaml is
replaced through a temp file and os.replace (no symlinks: they break on Windows). The draft's profile.json holds the
statistics, the top values, the statements and their timings - and no value of a sensitive column, because these
files end up in bug reports.
"""

from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any

FOLDER = "descriptors"
CURRENT = "current.yaml"
PROFILE = "profile.json"
DRAFT = "draft.yaml"
_VERSION = re.compile(r"^v([1-9][0-9]*)\.yaml$")


class VersionTaken(RuntimeError):
    """Another writer took the version number first."""


def kit_home() -> Path:
    given = os.environ.get("EXAKIT_HOME")
    return Path(given).expanduser() if given else Path.home() / ".exasol-starter-kit"


def folder(table: str, home: Path | None = None) -> Path:
    """The store folder of ``SCHEMA.TABLE`` (its name keeps the table's own spelling)."""
    if "/" in table or "\\" in table or table.startswith(".") or "." not in table:
        raise ValueError(f"'{table}' is not SCHEMA.TABLE")
    return (home or kit_home()) / FOLDER / table


def versions(table: str, home: Path | None = None) -> list[int]:
    where = folder(table, home)
    if not where.is_dir():
        return []
    return sorted(int(m.group(1)) for m in (_VERSION.match(p.name) for p in where.iterdir()) if m)


def read(table: str, version: int, home: Path | None = None) -> str:
    return (folder(table, home) / f"v{version}.yaml").read_text(encoding="utf-8")


def current(table: str, home: Path | None = None) -> str | None:
    path = folder(table, home) / CURRENT
    return path.read_text(encoding="utf-8") if path.is_file() else None


def _private(path: Path) -> None:
    if os.name != "nt":
        path.chmod(0o600)


def write_version(table: str, version: int, text: str, home: Path | None = None) -> Path:
    """v<version>.yaml, created exclusively: VersionTaken when it exists."""
    where = folder(table, home)
    where.mkdir(parents=True, exist_ok=True)
    path = where / f"v{version}.yaml"
    try:
        with path.open("x", encoding="utf-8") as handle:
            handle.write(text)
    except FileExistsError as err:
        raise VersionTaken(f"{table} v{version} was written by someone else meanwhile") from err
    _private(path)
    return path


def replace_current(table: str, text: str, home: Path | None = None) -> Path:
    """current.yaml through a temp file in the same folder and os.replace."""
    where = folder(table, home)
    where.mkdir(parents=True, exist_ok=True)
    handle, name = tempfile.mkstemp(dir=where, prefix=".current-", suffix=".yaml")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(text)
        _private(Path(name))
        os.replace(name, where / CURRENT)
    except BaseException:
        Path(name).unlink(missing_ok=True)
        raise
    return where / CURRENT


def write_profile(table: str, profile: dict[str, Any], home: Path | None = None, *, version: int | None = None) -> Path:
    """profile.json beside the draft (the version it drafts is recorded in it)."""
    where = folder(table, home)
    where.mkdir(parents=True, exist_ok=True)
    path = where / PROFILE
    path.write_text(json.dumps({"version": version, **profile}, indent=2, ensure_ascii=False, default=str) + "\n",
                    encoding="utf-8")
    _private(path)
    return path


def write_draft(table: str, text: str, home: Path | None = None) -> Path:
    where = folder(table, home)
    where.mkdir(parents=True, exist_ok=True)
    path = where / DRAFT
    path.write_text(text, encoding="utf-8")
    _private(path)
    return path


def draft(table: str, home: Path | None = None) -> str | None:
    path = folder(table, home) / DRAFT
    return path.read_text(encoding="utf-8") if path.is_file() else None


def promote_profile(table: str, version: int, home: Path | None = None) -> None:
    """On approval: the draft's profile becomes v<n>.profile.json (carry-over compares column types with it) and the
    draft file goes."""
    where = folder(table, home)
    if (where / PROFILE).is_file():
        os.replace(where / PROFILE, where / f"v{version}.profile.json")
    (where / DRAFT).unlink(missing_ok=True)


def read_profile(table: str, version: int, home: Path | None = None) -> dict[str, Any] | None:
    path = folder(table, home) / f"v{version}.profile.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None
