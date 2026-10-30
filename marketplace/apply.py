"""Apply a validated marketplace selection through the shared Python backend."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from integration import install_addon_skills, register_autostart
from model import CatalogError, load_addons
from runtime import AddonFailure, KitContext
from service import _module, invoke

ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Event:
    addon: str
    phase: str
    detail: str = ""
    seconds: int = 0


def _selection(root: Path, ids: str) -> list[str]:
    catalog = {addon.id: addon for addon in load_addons(root)}
    words = [word.strip().lower() for word in ids.split(",")]
    if not words or any(not word for word in words):
        raise CatalogError("a comma-separated add-on selection is required")
    seen: set[str] = set()
    result = []
    for word in words:
        if word not in catalog:
            raise CatalogError(f"unknown add-on: {word}")
        if not catalog[word].visible:
            raise CatalogError(f"{word} is disabled in marketplace/catalog.json")
        if word in seen:
            continue
        seen.add(word)
        result.append(word)
    return result


def apply(ctx: KitContext, ids: str, emit: Callable[[Event], None]) -> bool:
    selected = _selection(ctx.root, ids)
    ctx.manifest.read()
    modules = {addon_id: _module(ctx.root, addon_id)[1] for addon_id in selected}
    for module in modules.values():
        validate_selection = getattr(module, "validate_selection", None)
        if callable(validate_selection):
            validate_selection(ctx)
    previous_row = os.environ.get("EXAKIT_MARKETPLACE_ACTIVITY_ROW")
    try:
        return _apply_selected(ctx, modules, emit)
    finally:
        if previous_row is None:
            os.environ.pop("EXAKIT_MARKETPLACE_ACTIVITY_ROW", None)
        else:
            os.environ["EXAKIT_MARKETPLACE_ACTIVITY_ROW"] = previous_row


def _apply_selected(ctx: KitContext, modules: dict[str, object], emit: Callable[[Event], None]) -> bool:
    failed = False
    for addon_id, module in modules.items():
        started = time.monotonic()
        table_ids = os.environ.get("EXAKIT_ADDON_TABLE_IDS", "").splitlines()
        os.environ["EXAKIT_MARKETPLACE_ACTIVITY_ROW"] = (
            str(table_ids.index(addon_id) + 1) if addon_id in table_ids else "")
        emit(Event(addon_id, "installing"))
        try:
            invoke(ctx.root, addon_id, "install", ctx=ctx)
            emit(Event(addon_id, "validating"))
            try:
                valid, _ = invoke(ctx.root, addon_id, "validate", ctx=ctx) if callable(getattr(module, "validate", None)) else (0, None)
                if valid:
                    emit(Event(addon_id, "warning", "validation did not finish; retry with exakit update " + addon_id))
            except (AddonFailure, CatalogError, OSError, ValueError) as error:
                emit(Event(addon_id, "warning", f"validation reported: {error}"))
            try:
                install_addon_skills(ctx, addon_id)
            except (AddonFailure, OSError, ValueError) as error:
                emit(Event(addon_id, "warning", f"skills were not placed: {error}"))
            try:
                register_autostart(ctx, addon_id, module)
            except (AddonFailure, OSError, ValueError) as error:
                emit(Event(addon_id, "warning", f"autostart was not registered: {error}"))
            if callable(getattr(module, "start", None)):
                emit(Event(addon_id, "starting"))
                try:
                    invoke(ctx.root, addon_id, "start", ctx=ctx)
                except (AddonFailure, CatalogError, OSError, ValueError) as error:
                    emit(Event(addon_id, "warning", f"installed but did not start: {error}; retry with exakit start"))
            summary = ""
            if callable(getattr(module, "summary", None)):
                try:
                    _, value = invoke(ctx.root, addon_id, "summary", ctx=ctx)
                    summary = str(value or "")
                except (AddonFailure, CatalogError, OSError, ValueError):
                    pass
            emit(Event(addon_id, "done", summary, int(time.monotonic() - started)))
        except (AddonFailure, CatalogError, OSError, ValueError) as error:
            failed = True
            emit(Event(addon_id, "failed", str(error), int(time.monotonic() - started)))
    return not failed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ids", help="comma-separated add-on IDs")
    parser.add_argument("--json", action="store_true", help="emit one result object after all selected add-ons")
    parser.add_argument("--stream", action="store_true", help="emit live records for the platform progress table")
    args = parser.parse_args(argv)
    if args.json and args.stream:
        parser.error("--json and --stream cannot be combined")
    events: list[Event] = []

    def emit(event: Event) -> None:
        events.append(event)
        if args.json:
            return
        if args.stream:
            safe = event.detail.replace("\r", " ").replace("\n", " ").replace("|", " ")
            print(f"@@EXAKIT|{event.addon}|{event.phase}|{safe}|{event.seconds}", flush=True)
            return
        if event.phase == "done":
            print(f"  ✓ {event.addon} installed" + (f" — {event.detail}" if event.detail else ""), flush=True)
        elif event.phase == "failed":
            print(f"  ✗ {event.addon}: {event.detail}", file=sys.stderr, flush=True)
        elif event.phase == "warning":
            print(f"  ! {event.addon}: {event.detail}", file=sys.stderr, flush=True)
        else:
            print(f"  • {event.addon}: {event.phase}", flush=True)

    try:
        if args.json:
            from contextlib import redirect_stdout
            with redirect_stdout(sys.stderr):
                success = apply(KitContext.from_environment(ROOT), args.ids, emit)
        else:
            success = apply(KitContext.from_environment(ROOT), args.ids, emit)
    except (AddonFailure, CatalogError, OSError, ValueError) as error:
        if args.json:
            print(json.dumps({"ok": False, "error": str(error), "events": []}, separators=(",", ":")))
        else:
            print(f"marketplace: {error}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({"ok": success, "events": [event.__dict__ for event in events]}, separators=(",", ":")))
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
