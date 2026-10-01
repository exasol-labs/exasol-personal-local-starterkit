"""The Windows half of "owner-only" is real, not a chmod that does nothing.

Everything the runtime writes under the kit home can carry the read-only
database password - the AI client configs above all, and every snapshot copy of
them. On POSIX that is a 0600 mode; on Windows ``chmod`` only toggles the
read-only attribute and the file keeps whatever ACL its parent handed down,
which on a domain machine with folder redirection is an ACL a file-server admin
set. These tests drive the Windows branch on any platform (CI has no Windows
runner) and fail if the snapshot path, the directory creation or the reported
permission ever go back to POSIX-only.
"""

from __future__ import annotations

from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

from mcp.runtime.filesystem import OWNER_ONLY_ACL, FileSystem
from mcp.runtime.manifest import ManifestRepository
from mcp.runtime.paths import RuntimePaths
from mcp.runtime.snapshots import SnapshotRepository
from mcp.security.policy import SecurityPolicy


class _FakeIcacls:
    """Stand-in for subprocess.run that records the icacls invocations."""

    def __init__(self) -> None:
        self.calls: list[list[str]] = []

    def __call__(self, args, **kwargs):
        self.calls.append(list(args))
        return mock.Mock(returncode=0)

    def paths_granted(self) -> set[str]:
        return {call[1] for call in self.calls if call and call[0] == "icacls"}


class WindowsProtectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-win-acl-tests-"))
        self.filesystem = FileSystem()

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def _as_windows(self, icacls: _FakeIcacls):
        return (
            mock.patch("mcp.runtime.filesystem._is_windows", return_value=True),
            mock.patch("mcp.runtime.filesystem.subprocess.run", icacls),
        )

    def test_snapshot_backup_gets_a_windows_acl(self) -> None:
        """The snapshot path is Windows-aware.

        create_snapshot copies each managed config into backups/; a bare
        shutil.copy2 left that copy - password inside - at whatever ACL the
        backup directory inherited.
        """
        config = self._temp_dir / "claude_desktop_config.json"
        config.write_text('{"password": "s3cret"}', encoding="utf-8")
        paths = RuntimePaths(runtime_root=self._temp_dir / "runtime")
        manifests = ManifestRepository(paths=paths, filesystem=self.filesystem)
        snapshots = SnapshotRepository(paths=paths, manifest_repository=manifests)

        icacls = _FakeIcacls()
        windows, patched_run = self._as_windows(icacls)
        with windows, patched_run:
            record = snapshots.create_snapshot("configure", [config])

        backup = paths.backups_dir / record["snapshot_id"] / "artifacts" / record["files"][0]["backup_name"]
        self.assertTrue(backup.exists())
        self.assertIn(str(backup), icacls.paths_granted())

    def test_runtime_directories_get_a_windows_acl(self) -> None:
        paths = RuntimePaths(runtime_root=self._temp_dir / "runtime")
        icacls = _FakeIcacls()
        windows, patched_run = self._as_windows(icacls)
        with windows, patched_run:
            paths.ensure()

        granted = icacls.paths_granted()
        for directory in (paths.mcp_dir, paths.backups_dir, paths.logs_dir):
            self.assertIn(str(directory), granted)
        # A directory's grant has to be inheritable, or files created inside it
        # afterwards pick up nothing.
        for call in icacls.calls:
            self.assertIn("/inheritance:r", call)
            self.assertTrue(call[-1].endswith(":(OI)(CI)F"), call)

    def test_reported_permission_is_not_a_posix_mode_on_windows(self) -> None:
        artifact = self._temp_dir / "config.json"
        artifact.write_text("{}", encoding="utf-8")

        icacls = _FakeIcacls()
        windows, patched_run = self._as_windows(icacls)
        with windows, patched_run:
            self.assertIsNone(self.filesystem.mode_string(artifact))
            self.assertEqual(SecurityPolicy().apply_managed_permissions(artifact), OWNER_ONLY_ACL)

    def test_posix_still_reports_a_mode(self) -> None:
        artifact = self._temp_dir / "config.json"
        artifact.write_text("{}", encoding="utf-8")
        with mock.patch("mcp.runtime.filesystem._is_windows", return_value=False):
            self.assertEqual(SecurityPolicy().apply_managed_permissions(artifact), "0600")
            self.assertEqual(self.filesystem.mode_string(artifact), "0600")


if __name__ == "__main__":
    unittest.main()


class DescribeProtectionTests(unittest.TestCase):
    """The READ side of protect_path, which did not exist.

    The validator's permission check read ``stat().st_mode`` and compared it
    only when not on Windows - and then recorded a PASS for the comparison it
    had just skipped. So on the platform where the exposure matters most, and
    on the files that carry the database password in plaintext, mcp-doctor
    asserted a posture it had never looked at.

    These drive the Windows branch on any platform, the same way the tests
    above do, because CI has no Windows runner.
    """

    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-acl-read-tests-"))
        self.addCleanup(shutil.rmtree, self._temp_dir, True)
        self.target = self._temp_dir / "claude.json"
        self.target.write_text("{}", encoding="utf-8")

    def _icacls(self, stdout: str):
        def _run(args, **kwargs):
            return mock.Mock(returncode=0, stdout=stdout, stderr="")
        return _run

    def _describe(self, stdout: str, username: str = "piotr") -> str | None:
        from mcp.runtime import filesystem as fs
        with mock.patch.object(fs, "_is_windows", return_value=True), \
             mock.patch.dict("os.environ", {"USERNAME": username}), \
             mock.patch.object(fs.subprocess, "run", self._icacls(stdout)):
            return fs.describe_protection(self.target)

    def test_owner_only_acl_is_recognised(self) -> None:
        from mcp.runtime.filesystem import OWNER_ONLY_ACL
        out = f"{self.target} DESKTOP-1\\piotr:(F)\n\nSuccessfully processed 1 files.\n"
        self.assertEqual(self._describe(out), OWNER_ONLY_ACL)

    def test_an_inherited_ace_is_drift(self) -> None:
        """The exact shape a client rewrite produces: the file is recreated and
        picks the parent's ACEs back up, marked (I)."""
        from mcp.runtime.filesystem import NOT_OWNER_ONLY_ACL
        out = (
            f"{self.target} DESKTOP-1\\piotr:(F)\n"
            "                 NT AUTHORITY\\SYSTEM:(I)(F)\n"
        )
        self.assertEqual(self._describe(out), NOT_OWNER_ONLY_ACL)

    def test_another_principal_is_drift(self) -> None:
        """No inheritance, but a second account is granted - a file-share ACL
        on a redirected profile looks like this."""
        from mcp.runtime.filesystem import NOT_OWNER_ONLY_ACL
        out = (
            f"{self.target} DESKTOP-1\\piotr:(F)\n"
            "                 CORP\\helpdesk:(R)\n"
        )
        self.assertEqual(self._describe(out), NOT_OWNER_ONLY_ACL)

    def test_unreadable_acl_is_none_not_a_pass(self) -> None:
        """The distinction the whole fix rests on: a check that could not run
        must not be folded into either outcome."""
        from mcp.runtime import filesystem as fs

        def _boom(args, **kwargs):
            raise OSError("icacls not found")

        with mock.patch.object(fs, "_is_windows", return_value=True), \
             mock.patch.object(fs.subprocess, "run", _boom):
            self.assertIsNone(fs.describe_protection(self.target))

    def test_empty_icacls_output_is_none(self) -> None:
        self.assertIsNone(self._describe("\nSuccessfully processed 1 files.\n"))

    def test_posix_still_reports_the_mode(self) -> None:
        from mcp.runtime import filesystem as fs
        self.target.chmod(0o600)
        with mock.patch.object(fs, "_is_windows", return_value=False):
            self.assertEqual(fs.describe_protection(self.target), "0600")
        self.target.chmod(0o644)
        with mock.patch.object(fs, "_is_windows", return_value=False):
            self.assertEqual(fs.describe_protection(self.target), "0644")
