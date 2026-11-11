"""What the guided cards in one notebook share: the connection, the chosen data,
the role review and the approved dataset.

Cards register as listeners; when one card changes the session (data chosen,
roles approved) the others redraw. `code` records the exakit.nb calls that
actually ran, so Code mode can show them and anyone can copy them into a
notebook of their own.
"""

from __future__ import annotations

import weakref
from contextlib import contextmanager
from typing import Any


class Session:
    def __init__(self) -> None:
        self.conn = None
        self.workflow_id: str | None = None
        self.source: Any = None          # Dataset or LoadedTable the user picked
        self.source_label: str = ""
        self.source_rows: int | None = None
        self.review: Any = None          # RoleReview
        self.dataset: Any = None         # approved Dataset (what later steps read)
        self.broken: dict | None = None  # a saved column map the kit refuses to open, and why
        self.code: list[str] = []        # exakit.nb calls that ran, in order
        self._listeners: list[weakref.ref] = []
        self.followed: str | None = None   # the "approved last" dataset this kernel last loaded
        self._watching = False

    # -- connection -------------------------------------------------------------------
    def connection(self):
        import exakit.nb as nb

        if self.conn is None:
            self.conn = nb.connect()
            self.log("import exakit.nb as nb", "connection = nb.connect()")
        return self.conn

    def release(self) -> None:
        """Give the database connection back while nothing is running.
        Exasol Personal has a small number of connections; an idle notebook shouldn't hold one."""
        conn, self.conn = self.conn, None
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass

    def log(self, *lines: str) -> None:
        for line in lines:
            if line in self.code and line.startswith(("import ", "connection =", "first_rows =")):
                continue
            if self.code and self.code[-1] == line:
                continue
            self.code.append(line)

    # -- the dataset approved last (step 1 writes it; every step follows it) -------------------
    @staticmethod
    def latest_approved() -> str | None:
        import os
        from pathlib import Path

        home = Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit").expanduser()
        try:
            return (home / "last-dataset").read_text(encoding="utf-8").strip() or None
        except OSError:
            return None

    def open_latest(self) -> None:
        """Load the dataset approved last, unless this kernel already follows it.
        Each step runs in its own kernel; without this a step keeps the dataset it first opened."""
        import exakit.nb as nb

        latest = self.latest_approved()
        if self.dataset is None or (latest and latest != self.followed):
            self.dataset = nb.dataset(self.connection(), nb.chosen_dataset(None))
            self.followed = latest
        self._watch()

    def newer_approved(self) -> str | None:
        """A dataset approved in step 1 after this step opened its data (None when there is nothing newer)."""
        latest = self.latest_approved()
        ds_id = getattr(self.dataset, "id", None)
        if self.dataset is None or not latest or latest == self.followed or latest == ds_id:
            return None
        return latest

    def _watch(self) -> None:
        """Redraw open cards when step 1 approves another dataset, so they can say so."""
        if self._watching:
            return
        self._watching = True
        import threading
        import time

        def loop():
            seen = self.latest_approved()
            while True:
                time.sleep(2)
                now = self.latest_approved()
                if now != seen:
                    seen = now
                    from .card import redraw_all

                    redraw_all()

        threading.Thread(target=loop, name="exakit-guide-watch", daemon=True).start()

    # -- listeners ----------------------------------------------------------------------
    def listen(self, screen) -> None:
        self._listeners.append(weakref.ref(screen))

    def changed(self, what: str, source=None) -> None:
        alive = []
        for ref in self._listeners:
            screen = ref()
            if screen is None:
                continue
            alive.append(ref)
            if screen is not source and hasattr(screen, "on_session"):
                screen.on_session(what)
        self._listeners = alive


SESSION = Session()


@contextmanager
def quiet():
    """Run kit helpers without their printed lines landing in the notebook.
    The lines are kept (yielded object .text) so a card can show them on request."""
    from IPython.utils.capture import capture_output

    class Out:
        text = ""

    out = Out()
    with capture_output(display=True) as cap:
        try:
            yield out
        finally:
            out.text = (cap.stdout or "").strip()


try:   # the AI model chosen on Home, in this step's kernel too (each step is its own kernel)
    from . import aikey as _aikey

    _aikey.load()
except Exception:
    pass
