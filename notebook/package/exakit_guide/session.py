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
    """The notebook's state as its cells would hold it: a namespace with `nb`, `connection`, `chosen_data`,
    `role_review`, `dataset`, `lab`, `proposal` ... - the very names the code section uses. Every card action runs its
    code in this namespace (actions.run), so what a card did is what those cells would have done."""

    def __init__(self) -> None:
        self._ns: dict[str, Any] | None = None
        self.source_label: str = ""
        self.source_rows: int | None = None
        self.broken: dict | None = None  # a saved column map the kit refuses to open, and why
        self.code: list[str] = []        # the code every action ran, in order (Code mode, Copy as cell)
        self.said: str = ""              # what the last action printed
        self._listeners: list[weakref.ref] = []
        self.followed: str | None = None   # the "approved last" dataset this kernel last loaded
        self._watching = False

    # -- the notebook's namespace ----------------------------------------------------------
    def namespace(self) -> dict[str, Any]:
        if self._ns is None:
            import exakit.nb as nb

            self._ns = {"nb": nb}
            self.log("import exakit.nb as nb")
        return self._ns

    def get(self, name: str) -> Any:
        return self.namespace().get(name)

    def set(self, name: str, value: Any) -> None:
        self.namespace()[name] = value

    # The cards' own words for what the cells call chosen_data, role_review and dataset.
    source = property(lambda self: self.get("chosen_data"), lambda self, v: self.set("chosen_data", v))
    review = property(lambda self: self.get("role_review"), lambda self, v: self.set("role_review", v))
    dataset = property(lambda self: self.get("dataset"), lambda self, v: self.set("dataset", v))

    # -- connection -------------------------------------------------------------------
    def connection(self):
        """The notebook's `connection`, opened the way its first cell opens it (nb.connect) when there is none."""
        if self.get("connection") is None:
            from . import actions

            actions.run("data.connect", self)
        return self.get("connection")

    def release(self) -> None:
        """Give the database connection back while nothing is running (Exasol Personal has a small number of
        connections; an idle notebook should not hold one). The next action opens it again."""
        conn = self.namespace().pop("connection", None)
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass

    def log(self, *lines: str) -> None:
        for line in lines:
            if line in self.code and line.startswith(("import ", "connection =")):
                continue
            if self.code and self.code[-1] == line:
                continue
            self.code.append(line)

    # -- the dataset approved last (step 1 writes it; every step follows it) -------------------
    @staticmethod
    def latest_approved() -> str | None:
        """The dataset approved last (the kit's own record, which nb.chosen_dataset() reads too)."""
        from exakit_nb.dataset import _last_file

        try:
            return _last_file().read_text(encoding="utf-8").strip() or None
        except OSError:
            return None

    def open_latest(self, action: str = "explore.open") -> None:
        """Open the dataset approved last with the step's own opening cells (explore.open, ask.open, share.open),
        unless this kernel already follows it. Each step runs in its own kernel; without this a step would keep the
        dataset it first opened."""
        from . import actions

        latest = self.latest_approved()
        if self.dataset is None or (latest and latest != self.followed):
            actions.run(action, self, dataset_id=None)
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
