"""Retain the Marimo process marker used by installed kits."""
import sys

from server_wrapper import run


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1:]))
