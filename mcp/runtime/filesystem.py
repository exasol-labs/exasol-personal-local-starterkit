"""Filesystem primitives used by runtime services."""

from __future__ import annotations

import getpass
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess

from mcp.core.errors import MCPSubsystemError
from mcp.core.serialization import sha256_text

# What protect_path() reports when it applied a Windows ACL rather than a POSIX
# mode. It is a label, not a mode: nothing about it is chmod-shaped, and callers
# that record it must not present it as one.
OWNER_ONLY_ACL = "owner-only-acl"

# What describe_protection() reports for a Windows file whose ACL is NOT the
# owner-only one protect_path applies - it still inherits from its parent, or it
# grants somebody else. Distinct from None, which means "could not be read":
# one is drift to report, the other is a check that did not run.
NOT_OWNER_ONLY_ACL = "not-owner-only-acl"


def _is_windows() -> bool:
    """One place the whole module asks "is chmod real here?".

    A function rather than a bare ``os.name`` check so the Windows branch can be
    exercised from a test on any platform - the branch that matters most is the
    one CI can never actually run.
    """
    return os.name == "nt"


def protect_path(path: Path) -> str | None:
    """Make ``path`` reachable by its owner alone, on POSIX *and* on Windows.

    Returns the protection that was actually applied - a four-digit POSIX mode,
    or ``OWNER_ONLY_ACL`` - and ``None`` when nothing could be applied.

    ``chmod`` is not a security mechanism on Windows: CPython maps the mode
    argument to the read-only attribute and nothing else, so a file created
    0o600 still carries whatever ACL it inherited from its parent. That is the
    difference between "owner-only" and "readable by everyone the file share
    grants" on the domain-joined, folder-redirected machines this kit targets.
    The real equivalent there is an ACL stripped of inheritance and granted to
    the current user alone - the same posture Protect-ExakitFile takes for every
    credential the PowerShell half writes.
    """
    if not path.exists():
        return None
    if _is_windows():
        username = os.environ.get("USERNAME") or getpass.getuser()
        # (OI)(CI) on a directory so files created inside it inherit the same
        # single-user ACL; a plain F on a file.
        grant = f"{username}:(OI)(CI)F" if path.is_dir() else f"{username}:F"
        try:
            subprocess.run(
                ["icacls", str(path), "/inheritance:r", "/grant:r", grant],
                check=True,
                capture_output=True,
                timeout=30,
            )
        except (OSError, subprocess.SubprocessError):
            # Best effort: a failed tightening must not fail the write it
            # protects - but it must not be REPORTED as applied either.
            return None
        return OWNER_ONLY_ACL
    path.chmod(stat.S_IRWXU if path.is_dir() else (stat.S_IRUSR | stat.S_IWUSR))
    return format(stat.S_IMODE(path.stat().st_mode), "04o")


def describe_protection(path: Path) -> str | None:
    """What ``path`` is ACTUALLY protected by right now - the read side of
    :func:`protect_path`.

    Returns a four-digit POSIX mode, :data:`OWNER_ONLY_ACL`,
    :data:`NOT_OWNER_ONLY_ACL`, or ``None`` when the posture could not be
    determined at all.

    This exists because the validator had no way to ask. Its permission check
    read ``stat().st_mode`` and skipped the comparison on Windows - where the
    mode means nothing - and then recorded a PASS for the check it had just
    skipped, on the files that carry the database password in plaintext. A
    check that cannot read a posture must report that it could not, not that
    the posture is good; so ``None`` is a distinct answer here and callers are
    expected to treat it as "unverified" rather than folding it into either
    outcome.

    Owner-only on Windows means what protect_path makes it mean: inheritance
    stripped, and no principal granted but this user.
    """
    if not path.exists():
        return None
    if _is_windows():
        try:
            completed = subprocess.run(
                ["icacls", str(path)],
                check=True,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        username = (os.environ.get("USERNAME") or getpass.getuser()).strip().lower()
        target = str(path).lower()
        principals: list[str] = []
        inherited = False
        for raw in (completed.stdout or "").splitlines():
            line = raw.strip()
            if not line or line.lower().startswith("successfully processed"):
                continue
            # icacls prints "<path> PRINCIPAL:(FLAGS)" on its first line and a
            # bare "PRINCIPAL:(FLAGS)" on every line after it.
            if line.lower().startswith(target):
                line = line[len(target):].strip()
            if ":" not in line:
                continue
            principal, _, flags = line.partition(":")
            # (I) marks an ACE inherited from the parent - exactly what
            # /inheritance:r removes, and exactly what a client rewriting its
            # own config re-acquires.
            if "(I)" in flags:
                inherited = True
            principals.append(principal.strip().lower())
        if not principals:
            return None
        if inherited:
            return NOT_OWNER_ONLY_ACL
        # A principal arrives as "DOMAIN\\user" or bare "user"; compare the
        # account name, which is what protect_path granted.
        if any(p.rsplit("\\", 1)[-1] != username for p in principals):
            return NOT_OWNER_ONLY_ACL
        return OWNER_ONLY_ACL
    return format(stat.S_IMODE(path.stat().st_mode), "04o")


class FileSystem:
    """Small wrapper around common filesystem operations."""

    def ensure_dir(self, path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True)

    def write_text(self, path: Path, content: str) -> None:
        # Files written by this subsystem can embed database credentials,
        # so they must be owner-only from the moment they exist — creating
        # with the default umask and chmod-ing afterward leaves a window
        # where other local users can read the secret. The 0o600 below is
        # that guarantee on POSIX only; on Windows it is protect_path() on
        # the temp file, before the replace, that provides it.
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
            if _is_windows():
                # The mode argument to os.open() did nothing here. Tighten the
                # ACL while the file is still the temp name, so the secret never
                # exists at inherited permissions under its real name.
                protect_path(tmp)
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
        # Snapshots of AI client configs go through here, and those configs
        # carry the read-only database password inline. copy2 copies the source
        # mode on POSIX and nothing at all on Windows, where the copy simply
        # inherits the backup directory's ACL - so the protection is applied
        # explicitly, on both platforms, to the file that just landed.
        self.ensure_dir(target.parent)
        shutil.copy2(source, target)
        protect_path(target)

    def exists(self, path: Path) -> bool:
        return path.exists()

    def hash_file(self, path: Path) -> str:
        return sha256_text(self.read_text(path))

    def mode_string(self, path: Path) -> str | None:
        if not path.exists():
            return None
        if _is_windows():
            # st_mode on Windows is synthetic - 0666 for anything writable,
            # 0444 for anything read-only - and says nothing about who may
            # read the file. Recording it in snapshot metadata dressed a
            # meaningless number as a permission record. There is no POSIX
            # mode to report here, so none is reported.
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
