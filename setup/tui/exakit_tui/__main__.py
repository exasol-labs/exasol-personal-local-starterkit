"""python -m exakit_tui --cli <word> [--cli <word>]... [--root <kit copy>] [--tab TAB] [--persona ID]

Started by `exakit` itself (bare, in a terminal; `exakit tui`; `exakit <persona-id>`), never on its own."""

from __future__ import annotations

import argparse
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="exakit tui", description="The whole kit on five tabs.")
    parser.add_argument("--cli", action="append", required=True,
                        help="the command that runs exakit, one word each: --cli bash --cli /path/setup/exakit")
    parser.add_argument("--root", default="", help="the kit copy (default: the kit copy this package is in)")
    parser.add_argument("--tab", default="status", choices=("status", "marketplace", "clients", "sources", "personas"))
    parser.add_argument("--persona", default=None, help="open the Personas tab on this persona")
    args = parser.parse_args(argv)
    from .app import run
    from .kit import Kit

    root = Path(args.root) if args.root else Path(__file__).resolve().parents[3]
    return run(Kit(args.cli, root), tab=args.tab, persona=args.persona)


if __name__ == "__main__":
    raise SystemExit(main())
