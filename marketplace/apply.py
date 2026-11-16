"""Apply a validated marketplace selection through the shared Python backend."""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator

from integration import install_addon_skills, register_autostart
from model import CatalogError, load_addons, parse_ids
from runtime import AddonFailure, KitContext, activity_sink, append_log, current_activity_sink, log_sink
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
    """Install the selected add-ons; ``emit`` receives one Event per phase, in selection order. Consecutive
    parallel-safe add-ons download and build at the same time (_apply_side_by_side); everything else, and every step
    after an install, runs one after the other. Every selection problem is raised before anything is touched.
    Returns True when every add-on installed."""
    selected = _selection(ctx.root, ids)
    ctx.manifest.read()
    modules = {addon_id: _module(ctx.root, addon_id)[1] for addon_id in selected}
    for module in modules.values():
        validate_selection = getattr(module, "validate_selection", None)
        if callable(validate_selection):
            validate_selection(ctx)
    outer = emit

    def settled(event: Event) -> None:
        outer(event)
        if event.phase in ("done", "failed") and ":" not in event.addon:
            row = _table_row(event.addon)
            if row:
                ctx.clear_activity(row)     # its activity line goes with it

    emit = settled
    with _activity_rows():
        results: list[bool] = []
        for group in _groups(selected, modules):
            if len(group) == 1:
                results.append(_apply_one(ctx, group[0], modules[group[0]], emit))
            else:
                results.extend(_apply_side_by_side(ctx, group, modules, emit))
        return all(results)


# At most this many installs run at the same time; the rest wait for a free place.
WORKERS = 4


def _parallel_safe(module: object) -> bool:
    """An add-on whose install() only fetches files and builds its own environment under its own folders, and writes
    its receipt through the locked manifest, declares PARALLEL_INSTALL = True. Anything else (a container, the
    database's UDF setup, an add-on that needs another one installed first) installs on its own, as before."""
    return getattr(module, "PARALLEL_INSTALL", False) is True


def _groups(selected: list[str], modules: dict[str, object]) -> list[list[str]]:
    """The selection in its own order, cut into turns: consecutive parallel-safe add-ons share one turn; every other
    add-on is a turn of its own, so nothing that was installed before it in a serial run is still installing when it
    starts, and nothing after it has started. EXAKIT_MARKETPLACE_PARALLEL=0 makes every add-on its own turn."""
    serial = os.environ.get("EXAKIT_MARKETPLACE_PARALLEL", "1") == "0"
    groups: list[list[str]] = []
    joinable = False                     # the last turn is a parallel-safe one another may join
    for addon_id in selected:
        safe = not serial and _parallel_safe(modules[addon_id])
        if safe and joinable:
            groups[-1].append(addon_id)
        else:
            groups.append([addon_id])
        joinable = safe
    return groups


class _Turn:
    """What one add-on's install says while it waits for its turn. Activity and marketplace.log records are held
    until the add-on is the one being shown, then replayed in the order they happened and passed straight through
    from there on; so the progress output and the log read exactly as a one-after-the-other install's would."""

    def __init__(self, ctx: KitContext, show: Callable[[str], None], row: str = "", addon_id: str = ""):
        self._ctx = ctx
        self._show = show
        self._row = row
        self._addon_id = addon_id
        self._lock = threading.Lock()
        self._held: list[tuple[str, str]] = []
        self._live = False

    def activity(self, label: str) -> None:
        # In the platform's table every add-on has its own activity line: shown at once, on its own row.
        if self._row:
            self._ctx.show_activity(label, row=self._row)
            return
        # A table that reads the stream (Windows): the record names its add-on, so its own row shows it.
        if self._addon_id and os.environ.get("EXAKIT_MARKETPLACE_ACTIVITY_EVENTS") == "1":
            safe = label.replace("\r", " ").replace("\n", " ").replace("|", " ")
            print(f"@@EXAKIT|{self._addon_id}|activity|{safe}|0", flush=True)
            return
        with self._lock:
            if self._live:
                self._show(label)
            else:
                self._held.append(("activity", label))

    def log(self, record: str) -> None:
        with self._lock:
            if self._live:
                append_log(self._ctx.home, record)
            else:
                self._held.append(("log", record))

    def go_live(self) -> None:
        with self._lock:
            for kind, text in self._held:
                if kind == "activity":
                    self._show(text)
                else:
                    append_log(self._ctx.home, text)
            self._held.clear()
            self._live = True


def _install_held(ctx: KitContext, addon_id: str, turn: _Turn) -> tuple[BaseException | None, float]:
    """One add-on's install on a worker thread, everything it says held by its turn: (the failure, seconds taken)."""
    started = time.monotonic()
    with activity_sink(turn.activity), log_sink(turn.log):
        try:
            invoke(ctx.root, addon_id, "install", ctx=ctx)
        except Failure as error:
            return error, time.monotonic() - started
    return None, time.monotonic() - started


def _apply_side_by_side(ctx: KitContext, group: list[str], modules: dict[str, object],
                        emit: Callable[[Event], None]) -> list[bool]:
    """Install a turn's parallel-safe add-ons at the same time, then finish each in selection order on this thread:
    its events, the steps after the install (validation, skills, autostart, start) and its summary come out exactly
    as _apply_one's would. An add-on the kit already has is skipped as before and starts no worker."""
    force = os.environ.get("EXAKIT_FORCE_COMPONENT_INSTALL") == "1"
    pending = [addon_id for addon_id in group if force or not _installed(ctx, addon_id, modules[addon_id])]
    if len(pending) < 2:
        return [_apply_one(ctx, addon_id, modules[addon_id], emit) for addon_id in group]
    sink = current_activity_sink()
    show = sink if sink is not None else ctx.show_activity
    table = sink is None and bool(os.environ.get("EXAKIT_MARKETPLACE_ACTIVITY_FILE"))
    turns = {addon_id: _Turn(ctx, show, _table_row(addon_id) if table else "", addon_id if sink is None else "")
             for addon_id in pending}
    results: list[bool] = []
    with ThreadPoolExecutor(max_workers=min(WORKERS, len(pending)), thread_name_prefix="exakit-addon") as pool:
        futures: dict[str, Future] = {addon_id: pool.submit(_install_held, ctx, addon_id, turns[addon_id])
                                      for addon_id in pending}
        # Every one of them is installing NOW: each row gets its bar at once, side by side. What they say (the
        # activity line, the log) still comes out one add-on after the other, in selection order.
        for addon_id in pending:
            emit(Event(addon_id, "installing"))
        for addon_id in group:
            if addon_id not in futures:
                results.append(_apply_one(ctx, addon_id, modules[addon_id], emit))
                continue
            _point_activity_at(addon_id)
            turns[addon_id].go_live()
            error, seconds = futures[addon_id].result()
            finishing = time.monotonic()
            if error is not None:
                emit(Event(addon_id, "failed", str(error), int(seconds)))
                results.append(False)
                continue
            _finish(ctx, addon_id, modules[addon_id], emit, lambda: seconds + time.monotonic() - finishing)
            results.append(True)
    return results


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


def _table_row(addon_id: str) -> str:
    """The platform table's row for this add-on ("" when there is no table, or it has no row)."""
    table_ids = os.environ.get("EXAKIT_ADDON_TABLE_IDS", "").splitlines()
    return str(table_ids.index(addon_id) + 1) if addon_id in table_ids else ""


def _point_activity_at(addon_id: str) -> None:
    os.environ["EXAKIT_MARKETPLACE_ACTIVITY_ROW"] = _table_row(addon_id)


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
    _finish(ctx, addon_id, module, emit, lambda: time.monotonic() - started)
    return True


def _finish(ctx: KitContext, addon_id: str, module: object, emit: Callable[[Event], None],
            elapsed: Callable[[], float]) -> None:
    """After a successful install: the steps that follow, each of which can only warn, then done and the tool rows."""
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
    emit(Event(addon_id, "done", _summary(ctx, addon_id, module), int(elapsed())))
    for event in _tool_rows(ctx, addon_id, module):
        emit(event)


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
