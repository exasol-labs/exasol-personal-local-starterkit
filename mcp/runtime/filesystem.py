"""Filesystem primitives used by runtime services."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import stat

from mcp.core.errors import MCPSubsystemError
from mcp.core.serialization import sha256_text


class FileSystem:
    """Small wrapper around common filesystem operations."""

    def ensure_dir(self, path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True)

    def write_text(self, path: Path, content: str) -> None:
        # Files written by this subsystem can embed database credentials,
        # so they must be owner-only from the moment they exist — creating
        # with the default umask and chmod-ing afterward leaves a window
        # where other local users can read the secret.
        #
        # Write to a sibling temp file, then os.replace() it into place. The
        # replace is atomic on the same filesystem, so a crash mid-write leaves
        # the previous file intact instead of a truncated/corrupt one.
        self.ensure_dir(path.parent)
        tmp = path.parent / f".{path.name}.tmp"
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(content)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def write_json(self, path: Path, content: dict) -> None:
        self.write_text(path, json.dumps(content, indent=2, sort_keys=True) + "\n")

    def read_text(self, path: Path) -> str:
        return path.read_text(encoding="utf-8")

    def read_json(self, path: Path) -> dict:
        # Turn a corrupt / non-UTF-8 / unreadable / missing file into a typed,
        # user-facing error instead of a raw traceback. Manifests and snapshot
        # metadata are the main callers, and a hand-edited or interrupted-write
        # manifest.json is the most likely real-world failure here.
        try:
            raw = self.read_text(path)
        except FileNotFoundError as exc:
            raise MCPSubsystemError("file_missing", f"Required file is missing: {path}") from exc
        except (OSError, UnicodeDecodeError) as exc:
            raise MCPSubsystemError("file_unreadable", f"Could not read {path}: {exc}") from exc
        try:
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            raise MCPSubsystemError(
                "file_invalid_json",
                f"{path} is not valid JSON (corrupt or hand-edited?): {exc}",
            ) from exc

    def remove_file(self, path: Path) -> None:
        if path.exists():
            path.unlink()

    def copy_file(self, source: Path, target: Path) -> None:
        self.ensure_dir(target.parent)
        shutil.copy2(source, target)

    def exists(self, path: Path) -> bool:
        return path.exists()

    def hash_file(self, path: Path) -> str:
        return sha256_text(self.read_text(path))

    def mode_string(self, path: Path) -> str | None:
        if not path.exists():
            return None
        return format(stat.S_IMODE(path.stat().st_mode), "04o")

    def prune_empty_parents(self, path: Path, stop_at: Path) -> None:
        current = path
        while current != stop_at and current.exists():
            try:
                current.rmdir()
            except OSError:
                break
            current = current.parent
