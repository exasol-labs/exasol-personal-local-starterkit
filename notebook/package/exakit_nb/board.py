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

__all__ = ["Board", "board", "board_app", "boards", "dashboard_rules", "pin", "starter_board", "starter_rules"]

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


DASHBOARD_RULES: dict[str, Any] = {
    "CACHE_SECONDS": 300, "WAIT_SECONDS": 25, "MAX_ROWS": 5000, "TABLE_ROWS": 1000, "PARALLEL": 4,
    "REFRESH_SECONDS": 300, "FILTERS": 3, "FILTER_SHARED_BY": 2, "BAR_MAX_ROWS": 50,
    "COLORS": ["#2a78d6", "#1baf7a", "#eb6834", "#eda100", "#8b6dcc", "#3c949c"],
}


def dashboard_rules() -> dict[str, Any]:
    """How a dashboard of several pages behaves, to copy, change and give a board (board.rules = {...}):

    CACHE_SECONDS       how long a tile's result is kept before it is queried again
    WAIT_SECONDS        how long a tab waits for a query before the tile says it is still running
    MAX_ROWS            the most rows a tile keeps; TABLE_ROWS the most a table shows
    PARALLEL            how many tiles of a tab are queried at once
    REFRESH_SECONDS     how often an open dashboard refreshes by itself (0: only on Refresh)
    FILTERS             the most filters a page gets; FILTER_SHARED_BY how many tiles must return a column for it
    BAR_MAX_ROWS        an answer with more rows than this is shown as a table, not bars
    COLORS              the chart colours, in order"""
    return {k: list(v) if isinstance(v, list) else v for k, v in DASHBOARD_RULES.items()}


def _dashboard_rules(given: dict[str, Any] | None) -> dict[str, Any]:
    found = dashboard_rules()
    for key, value in (given or {}).items():
        if key not in found:
            raise ValueError(f"{key} is not a dashboard rule: the rules are {', '.join(found)}")
        if key == "COLORS":
            if not isinstance(value, (list, tuple)) or not value or not all(isinstance(c, str) and c.startswith("#") for c in value):
                raise ValueError(f"COLORS is a list of colours such as \"#2a78d6\", not {value!r}")
            value = list(value)
        elif isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"{key} is a whole number, not {value!r}")
        found[key] = value
    return found


def board_app() -> str:
    """The dashboard's own source (app.py), to save, change and give back: board.share(app=your_text). It reads its
    pages from BOARD.json and runs each tile's SQL file through Dash Server's profile; keep create_dash_app."""
    from .board_template import BOARD_APP

    return BOARD_APP


def guess_kind(frame, bar_max_rows: int | None = None) -> str:
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
    return "bar" if len(rows) <= int(bar_max_rows if bar_max_rows is not None else DASHBOARD_RULES["BAR_MAX_ROWS"]) else "table"


@dataclass
class Board:
    """A dashboard being put together: its pages, in order, each with its tiles."""
    name: str
    title: str = ""
    pages: list[dict[str, Any]] = field(default_factory=list)
    rules: dict[str, Any] = field(default_factory=dict)       # only the dashboard rules changed (dashboard_rules)

    # -- reading and writing ---------------------------------------------------------------------------------------
    def save(self) -> Path:
        folder = _folder()
        folder.mkdir(parents=True, exist_ok=True)
        path = _path(self.name)
        temp = path.with_suffix(".tmp")
        _dashboard_rules(self.rules)
        temp.write_text(json.dumps({"name": self.name, "title": self.title or self.name.replace("-", " ").title(),
                                    "pages": self.pages, "rules": self.rules}, indent=2, default=str) + "\n", encoding="utf-8")
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

    def recheck(self, conn, *, update: bool = False) -> list[dict[str, Any]]:
        """Each tile answered from your data map, compiled again from its request: when the data map changed since
        it was pinned (a new link, a definition changed, a table rebuilt), its SQL comes out different, or is refused.
        Tiles written or edited by hand have no request and are left as they are. ``update=True`` takes the new SQL
        for the changed tiles and saves the dashboard (that is your approval of it); else nothing changes.
        [{id, page, title, state: same | changed | refused, sql, reason}]."""
        from .ask import _read_sql
        from .semantic import _service

        service = _service()
        found = []
        hashes: dict[str, dict[str, str]] = {}
        for page in self.pages:
            for tile in page["tiles"]:
                if not tile.get("request"):
                    continue
                entry = {"id": tile["id"], "page": page["title"], "title": tile["title"], "sql": None, "reason": None}
                if tile.get("hashes"):
                    # Semantic Views' fingerprints of the fields this tile uses: unchanged, nothing to compile
                    model = tile["request"].get("model")
                    if model not in hashes:
                        try:
                            got = service.definition_hashes(conn, model)
                            hashes[model] = got if isinstance(got, dict) else {}
                        except Exception:       # noqa: BLE001
                            hashes[model] = {}
                    now = {k: hashes[model].get(k) for k in tile["hashes"]}
                    if hashes[model] and now == tile["hashes"]:
                        found.append(dict(entry, state="same"))
                        continue
                try:
                    compiled = service.compile_request(conn, dict(tile["request"]))
                except Exception as err:     # noqa: BLE001 - the data map cannot be read: said per tile, nothing changes
                    found.append(dict(entry, state="refused", reason=" ".join(str(err).split())[:200]))
                    continue
                if compiled["status"] != "ok":
                    found.append(dict(entry, state="refused", reason=compiled.get("error")))
                    continue
                fresh = _read_sql(compiled["sql"])
                same = " ".join(fresh.split()) == " ".join(str(tile["sql"]).split())
                found.append(dict(entry, state="same" if same else "changed", sql=None if same else fresh))
                if update and not same:
                    tile.update(sql=fresh, sql_digest=hashlib.sha256(fresh.encode("utf-8")).hexdigest())
                    if tile.get("hashes"):
                        tile["hashes"] = {k: (hashes.get(tile["request"].get("model")) or {}).get(k, v) for k, v in tile["hashes"].items()}
                    log_event("board.recheck", board=self.name, tile=tile["id"], sql_digest=tile["sql_digest"])
        if update and any(f["state"] == "changed" for f in found):
            self.save()
        return found

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
        """What a page can be filtered by: the ones set for it (set_filters), else the columns that are not numbers
        and that every tile of the page returns, or that FILTER_SHARED_BY of its tiles do - FILTERS of them at most."""
        if page.get("filters") is not None:
            return list(page["filters"])
        rules = _dashboard_rules(self.rules)
        sets = [set(t.get("dimensions") or []) for t in page["tiles"] if t.get("kind") != "kpi"]
        common = set.intersection(*sets) if sets else set()
        shared = {c for c in set().union(*sets) if sum(c in one for one in sets) >= rules["FILTER_SHARED_BY"]} if sets else set()
        order = [c for t in page["tiles"] if t.get("kind") != "kpi" for c in t.get("dimensions") or []]
        return [c for c in dict.fromkeys(order) if c in common | shared][:rules["FILTERS"]]

    def set_filters(self, page: str, columns: list[str] | None) -> "Board":
        """The filters of a page, chosen by you (columns its tiles return); None goes back to the kit's choice."""
        found = next((p for p in self.pages if p["title"].lower() == str(page).lower()), None)
        if found is None:
            raise KeyError(f"No page {page} on {self.name}: {', '.join(p['title'] for p in self.pages)}")
        if columns is None:
            found.pop("filters", None)
        else:
            known = {c for t in found["tiles"] for c in t.get("dimensions") or []}
            wrong = [c for c in columns if c not in known]
            if wrong:
                raise ValueError(f"No tile of {found['title']} returns {', '.join(wrong)}: its columns are {', '.join(sorted(known))}")
            found["filters"] = list(columns)
        return self

    def spec(self) -> dict[str, Any]:
        """What the Dash app reads (BOARD.json): the title, and each page with its filters and its tiles' SQL files."""
        pages = []
        for n, p in enumerate(self.pages, 1):
            pages.append({"id": f"page-{n}", "title": p["title"], "filters": self.filters(p),
                          "tiles": [{"id": t["id"], "title": t["title"], "kind": t["kind"], "query": f"queries/{t['id']}.sql",
                                     "ordered": bool(re.search(r"\bORDER\s+BY\b", str(t.get("sql") or ""), re.I)),
                                     "sql_digest": t["sql_digest"], "dataset": t.get("dataset"),
                                     "descriptor_version": t.get("descriptor_version")} for t in p["tiles"]]})
        return {"title": self.title or self.name.replace("-", " ").title(), "pages": pages,
                "settings": _dashboard_rules(self.rules)}

    def __str__(self) -> str:
        lines = [f"{self.title or self.name} ({self.name}): {len(self.pages)} pages, {len(self.tiles)} tiles"]
        for p in self.pages:
            filters = self.filters(p)
            lines.append(f"  {p['title']}" + (f" - filters: {', '.join(filters)}" if filters else ""))
            lines += [f"    [{t['id']}] {t['kind']:5} {t['title']}" for t in p["tiles"]]
        return "\n".join(lines)

    __repr__ = __str__

    def share(self, name: str | None = None, app: str | None = None, *, show: bool = True):
        """The Dash app for this board (a BoardDraft): nothing is sent until its preview(). ``app`` is your own
        version of the dashboard's source (nb.board_app(), changed). ``show``: print each tile's SQL."""
        from .share import board_draft

        return board_draft(self, name or self.name, app=app, show=show)


_PREPARING_LOCK = None          # one background preview at a time in this kernel (threading.Lock, made on first use)
_PREPARE_NEXT: dict[str, bool] = {}
PREPARED_PREVIEWS: dict[str, str] = {}      # board -> "building" | the preview path | why it could not be built


def prepare_preview(name: str) -> str:
    """Build the preview of a board's dashboard in the background, right after a pin, so 03_share shows it at once:
    Dash Server deploys and health-checks a dashboard in ~20 s. Nothing is published: it is the same preview that
    Preview makes (nb.board(name).share().preview(...)), and Preview uses it once Dash Server confirms it is still
    the one shown, built from exactly the files it would deploy. Another pin while it builds builds once more after.
    Returns at once: "building" (PREPARED_PREVIEWS[name] has the outcome), or why it was not started."""
    import threading

    global _PREPARING_LOCK
    name = _check_name(name)
    try:
        from .dash_mcp import dash_tools

        tools = dash_tools(ready=False)              # never installs or starts anything in the background
    except Exception as exc:                          # noqa: BLE001 - not running: 03_share builds it when asked
        PREPARED_PREVIEWS[name] = (str(exc).splitlines() or [type(exc).__name__])[0][:200]
        return PREPARED_PREVIEWS[name]
    if _PREPARING_LOCK is None:
        _PREPARING_LOCK = threading.Lock()
    if not _PREPARING_LOCK.acquire(blocking=False):
        _PREPARE_NEXT[name] = True                    # the build running now is followed by one of the latest pins
        PREPARED_PREVIEWS[name] = "building"
        return "building"
    PREPARED_PREVIEWS[name] = "building"

    def build() -> None:
        try:
            todo = [name]
            while todo:
                one = todo.pop(0)
                _PREPARE_NEXT.pop(one, None)
                try:
                    PREPARED_PREVIEWS[one] = board(one).share(show=False).preview(tools, building=True)
                except Exception as exc:              # noqa: BLE001 - said in PREPARED_PREVIEWS; Preview builds it
                    PREPARED_PREVIEWS[one] = (str(exc).splitlines() or [type(exc).__name__])[0][:200]
                todo += [n for n in list(_PREPARE_NEXT) if n not in todo]
        finally:
            _PREPARING_LOCK.release()
        if _PREPARE_NEXT:                             # pinned again just as this one finished
            prepare_preview(next(iter(_PREPARE_NEXT)))

    threading.Thread(target=build, name="exakit-preview", daemon=True).start()
    return "building"


def boards() -> list[dict[str, Any]]:
    """Every dashboard being put together on this computer, the one changed last first: name, title, pages, tiles."""
    found = []
    for path in sorted(_folder().glob("*.json")) if _folder().is_dir() else []:
        if path.name.endswith(".preview.json"):
            continue
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
    return Board(name, str(doc.get("title") or ""), list(doc.get("pages") or []), dict(doc.get("rules") or {}))


def _field_hashes(conn, request: dict[str, Any]) -> dict[str, str]:
    """The fingerprints Semantic Views keeps of the fields a request uses (DEFINITION_HASHES_FOR_AGENT), so a recheck
    knows which tiles' fields changed without compiling every tile again. {} when they cannot be read."""
    try:
        from .semantic import _service

        every = _service().definition_hashes(conn, request["model"])
    except Exception:                       # noqa: BLE001
        return {}
    if not isinstance(every, dict):
        return {}
    used = [f"METRIC:{m}" for m in request.get("metrics") or []] + [f"DIMENSION:{d}" for d in request.get("dimensions") or []]
    return {k: every[k] for k in used if k in every}


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
            "kind": kind or (guess_kind(answer, _dashboard_rules(target.rules)["BAR_MAX_ROWS"]) if answer is not None else "table"),
            "dimensions": dimensions, "columns": [str(c) for c in getattr(answer, "columns", [])],
            "dataset": getattr(dataset, "id", None), "descriptor_version": str(getattr(dataset, "version", "") or ""),
            "request": getattr(proposal, "request", None), "workflow_id": current_workflow()}
    if tile["request"] and getattr(proposal, "conn", None) is not None:
        tile["hashes"] = _field_hashes(proposal.conn, tile["request"])
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


STARTER_RULES = {"MEASURES": 2, "GROUPS": 3, "TOP": 25, "TOTAL_BY_GROUP": True, "MEASURE_SUM": "SUM",
                 "TREND": True, "PERIOD": "MONTH", "GROUP_ROLES": ["category", "flag"], "LINKED": 6}
PERIODS = ("DAY", "WEEK", "MONTH", "QUARTER", "YEAR")
AGGREGATES = ("SUM", "AVG", "MIN", "MAX")


def starter_rules() -> dict[str, Any]:
    """The rules a starter dashboard is made with, to copy, change and pass (nb.starter_board(..., rules={...})):

    MEASURES, GROUPS     how many measures and groups of a table get tiles
    TOP                  the largest groups a bar shows
    TOTAL_BY_GROUP       the first group again by the first measure (the two share a filter)
    MEASURE_SUM          how a measure is added up: SUM, AVG, MIN or MAX
    TREND, PERIOD        rows over time, per DAY, WEEK, MONTH, QUARTER or YEAR
    GROUP_ROLES          which column map roles are groups: category, flag (identifier, key ...)
    LINKED               how many links to other tables get a tile"""
    return {k: list(v) if isinstance(v, list) else v for k, v in STARTER_RULES.items()}


def _rules(given: dict[str, Any] | None) -> dict[str, Any]:
    found = starter_rules()
    for key, value in (given or {}).items():
        if key not in found:
            raise ValueError(f"{key} is not a starter rule: the rules are {', '.join(found)}")
        if key in ("MEASURES", "GROUPS", "TOP", "LINKED") and (isinstance(value, bool) or not isinstance(value, int) or value < 0):
            raise ValueError(f"{key} is a whole number, not {value!r}")
        if key in ("TOTAL_BY_GROUP", "TREND") and not isinstance(value, bool):
            raise ValueError(f"{key} is True or False, not {value!r}")
        if key == "PERIOD" and str(value).upper() not in PERIODS:
            raise ValueError(f"PERIOD is one of {', '.join(PERIODS)}, not {value!r}")
        if key == "MEASURE_SUM" and str(value).upper() not in AGGREGATES:
            raise ValueError(f"MEASURE_SUM is one of {', '.join(AGGREGATES)}, not {value!r}")
        if key == "GROUP_ROLES" and not isinstance(value, (list, tuple)):
            raise ValueError(f"GROUP_ROLES is a list of roles, not {value!r}")
        found[key] = str(value).upper() if key in ("PERIOD", "MEASURE_SUM") else value
    return found


def _starter_page(ds, rules: dict[str, Any] | None = None) -> dict[str, Any] | None:
    """One table's page, from its approved column map and the starter rules (starter_rules): how many rows, each
    measure's total, rows and totals per group (the map's category first), and rows over time when it has a date. No
    personal-data column is ever used."""
    from .readout import count_name, name, noun

    rules = _rules(rules)
    columns = dict(getattr(ds.descriptor, "columns", {}) or {})
    usable = lambda role: [c for c, e in columns.items() if e.get("role") in role and not e.get("sensitive")]
    measures = usable(("measure",))[:rules["MEASURES"]]
    agg, top = rules["MEASURE_SUM"], int(rules["TOP"])
    groups = usable(tuple(rules["GROUP_ROLES"]))
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
    word = {"SUM": "Total", "AVG": "Average", "MIN": "Lowest", "MAX": "Highest"}[agg]
    suffix = {"SUM": "TOTAL", "AVG": "AVG", "MIN": "MIN", "MAX": "MAX"}[agg]
    for m in measures:
        tiles.append(_starter_tile(f"{word} {_words(m)}", f'SELECT {agg}("{m}") AS {name(m, suffix)} FROM {table}', "kpi", [], ds))
    for n, group in enumerate(groups[:rules["GROUPS"]]):
        header = name(group)
        tiles.append(_starter_tile(f"{what.capitalize()} by {_words(group)}",
                                   f'SELECT "{group}" AS {header}, COUNT(*) AS {count} FROM {table} '
                                   f"GROUP BY 1 ORDER BY 2 DESC LIMIT {top}", "bar", [header], ds))
        if n == 0 and measures and rules["TOTAL_BY_GROUP"]:
            m = measures[0]
            tiles.append(_starter_tile(f"{word} {_words(m)} by {_words(group)}",
                                       f'SELECT "{group}" AS {header}, {agg}("{m}") AS {name(m, suffix)} FROM {table} '
                                       f"GROUP BY 1 ORDER BY 2 DESC LIMIT {top}", "bar", [header], ds))
    if ds.has("date") and rules["TREND"]:
        d, period = ds.col("date"), rules["PERIOD"]
        tiles.append(_starter_tile(f"{what.capitalize()} over time",
                                   f"SELECT CAST(DATE_TRUNC('{period}', {d}) AS DATE) AS {period}_START, COUNT(*) AS {count} "
                                   f"FROM {table} WHERE {d} IS NOT NULL GROUP BY 1 ORDER BY 1", "line", [f"{period}_START"], ds))
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


def starter_board(conn, datasets: list[Any] | None = None, *, name: str = "overview", title: str | None = None,
                  rules: dict[str, Any] | None = None) -> Board:
    """A dashboard to start from, made from the approved column maps with no question asked: a page per table (how
    many rows, each measure's total, rows and totals per group, rows over time); a table that links to another one
    (the links saved in your data map) also shows its rows per group of that table. ``datasets``
    defaults to the tables you chose (nb.chosen_tables) that are approved, else every approved one (12 at most).
    ``rules`` changes how the tiles are made (nb.starter_rules() lists them: how many groups, the largest how many, the
    period of the trend ...). Every tile is a query the kit wrote from the map - shown when it is shared, checked in
    the preview before it goes live - and can be edited, moved, removed or joined by your own pinned answers. A page that was made here before is
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
    rules = _rules(rules)
    target = board(name)
    target.title = title or target.title or "Overview of your data"
    target.pages = [p for p in target.pages if not all(t.get("starter") for t in p["tiles"])]      # yours stay
    made, pages = [], {}
    for ds in datasets:
        page = _starter_page(ds, rules)
        if page:
            made.append(page)
            pages[str(ds.fact_table).replace('"', "").upper()] = page
        else:
            print(f"{ds.fact_table}: no group, date or measure in its column map, so it has no page.")
    # a table that links to another one also gets its rows per group of that table, on its own page
    by_table = {str(d.fact_table).replace('"', "").upper(): d for d in datasets}
    for link in _starter_links(datasets)[:int(rules["LINKED"])]:
        a, b = by_table[link["from"].upper()], by_table[link["to"].upper()]
        columns = dict(getattr(b.descriptor, "columns", {}) or {})
        group = next((c for c, e in columns.items() if e.get("role") in tuple(rules["GROUP_ROLES"]) and not e.get("sensitive")), None)
        page = pages.get(link["from"].upper())
        if not group or page is None:
            continue
        from .readout import count_name, name as header_of, noun

        page["tiles"].append(_starter_tile(
            f"{noun(a).capitalize()} by {_words(group)} ({_words(link['to'])})",
            f'SELECT b."{group}" AS {header_of(group)}, COUNT(*) AS {count_name(a)} FROM {a.fact_table} a '
            f'JOIN {b.fact_table} b ON a."{link["column"]}" = b."{link["key"]}" GROUP BY 1 ORDER BY 2 DESC LIMIT {int(rules["TOP"])}',
            "bar", [header_of(group)], a))
    if not made:
        raise ValueError("Nothing to show yet: no approved table has a group, a date or a measure in its column map.")
    target.pages = made + target.pages
    target.save()
    log_event("board.starter", board=target.name, pages=[p["title"] for p in made], tiles=sum(len(p["tiles"]) for p in made))
    print(f"{target.name}: {len(made)} pages, {sum(len(p['tiles']) for p in made)} tiles, from {len(datasets)} approved tables.")
    return target
