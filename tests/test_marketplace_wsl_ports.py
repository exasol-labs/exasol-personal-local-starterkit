"""Inside WSL a port a Windows program listens on is not free (WSL-04).

The notebook, MLflow and Dash URLs open in a Windows browser on Windows' localhost, where a Windows-side listener on
the same port wins over the distro's forwarded one; the ports used to be checked only inside the distro. netstat.exe
answers for the Windows side; outside WSL it is never asked.
"""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
sys.path.insert(0, str(ROOT / "setup" / "lib"))
import process  # noqa: E402
import mlflow_service  # noqa: E402

NETSTAT = """
Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1234
  TCP    127.0.0.1:8888         0.0.0.0:0              LISTENING       4321
  TCP    127.0.0.1:5000         0.0.0.0:0              LISTENING       999
  TCP    [::]:5100              [::]:0                 LISTENING       777
  TCP    192.168.1.5:52000      20.1.1.1:443           ESTABLISHED     55
"""


def _netstat(args, **_kw):
    return subprocess.CompletedProcess(args, 0, stdout=NETSTAT, stderr="")


class WslPortsTest(unittest.TestCase):
    def setUp(self) -> None:
        process._WINDOWS_LISTENING = None

    def test_windows_listeners_are_read_once(self) -> None:
        with patch.dict("os.environ", {"WSL_DISTRO_NAME": "Ubuntu"}), \
                patch("shutil.which", return_value="/mnt/c/Windows/System32/netstat.exe"), \
                patch("subprocess.run", side_effect=_netstat) as run:
            self.assertTrue(process.windows_listening(8888))
            self.assertTrue(process.windows_listening(5100))
            self.assertFalse(process.windows_listening(52000))     # an outgoing connection, not a listener
            self.assertFalse(process.windows_listening(8889))
        self.assertEqual(run.call_count, 1)

    def test_outside_wsl_windows_is_never_asked(self) -> None:
        with patch.dict("os.environ", {}, clear=True), patch("subprocess.run") as run:
            self.assertFalse(process.windows_listening(8888))
        run.assert_not_called()

    def test_mlflow_skips_a_port_windows_holds(self) -> None:
        with patch.dict("os.environ", {"WSL_DISTRO_NAME": "Ubuntu"}), \
                patch("shutil.which", return_value="/mnt/c/Windows/System32/netstat.exe"), \
                patch("subprocess.run", side_effect=_netstat), \
                patch("socket.socket") as sock:
            sock.return_value.__enter__.return_value.bind.return_value = None
            self.assertEqual(mlflow_service.free_port(5000), 5001)


if __name__ == "__main__":
    unittest.main()
