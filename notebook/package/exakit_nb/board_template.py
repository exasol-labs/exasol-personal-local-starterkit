"""The multi-page dashboard's Dash app (uploaded as app.py); imports need no dashboard libraries here."""

BOARD_APP = r'''
"""A multi-page dashboard of approved answers: a tab per page, read from BOARD.json; connection data stays in the
scaffold's server-side profile, and every tile runs its approved SQL file unchanged.

Fast by design: only the open tab's tiles are queried, in parallel; each result is kept for CACHE_SECONDS, so moving
between tabs and filtering never queries again; a query that takes longer than WAIT_SECONDS leaves its tile saying
so instead of holding the page; each result is capped at MAX_ROWS rows."""
import csv
import importlib.util
import io
import json
import math
import threading
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as Late
from datetime import datetime, timezone
from pathlib import Path

import plotly.graph_objects as go
from dash import ALL, Dash, Input, Output, State, ctx, dash_table, dcc, html

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location("dash_server_generated_exasol_helper", HERE / "dash_server_exasol.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
BOARD = json.loads((HERE / "BOARD.json").read_text(encoding="utf-8"))
LINEAGE = json.loads((HERE / "REVISION.json").read_text(encoding="utf-8"))
RULES = BOARD.get("settings") or {}
COLORS = RULES.get("COLORS") or ["#2a78d6", "#1baf7a", "#eb6834", "#eda100", "#8b6dcc", "#3c949c"]
CACHE_SECONDS, WAIT_SECONDS = int(RULES.get("CACHE_SECONDS", 300)), int(RULES.get("WAIT_SECONDS", 25))
MAX_ROWS, TABLE_ROWS = int(RULES.get("MAX_ROWS", 5000)), int(RULES.get("TABLE_ROWS", 1000))
REFRESH_SECONDS = int(RULES.get("REFRESH_SECONDS", CACHE_SECONDS))
POOL = ThreadPoolExecutor(max_workers=max(1, int(RULES.get("PARALLEL", 4))))
CACHE, RUNNING, LOCK = {}, {}, threading.RLock()   # re-entrant: a query done at once calls back under it


def number(value):
    if isinstance(value, bool):
        return None
    try:
        value = float(value)
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


def tiles_of(page_id):
    return next((p for p in BOARD["pages"] if p["id"] == page_id), BOARD["pages"][0])["tiles"]


def _query(tile, server, metadata):
    rows = helper.load_rows(server, metadata, __file__, tile["query"])
    if helper.has_error(rows):
        return {"error": "The query failed; no stale values are shown.", "rows": [], "at": time.time()}
    rows = list(rows or [])
    return {"error": None, "rows": rows[:MAX_ROWS], "cut": len(rows) > MAX_ROWS, "at": time.time()}


def results(tiles, server, metadata, fresh=False):
    """{tile id: result} for these tiles: from the cache when it is young, else queried - all at once, in parallel -
    and a tile still running after WAIT_SECONDS says so (its query finishes in the background and fills the cache)."""
    now, out, waiting = time.time(), {}, {}
    with LOCK:
        for tile in tiles:
            kept = CACHE.get(tile["id"])
            if kept and not fresh and now - kept["at"] < CACHE_SECONDS:
                out[tile["id"]] = kept
            elif tile["id"] in RUNNING:
                waiting[tile["id"]] = RUNNING[tile["id"]]
            else:
                future = POOL.submit(_query, tile, server, metadata)
                RUNNING[tile["id"]] = future
                waiting[tile["id"]] = future

                def done(f, key=tile["id"]):
                    with LOCK:
                        RUNNING.pop(key, None)
                        if not f.exception():
                            CACHE[key] = f.result()
                future.add_done_callback(done)
    deadline = now + WAIT_SECONDS
    for key, future in waiting.items():
        try:
            out[key] = future.result(timeout=max(0.1, deadline - time.time()))
        except Late:
            out[key] = {"error": None, "late": True, "rows": [], "at": now}
        except Exception:
            out[key] = {"error": "The query failed; no stale values are shown.", "rows": [], "at": now}
    return out


def keep(rows, chosen):
    """The rows whose filter columns hold one of the chosen values (a column the result does not have is ignored)."""
    if not chosen:
        return rows
    return [r for r in rows if all(col not in r or str(r[col]) in values for col, values in chosen.items() if values)]


def export_csv(rows):
    out = io.StringIO()
    if rows:
        writer = csv.DictWriter(out, fieldnames=list(rows[0]))
        writer.writeheader()
        for row in rows:
            writer.writerow({k: ("'" + str(v) if isinstance(v, str) and v[:1] in "=+-@" else v) for k, v in row.items()})
    return out.getvalue()


def figure(tile, rows):
    keys = list(rows[0]) if rows else []
    measures = [k for k in keys if all(number(r.get(k)) is not None for r in rows if r.get(k) is not None)]
    labels = [k for k in keys if k not in measures]
    fig = go.Figure()
    if not rows or not measures:
        return None
    x = labels[0] if labels else keys[0]
    if tile["kind"] != "line" and not tile.get("ordered"):       # no ORDER BY in its SQL: the largest bar first
        rows = sorted(rows, key=lambda r: (number(r.get(measures[0])) is None, -(number(r.get(measures[0])) or 0)))
    for n, measure in enumerate(measures[:3]):
        values = [number(r.get(measure)) for r in rows]
        names = ["(no value)" if r.get(x) is None else str(r.get(x)) for r in rows]
        if tile["kind"] == "line":
            fig.add_trace(go.Scatter(x=names, y=values, mode="lines+markers", name=measure.replace("_", " "),
                                     line={"color": COLORS[n % len(COLORS)], "width": 2}))
        else:
            fig.add_trace(go.Bar(x=values, y=names, orientation="h", name=measure.replace("_", " "),
                                 marker_color=COLORS[n % len(COLORS)]))
    fig.update_layout(margin={"l": 8, "r": 8, "t": 8, "b": 8}, paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)",
                      font={"family": "system-ui, sans-serif", "size": 12}, showlegend=len(measures) > 1,
                      height=320 if tile["kind"] == "line" else max(240, min(900, len(rows) * 24 + 40)))
    if tile["kind"] != "line":
        fig.update_yaxes(autorange="reversed", automargin=True)
    fig.update_xaxes(gridcolor="#e9e9e4", zeroline=False)
    return fig


def tile_view(tile, result, chosen):
    head = html.Div([html.H2(tile["title"]), html.Span(tile["kind"], className="share-badge")], className="board-tile-head")
    if result.get("late"):
        return html.Article([head, html.P("Still running at the source. Refresh in a moment: the answer is kept when it comes.",
                                          className="board-note")], className="share-panel board-tile")
    if result.get("error"):
        return html.Article([head, html.P(result["error"], className="board-note board-error")], className="share-panel board-tile")
    rows = keep(result["rows"], chosen)
    note = (f"{len(rows):,} of {len(result['rows']):,} rows" if chosen else f"{len(rows):,} rows") + (" (capped)" if result.get("cut") else "")
    body = []
    if not rows:
        body.append(html.P("No rows for this selection.", className="board-note"))
    elif tile["kind"] == "kpi":
        value = next(iter(rows[0].values()))
        shown = f"{number(value):,.0f}" if number(value) is not None and abs(number(value)) >= 100 else str(value)
        body.append(html.Div(shown, className="share-stat-value board-kpi"))
    elif tile["kind"] in ("bar", "line") and (fig := figure(tile, rows)) is not None:
        # responsive charts take their container's height: without one the chart collapses to a sliver
        body.append(dcc.Graph(figure=fig, style={"height": f"{fig.layout.height or 320}px"},
                              config={"displayModeBar": False, "responsive": True}))
    if rows and tile["kind"] != "kpi":
        table = dash_table.DataTable(data=rows[:TABLE_ROWS], columns=[{"name": k.replace("_", " "), "id": k} for k in rows[0]],
                                     page_size=10, sort_action="native", export_format="csv", style_table={"overflowX": "auto"},
                                     style_cell={"fontFamily": "inherit", "fontSize": "12px", "textAlign": "left", "padding": "8px 12px"})
        body.append(table if tile["kind"] == "table" else html.Details([html.Summary("The rows"), table], className="board-rows"))
    return html.Article([head, *body, html.P(note, className="board-note")], className="share-panel board-tile")


def create_dash_app(server, url_base_pathname, metadata):
    app = Dash(__name__, server=server, routes_pathname_prefix="/", requests_pathname_prefix=url_base_pathname.rstrip("/") + "/",
               assets_folder=str(HERE / "assets"), title=BOARD["title"], suppress_callback_exceptions=True)
    pages = BOARD["pages"]
    app.layout = html.Main([
        html.Header([html.Div([html.Span("Exasol", className="share-brand"), html.Span("Dashboard", className="share-section")]),
                     html.Span("Read-only data", className="share-badge")], className="share-topbar"),
        html.Section([html.Div([html.H1(BOARD["title"]),
                                html.P(f"{len(pages)} page{'s' if len(pages) != 1 else ''} of approved answers", className="share-subtitle")]),
                      html.Div([html.Span(id="board-status", className="share-freshness"),
                                html.Button("Refresh", id="board-refresh", n_clicks=0, className="share-export")], className="board-actions")],
                     className="share-heading"),
        dcc.Tabs(id="board-page", value=pages[0]["id"], className="board-tabs",
                 children=[dcc.Tab(label=p["title"], value=p["id"], className="board-tab", selected_className="board-tab-on") for p in pages]),
        html.Div(id="board-filters", className="board-filters"),
        dcc.Loading(html.Div(id="board-tiles", className="board-grid"), type="dot", delay_show=300),
        html.Details([html.Summary("About this dashboard"),
                      html.P("Every tile is an approved question: its SQL ran as written when it was approved, as the read-only user."),
                      html.P("Workflow: " + LINEAGE.get("workflow_id", "") + " · Board: " + LINEAGE.get("board", "")
                             + " · Queries: " + LINEAGE.get("query_digest", "")[:16])], className="share-about"),
        dcc.Interval(id="board-tick", interval=max(REFRESH_SECONDS, 1) * 1000, n_intervals=0, disabled=REFRESH_SECONDS == 0),
    ], className="exakit-share")

    @app.callback(Output("board-filters", "children"), Input("board-page", "value"))
    def filters(page_id):
        page = next((p for p in pages if p["id"] == page_id), pages[0])
        if not page.get("filters"):
            return []
        found = results(page["tiles"], server, metadata)
        boxes = []
        for col in page["filters"]:
            values = sorted({str(r[col]) for res in found.values() for r in res.get("rows") or [] if col in r and r[col] is not None})[:500]
            boxes.append(html.Div([html.Label(col.replace("_", " ").lower()),
                                   dcc.Dropdown(id={"type": "board-filter", "col": col}, multi=True, placeholder="All",
                                                options=[{"label": v, "value": v} for v in values], className="share-select")],
                                  className="share-field"))
        return boxes

    @app.callback(Output("board-tiles", "children"), Output("board-status", "children"),
                  Input("board-page", "value"), Input("board-refresh", "n_clicks"), Input("board-tick", "n_intervals"),
                  Input({"type": "board-filter", "col": ALL}, "value"))
    def render(page_id, _clicks, _ticks, _values):
        fresh = ctx.triggered_id in ("board-refresh", "board-tick")
        tiles = tiles_of(page_id)
        found = results(tiles, server, metadata, fresh=fresh)
        chosen = {}
        for item in (ctx.inputs_list[3] if len(ctx.inputs_list) > 3 else []):
            if item.get("value"):
                chosen[item["id"]["col"]] = set(str(v) for v in item["value"])
        views = [tile_view(t, found.get(t["id"], {"rows": []}), chosen) for t in tiles]
        return views, "Refreshed " + datetime.now(timezone.utc).strftime("%H:%M UTC")

    return app
'''

BOARD_CSS = r'''
.board-actions{display:flex;align-items:center;gap:12px}
.board-tabs{margin:0 0 14px;border-bottom:1px solid var(--share-grid)}
.board-tab{font:inherit!important;font-size:13px!important;padding:10px 16px!important;border:0!important;background:transparent!important;color:var(--share-muted)!important}
.board-tab-on{color:var(--share-ink)!important;border-bottom:2px solid var(--share-accent)!important;font-weight:650}
.board-filters{display:flex;gap:14px;flex-wrap:wrap;margin:0 0 16px}.board-filters .share-field{min-width:220px;flex:1;max-width:360px}
.board-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:18px}
.board-tile{padding:16px 18px}.board-tile-head{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;margin-bottom:8px}
.board-kpi{font-size:40px;margin:12px 0}.board-note{font-size:11px;color:var(--share-muted);margin:8px 0 0}.board-error{color:#b42318}
.board-rows summary{cursor:pointer;font-size:12px;color:var(--share-accent);margin-top:8px}
@media(max-width:760px){.board-grid{grid-template-columns:1fr}}
'''
