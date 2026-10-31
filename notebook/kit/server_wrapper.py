"""Forward notebook server output while masking its login token."""

from __future__ import annotations

import signal
import subprocess
import sys
from pathlib import Path


def run(args: list[str]) -> int:
    token = Path(args[0]).read_text(encoding="utf-8").strip()
    with subprocess.Popen(args[1:], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                          errors="replace", bufsize=1) as child:
        def stop(*_):
            child.terminate()

        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, stop)
        for line in child.stdout:
            sys.stdout.write(line.replace(token, "***") if token else line)
            sys.stdout.flush()
        return child.wait()


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
