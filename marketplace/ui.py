"""One Textual selector for personas and an in-place marketplace progress view."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path

from textual.app import App, ComposeResult
from textual.widgets import DataTable, ProgressBar, Static

from model import CatalogError, choose_addons, choose_personas, load_addons, load_personas


class ChoiceApp(App[dict | None]):
    """The kit's existing inline checkbox table, drawn through Textual.

    Arrow keys move, Space toggles, Enter applies, and Skip/Escape cancel.
    This keeps the existing interaction and leaves the earlier install screen
    visible above the selector on platforms where Textual supports inline mode.
    """

    INLINE_PADDING = 0
    BINDINGS = [("escape", "cancel", "Cancel"), ("space", "toggle", "Toggle"),
                ("enter", "confirm", "Install"), ("q", "cancel", "Cancel")]
    CSS = """
    Screen { background: $background; }
    #title { height: 2; margin: 0 1; text-style: bold; color: $text; }
    #table { height: auto; max-height: 22; margin: 0 1; border: round $accent; }
    #activity { display: none; height: 1; margin: 0 2; color: $text-muted; }
    #progress { display: none; height: 1; margin: 0 2; }
    #hint { height: 2; margin: 0 1; color: $text-muted; }
    Screen:inline { height: auto; max-height: 30; }
    """

    def __init__(self, mode: str, rows: list[dict], defaults: set[str], frontend_defaults: set[str],
                 *, apply_selection: bool = False):
        super().__init__()
        self.mode = mode
        self.rows = rows
        self.selected = {row["id"] for row in rows if row["id"] in defaults and not row.get("disabled")}
        self.choices_by_addon = {row["id"]: dict(row.get("choices", ())) for row in rows}
        self.choices = self.choices_by_addon.get("notebook", {})
        self.selected_choices = {
            row["id"]: ((set(frontend_defaults) & self.choices_by_addon[row["id"]].keys())
                        if row["id"] == "notebook" else set(self.choices_by_addon[row["id"]]))
            for row in rows if row["id"] in self.selected and self.choices_by_addon[row["id"]]
        }
        self.frontends = self.selected_choices.setdefault("notebook", set())
        self.table_rows: list[tuple[str, str | None]] = []
        self.apply_selection = apply_selection
        self.applying = False
        self._progress_floor = 0
        self._progress_ceiling = 0
        self._progress_seconds = 1
        self._progress_started = 0.0
        self._current_addon = ""
        self.apply_events = []
        self.title = "Exasol starter kit"

    def compose(self) -> ComposeResult:
        heading = {"persona": "What will you use this machine for?", "marketplace": "Marketplace add-ons",
                   "notebook": "Open which notebook tools?"}
        yield Static(heading[self.mode], id="title")
        yield DataTable(id="table", cursor_type="row", show_header=self.mode == "marketplace")
        yield Static("", id="activity")
        yield ProgressBar(total=100, show_eta=False, id="progress")
        yield Static("↑↓ move   Space select   Enter continue   Esc cancel", id="hint")

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_column("Selection", key="selection")
        if self.mode == "marketplace":
            table.add_column("Version", key="version", width=12)
            table.add_column("Description", key="description")
            self._add_row("all", None)
        for row in self.rows:
            self._add_row("item", row["id"])
            if self.mode == "marketplace" and not row.get("disabled"):
                for name in self.choices_by_addon[row["id"]]:
                    self._add_row("choice", f"{row['id']}:{name}")
        self._add_row("skip", None)
        if self.apply_selection:
            self.set_interval(0.2, self._tick_progress)
        table.focus()

    def _add_row(self, kind: str, name: str | None) -> None:
        self.table_rows.append((kind, name))
        cells = self._cells(kind, name)
        self.query_one(DataTable).add_row(*cells, key=f"row-{len(self.table_rows)}")

    def _cells(self, kind: str, name: str | None) -> tuple[str, ...]:
        if kind == "all":
            checked = all(row.get("disabled") or row["id"] in self.selected for row in self.rows)
            return (f"{'[✓]' if checked else '[ ]'} Select All", "", "")
        if kind == "skip":
            if self.mode == "marketplace":
                return ("[ ] Skip", "", "")
            if self.mode == "notebook":
                return ("[ ] Skip - open nothing",)
            return (f"{'[✓]' if not self.selected else '[ ]'} None - just the kit, with the TPC-H, energy and weather samples",)
        if kind == "choice":
            addon_id, choice_id = name.split(":", 1)
            label = self.choices_by_addon[addon_id][choice_id]
            picked = choice_id in self.selected_choices.get(addon_id, set())
            return (f"{'[✓]' if picked else '[ ]'}    └─ {label}", "", "")
        row = next(row for row in self.rows if row["id"] == name)
        prefix = "[·]" if row.get("disabled") else "[✓]" if name in self.selected else "[ ]"
        label = f"{prefix} ├─ {row['label']}" if self.mode == "marketplace" else f"{prefix} {row['label']}"
        if self.mode in ("persona", "notebook"):
            return (label + " - " + row.get("detail", ""),)
        return (label, str(row.get("version", "")), str(row.get("detail", "")))

    def _refresh(self) -> None:
        table = self.query_one(DataTable)
        for index, (kind, name) in enumerate(self.table_rows):
            cells = self._cells(kind, name)
            for column, value in enumerate(cells):
                table.update_cell_at((index, column), value)

    def action_cancel(self) -> None:
        if not self.applying:
            self.exit(None)

    def action_confirm(self) -> None:
        if self.applying:
            return
        table = self.query_one(DataTable)
        if self.table_rows[table.cursor_row][0] == "skip":
            self.exit(None)
            return
        selected = [row["id"] for row in self.rows if row["id"] in self.selected]
        frontends = [name for name in self.choices if name in self.frontends]
        result = {"selected": selected, "frontends": frontends}
        if self.mode == "marketplace":
            result["choices"] = {addon_id: [name for name in choices if name in self.selected_choices.get(addon_id, set())]
                                 for addon_id, choices in self.choices_by_addon.items()
                                 if addon_id in self.selected and choices}
        if self.apply_selection and not selected:
            self.exit(None)
            return
        if self.apply_selection and self.mode == "marketplace" and selected:
            self.applying = True
            self.query_one("#activity", Static).styles.display = "block"
            self.query_one("#progress", ProgressBar).styles.display = "block"
            self.query_one("#hint", Static).update("Installing selected add-ons…")
            asyncio.create_task(self._install(result))
            return
        self.exit(result)

    def action_toggle(self) -> None:
        if self.applying:
            return
        kind, name = self.table_rows[self.query_one(DataTable).cursor_row]
        if kind == "skip":
            self.selected.clear()
            for selected in self.selected_choices.values():
                selected.clear()
        elif kind == "all":
            enabled = {row["id"] for row in self.rows if not row.get("disabled")}
            self.selected = set() if self.selected == enabled else enabled
            for addon_id, choices in self.choices_by_addon.items():
                selected = self.selected_choices.setdefault(addon_id, set())
                selected.clear()
                if addon_id in self.selected:
                    selected.update(choices)
        elif kind == "item":
            row = next(row for row in self.rows if row["id"] == name)
            if row.get("disabled"):
                return
            if name in self.selected:
                self.selected.remove(name)
                self.selected_choices.setdefault(name, set()).clear()
            else:
                self.selected.add(name)
                selected = self.selected_choices.setdefault(name, set())
                if not selected:
                    selected.update(self.choices_by_addon.get(name, {}))
        elif kind == "choice":
            addon_id, choice_id = name.split(":", 1)
            selected = self.selected_choices.setdefault(addon_id, set())
            if choice_id in selected:
                selected.remove(choice_id)
            else:
                selected.add(choice_id)
                self.selected.add(addon_id)
        self._refresh()

    def on_data_table_row_selected(self, _: DataTable.RowSelected) -> None:
        self.action_confirm()

    def _tick_progress(self) -> None:
        if not self.applying or self._progress_ceiling <= self._progress_floor:
            return
        elapsed = time.monotonic() - self._progress_started
        step = int((self._progress_ceiling - self._progress_floor) * elapsed / self._progress_seconds)
        value = min(self._progress_ceiling - 1, self._progress_floor + max(0, step))
        self.query_one("#progress", ProgressBar).update(progress=value)

    def _on_activity(self, label: str) -> None:
        self.query_one("#activity", Static).update(label)

    def _on_event(self, event) -> None:
        self.apply_events.append(event)
        stages = {"installing": (0, 65, 40), "validating": (65, 90, 8),
                  "starting": (90, 100, 3)}
        if event.phase in stages:
            self._current_addon = event.addon
            self._progress_floor, self._progress_ceiling, self._progress_seconds = stages[event.phase]
            self._progress_started = time.monotonic()
            self.query_one("#progress", ProgressBar).update(progress=self._progress_floor)
            self._on_activity(f"{event.addon}: {event.phase}")
        elif event.phase == "warning":
            self._on_activity(f"{event.addon}: {event.detail}")
        else:
            self._progress_ceiling = 0
            self.query_one("#progress", ProgressBar).update(progress=100)
            self._on_activity(f"{event.addon}: {'installed' if event.phase == 'done' else event.detail}")
        row = next((row for row in self.rows if row["id"] == event.addon), None)
        if row is not None and event.phase != "warning":
            row["detail"] = event.detail if event.phase in ("done", "failed") else event.phase
            self._refresh()

    async def _install(self, result: dict) -> None:
        from apply import apply
        from runtime import KitContext, activity_sink

        selected = result["selected"]
        if "notebook" in selected:
            os.environ["EXAKIT_NOTEBOOK_FRONTENDS"] = ",".join(result["frontends"]) or "none"

        def run() -> bool:
            ctx = KitContext.from_environment(Path(__file__).resolve().parent.parent)
            with activity_sink(lambda label: self.call_from_thread(self._on_activity, label)):
                return apply(ctx, ",".join(selected),
                             lambda event: self.call_from_thread(self._on_event, event))

        try:
            result["success"] = await asyncio.to_thread(run)
        except Exception as error:
            result["success"] = False
            result["error"] = str(error)
            self._on_activity(str(error))
        self.exit(result)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("persona", "marketplace", "notebook"))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--states", type=Path)
    parser.add_argument("--defaults", default="")
    parser.add_argument("--recorded", default="")
    parser.add_argument("--only", default="")
    parser.add_argument("--frontends", default="jupyterlab,marimo,positron")
    parser.add_argument("--apply", action="store_true", help="keep Textual open while Python installs the selection")
    args = parser.parse_args()
    if args.apply and args.mode != "marketplace":
        parser.error("--apply is only valid for marketplace")
    root = Path(__file__).resolve().parent.parent
    defaults = {part for part in args.defaults.split(",") if part}
    try:
        if args.mode == "persona":
            personas = load_personas(root)
            rows = [{"id": row["id"], "label": row["title"], "detail": row.get("summary", "")}
                    for row in personas]
            if args.recorded:
                defaults = set(args.recorded.split(","))
            elif not defaults:
                defaults = {row["id"] for row in personas if row.get("default")}
            states = {}
            addons = []
        elif args.mode == "notebook":
            raw = json.loads(args.states.read_text(encoding="utf-8")) if args.states else {}
            rows = raw.get("tools", [])
            known = {"jupyterlab", "marimo", "positron"}
            if not isinstance(rows, list) or {row.get("id") for row in rows} != known:
                raise CatalogError("notebook choices must list JupyterLab, Marimo, and Positron once")
            defaults = set(args.recorded.split(",")) if args.recorded else {"jupyterlab"}
            if not defaults & known:
                defaults = {"jupyterlab"}
            states = {}
            addons = []
        else:
            all_addons = load_addons(root)
            addons = [addon for addon in all_addons if addon.visible]
            notebook = next((addon for addon in all_addons if addon.id == "notebook"), None)
            requested_frontends = {name for name in args.frontends.split(",") if name}
            available_frontends = {name for name, _ in notebook.choices} if notebook else set()
            unknown_frontends = requested_frontends - available_frontends
            if unknown_frontends:
                raise CatalogError(f"unknown notebook choice: {', '.join(sorted(unknown_frontends))}")
            if args.only:
                only = set(args.only.split(","))
                addons = [addon for addon in addons if addon.id in only]
            raw = json.loads(args.states.read_text(encoding="utf-8")) if args.states else {}
            states = {row["id"]: row for row in raw.get("addons", [])}
            rows = [{"id": row.id, "label": row.label, "version": row.version or row.default_version,
                     "choices": row.choices,
                     "detail": states.get(row.id, {}).get("status", "not in this kit copy"),
                     "disabled": states.get(row.id, {}).get("status") != "available"}
                    for row in addons]
            if args.recorded:
                defaults = set(args.recorded.split(","))
            elif not defaults:
                defaults = {row.id for row in addons if states.get(row.id, {}).get("status") == "available"}
        app = ChoiceApp(args.mode, rows, defaults, set(args.frontends.split(",")),
                        apply_selection=args.apply)
        result = app.run(inline=sys.platform != "win32", inline_no_clear=True)
        if result is None:
            return 10
        if args.apply:
            for event in app.apply_events:
                if event.phase in ("warning", "failed"):
                    print(f"{event.addon}: {event.detail}", file=sys.stderr)
                elif event.phase == "done" and sys.platform == "win32":
                    print(f"{event.addon} installed" + (f" — {event.detail}" if event.detail else ""))
            if result.get("error"):
                print(f"marketplace: {result['error']}", file=sys.stderr)
            return 0 if result.get("success") else 1
        if args.mode == "persona":
            selected = choose_personas(personas, result["selected"])
        elif args.mode == "notebook":
            selected = [row["id"] for row in rows if row["id"] in result["selected"] and not row.get("disabled")]
        else:
            selected = choose_addons(addons, states, result["selected"])
        frontends = result["frontends"] if "notebook" in selected else []
        payload = {"selected": selected, "frontends": frontends}
        if args.mode == "marketplace":
            payload["choices"] = result["choices"]
        temporary = args.out.with_name(args.out.name + ".tmp")
        temporary.write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
        os.replace(temporary, args.out)
        return 0
    except (OSError, ValueError, CatalogError, KeyError) as error:
        print(f"Marketplace UI: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
