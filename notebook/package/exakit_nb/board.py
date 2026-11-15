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

__all__ = ["Board", "board", "boards", "pin", "starter_board"]

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

    def edit(self, tile_id: str, sql: str, title: str | None = None) -> "Board":
        """Your own SQL for a tile (the one shown, edited): saving it here is your approval of it, so the dashboard
        runs exactly this. Its shape stays as it was; show_as() changes it."""
        from .ask import _read_sql

        statement = _read_sql(sql)
        tile = self._find(tile_id)[1]
        tile.update(sql=statement, sql_digest=hashlib.sha256(statement.encode("utf-8")).hexdigest(), starter=False,
                    edited=True, request=None)
        if title:
            tile["title"] = " ".join(str(title).split())[:120]
        log_event("board.edit", board=self.name, tile=tile_id, sql_digest=tile["sql_digest"])
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
        """What a page can be filtered by: the columns that are not numbers and that every tile of the page returns,
        or that two or more of its tiles do."""
        sets = [set(t.get("dimensions") or []) for t in page["tiles"] if t.get("kind") != "kpi"]
        common = set.intersection(*sets) if sets else set()
        # also a column two or more tiles return: it filters those, and the dashboard leaves the others as they are
        shared = {c for c in set().union(*sets) if sum(c in one for one in sets) >= 2} if sets else set()
        order = [c for t in page["tiles"] if t.get("kind") != "kpi" for c in t.get("dimensions") or []]
        return [c for c in dict.fromkeys(order) if c in common | shared][:3]

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


# --- a starter dashboard, straight from the column maps -----------------------------------------------------------------

def _words(text: str) -> str:
    return str(text).replace('"', "").split(".")[-1].replace("_", " ").strip().lower()


def _starter_tile(title: str, sql: str, kind: str, dimensions: list[str], ds) -> dict[str, Any]:
    from .ask import _read_sql

    statement = _read_sql(sql)
    digest = hashlib.sha256(statement.encode("utf-8")).hexdigest()
    return {"id": digest[:8], "title": title, "question": title, "sql": statement, "sql_digest": digest, "kind": kind,
            "dimensions": dimensions, "columns": [], "dataset": getattr(ds, "id", None),
            "descriptor_version": str(getattr(ds, "version", "") or ""), "request": None, "workflow_id": current_workflow(),
            "starter": True}


def _starter_page(ds) -> dict[str, Any] | None:
    """One table's page, from its approved column map: how many rows, each measure's total, rows and totals per group
    (the map's category first), and rows over time when it has a date. No personal-data column is ever used."""
    from .readout import count_name, name, noun

    columns = dict(getattr(ds.descriptor, "columns", {}) or {})
    usable = lambda role: [c for c, e in columns.items() if e.get("role") in role and not e.get("sensitive")]
    measures = usable(("measure",))[:2]
    groups = usable(("category", "flag"))
    try:
        role, first = ds.group_by()
        first = first.strip('"')
        if role == "category" and first in groups:
            groups = [first] + [g for g in groups if g != first]
    except ValueError:
        pass
    table, count = ds.fact_table, count_name(ds)
    what = noun(ds)
    tiles = [_starter_tile(f"Number of {what}", f"SELECT COUNT(*) AS {count} FROM {table}", "kpi", [], ds)]
    for m in measures:
        tiles.append(_starter_tile(f"Total {_words(m)}", f'SELECT SUM("{m}") AS {name(m, "TOTAL")} FROM {table}', "kpi", [], ds))
    for n, group in enumerate(groups[:3]):
        header = name(group)
        tiles.append(_starter_tile(f"{what.capitalize()} by {_words(group)}",
                                   f'SELECT "{group}" AS {header}, COUNT(*) AS {count} FROM {table} '
                                   f"GROUP BY 1 ORDER BY 2 DESC LIMIT 25", "bar", [header], ds))
        if n == 0 and measures:          # the first group again by the first measure: the two share a filter
            m = measures[0]
            tiles.append(_starter_tile(f"Total {_words(m)} by {_words(group)}",
                                       f'SELECT "{group}" AS {header}, SUM("{m}") AS {name(m, "TOTAL")} FROM {table} '
                                       f"GROUP BY 1 ORDER BY 2 DESC LIMIT 25", "bar", [header], ds))
    if ds.has("date"):
        d = ds.col("date")
        tiles.append(_starter_tile(f"{what.capitalize()} over time",
                                   f"SELECT CAST(DATE_TRUNC('MONTH', {d}) AS DATE) AS MONTH_START, COUNT(*) AS {count} "
                                   f"FROM {table} WHERE {d} IS NOT NULL GROUP BY 1 ORDER BY 1", "line", ["MONTH_START"], ds))
    if len(tiles) == 1 + len(measures) and not groups:
        return None if not measures else {"title": _words(table).title(), "tiles": tiles}
    return {"title": _words(table).title(), "tiles": tiles}


def _starter_links(datasets: list[Any]) -> list[dict[str, Any]]:
    """The links saved in your data map between these tables ({from table, column, to table, key}); [] without any."""
    try:
        from .describe import describe_service

        kept = describe_service().publishing.kept("all_data") or {}
    except Exception:
        return []
    spec = kept.get("spec") or {}
    tables = {e["name"]: f"{e['schema']}.{e['table']}" for e in spec.get("entities") or []}
    have = {str(d.fact_table).replace('"', "").upper() for d in datasets}
    out = []
    for r in spec.get("relationships") or []:
        a, b = tables.get(r["from"], ""), tables.get(r["to"], "")
        if a.upper() in have and b.upper() in have:
            out.append({"from": a, "column": r["from_column"], "to": b, "key": r["to_column"]})
    return out


def starter_board(conn, datasets: list[Any] | None = None, *, name: str = "overview", title: str | None = None) -> Board:
    """A dashboard to start from, made from the approved column maps with no question asked: a page per table (how
    many rows, each measure's total, rows and totals per group, rows over time); a table that links to another one
    (the links saved in your data map) also shows its rows per group of that table. ``datasets``
    defaults to the tables you chose (nb.chosen_tables) that are approved, else every approved one (12 at most).
    Every tile is a query the kit wrote from the map - shown when it is shared, checked in the preview before it goes
    live - and can be moved, removed or joined by your own pinned answers. A page that was made here before is
    replaced; pages of your own are kept. Returns the Board, saved."""
    if datasets is None:
        from .chosen import chosen_tables
        from .dataset import dataset
        from .descriptor_store import approved_datasets

        approved = approved_datasets()
        chosen = {t.upper() for t in chosen_tables()}
        picked = [a for a in approved if a["table"].upper() in chosen] or approved
        datasets = []
        for entry in picked[:12]:
            try:
                datasets.append(dataset(conn, entry["id"]))
            except Exception as error:                      # a table that is gone, or a map the kit refuses: said, skipped
                print(f"Left out {entry['table']}: {str(error).splitlines()[0][:160]}")
    datasets = list(datasets.values()) if isinstance(datasets, dict) else list(datasets)
    if not datasets:
        raise ValueError("No table has an approved column map yet: approve one in 01_explore first.")
    target = board(name)
    target.title = title or target.title or "Overview of your data"
    target.pages = [p for p in target.pages if not all(t.get("starter") for t in p["tiles"])]      # yours stay
    made, pages = [], {}
    for ds in datasets:
        page = _starter_page(ds)
        if page:
            made.append(page)
            pages[str(ds.fact_table).replace('"', "").upper()] = page
        else:
            print(f"{ds.fact_table}: no group, date or measure in its column map, so it has no page.")
    # a table that links to another one also gets its rows per group of that table, on its own page
    by_table = {str(d.fact_table).replace('"', "").upper(): d for d in datasets}
    for link in _starter_links(datasets)[:6]:
        a, b = by_table[link["from"].upper()], by_table[link["to"].upper()]
        columns = dict(getattr(b.descriptor, "columns", {}) or {})
        group = next((c for c, e in columns.items() if e.get("role") in ("category", "flag") and not e.get("sensitive")), None)
        page = pages.get(link["from"].upper())
        if not group or page is None:
            continue
        from .readout import count_name, name as header_of, noun

        page["tiles"].append(_starter_tile(
            f"{noun(a).capitalize()} by {_words(group)} ({_words(link['to'])})",
            f'SELECT b."{group}" AS {header_of(group)}, COUNT(*) AS {count_name(a)} FROM {a.fact_table} a '
            f'JOIN {b.fact_table} b ON a."{link["column"]}" = b."{link["key"]}" GROUP BY 1 ORDER BY 2 DESC LIMIT 25',
            "bar", [header_of(group)], a))
    if not made:
        raise ValueError("Nothing to show yet: no approved table has a group, a date or a measure in its column map.")
    target.pages = made + target.pages
    target.save()
    log_event("board.starter", board=target.name, pages=[p["title"] for p in made], tiles=sum(len(p["tiles"]) for p in made))
    print(f"{target.name}: {len(made)} pages, {sum(len(p['tiles']) for p in made)} tiles, from {len(datasets)} approved tables.")
    return target
