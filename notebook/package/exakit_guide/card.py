"""The one widget every guided-view screen is drawn with.

A card is a list of declarative blocks (text, rows, buttons, forms, tables,
folds) that the front end (static/card.js) renders. Clicks come back as
events; the Python object that owns the card handles them and redraws.

Owners subclass `Screen`: implement `build()` (returns blocks) and
`on_<action id>(values)` handlers. Every handler is wrapped so the user sees
a plain sentence, never a traceback; details go to the log file.
"""

from __future__ import annotations

import json
import logging
import re
import weakref
import traceback
from pathlib import Path

import anywidget
import traitlets

STATIC = Path(__file__).parent / "static"


def _log_dir() -> Path:
    """The kit's own logs folder (~/.exasol-starter-kit/logs): installed, this package sits in a venv."""
    import os

    return Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit").expanduser() / "logs"


LOG_DIR = _log_dir()
_log = logging.getLogger("exakit_guide")
_SCREENS: weakref.WeakSet = weakref.WeakSet()  # every open card, so all can redraw


def redraw_all() -> None:
    for screen in list(_SCREENS):
        try:
            screen.refresh()
        except Exception:
            pass


def _logger() -> logging.Logger:
    if not _log.handlers:
        try:
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            handler = logging.FileHandler(LOG_DIR / "guide.log", encoding="utf-8")
            handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
            _log.addHandler(handler)
        except OSError:
            _log.addHandler(logging.NullHandler())
        _log.setLevel(logging.INFO)
    return _log


def _log_action(card: str, event: str, code: list[str], error: str | None) -> None:
    """One line in the workflow's log for each card action: the card, what was clicked, the exact code it ran and how
    it ended (nb.workflow_log shows them). The code never holds a secret: a key is passed beside it, not in it. Nothing
    when no workflow is active; a log that fails never fails the card."""
    if event == "refresh" or not code and error is None:
        return
    try:
        import json

        import importlib

        workflow = importlib.import_module("exakit_nb.workflow")     # the module: exakit_nb.workflow is a function too
        name = event
        if event.startswith("run:"):
            name = json.loads(event[4:])[0]
        workflow.log_event("guide_action", card=card, action=name, code="\n".join(code), ok=error is None,
                           **({"error": error} if error else {}))
    except Exception:
        _logger().warning("workflow log: %s", traceback.format_exc())


_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
_STEP = (re.compile(r"\bStep (\d+)\s*/\s*(\d+)", re.I), re.compile(r"\[(\d+)\s*/\s*(\d+)\]"))
_PERCENT = re.compile(r"(\d{1,3})(?:\.\d+)?\s*%")


class Progress:
    """A running kit command's progress, from the lines it prints (the same ones `exakit data-load` shows in a
    terminal): the last line as what it is doing now, a share done when a line says "Step 2/7", "[1/2]" or "40%",
    and the last few lines. Sent to the card at most a few times a second."""

    EVERY = 0.25

    def __init__(self, send) -> None:
        self.send, self.lines, self.partial, self.pct, self.sent, self.last = send, [], "", None, 0.0, None
        self.phase = ""                 # what the kit says it is doing (EXAKIT_PROGRESS_LOG), over its printed lines

    def kit(self, pct, phase: str) -> None:
        """The kit's own live progress (nb.exakit, watch_progress): the share done and the phase, as its terminal
        bar shows them."""
        if pct is not None:
            self.pct = max(0, min(100, int(pct)))
        if phase:
            self.phase = phase
        self._send(force=True)

    def feed(self, text: str) -> None:
        import time

        for piece in re.split(r"(\r\n|\n|\r)", self.partial + text):
            if piece in ("\r\n", "\n", "\r"):
                self._line(self.partial)
                self.partial = ""
            else:
                self.partial = piece
        self._send()

    def _send(self, force: bool = False) -> None:
        import time

        label = self.phase or (self.lines[-1] if self.lines else "")
        update = {"label": label, "pct": self.pct, "lines": self.lines[-6:]} if label else None
        if update and update != self.last and (force or time.monotonic() - self.sent >= self.EVERY):
            self.sent, self.last = time.monotonic(), update
            self.send(update)

    def _line(self, raw: str) -> None:
        line = _ANSI.sub("", raw).strip()
        if not line:
            return
        for pattern in _STEP:
            found = pattern.search(line)
            if found and int(found.group(2)):
                self.pct = min(100, round(100 * int(found.group(1)) / int(found.group(2))))
                break
        else:
            found = _PERCENT.search(line)
            if found and int(found.group(1)) <= 100:
                self.pct = int(found.group(1))
        if self.lines and line == self.lines[-1]:
            return
        self.lines.append(line)
        del self.lines[:-50]


class Card(anywidget.AnyWidget):
    _esm = STATIC / "card.js"
    _css = STATIC / "card.css"

    kind = traitlets.Unicode("card").tag(sync=True)
    blocks = traitlets.List([]).tag(sync=True)


class Screen:
    """Owns one Card: builds its blocks and handles its events."""

    kind = "card"

    def __init__(self) -> None:
        self.widget = Card(kind=self.kind)
        self.widget.on_msg(self._on_msg)
        self.flash: dict | None = None  # one message shown at the top until the next action
        self.ran: list[str] = []        # the code this card ran, in order: its Code view
        self.cells: dict[str, dict] = {}    # what each cell of its Code view last showed when run from there
        _SCREENS.add(self)

    # Displaying the Screen object in a notebook shows its card.
    def _repr_mimebundle_(self, **kwargs):
        return self.widget._repr_mimebundle_(**kwargs)

    def _display_(self):
        """Marimo's display hook: the same card, as Marimo's own anywidget element."""
        import marimo as mo

        return mo.ui.anywidget(self.widget)

    def build(self) -> list[dict]:
        raise NotImplementedError

    def _send_progress(self, action: str, update: dict) -> None:
        try:
            self.widget.send({"type": "progress", "id": action, **update})
        except Exception:
            pass

    def _code_mark(self) -> int:
        try:
            from .session import SESSION

            return len(SESSION.code)
        except Exception:
            return 0

    def _code_since(self, mark: int) -> list[str]:
        """What actions.run logged since mark: this card's own code, kept for its Code view."""
        try:
            from .session import SESSION

            new = list(SESSION.code[mark:])
        except Exception:
            return []
        self.ran.extend(line for line in dict.fromkeys(new) if line not in self.ran)   # a card's code once each
        return new

    # help: the links under this card's title, as (label, "page#heading") into the kit's documentation - what a step
    # does behind the scenes, how the data is cleaned, where a key comes from - each opening that very section.
    help: tuple[tuple[str, str], ...] = ()

    def _add_help(self, blocks: list[dict]) -> None:
        if not self.help:
            return
        head = next((b for b in blocks if b.get("t") in ("head", "home_head")), None)
        if head is None or "help" in head:
            return
        links = [{"label": label, "href": _cached_link(target)} for label, target in self.help]
        head["help"] = [link for link in links if link["href"]]

    def refresh(self) -> None:
        mark = self._code_mark()
        try:
            blocks = self.build()
            self._add_help(blocks)
        except Exception as exc:  # never leave a blank card
            _logger().error("build failed: %s\n%s", exc, traceback.format_exc())
            blocks = [{"t": "msg", "kind": "error",
                       "v": f"This screen couldn't load: {_plain(exc)} Details are in {LOG_DIR / 'guide.log'}."}]
        if self.flash:
            flash = {k: v for k, v in self.flash.items() if k != "said"}
            said = [{"t": "details", "title": "What the kit said", "open": True, "blocks": [{"t": "pre", "v": self.flash["said"]}]}] \
                if self.flash.get("said") else []
            lines = flash.pop("lines", None) or []
            note = [{"t": "msg", **flash}] + [{"t": "msg", "kind": kind, "v": text, "keep": True} for kind, text in lines] + said
            # Said where it was asked: under the buttons that were pressed (a long card's top is out of sight
            # from there), else at the top.
            pressed = getattr(self, "last_event", None)
            holds = [i for i, b in enumerate(blocks) if pressed and pressed in json.dumps(b)]
            buttons = [i for i, b in enumerate(blocks) if b.get("t") == "actions"]
            at = (holds or buttons or [-1])[-1] + 1
            blocks = blocks[:at] + note + blocks[at:]
        try:
            from .session import SESSION

            newer = SESSION.newer_approved()
        except Exception:
            newer = None
        if newer:
            blocks = [{"t": "msg", "kind": "warn",
                       "v": f"Step 1 approved {newer} after this page opened its data. This page still shows "
                            f"{getattr(SESSION.dataset, 'id', 'the earlier data')}. Run this cell again (Shift+Enter) to switch."}] + blocks
        if getattr(self, "brand", None) is not None:      # the first card of a page carries the kit's mark
            for block in blocks:
                if block.get("t") in ("head", "home_head"):
                    block["brand"] = self.brand
                    if getattr(self, "docs_url", ""):     # and a Docs button, to this page's documentation
                        block["docs"] = self.docs_url
                    break
        self._code_since(mark)
        if self.ran:
            blocks = blocks + [{"t": "ran", "v": "\n".join(self.ran)}]
        if getattr(self, "cells", None):
            blocks = blocks + [{"t": "cells", "v": self.cells}]
        self.widget.blocks = blocks

    def on_run_code(self, values: dict) -> None:
        """Run on a cell of this card's Code view: the code as it stands there (edited or not) runs in the notebook's
        namespace, as a cell of the notebook would, and what it printed or returned shows under it. The other cards
        redraw: the cell may have changed the data they show."""
        from . import actions
        from .session import SESSION

        key = str(values.get("cell") or "")
        result = actions.run_text(str(values.get("code") or ""))
        if getattr(self, "cells", None) is None:
            self.cells = {}
        self.cells[key] = {"ok": bool(result["ok"]), "text": str(result["text"])}
        SESSION.changed("code", self)

    def _on_msg(self, _widget, content, _buffers) -> None:
        if not isinstance(content, dict) or content.get("type") != "event":
            return
        action = str(content.get("id", ""))
        values = content.get("values") or {}
        self.flash = None
        try:
            from .session import SESSION

            SESSION.said = ""          # what this action prints, nothing older
        except Exception:
            pass
        mark, error = self._code_mark(), None
        self.last_event = f'"{action}"'          # the message goes under the block holding this button
        try:
            handler = getattr(self, f"on_{action}", None)
            if handler is None:
                raise ValueError("That button isn't wired up yet.")
            from .session import watch_output

            from exakit_nb.kit_commands import watch_progress

            self._live = Progress(lambda update: self._send_progress(action, update))
            with watch_output(self._live.feed), watch_progress(self._live.kit):
                handler(values)
        except Exception as exc:
            error = _plain(exc)
            _logger().error("action %s failed: %s\n%s", action, exc, traceback.format_exc())
            self.flash = {"kind": "error", "v": _plain(exc)}
            try:
                from .session import SESSION

                if SESSION.said:   # the kit's own lines say why: shown open under the error
                    self.flash["said"] = SESSION.said
            except Exception:
                pass
        finally:
            _log_action(type(self).__name__, action, self._code_since(mark), error)
            self.refresh()
            try:
                from .session import SESSION

                SESSION.release()      # don't hold a database connection while the card waits for the next click
            except Exception:
                pass
            try:
                self.widget.send({"type": "done", "id": action})
            except Exception:
                pass


def _plain(exc: Exception) -> str:
    """The kit's own errors are written for people; keep their sentence, drop the type name."""
    text = str(exc).strip() or exc.__class__.__name__
    return text if text.endswith((".", "!", "?")) else text + "."


def _persona_title() -> str:
    """The persona whose notebook this is, by its title in the kit (personas/*.json): the notebook's folder is the
    persona's id. Empty when the folder is no persona's."""
    try:
        import exakit.nb as nb
        from pathlib import Path

        here = Path.cwd().name
        return next((str(p["title"]) for p in nb.personas() if p["id"] == here), "")
    except Exception:
        return ""


def _docs_url(page: str) -> str:
    """Where this page's documentation is: the kit's own site, served from this computer by nb.docs() (it starts the
    server on the first call). The page of this notebook when the site has it, else this persona's section; empty
    when the kit copy has no documentation, and then no button shows."""
    try:
        import exakit.nb as nb

        found = nb.docs(page).url if page else ""
        return found if found and "?q=" not in found else nb.docs().url
    except Exception:
        return ""


def doc_link(target: str) -> str:
    """The kit's documentation at a page and, after #, a heading on it ("set-up/ai-and-langfuse#get-langfuse"):
    the link a field's "How do I get this?" opens. Empty when the kit copy has no documentation."""
    page, _, anchor = str(target or "").partition("#")
    url = _docs_url(page)
    if not url:
        return ""
    found_page = url.split("?", 1)[0].rstrip("/").endswith("/" + page.strip("/")) if page else True
    return url + (f"#{anchor}" if anchor and found_page else "")


_LINKS: dict[str, str] = {}


def _cached_link(target: str) -> str:
    """doc_link, once per target and kernel (it may start the documentation's server)."""
    if target not in _LINKS:
        _LINKS[target] = doc_link(target)
    return _LINKS[target]


def mark(screen: "Screen", docs: str = "") -> "Screen":
    """Make a card the first of its page: the kit's mark (the logo, Starter Kit - <persona>) and the Docs button,
    which opens ``docs``, this page's guide in the kit's documentation."""
    screen.brand = _persona_title()
    screen.docs_url = _docs_url(docs)
    screen.refresh()
    return screen


def show(*screens: "Screen", docs: str = ""):
    """Display a step's cards: one after another in JupyterLab (the cell's result is None); in Marimo, which has no
    display(), they come back stacked as the cell's result. ``docs`` is the page of the documentation the first
    card's Docs button opens."""
    if screens:
        mark(screens[0], docs)
    try:
        import marimo as mo

        if mo.running_in_notebook():
            return mo.vstack([screen._display_() for screen in screens])
    except ImportError:
        pass
    from IPython.display import display

    for screen in screens:
        display(screen)
    return None
