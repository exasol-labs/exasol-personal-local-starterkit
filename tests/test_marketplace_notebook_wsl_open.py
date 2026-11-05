"""Inside WSL the notebook's login file is opened through Windows (WSL-03).

The browser in WSL is a Windows one, and file:///home/... means nothing to it; the login file is handed over as its
own Windows path (wslpath -w) and opened with explorer.exe. Its token never goes on a command line. Outside WSL
nothing changes.
"""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
import notebook_cli  # noqa: E402

TARGET = Path("/home/me/.exasol-starter-kit/notebook/open-jupyter.html")
WINDOWS = r"\\wsl.localhost\Ubuntu\home\me\.exasol-starter-kit\notebook\open-jupyter.html"


class WslOpenTest(unittest.TestCase):
    def test_in_wsl_explorer_gets_the_windows_path_and_nothing_secret(self) -> None:
        calls: list[list[str]] = []

        def run(args, **_kw):
            calls.append(list(args))
            out = WINDOWS + "\n" if args[0].endswith("wslpath") else ""
            return subprocess.CompletedProcess(args, 1 if "explorer" in args[0] else 0, stdout=out, stderr="")

        with patch.dict("os.environ", {"WSL_DISTRO_NAME": "Ubuntu"}), \
                patch("shutil.which", lambda name: f"/usr/bin/{name}"), patch("subprocess.run", run):
            self.assertTrue(notebook_cli._open_in_windows(TARGET))
        self.assertEqual(calls[0], ["/usr/bin/wslpath", "-w", str(TARGET)])
        self.assertEqual(calls[1], ["/usr/bin/explorer.exe", WINDOWS])

    def test_outside_wsl_it_steps_aside(self) -> None:
        with patch.dict("os.environ", {}, clear=True), patch("platform.release", return_value="6.8.0-generic"):
            self.assertFalse(notebook_cli._open_in_windows(TARGET))


if __name__ == "__main__":
    unittest.main()


class SnapBrowserTest(unittest.TestCase):
    """LNX-05: a snap-packaged default browser cannot read ~/.exasol-starter-kit; its own ~/snap/<name>/common it can."""

    def test_a_snap_firefox_gets_its_own_folder(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as home:
            (Path(home) / "snap" / "firefox" / "common").mkdir(parents=True)
            answer = subprocess.CompletedProcess([], 0, stdout="firefox_firefox.desktop\n", stderr="")
            with patch("sys.platform", "linux"), patch("shutil.which", return_value="/usr/bin/xdg-settings"), \
                    patch("subprocess.run", return_value=answer), patch("pathlib.Path.home", return_value=Path(home)):
                self.assertEqual(notebook_cli._snap_browser_folder(), Path(home) / "snap" / "firefox" / "common")

    def test_a_deb_browser_keeps_the_kit_folder(self) -> None:
        answer = subprocess.CompletedProcess([], 0, stdout="firefox.desktop\n", stderr="")
        with patch("sys.platform", "linux"), patch("shutil.which", return_value="/usr/bin/xdg-settings"), \
                patch("subprocess.run", return_value=answer):
            self.assertIsNone(notebook_cli._snap_browser_folder())
