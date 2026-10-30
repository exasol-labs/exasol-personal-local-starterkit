"""Read-only catalog adapter for the two platform entry scripts.

The output is deliberately line based: neither shell needs to parse JSON or
maintain an add-on list. All fields are validated before any row is printed.
"""

from __future__ import annotations

import argparse
import importlib
import sys
from pathlib import Path

from model import CatalogError, load_addons
from service import OPERATIONS


def rows(root: Path, kind: str) -> list[str]:
    addons = load_addons(root)
    result = []
    for addon in addons:
        if kind == "registry":
            result.append("|".join((addon.id, addon.label, addon.backend,
                                    "1" if addon.visible else "0", addon.default_version)))
        elif kind == "shell-hooks":
            if not (root / "marketplace" / "addons" / (addon.id.replace("-", "_") + ".py")).is_file():
                continue
            try:
                module = importlib.import_module("addons." + addon.id.replace("-", "_"))
            except (ImportError, SyntaxError):
                continue
            for operation in sorted(OPERATIONS):
                method = operation.replace("-", "_")
                if callable(getattr(module, method, None)):
                    result.append(f"{addon.id}|{method}|{operation}")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("kind", choices=("registry", "shell-hooks"))
    args = parser.parse_args(argv)
    try:
        for row in rows(args.root, args.kind):
            print(row)
    except (OSError, ValueError, CatalogError, ImportError) as error:
        print(f"marketplace catalog: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
