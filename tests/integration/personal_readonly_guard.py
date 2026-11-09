"""Permit launcher queries during UDF reuse acceptance; refuse runtime changes."""

from pathlib import Path
import subprocess
import sys


def main(argv: list[str] | None = None) -> int:
    launcher, denied, *command = sys.argv[1:] if argv is None else argv
    if command[:1] not in (["version"], ["status"]) and command[:2] != ["slc", "list"]:
        Path(denied).touch()
        print("The UDF acceptance launcher refuses runtime changes", file=sys.stderr)
        return 97
    return subprocess.call([launcher, *command])


if __name__ == "__main__":
    raise SystemExit(main())
