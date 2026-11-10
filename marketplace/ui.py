"""The persona, notebook-tool and marketplace questions, drawn through Textual exactly as the
kit's shell menus draw them.

Textual handles the keys, the mouse and the in-place redraw; what it draws is the shell's own
screen, character for character: ui_checkbox_menu (setup/lib/common.sh) for the persona and
notebook questions, ui_table_frame (setup/lib/ui.sh) for the marketplace table, and that table's
Status cells as the install's progress - the same bar the data-load table shows. The App runs
with ansi_color=True and paints no background, so the colours are the terminal's own: default
foreground, the 256-colour 35 accent, a bold green tick and dim detail, the codes the shell
writes, following whatever colour scheme the terminal has.

Keys are the shell's: up/down or j/k move, Space ticks, "a" ticks all, Enter confirms, Esc or q
cancels. A click ticks or unticks the row under it; only Enter moves on. The wheel belongs to the
terminal: the first wheel event hands mouse reporting back, so the screen scrolls as it always
does, and clicks are re-armed after two quiet seconds or on the next key (_ui_mouse_pause in
ui.sh is the shell twin).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import signal
import sys
import textwrap
import time
from pathlib import Path

# The shell writes the accent as 38;5;35. Textual would upgrade it to the same colour in RGB on a
# truecolor terminal; held at 256 colours it writes the shell's own code. Read at import.
os.environ.setdefault("TEXTUAL_COLOR_SYSTEM", "256")

from rich.cells import cell_len
from rich.style import Style
from rich.text import Text
from textual import events
from textual.app import App, ComposeResult
from textual.geometry import Size
from textual.widgets import Static

from model import CatalogError, choose_addons, choose_personas, load_addons, load_personas, split_ids

# The shell palette (ui.sh): UI_ACCENT 38;5;35, UI_OK 1;32, UI_ERR 1;31, UI_DIM 2, UI_BOLD 1.
ACCENT = Style(color="color(35)")
OK = Style(bold=True, color="green")
ERR = Style(bold=True, color="red")
DIM = Style(dim=True)
BOLD = Style(bold=True)
TICK, CROSS, BULLET, ARROW, POINTER = "✓", "✗", "•", "▸", "❯"
HR, TL, TR, BL, BR, VB = "─", "╭", "╮", "╰", "╯", "│"
BAR_FULL, BAR_EMPTY, EIGHTHS = "█", "░", " ▏▎▍▌▋▊▉"
HINT = "↑/↓ to move · Space to toggle · Enter to confirm"
STAT_MIN = 44                       # UI_TABLE_STAT_MIN
COL3_FIXED = 44                     # UI_TABLE_COL3_FIXED
COL3_MAX = 90                       # UI_TABLE_COL3_MAX
STAGES = {"installing": (0, 65, 40), "validating": (65, 90, 8), "starting": (90, 100, 3)}
CONNECTOR = {"tee": "├─ ", "corner": "└─ ", "tee-tee": "│  ├─ ", "tee-corner": "│  └─ ",
             "corner-tee": "   ├─ ", "corner-corner": "   └─ "}
SPINE = {"tee": "│", "corner": "", "tee-tee": "│  │", "tee-corner": "│",
         "corner-tee": "   │", "corner-corner": ""}


def fit(text: str, chrome: int, cols: int) -> str:
    """_ui_fit_row: a row that would pass the last column is cut, with an ellipsis."""
    if len(text) + chrome > cols:
        return text[:max(1, cols - chrome - 1)] + "…"
    return text


def creep(floor: int, ceiling: int, seconds: int, elapsed: float) -> int:
    """ui_progress_creep: between the stage reached and the next, never claiming the next."""
    span = ceiling - floor
    if span <= 0 or seconds <= 0:
        return floor
    return floor + min(span - 1, max(0, int(span * elapsed / seconds)))


def widths(cols: int, name_w: int, col2_w: int, col3_w: int, stat_w: int) -> tuple[int, int, int]:
    """ui_table_widths: the Description grows into slack up to UI_TABLE_COL3_MAX, gives way first
    on a narrow terminal (down to 8, then the whole column), then the name, then the Status."""
    total = 9 + name_w + 3 + 2 + col2_w + (2 + col3_w if col3_w else 0) + (2 + stat_w if stat_w else 0)
    over = total - cols
    if over < 0 and col3_w:
        grow = max(0, min(COL3_MAX - col3_w, -over))
        col3_w += grow
        over += grow
    if over > 0 and col3_w:
        if over >= col3_w + 2:
            over -= col3_w + 2
            col3_w = 0
        else:
            col3_w -= over
            over = 0
            if col3_w < 8:
                over, col3_w = 8 - col3_w, 8
    if over > 0:
        name_w -= over
        if name_w < 12:
            over, name_w = 12 - name_w, 12
            stat_w = max(12, stat_w - over)
    return name_w, col3_w, stat_w


def finished(detail: str, seconds) -> str:
    """_exakit_addon_table_cell: the summary padded to the column, then the elapsed time."""
    elapsed = f"{'(' + str(seconds) + 's)':>5}"
    room = STAT_MIN - len(TICK) - len(elapsed) - 2
    text = detail or "installed"
    if len(text) > room:
        text = text[:room - 1] + "…"
    return f"{text:<{room}} {elapsed}"


# Trailing padding: spaces, and the style codes around them, at the end of a line.
_PADDING = re.compile(r"(?:\x1b\[[0-9;]*m| )*$")


def _unpadded(frame: str) -> str:
    """A frame's lines without the spaces Textual pads them to the full width with; the rest of each line is
    cleared instead (ESC[K). A padded line fills the last column and leaves the terminal waiting to wrap, and
    such lines did not re-wrap the way the redraw counts them: iTerm2 left twice as much of the old frame
    above the new one. Unpadded, a terminal re-wraps what the redraw counts, the visible text. The block
    paints no background, so nothing is lost."""
    tail = re.search(r"(?:\n\x1b\[J)?(?:\x1b\[\d+A)?$", frame)
    body, end = frame[:tail.start()], frame[tail.start():]
    lines = [_PADDING.sub(lambda match: "\x1b[0m\x1b[K" if " " in match.group(0) else match.group(0), line)
             for line in body.split("\n")]
    return "\n".join(lines) + end


class Screenful(Static):
    """The whole question as one block of text, the way the shell prints it."""

    # Never wrapped: every line is already fitted to the width. Wrapped, the old (wider) frame grew
    # taller for the one repaint Textual makes before the redraw at a new size, and pushed the
    # install's output above it off the screen.
    DEFAULT_CSS = """Screenful { background: ansi_default; color: ansi_default; padding: 0;
                                 text-wrap: nowrap; text-overflow: clip; }"""

    def on_click(self, event: events.Click) -> None:
        self.app.click_line(event.y, event.button)

    def on_resize(self, _: events.Resize) -> None:
        self.app.after_resize()


class ChoiceApp(App[dict | None]):
    """One question, drawn as the shell draws it; see the module docstring."""

    INLINE_PADDING = 0
    BINDINGS = [("escape", "cancel", "Cancel"), ("q", "cancel", "Cancel"), ("space", "toggle", "Toggle"),
                ("enter", "confirm", "Confirm"), ("up", "move(-1)", "Up"), ("k", "move(-1)", "Up"),
                ("down", "move(1)", "Down"), ("j", "move(1)", "Down"), ("a", "select_all", "All")]
    # No background, no inline border, no scrollbar: Textual's own chrome would be the one
    # thing on screen the shell never draws.
    CSS = """
    Screen { background: ansi_default; color: ansi_default; scrollbar-size: 0 0; }
    Screen:inline, Screen:ansi:inline { height: auto; border-top: none; border-bottom: none; }
    """

    def __init__(self, mode: str, rows: list[dict], defaults: set[str], frontend_defaults: set[str],
                 *, apply_selection: bool = False):
        super().__init__(ansi_color=True)
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
        self.skip = False
        self.apply_selection = apply_selection
        self.applying = False
        self.apply_events = []
        self.status: dict[str, dict] = {}
        self.activity = ""
        self.active = ""
        self.line_rows: list[int | None] = []
        self._mouse_paused = False
        self._rearm = None
        self._resize_pending = False
        self.table_rows: list[tuple[str, str | None]] = []
        if mode == "marketplace":
            self.table_rows.append(("all", None))
        for row in rows:
            if row.get("disabled"):
                continue
            self.table_rows.append(("item", row["id"]))
            if mode == "marketplace":
                self.table_rows.extend(("choice", f"{row['id']}:{name}") for name in self.choices_by_addon[row["id"]])
        if mode == "marketplace":
            self.table_rows.extend(("disabled", row["id"]) for row in rows if row.get("disabled"))
        elif mode == "notebook":
            self.table_rows.extend(("disabled", row["id"]) for row in rows if row.get("disabled"))
        if mode != "persona":
            self.table_rows.append(("skip", None))
        # The shell's first cursor position: past the group row, never on a row that cannot be picked.
        pickable = [i for i, (kind, _) in enumerate(self.table_rows) if kind not in ("disabled", "all")]
        self.cursor = pickable[0] if pickable else 0

    # --- what is drawn ------------------------------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Screenful(id="screen")

    def on_mount(self) -> None:
        self.set_interval(0.2, self._tick)
        self._keep_the_screen_on_resize()
        self._draw()

    def _keep_the_screen_on_resize(self) -> None:
        """Textual's inline driver answers a terminal resize with ESC[2J, which wipes the WHOLE screen -
        the install's output above the question vanished and only this block was drawn again. Its handler
        is replaced, and between frames the cursor waits on the block's LAST line instead of its first.

        Why the last line: a terminal that narrows re-wraps every line that no longer fits, and it keeps the
        cursor at the end of what is written - what lies below the cursor it treats as empty. Parked on the
        block's first line (Textual's way) the whole block sat below the cursor: xterm.js (the desktop app's
        panel) left the cursor halfway down the re-wrapped frame, Terminal.app scrolled the frame up and put
        the cursor on the bottom row, and every redraw left part of the old frame above the new one. Parked
        on the last line, the rows the old frame fills after any resize are known exactly - each of its
        lines was written to the full width it was drawn at, so it now takes ceil(drawn / new width) rows -
        and the redraw moves up that far, clears down, and draws the block where it was. Everything above
        it stays."""
        driver = getattr(self, "_driver", None)
        if sys.platform == "win32" or not hasattr(signal, "SIGWINCH") or not getattr(driver, "is_inline", False):
            return
        loop = asyncio.get_running_loop()
        write = driver.write
        parked = self._parked = {"rows": 0, "on": True}

        def write_frame(data: str) -> None:
            # A frame is what Textual's InlineUpdate writes: the lines, then the move back to the first one
            # (ESC[nA, CR) or just a CR for a single line, then ESC[6n. Before it the cursor goes back up from
            # where it waits; after it, down to the last line (the ESC[6n answer, which places mouse clicks,
            # still reports the first line: the terminal answers before it moves).
            if not data.endswith("\r\x1b[6n"):
                write(data)
                return
            if self._resize_pending and parked["on"]:
                # Drawn at the width before the resize, a frame wraps in the narrower terminal and its move
                # back up lands inside the block: every frame after it was out of place. iTerm2 reports the
                # pointer moving while its window resizes, and each report repainted the block. The block
                # is drawn again, whole, once it is laid out at the new width.
                return
            core = _unpadded(data[:-len("\r\x1b[6n")])
            data = core + "\r\x1b[6n"
            rows = 0
            if core.endswith("A"):
                start = core.rfind("\x1b[")
                count = core[start + 2:-1] if start >= 0 else ""
                if count.isdigit():
                    rows = int(count) - (1 if "\x1b[J" in core else 0)
            up = f"\x1b[{parked['rows']}A\r" if parked["rows"] else ""
            if not parked["on"]:
                write(up + data)
                parked["rows"] = 0
                return
            write(up + data + (f"\x1b[{rows}B" if rows else ""))
            parked["rows"] = rows

        driver.write = write_frame
        burst = {"generation": 0}

        def on_resize(_signum, _frame) -> None:
            # From here until the resize is handled no frame is drawn: one drawn at the old width
            # would wrap in the narrower terminal and push the redraw out of place.
            self._resize_pending = True
            burst["generation"] += 1
            generation = burst["generation"]

            async def redraw() -> None:
                # A window that is dragged, or animated as Terminal.app does, sends a signal for every column
                # it passes: one redraw, once it has stopped. Thirty overlapping redraws stacked thirty frames.
                await asyncio.sleep(0.15)
                if generation != burst["generation"]:
                    return
                width, height = driver._get_terminal_size()
                # The rows between the block's first line and the one the cursor waits on, as the terminal now
                # holds them: a line wider than the terminal takes one row per width it spans, the rest one.
                shown = getattr(self, "_shown", [])
                above = shown[:parked["rows"]] + [0] * max(0, parked["rows"] - len(shown))
                up = sum(max(1, -(-columns // max(1, width))) for columns in above)
                write((f"\x1b[{up}A" if up else "") + "\r\x1b[J")
                parked["rows"] = 0
                await self._post_message(events.Resize(Size(width, height), Size(width, height)))
                # A resize that ends at the size it began lays nothing out again, and the block would wait.
                await asyncio.sleep(0.5)
                if generation == burst["generation"] and self._resize_pending:
                    self.after_resize()

            asyncio.run_coroutine_threadsafe(redraw(), loop)

        signal.signal(signal.SIGWINCH, on_resize)

    def exit(self, *args, **kwargs) -> None:
        """Back to the block's first line before Textual's own exit, which moves and prints from there."""
        parked = getattr(self, "_parked", None)
        if parked and parked["on"]:
            parked["on"] = False
            if parked["rows"]:
                self._driver.write(f"\x1b[{parked['rows']}A\r")
                parked["rows"] = 0
        super().exit(*args, **kwargs)

    def after_resize(self) -> None:
        """Called by the block itself once Textual has laid it out at the new size. Drawn on the App's
        resize instead, the new content was painted at the old width, wrapped, and left a copy of the
        block above the redraw."""
        self._resize_pending = False
        self._draw()

    def _tick(self) -> None:
        if self.applying:
            self._draw()

    def _draw(self) -> None:
        if self._resize_pending:
            return
        text, self.line_rows = self.render_screen(max(40, self.size.width or 80))
        # What each line shows, without the padding Textual adds: a terminal that re-wraps on resize
        # counts only this, so it is what tells how many rows the frame takes at a new width.
        self._shown = [cell_len(line.rstrip()) for line in text.plain.split("\n")]
        self.query_one("#screen", Screenful).update(text)

    def _label(self, name: str) -> str:
        row = next(row for row in self.rows if row["id"] == name)
        return row["label"] + (" - " + row["detail"] if row.get("detail") else "")

    def _ticked(self, kind: str, name: str | None) -> bool:
        if kind == "all":
            return self._all_selected()
        if kind == "skip":
            return self.skip
        if kind == "choice":
            addon_id, choice_id = name.split(":", 1)
            return choice_id in self.selected_choices.get(addon_id, set())
        return kind == "item" and name in self.selected

    def render_screen(self, width: int) -> tuple[Text, list[int | None]]:
        """The question as the shell prints it, and which row each printed line belongs to."""
        if self.mode == "marketplace":
            return self._render_table(width)
        return self._render_checkbox(width)

    def _render_checkbox(self, width: int) -> tuple[Text, list[int | None]]:
        """ui_checkbox_menu: the title as an info line, one row per choice, the dim hint."""
        cols = width - 1
        out, lines = Text(), []
        if self.mode == "notebook":
            out.append("  ").append(ARROW, OK).append(" Open which notebook tools?\n")
            lines.append(None)
        title = "Personas - tick one or more" if self.mode == "persona" else "Notebook tools - tick one or more"
        out.append("    ").append(BULLET, DIM).append(f" {title}\n")
        lines.append(None)
        for index, (kind, name) in enumerate(self.table_rows):
            label = "Skip - open nothing" if kind == "skip" else self._label(name)
            if kind == "disabled":
                out.append("      ").append("[ ] " + fit(label, 10, cols), DIM).append("\n")
            else:
                pointer = POINTER if index == self.cursor and not self.applying else " "
                out.append("    ").append(pointer, ACCENT).append(" ")
                out.append(f"[{TICK}]", OK) if self._ticked(kind, name) else out.append("[ ]")
                out.append(" " + fit(label, 10, cols) + "\n")
            lines.append(index)
        out.append("      ").append(fit(HINT, 6, cols), DIM)
        lines.append(None)
        return out, lines

    def _table_entries(self) -> list[dict]:
        """_exakit_addon_table_build: Select All, the add-ons with their choices one level down,
        the ones that cannot be picked, Skip."""
        entries = []
        last_item = max((i for i, (kind, _) in enumerate(self.table_rows) if kind in ("item", "disabled")), default=-1)
        children_of: dict[str, list[int]] = {}
        for index, (kind, name) in enumerate(self.table_rows):
            if kind == "choice":
                children_of.setdefault(name.split(":", 1)[0], []).append(index)
        for index, (kind, name) in enumerate(self.table_rows):
            entry = {"index": index, "kind": kind, "tree": "", "version": "", "desc": "", "parent": False}
            if kind == "all":
                entry["label"] = "Select All"
            elif kind == "skip":
                entry["label"] = "Skip"
            elif kind in ("item", "disabled"):
                row = next(row for row in self.rows if row["id"] == name)
                # label keys the row (its install status, the active row); shown is what it says.
                entry.update(label=name, shown=row.get("label") or name, version=str(row.get("version") or ""),
                             desc=row.get("reason", "") if kind == "disabled" else row.get("about", ""),
                             tree="corner" if index == last_item else "tee",
                             parent=bool(children_of.get(name)))
            else:
                addon_id, choice_id = name.split(":", 1)
                parent_tree = "corner" if self.table_rows.index(("item", addon_id)) == last_item else "tee"
                siblings = children_of[addon_id]
                entry.update(label=self.choices_by_addon[addon_id][choice_id],
                             tree=f"{parent_tree}-{'corner' if index == siblings[-1] else 'tee'}")
            entries.append(entry)
        return entries

    def _cell(self, entry: dict, stat_w: int, now: float) -> tuple[Text, int]:
        """_ui_table_cell: the bar while running, the tick and summary when done."""
        if entry["kind"] == "disabled":
            return (Text(entry["desc"], DIM), len(entry["desc"])) if stat_w else (Text(), 0)
        key = (entry["label"] if entry["kind"] == "item"
               else self.table_rows[entry["index"]][1] if entry["kind"] == "choice" else None)
        state = self.status.get(key) if key else None
        if not state:
            return Text(), 0
        if state["state"] == "skipped":
            return Text(state["final"], DIM), len(state["final"])
        if state["state"] == "running":
            bar_w = max(8, stat_w - 7)
            at = min(100, creep(state["pct"], state["ceil"], state["secs"], now - state["t0"]))
            units = at * bar_w * 8 // 100
            full, rem = min(bar_w, units // 8), units % 8
            head = EIGHTHS[rem] if full < bar_w and rem else ""
            empty = max(0, bar_w - full - len(head))
            cell = Text().append(BAR_FULL * full, ACCENT).append(head + BAR_EMPTY * empty, DIM)
            cell.append(f"{at}%".rjust(7))
            return cell, bar_w + 7
        if state["state"] == "done":
            return Text().append(TICK, OK).append(" " + state["final"]), len(TICK) + 1 + len(state["final"])
        final = "did not finish — see the log"
        return Text().append(CROSS, ERR).append(" " + final), len(CROSS) + 1 + len(final)

    def _render_table(self, width: int) -> tuple[Text, list[int | None]]:
        """ui_table_frame, then ui_table_menu's hint while the selection is open."""
        entries = self._table_entries()
        name_w = max([10] + [len(CONNECTOR.get(e["tree"], "")) + len(e.get("shown", e["label"])) for e in entries])
        col2_w = max([len("Version")] + [len(e["version"]) for e in entries])
        stat_w = 0
        if self.status:
            stat_w = max([STAT_MIN] + [len(s["final"]) + len(TICK) + 1 for s in self.status.values() if s.get("final")])
        # The Description helps the choice; once Enter starts the install the rows show
        # their Version and Status only (_exakit_marketplace_menu drops UI_TABLE_COL3).
        name_w, col3_w, stat_w = widths(width, name_w, col2_w, 0 if self.applying else COL3_FIXED, stat_w)
        sep = "  "
        inner = 5 + name_w + 1 + len(sep) + col2_w + (len(sep) + col3_w if col3_w else 0) + (len(sep) + stat_w if stat_w else 0)
        now = time.monotonic()
        out, lines = Text(), []

        def border(left: str, right: str, body: Text) -> None:
            out.append("  ").append(left, ACCENT).append_text(body).append(right + "\n", ACCENT)

        out.append("\n    ").append(BULLET, DIM).append(" Details on any add-on: exakit help <id>\n")
        lines += [None, None]
        title = " Marketplace add-ons "
        out.append("  ").append(TL + HR, ACCENT).append(title, BOLD)
        out.append(HR * max(0, inner - len(title) - 1) + TR + "\n", ACCENT)
        lines.append(None)
        head = "     " + "Add-on".ljust(name_w) + sep + "Version".ljust(col2_w)
        if col3_w:
            head += sep + "Description"[:col3_w].ljust(col3_w)
        if stat_w:
            head += sep + "Status"
        border(VB, VB, Text(head.ljust(inner)))
        lines.append(None)
        status_left = 5 + name_w + len(sep) + col2_w + (len(sep) + col3_w if col3_w else 0) + len(sep)
        for entry in entries:
            if self.applying and entry["kind"] == "item" and entry["label"] == self.active:
                room = inner - status_left
                # Cut where the cell ends, and say so: a label stopping mid-word reads as broken.
                note = self.activity if len(self.activity) <= room else self.activity[:max(room - 1, 0)] + "…"
                border(VB, VB, Text(" " * status_left).append(note.ljust(inner - status_left), DIM))
                lines.append(None)
            kind = entry["kind"]
            # Built from an unstyled Text: a Text made WITH a style hands it to everything
            # appended after it, and the name would come out in the accent colour.
            row = Text().append(POINTER if entry["index"] == self.cursor and not self.applying else " ", ACCENT)
            if kind == "disabled":
                row.append("   ")
            elif self._ticked(kind, self.table_rows[entry["index"]][1]):
                row.append(f"[{TICK}]", OK)
            else:
                row.append("[ ]")
            name = CONNECTOR.get(entry["tree"], "") + entry.get("shown", entry["label"])
            if len(name) > name_w and entry.get("shown"):
                # Too narrow for "name (id)": the id the commands take, rather than a name cut short.
                name = CONNECTOR.get(entry["tree"], "") + entry["label"]
            name = name if len(name) <= name_w else name[:name_w - 1] + "…"
            wrapped = textwrap.wrap(entry["desc"], col3_w) if entry["desc"] and col3_w else []
            row.append(" ")
            row.append(name.ljust(name_w), DIM if kind == "disabled" else None)
            version = entry["version"] if len(entry["version"]) <= col2_w else entry["version"][:col2_w - 1] + "…"
            row.append(sep).append(version.ljust(col2_w), DIM)
            used = 1 + 3 + 1 + name_w + len(sep) + col2_w
            if col3_w:
                row.append(sep).append((wrapped[0] if wrapped else "").ljust(col3_w), DIM)
                used += len(sep) + col3_w
            if stat_w:
                cell, cell_len = self._cell(entry, stat_w, now)
                row.append(sep).append_text(cell)
                used += len(sep) + cell_len
            row.append(" " * max(0, inner - used))
            border(VB, VB, row)
            lines.append(entry["index"])
            spine = SPINE.get(entry["tree"], "")
            if entry["parent"]:
                spine = "│  │" if entry["tree"] == "tee" else "   │"
            for more in wrapped[1:]:
                cont = Text("     " + spine.ljust(name_w) + sep + " " * col2_w + sep)
                cont.append(more.ljust(col3_w), DIM)
                cont.append(" " * max(0, inner - (5 + name_w + len(sep) + col2_w + len(sep) + col3_w)))
                border(VB, VB, cont)
                lines.append(entry["index"])
        out.append("  ").append(BL + HR * inner + BR, ACCENT)
        lines.append(None)
        if not self.applying:
            out.append("\n      ").append(HINT, DIM)
            lines.append(None)
        return out, lines

    # --- keys and the mouse -----------------------------------------------------------------------

    def _pickable(self, index: int) -> bool:
        return self.table_rows[index][0] != "disabled"

    def action_move(self, step: int) -> None:
        if self.applying or not self.table_rows:
            return
        for _ in range(len(self.table_rows)):
            self.cursor = (self.cursor + step) % len(self.table_rows)
            if self._pickable(self.cursor):
                break
        self._draw()

    def click_line(self, line: int, button: int) -> None:
        if self.applying or button != 1 or not 0 <= line < len(self.line_rows):
            return
        index = self.line_rows[line]
        if index is None or not self._pickable(index):
            return
        self.cursor = index
        self.action_toggle()

    def on_mouse_scroll_down(self, _: events.MouseScrollDown) -> None:
        self._pause_mouse()

    def on_mouse_scroll_up(self, _: events.MouseScrollUp) -> None:
        self._pause_mouse()

    def _pause_mouse(self) -> None:
        """Hand the wheel back to the terminal (see the module docstring)."""
        driver = getattr(self, "_driver", None)
        if self._mouse_paused or driver is None or not hasattr(driver, "_disable_mouse_support"):
            return
        driver._disable_mouse_support()
        self._mouse_paused = True
        self._rearm = self.set_timer(2.0, self._rearm_mouse)

    def _rearm_mouse(self) -> None:
        if self._rearm is not None:
            self._rearm.stop()
            self._rearm = None
        driver = getattr(self, "_driver", None)
        if self._mouse_paused and driver is not None and hasattr(driver, "_enable_mouse_support"):
            driver._enable_mouse_support()
        self._mouse_paused = False

    def on_key(self, _: events.Key) -> None:
        if self._mouse_paused:
            self._rearm_mouse()

    def _all_selected(self) -> bool:
        enabled = [row["id"] for row in self.rows if not row.get("disabled")]
        return bool(enabled) and all(
            addon in self.selected and set(self.choices_by_addon[addon]).issubset(
                self.selected_choices.get(addon, set())) for addon in enabled)

    def action_cancel(self) -> None:
        if not self.applying:
            self.exit(None)

    def action_select_all(self) -> None:
        """"a" ticks every real choice - never the exclusive Skip, never a disabled row."""
        if self.applying or self.mode == "marketplace":
            return
        self.skip = False
        self.selected = {row["id"] for row in self.rows if not row.get("disabled")}
        self._draw()

    def action_confirm(self) -> None:
        if self.applying:
            return
        if self.table_rows[self.cursor][0] == "skip" or self.skip:
            self.exit(None)
            return
        selected = [row["id"] for row in self.rows if row["id"] in self.selected]
        if not selected:
            self.bell()                                 # at least one selection, as in the shell menus
            return
        frontends = [name for name in self.choices if name in self.frontends]
        result = {"selected": selected, "frontends": frontends}
        if self.mode == "marketplace":
            result["choices"] = {addon_id: [name for name in choices if name in self.selected_choices.get(addon_id, set())]
                                 for addon_id, choices in self.choices_by_addon.items()
                                 if addon_id in self.selected and choices}
        if self.apply_selection and self.mode == "marketplace":
            self.applying = True
            self._draw()
            asyncio.create_task(self._install(result))
            return
        self.exit(result)

    def action_toggle(self) -> None:
        if self.applying:
            return
        kind, name = self.table_rows[self.cursor]
        if kind == "skip":
            self.skip = not self.skip
            if self.skip:
                self.selected.clear()
                for selected in self.selected_choices.values():
                    selected.clear()
        elif kind == "all":
            enabled = {row["id"] for row in self.rows if not row.get("disabled")}
            self.selected = set() if self._all_selected() else enabled
            for addon_id, choices in self.choices_by_addon.items():
                selected = self.selected_choices.setdefault(addon_id, set())
                selected.clear()
                if addon_id in self.selected:
                    selected.update(choices)
            self.skip = False
        elif kind == "item":
            self.skip = False
            if name in self.selected:
                self.selected.remove(name)
                self.selected_choices.setdefault(name, set()).clear()
            else:
                self.selected.add(name)
                selected = self.selected_choices.setdefault(name, set())
                if not selected:
                    selected.update(self.choices_by_addon.get(name, {}))
        elif kind == "choice":
            self.skip = False
            addon_id, choice_id = name.split(":", 1)
            selected = self.selected_choices.setdefault(addon_id, set())
            if choice_id in selected:
                selected.remove(choice_id)
            else:
                selected.add(choice_id)
                self.selected.add(addon_id)
        self._draw()

    # --- the install, in the table's Status column ------------------------------------------------

    def _on_activity(self, label: str) -> None:
        self.activity = label

    def _on_event(self, event) -> None:
        self.apply_events.append(event)
        if ":" in event.addon:
            # One of an add-on's tools (notebook:jupyterlab), settled: its own row's Status says how.
            if event.phase in ("done", "skipped", "failed"):
                self.status[event.addon] = {"state": event.phase, "final": event.detail}
            self._draw()
            return
        if event.phase in STAGES:
            floor, ceiling, seconds = STAGES[event.phase]
            previous = self.status.get(event.addon, {})
            self.status[event.addon] = {"state": "running", "pct": floor, "ceil": ceiling, "secs": seconds,
                                        "t0": time.monotonic(), "final": ""}
            if previous.get("state") == "running":     # a new phase keeps the job's place on the bar
                self.status[event.addon]["pct"] = max(floor, creep(previous["pct"], previous["ceil"],
                                                                   previous["secs"], time.monotonic() - previous["t0"]))
            self.active = event.addon
            self.activity = event.phase
        elif event.phase == "done":
            self.status[event.addon] = {"state": "done", "final": finished(event.detail, getattr(event, "seconds", 0) or 0)}
        elif event.phase == "failed":
            self.status[event.addon] = {"state": "failed", "final": ""}
        row = next((row for row in self.rows if row["id"] == event.addon), None)
        if row is not None and event.phase != "warning":
            row["detail"] = event.detail if event.phase in ("done", "failed") else event.phase
        self._draw()

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
        self.active = ""
        self._draw()
        self.exit(result)


def about(path: Path | None) -> dict[str, tuple[str, str]]:
    """id|label|description lines, as the shell resolved them: the row's name (the repository's on GitHub,
    the id beside it when they differ) and its About. The About is last: prose, it may hold a "|"."""
    if not path or not path.is_file():
        return {}
    found = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split("|", 2)
        if len(parts) == 3 and parts[0]:
            found[parts[0]] = (parts[1].strip(), parts[2].strip())
    return found


NOTEBOOK_TOOLS = ("jupyterlab", "marimo", "positron")


def notebook_tools(raw: dict) -> list[dict]:
    """The notebook menu's rows: JupyterLab and Marimo, each once; Positron only when the caller
    offers it (it stays hidden until it is fully supported)."""
    rows = raw.get("tools", [])
    ids = [row.get("id") for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []
    if len(ids) != len(rows) or len(set(ids)) != len(ids) \
            or not {"jupyterlab", "marimo"} <= set(ids) <= set(NOTEBOOK_TOOLS):
        raise CatalogError("notebook choices must list JupyterLab and Marimo once")
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("persona", "marketplace", "notebook"))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--states", type=Path)
    parser.add_argument("--about", type=Path, help="id|label|description lines: each add-on row's name and About")
    parser.add_argument("--defaults", default="")
    parser.add_argument("--recorded", default="")
    parser.add_argument("--only", default="")
    parser.add_argument("--frontends", default="jupyterlab,marimo")
    parser.add_argument("--apply", action="store_true", help="keep the table open while Python installs the selection")
    args = parser.parse_args()
    if args.apply and args.mode != "marketplace":
        parser.error("--apply is only valid for marketplace")
    root = Path(__file__).resolve().parent.parent
    defaults = {part for part in split_ids(args.defaults) if part}
    try:
        if args.mode == "persona":
            personas = load_personas(root)
            rows = [{"id": row["id"], "label": row["title"], "detail": row.get("summary", "")}
                    for row in personas]
            if args.recorded:
                defaults = {part for part in split_ids(args.recorded) if part}
            elif not defaults:
                defaults = {row["id"] for row in personas if row.get("default")}
            states = {}
            addons = []
        elif args.mode == "notebook":
            raw = json.loads(args.states.read_text(encoding="utf-8")) if args.states else {}
            rows = notebook_tools(raw)
            known = {row["id"] for row in rows}
            defaults = ({part for part in split_ids(args.recorded) if part} if args.recorded else {"jupyterlab"}) & known
            if not defaults:
                defaults = {"jupyterlab"}
            states = {}
            addons = []
        else:
            all_addons = load_addons(root)
            addons = [addon for addon in all_addons if addon.visible]
            notebook = next((addon for addon in all_addons if addon.id == "notebook"), None)
            requested_frontends = {name for name in split_ids(args.frontends) if name and name != "none"}
            available_frontends = {name for name, _ in notebook.choices} if notebook else set()
            unknown_frontends = requested_frontends - available_frontends
            if unknown_frontends:
                raise CatalogError(f"unknown notebook choice: {', '.join(sorted(unknown_frontends))}")
            if args.only:
                only = set(split_ids(args.only))
                addons = [addon for addon in addons if addon.id in only]
            raw = json.loads(args.states.read_text(encoding="utf-8")) if args.states else {}
            states = {row["id"]: row for row in raw.get("addons", [])}
            abouts = about(args.about)
            # Not offerable here and not installed: no row at all, as in the shell table.
            addons = [addon for addon in addons
                      if states.get(addon.id, {}).get("status") != "not available on this machine"]
            rows = []
            for row in addons:
                status = states.get(row.id, {}).get("status", "not in this kit copy")
                installed = status == "installed"
                shown, said = abouts.get(row.id, ("", ""))
                rows.append({"id": row.id, "label": shown or row.label,
                             "version": (states.get(row.id, {}).get("version") if installed else None)
                             or row.version or row.default_version,
                             "choices": row.choices, "detail": status,
                             # The shell's live About, else the catalog's copy of it, else the help pointer.
                             "about": said or row.kit_about or row.github.get("about") or f"Details: exakit help {row.id}",
                             "reason": "Installed" if installed else status,
                             "disabled": status != "available"})
            if args.recorded:
                defaults = {part for part in split_ids(args.recorded) if part}
            elif not defaults or defaults == {"all"}:
                # No preselection, or "all" (EXAKIT_MARKETPLACE_PRESELECT=all): every add-on that can be installed.
                defaults = {row.id for row in addons if states.get(row.id, {}).get("status") == "available"}
        app = ChoiceApp(args.mode, rows, defaults, requested_frontends if args.mode == "marketplace" else set(),
                        apply_selection=args.apply)
        result = app.run(inline=True, inline_no_clear=True)  # never full screen; launch.py keeps Windows out
        if result is None:
            return 10
        if args.apply:
            for event in app.apply_events:
                if event.phase in ("warning", "failed"):
                    print(f"{event.addon}: {event.detail}", file=sys.stderr)
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
