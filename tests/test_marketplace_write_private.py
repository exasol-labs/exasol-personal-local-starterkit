"""runtime.write_private: a secret file is owner-only from the moment it exists (SEC-15)."""

from __future__ import annotations

import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from runtime import write_private  # noqa: E402


@unittest.skipIf(os.name == "nt", "POSIX modes")
class WritePrivateTest(unittest.TestCase):
    def test_created_owner_only_even_under_a_permissive_umask(self) -> None:
        old = os.umask(0o000)
        try:
            with tempfile.TemporaryDirectory() as temp:
                target = Path(temp) / "secret"
                write_private(target, "s3cret\n")
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
                self.assertEqual(target.read_text(encoding="utf-8"), "s3cret\n")
        finally:
            os.umask(old)

    def test_an_existing_loose_file_is_narrowed_and_replaced(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "secret"
            target.write_text("old-and-longer\n", encoding="utf-8")
            target.chmod(0o644)
            write_private(target, "new\n")
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            self.assertEqual(target.read_text(encoding="utf-8"), "new\n")

    def test_a_symlink_is_not_followed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            elsewhere = Path(temp) / "elsewhere"
            elsewhere.write_text("untouched\n", encoding="utf-8")
            link = Path(temp) / "secret"
            link.symlink_to(elsewhere)
            with self.assertRaises(OSError):
                write_private(link, "x\n")
            self.assertEqual(elsewhere.read_text(encoding="utf-8"), "untouched\n")


if __name__ == "__main__":
    unittest.main()
