"""The one widget every guided-view screen is drawn with.

A card is a list of declarative blocks (text, rows, buttons, forms, tables,
folds) that the front end (static/card.js) renders. Clicks come back as
events; the Python object that owns the card handles them and redraws.

Owners subclass `Screen`: implement `build()` (returns blocks) and
`on_<action id>(values)` handlers. Every handler is wrapped so the user sees
a plain sentence, never a traceback; details go to the log file.
"""

from __future__ import annotations

import logging
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

    def refresh(self) -> None:
        try:
            blocks = self.build()
        except Exception as exc:  # never leave a blank card
            _logger().error("build failed: %s\n%s", exc, traceback.format_exc())
            blocks = [{"t": "msg", "kind": "error",
                       "v": f"This screen couldn't load: {_plain(exc)} Details are in {LOG_DIR / 'guide.log'}."}]
        if self.flash:
            blocks = [{"t": "msg", **self.flash}] + blocks
        try:
            from .session import SESSION

            newer = SESSION.newer_approved()
        except Exception:
            newer = None
        if newer:
            blocks = [{"t": "msg", "kind": "warn",
                       "v": f"Step 1 approved {newer} after this page opened its data. This page still shows "
                            f"{getattr(SESSION.dataset, 'id', 'the earlier data')}. Run this cell again (Shift+Enter) to switch."}] + blocks
        self.widget.blocks = blocks

    def _on_msg(self, _widget, content, _buffers) -> None:
        if not isinstance(content, dict) or content.get("type") != "event":
            return
        action = str(content.get("id", ""))
        values = content.get("values") or {}
        self.flash = None
        try:
            handler = getattr(self, f"on_{action}", None)
            if handler is None:
                raise ValueError("That button isn't wired up yet.")
            handler(values)
        except Exception as exc:
            _logger().error("action %s failed: %s\n%s", action, exc, traceback.format_exc())
            self.flash = {"kind": "error", "v": _plain(exc)}
        finally:
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


def show(*screens: "Screen"):
    """Display a step's cards: one after another in JupyterLab (the cell's result is None); in Marimo, which has no
    display(), they come back stacked as the cell's result."""
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
