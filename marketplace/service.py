"""Stable Python entry point for add-on lifecycle calls from exakit.

The platform launchers only provide process setup and CLI presentation. Add-on
decisions, receipts and installation live in the modules selected here.
"""

from __future__ import annotations

import argparse
import importlib
import json
import sys
from contextlib import nullcontext, redirect_stdout
from pathlib import Path

from model import CatalogError, load_addons
from runtime import AddonFailure, KitContext


OPERATIONS = {
    "install", "installed-version", "system-present", "applicable", "applicable-reason",
    "validate", "update", "uninstall", "summary", "status", "start", "stop",
    "url", "log-path", "autostart-command", "autostart-kind", "latest",
}


def _module(root: Path, addon_id: str):
    addons = {addon.id: addon for addon in load_addons(root)}
    addon = addons.get(addon_id)
    if addon is None:
        raise CatalogError(f"unknown add-on: {addon_id}")
    if not (root / "marketplace" / "addons" / (addon_id.replace("-", "_") + ".py")).is_file():
        raise CatalogError(f"{addon_id}: Python add-on module is missing")
    try:
        module = importlib.import_module("addons." + addon_id.replace("-", "_"))
    except (ImportError, SyntaxError) as error:
        raise CatalogError(f"{addon_id}: Python add-on module cannot load: {error}") from error
    return addon, module


def invoke(root: Path, addon_id: str, operation: str, *, dry_run: bool = False,
           ctx: KitContext | None = None) -> tuple[int, object | None]:
    if operation not in OPERATIONS:
        raise CatalogError(f"unknown add-on operation: {operation}")
    addon, module = _module(root, addon_id)
    if operation == "install" and not addon.visible:
        raise AddonFailure(f"{addon_id} is disabled in marketplace/catalog.json")
    method = operation.replace("-", "_")
    fn = getattr(module, method, None)
    if fn is None:
        raise CatalogError(f"{addon_id} does not support {operation}")
    ctx = ctx or KitContext.from_environment(root)
    if operation in ("install", "update", "uninstall", "validate", "start", "stop"):
        ctx.manifest.read()  # refuse a missing installation before any download or service action
    if operation == "install":
        receipt = f"components.{addon_id.replace('-', '_')}"
        owner = ctx.manifest.get(f"{receipt}.ownership")
        if owner in ("user", "unknown"):
            raise AddonFailure(f"{addon_id} is managed outside the kit; its owner keeps control")
        present = getattr(module, "system_present", None)
        if owner != "kit" and callable(present) and present(ctx):
            raise AddonFailure(f"{addon_id} is already installed outside the kit; its owner keeps control")
    if operation == "uninstall":
        value = fn(ctx, dry_run=dry_run)
    else:
        value = fn(ctx)
    if operation == "install" and ctx.manifest.get(f"components.{addon_id.replace('-', '_')}.ownership") != "kit":
        # Some add-ons deliberately return early when they discover an
        # external tool. A platform wrapper must never turn that successful
        # return into a kit-owned receipt.
        raise AddonFailure(f"{addon_id} was not installed by the kit; its owner keeps control")
    if operation in ("system-present", "applicable", "validate"):
        return (0 if value else 1), None
    if operation in ("installed-version", "latest") and not value:
        return 1, None
    return 0, value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("addon_id")
    parser.add_argument("operation", choices=sorted(OPERATIONS))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.dry_run and args.operation != "uninstall":
        parser.error("--dry-run is only valid for uninstall")
    try:
        # An add-on may report activity while it installs. Keep --json as one
        # parseable stdout object; human progress belongs on stderr here.
        with redirect_stdout(sys.stderr) if args.json else nullcontext():
            rc, value = invoke(Path(__file__).resolve().parent.parent, args.addon_id, args.operation,
                               dry_run=args.dry_run)
    except (AddonFailure, CatalogError, OSError, ValueError, KeyError) as error:
        if args.json:
            print(json.dumps({"ok": False, "addon": args.addon_id, "operation": args.operation,
                              "error": str(error)}, separators=(",", ":")))
        else:
            print(f"{args.addon_id}: {error}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps({"ok": rc == 0, "addon": args.addon_id, "operation": args.operation,
                          "value": value}, default=str, separators=(",", ":")))
    elif value is not None:
        if isinstance(value, list):
            for item in value:
                print(item)
        elif isinstance(value, (str, int, float)):
            print(value)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
