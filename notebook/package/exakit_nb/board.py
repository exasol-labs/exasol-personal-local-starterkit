"""A dashboard of several pages, built from approved answers: pin answers to pages, then publish it on Dash Server.

    nb.pin(proposal, answer, board="sales-overview", page="Revenue")    # an approved answer onto a page
    board = nb.board("sales-overview")                                   # its pages and tiles
    board.move("a1b2c3", "Delivery"); board.remove("d4e5f6"); board.title = "Sales overview"; board.save()
    draft = board.share()                                                # the Dash app's files, nothing sent yet
    draft.preview(nb.dash_tools())                                       # a checked preview on Dash Server
    draft.confirm(nb.dash_tools(), figures_checked=True)                 # live, after a person checked the figures

A board is kept in ~/.exasol-starter-kit/boards/<name>.json. Each tile is one approved question: its SQL exactly as
approved (and its digest), the column map version it was asked of, the structured request when it came from the
semantic model, and how to show it (kpi, bar, line or table). Nothing is re-drafted on the way to the dashboard: the
dashboard runs the approved SQL as the kit's read-only user, through Dash Server's server-side profile.

The dashboard is one Dash app: a tab per page, built from BOARD.json, so pages and tiles change without new code;
only the open tab's tiles are queried (in parallel, each with a row cap), each result is cached for a few minutes,
and the filters - a column every tile of the page returns - narrow the cached rows without querying again.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .workflow import current_workflow, home, log_event

__all__ = ["Board", "board", "boards", "pin"]

_NAME = re.compile(r"^[a-z][a-z0-9-]*$")
KINDS = ("kpi", "bar", "line", "table")


def _folder() -> Path:
    return home() / "boards"


def _path(name: str) -> Path:
    return _folder() / f"{name}.json"


def _check_name(name: str) -> str:
    name = str(name or "").strip().lower()
    if not _NAME.fullmatch(name):
        raise ValueError("A dashboard name uses lower-case letters, digits and hyphens, starting with a letter: sales-overview")
    return name


def guess_kind(frame) -> str:
    """How to show a result: one number is a KPI, a date first is a line, a label and a number are bars, else a table."""
    try:
        columns = list(frame.columns)
        rows = frame.astype(object).values.tolist()
    except AttributeError:
        return "table"
    if len(rows) == 1 and len(columns) == 1:
        return "kpi"
    if len(columns) < 2 or not rows:
        return "table"
    import datetime as dt

    first = [r[0] for r in rows]
    numeric = all(isinstance(r[1], (int, float)) and not isinstance(r[1], bool) or r[1] is None for r in rows)
    if not numeric and len(columns) == 2:
        try:
            numeric = all(r[1] is None or float(r[1]) == float(r[1]) for r in rows)
        except (TypeError, ValueError):
            numeric = False
    if not numeric:
        return "table"
    if all(isinstance(v, (dt.date, dt.datetime)) or (isinstance(v, str) and re.match(r"^\d{4}-\d{2}", v)) for v in first):
        return "line"
    return "bar" if len(rows) <= 50 else "table"


@dataclass
class Board:
    """A dashboard being put together: its pages, in order, each with its tiles."""
    name: str
    title: str = ""
    pages: list[dict[str, Any]] = field(default_factory=list)

    # -- reading and writing ---------------------------------------------------------------------------------------
    def save(self) -> Path:
        folder = _folder()
        folder.mkdir(parents=True, exist_ok=True)
        path = _path(self.name)
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps({"name": self.name, "title": self.title or self.name.replace("-", " ").title(),
                                    "pages": self.pages}, indent=2, default=str) + "\n", encoding="utf-8")
        os.replace(temp, path)
        return path

    @property
    def tiles(self) -> list[dict[str, Any]]:
        return [t for p in self.pages for t in p["tiles"]]

    def page(self, title: str) -> dict[str, Any]:
        """The page of that title, made at the end when there is none."""
        title = " ".join(str(title or "").split())[:60] or "Overview"
        for p in self.pages:
            if p["title"].lower() == title.lower():
                return p
        self.pages.append({"title": title, "tiles": []})
        return self.pages[-1]

    def _find(self, tile_id: str) -> tuple[dict[str, Any], dict[str, Any]]:
        for p in self.pages:
            for t in p["tiles"]:
                if t["id"] == tile_id:
                    return p, t
        raise KeyError(f"No tile {tile_id} on {self.name}: board.tiles lists them.")

    def move(self, tile_id: str, page: str) -> "Board":
        here, tile = self._find(tile_id)
        here["tiles"].remove(tile)
        self.page(page)["tiles"].append(tile)
        self.pages = [p for p in self.pages if p["tiles"]]
        return self

    def remove(self, tile_id: str) -> "Board":
        here, tile = self._find(tile_id)
        here["tiles"].remove(tile)
        self.pages = [p for p in self.pages if p["tiles"]]
        return self

    def show_as(self, tile_id: str, kind: str) -> "Board":
        if kind not in KINDS:
            raise ValueError(f"A tile shows as one of {', '.join(KINDS)}.")
        self._find(tile_id)[1]["kind"] = kind
        return self

    def rename_page(self, old: str, new: str) -> "Board":
        for p in self.pages:
            if p["title"].lower() == str(old).lower():
                p["title"] = " ".join(str(new).split())[:60] or p["title"]
        return self

    def filters(self, page: dict[str, Any]) -> list[str]:
        """The columns every tile of a page returns that are not numbers: what the page can be filtered by."""
        sets = [set(t.get("dimensions") or []) for t in page["tiles"] if t.get("kind") != "kpi"]
        common = set.intersection(*sets) if sets else set()
        first = next((t.get("dimensions") or [] for t in page["tiles"] if t.get("kind") != "kpi"), [])
        return [c for c in first if c in common][:3]

    def spec(self) -> dict[str, Any]:
        """What the Dash app reads (BOARD.json): the title, and each page with its filters and its tiles' SQL files."""
        pages = []
        for n, p in enumerate(self.pages, 1):
            pages.append({"id": f"page-{n}", "title": p["title"], "filters": self.filters(p),
                          "tiles": [{"id": t["id"], "title": t["title"], "kind": t["kind"], "query": f"queries/{t['id']}.sql",
                                     "sql_digest": t["sql_digest"], "dataset": t.get("dataset"),
                                     "descriptor_version": t.get("descriptor_version")} for t in p["tiles"]]})
        return {"title": self.title or self.name.replace("-", " ").title(), "pages": pages}

    def __str__(self) -> str:
        lines = [f"{self.title or self.name} ({self.name}): {len(self.pages)} pages, {len(self.tiles)} tiles"]
        for p in self.pages:
            filters = self.filters(p)
            lines.append(f"  {p['title']}" + (f" - filters: {', '.join(filters)}" if filters else ""))
            lines += [f"    [{t['id']}] {t['kind']:5} {t['title']}" for t in p["tiles"]]
        return "\n".join(lines)

    __repr__ = __str__

    def share(self, name: str | None = None):
        """The Dash app for this board (a BoardDraft): nothing is sent until its preview()."""
        from .share import board_draft

        return board_draft(self, name or self.name)


def boards() -> list[dict[str, Any]]:
    """Every dashboard being put together on this computer, the one changed last first: name, title, pages, tiles."""
    found = []
    for path in sorted(_folder().glob("*.json")) if _folder().is_dir() else []:
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        found.append({"name": doc.get("name") or path.stem, "title": doc.get("title") or path.stem,
                      "pages": len(doc.get("pages") or []), "tiles": sum(len(p.get("tiles") or []) for p in doc.get("pages") or []),
                      "changed": path.stat().st_mtime})
    return sorted(found, key=lambda b: -b["changed"])


def board(name: str) -> Board:
    """A dashboard by name: the one kept on this computer, or a new empty one."""
    name = _check_name(name)
    try:
        doc = json.loads(_path(name).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return Board(name)
    return Board(name, str(doc.get("title") or ""), list(doc.get("pages") or []))


def pin(proposal, answer=None, *, board: str = "my-dashboard", page: str = "Overview", title: str | None = None,
        kind: str | None = None) -> dict[str, Any]:
    """Put an approved answer on a page of a dashboard: its SQL exactly as approved, shown as ``kind`` (kpi, bar, line
    or table; by default what the answer looks like). The same SQL pinned again to a page replaces its tile there.
    Returns the tile."""
    digest = getattr(proposal, "_approved_digest", None)
    if not digest:
        raise RuntimeError("Approve the SQL first: only an approved answer goes on a dashboard.")
    from .ask import _read_sql

    sql = _read_sql(proposal.sql)
    if hashlib.sha256(sql.encode("utf-8")).hexdigest() != digest:
        raise RuntimeError("The SQL changed after it was approved: approve it again first.")
    if kind is not None and kind not in KINDS:
        raise ValueError(f"A tile shows as one of {', '.join(KINDS)}.")
    dimensions: list[str] = []
    try:
        from pandas.api.types import is_bool_dtype, is_numeric_dtype

        # what the rows are about (text, dates, flags): a page can be filtered by a column all its tiles return
        dimensions = [str(c) for c in answer.columns if not is_numeric_dtype(answer[c]) or is_bool_dtype(answer[c])]
    except (AttributeError, ImportError):
        pass
    target = globals()["board"](board)
    dataset = getattr(proposal, "dataset", None)
    tile = {"id": digest[:8], "title": " ".join(str(title or proposal.question).split())[:120].rstrip("?"),
            "question": proposal.question, "sql": sql, "sql_digest": digest,
            "kind": kind or (guess_kind(answer) if answer is not None else "table"),
            "dimensions": dimensions, "columns": [str(c) for c in getattr(answer, "columns", [])],
            "dataset": getattr(dataset, "id", None), "descriptor_version": str(getattr(dataset, "version", "") or ""),
            "request": getattr(proposal, "request", None), "workflow_id": current_workflow()}
    here = target.page(page)
    here["tiles"] = [t for t in here["tiles"] if t["sql_digest"] != digest] + [tile]
    target.save()
    log_event("board.pin", board=target.name, page=here["title"], tile=tile["id"], sql_digest=digest, question=proposal.question)
    print(f"Pinned to {target.name} / {here['title']} as a {tile['kind']}: {tile['title']}")
    return tile
