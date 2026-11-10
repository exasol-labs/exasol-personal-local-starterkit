"""Apply a validated marketplace selection through the shared Python backend."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator

from integration import install_addon_skills, register_autostart
from model import CatalogError, load_addons, parse_ids
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
    """The add-ons to apply: one parser with the shells (model.parse_ids), then the catalog's own rule that a
    disabled add-on is never installed."""
    catalog = {addon.id: addon for addon in load_addons(root)}
    if not (ids or "").strip():
        raise CatalogError("a comma-separated add-on selection is required")
    try:
        selected = parse_ids(ids, list(catalog), what="add-on", where="the selection")
    except CatalogError as error:
        raise CatalogError(str(error).replace("Unknown add-on in the selection", "unknown add-on")) from error
    for word in selected:
        if not catalog[word].visible:
            raise CatalogError(f"{word} is disabled in marketplace/catalog.json")
    return selected


# What one add-on's install can raise and still leave the batch standing: the next add-on is tried.
Failure = (AddonFailure, CatalogError, OSError, ValueError)


def apply(ctx: KitContext, ids: str, emit: Callable[[Event], None]) -> bool:
    """Install the selected add-ons, one after the other; ``emit`` receives one Event per phase. Every selection
    problem is raised before anything is touched. Returns True when every add-on installed."""
    selected = _selection(ctx.root, ids)
    ctx.manifest.read()
    modules = {addon_id: _module(ctx.root, addon_id)[1] for addon_id in selected}
    for module in modules.values():
        validate_selection = getattr(module, "validate_selection", None)
        if callable(validate_selection):
            validate_selection(ctx)
    with _activity_rows():
        return all([_apply_one(ctx, addon_id, module, emit) for addon_id, module in modules.items()])


@contextmanager
def _activity_rows() -> Iterator[None]:
    """The platform table's row for the add-on being installed travels to runtime.activity through
    EXAKIT_MARKETPLACE_ACTIVITY_ROW; whatever it held before is put back when the batch ends."""
    previous = os.environ.get("EXAKIT_MARKETPLACE_ACTIVITY_ROW")
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop("EXAKIT_MARKETPLACE_ACTIVITY_ROW", None)
        else:
            os.environ["EXAKIT_MARKETPLACE_ACTIVITY_ROW"] = previous


def _point_activity_at(addon_id: str) -> None:
    table_ids = os.environ.get("EXAKIT_ADDON_TABLE_IDS", "").splitlines()
    os.environ["EXAKIT_MARKETPLACE_ACTIVITY_ROW"] = str(table_ids.index(addon_id) + 1) if addon_id in table_ids else ""


def _installed(ctx: KitContext, addon_id: str, module: object) -> str | None:
    """The version this kit installed, when the receipt is the kit's and the add-on still reports one."""
    if ctx.manifest.get(f"components.{addon_id.replace('-', '_')}.ownership") != "kit":
        return None
    installed_version = getattr(module, "installed_version", None)
    try:
        version = installed_version(ctx) if callable(installed_version) else None
    except Failure:
        return None
    return str(version) if version else None


def _apply_one(ctx: KitContext, addon_id: str, module: object, emit: Callable[[Event], None]) -> bool:
    """One add-on: skip it when the kit already has it (a second run changes nothing), else install it and run
    the steps that follow, each of which can only warn."""
    started = time.monotonic()
    _point_activity_at(addon_id)
    version = _installed(ctx, addon_id, module)
    if version and os.environ.get("EXAKIT_FORCE_COMPONENT_INSTALL") != "1":
        emit(Event(addon_id, "done", f"already installed ({version}); exakit update {addon_id} refreshes it", 0))
        return True
    emit(Event(addon_id, "installing"))
    try:
        invoke(ctx.root, addon_id, "install", ctx=ctx)
    except Failure as error:
        emit(Event(addon_id, "failed", str(error), int(time.monotonic() - started)))
        return False
    for phase, said, step in _after_install(ctx, addon_id, module):
        if phase:
            emit(Event(addon_id, phase))
        try:
            warning = step()
        except Failure as error:
            warning = f"{said}: {error}"
        except Exception as error:   # noqa: BLE001 - a step after the install can only warn (audit WIN-02)
            warning = f"{said}: {type(error).__name__}: {error}"
        if warning:
            emit(Event(addon_id, "warning", warning))
    emit(Event(addon_id, "done", _summary(ctx, addon_id, module), int(time.monotonic() - started)))
    for event in _tool_rows(ctx, addon_id, module):
        emit(event)
    return True


def _after_install(ctx: KitContext, addon_id: str, module: object) -> list[tuple[str, str, Callable[[], str]]]:
    """The steps after a successful install, in order: (phase to announce, what a failure is called, the step).
    A step returns a warning text, or "" when all is well."""
    steps: list[tuple[str, str, Callable[[], str]]] = []
    if callable(getattr(module, "validate", None)):
        def validate() -> str:
            rc, _ = invoke(ctx.root, addon_id, "validate", ctx=ctx)
            return f"validation did not finish; retry with exakit update {addon_id}" if rc else ""
        steps.append(("validating", "validation reported", validate))
    steps.append(("", "skills were not placed", _silent(lambda: install_addon_skills(ctx, addon_id))))
    steps.append(("", "autostart was not registered", _silent(lambda: register_autostart(ctx, addon_id, module))))
    if callable(getattr(module, "start", None)):
        def start() -> str:
            try:
                invoke(ctx.root, addon_id, "start", ctx=ctx)
            except Failure as error:
                return f"installed but did not start: {error}; retry with exakit start"
            return ""
        steps.append(("starting", "installed but did not start", start))
    return steps


def _silent(run: Callable[[], object]) -> Callable[[], str]:
    """A step whose result is not a warning: it runs, and answers ""."""
    def step() -> str:
        run()
        return ""
    return step


def _summary(ctx: KitContext, addon_id: str, module: object) -> str:
    if not callable(getattr(module, "summary", None)):
        return ""
    try:
        _, value = invoke(ctx.root, addon_id, "summary", ctx=ctx)
    except Failure:
        return ""
    return str(value or "")


def _tool_rows(ctx: KitContext, addon_id: str, module: object) -> list[Event]:
    """Each of the add-on's tools on its own row (the notebook's JupyterLab and Marimo), once they settled."""
    if not callable(getattr(module, "tool_outcomes", None)):
        return []
    try:
        _, outcomes = invoke(ctx.root, addon_id, "tool-outcomes", ctx=ctx)
    except (*Failure, TypeError):
        return []
    return [Event(f"{addon_id}:{tool}", state, str(said))
            for tool, state, said in outcomes or [] if state in ("done", "skipped")]


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
        if ":" in event.addon:
            return  # a tool's own row is a table's; the add-on's line already says it installed
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
