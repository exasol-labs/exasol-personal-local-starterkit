"""Inside WSL a client found on the appended Windows PATH is not this distro's (WSL-01).

WSL appends the Windows PATH (/mnt/c/...), so a Windows-side Claude Code, Cursor or Codex used to be detected as
installed in the distro, reported "connected", and given a config in the distro's files that the Windows program
never reads. Detection now looks only at the distro's own directories there; outside WSL nothing changes.
"""

from __future__ import annotations

import os
from pathlib import Path
import unittest
from unittest.mock import patch

from mcp.adapters.base import program_on_path
from mcp.runtime.environment import ExecutionEnvironment

WINDOWS_DIR = "/mnt/c/Users/me/AppData/Local/Programs/claude"
LINUX_DIR = "/home/me/.local/bin"


def _executable_in(*directories: str):
    present = {str(Path(directory) / "claude") for directory in directories}
    return (patch.object(Path, "is_file", lambda self: str(self) in present),
            patch.object(os, "access", lambda path, mode: str(path) in present))


class WslPathTest(unittest.TestCase):
    def detect(self, env: dict[str, str], *present: str) -> str | None:
        is_file, access = _executable_in(*present)
        with is_file, access:
            return program_on_path(ExecutionEnvironment("linux", Path("/home/me"), env), ["claude"])

    def test_in_wsl_the_windows_program_does_not_count(self) -> None:
        env = {"PATH": f"{LINUX_DIR}:{WINDOWS_DIR}", "WSL_DISTRO_NAME": "Ubuntu"}
        self.assertIsNone(self.detect(env, WINDOWS_DIR))

    def test_in_wsl_the_distros_own_program_still_does(self) -> None:
        env = {"PATH": f"{WINDOWS_DIR}:{LINUX_DIR}", "WSL_INTEROP": "/run/WSL/1_interop"}
        self.assertEqual(self.detect(env, WINDOWS_DIR, LINUX_DIR), f"{LINUX_DIR}/claude")

    def test_outside_wsl_mnt_is_an_ordinary_directory(self) -> None:
        self.assertEqual(self.detect({"PATH": WINDOWS_DIR}, WINDOWS_DIR), f"{WINDOWS_DIR}/claude")


if __name__ == "__main__":
    unittest.main()


class WslClaudeDesktopTest(unittest.TestCase):
    """WSL-02: Claude Desktop from a distro is on the Windows side, and the route there is named."""

    def test_locate_names_the_windows_route(self) -> None:
        from mcp.adapters.claude_desktop import ClaudeDesktopAdapter

        env = ExecutionEnvironment("linux", Path("/home/me"), {"WSL_DISTRO_NAME": "Ubuntu"})
        location = ClaudeDesktopAdapter().locate(env)
        self.assertFalse(location.available)
        self.assertIn("Windows", location.evidence[0])
        self.assertIn("exakit mcp-setup", location.remedy)

    def test_plain_linux_is_unchanged(self) -> None:
        from mcp.adapters.claude_desktop import ClaudeDesktopAdapter

        location = ClaudeDesktopAdapter().locate(ExecutionEnvironment("linux", Path("/home/me"), {}))
        self.assertFalse(location.available)
        self.assertIsNone(location.remedy)
