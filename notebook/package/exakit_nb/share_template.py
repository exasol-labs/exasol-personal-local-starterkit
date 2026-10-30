"""Dashboard source and shared design tokens; imports need no dashboard libraries."""

APP_SOURCE = r'''
"""Standalone Dash Server dashboard; connection data stays in the scaffold's server profile."""
import csv
import io
import importlib.util
import json
import math
from datetime import datetime, timezone
from pathlib import Path

import plotly.graph_objects as go
from dash import Dash, Input, Output, State, dcc, html, dash_table

spec = importlib.util.spec_from_file_location("dash_server_generated_exasol_helper", Path(__file__).with_name("dash_server_exasol.py"))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
TITLE = ''
LINEAGE = {}
COLORS = ["#2a78d6", "#1baf7a", "#eb6834", "#eda100", "#8b6dcc", "#3c949c"]


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) else None


def category_key(value):
    return json.dumps(value, sort_keys=True, default=str)


def filtered_rows(rows, categories, top_n, search=None, order="largest"):
    """One filtered result feeds cards, charts and table; the source rows remain unchanged."""
    if not rows:
        return []
    keys = list(rows[0])
    selected = [r for r in rows if not categories or category_key(r.get(keys[0])) in categories]
    if search and search.strip():
        term = search.strip().casefold()
        selected = [r for r in selected if term in " ".join(str(v) for v in r.values()).casefold()]
    numeric = len(keys) > 1 and all(number(r.get(keys[1])) is not None for r in selected)
    if numeric and order != "category":
        selected = sorted(selected, key=lambda r: ((-1 if order == "largest" else 1) * number(r[keys[1]]), str(r.get(keys[0]))))
    elif order == "category":
        selected = sorted(selected, key=lambda r: str(r.get(keys[0])).casefold())
    return selected[:max(0, int(top_n or 1000))]


def composition_series(labels, values, colors):
    """Keep a readable legend while preserving the total of every displayed count."""
    pairs = sorted(zip(labels, values, colors), key=lambda item: item[1], reverse=True)
    visible = pairs[:8]
    if len(pairs) > 8:
        visible.append(("Other displayed categories", sum(item[1] for item in pairs[8:]), "#c3c2b7"))
    return [p[0] for p in visible], [p[1] for p in visible], [p[2] for p in visible]


def export_csv(rows):
    """Keep source values unchanged; neutralize spreadsheet formulas only in the downloaded CSV."""
    if not rows:
        return ""
    keys = list(rows[0])
    def safe(value):
        if isinstance(value, str) and value.lstrip(" \t\r\n\v\f\ufeff\0").startswith(("=", "+", "-", "@")):
            return "'" + value
        return value
    stream = io.StringIO(newline="")
    writer = csv.writer(stream)
    writer.writerow([safe(key) for key in keys])
    writer.writerows([[safe(row.get(key)) for key in keys] for row in rows])
    return stream.getvalue()


def create_dash_app(server, url_base_pathname, metadata):
    app = Dash(__name__, server=server, routes_pathname_prefix="/",
               requests_pathname_prefix=url_base_pathname.rstrip("/") + "/",
               assets_folder=str(Path(__file__).with_name("assets")), title=metadata.get("title", TITLE))

    def field(label, component, name, wide=False):
        return html.Div([html.Label(label, htmlFor=name), component], className="share-field share-field-wide" if wide else "share-field")

    app.layout = html.Main([
        html.Header([html.Div([html.Span("Exasol", className="share-brand"), html.Span("Shared analysis", className="share-section")]),
                     html.Span("Read-only data", className="share-badge")], className="share-topbar"),
        html.Section([html.Div([html.P("DATA OVERVIEW", className="share-eyebrow"), html.H1(TITLE),
                               html.P("Compare the result, focus on what matters, and inspect the numbers behind it.", className="share-subtitle")]),
                      html.Div(id="result-status", role="status", **{"aria-live": "polite"}, className="share-freshness")], className="share-heading"),
        dcc.Interval(id="refresh", interval=30000, n_intervals=0), dcc.Store(id="source-rows"),
        html.Section([html.Article(id="count-summary", className="share-stat share-stat-primary"),
                      html.Article(id="category-summary", className="share-stat"),
                      html.Article(id="leading-summary", className="share-stat")], className="share-stats", **{"aria-label": "Current result summary"}),
        html.Section([
            html.Button("Reset filters", id="reset-filters", n_clicks=0, className="share-reset"),
            html.Details([html.Summary("Filters and display"), html.Div([
                field("Categories", dcc.Dropdown(id="category-filter", multi=True, placeholder="All categories", options=[], className="share-select"), "category-filter", True),
                field("Show", dcc.Dropdown(id="top-n", clearable=False, value=10, className="share-select",
                    options=[{"label": "Top " + str(n), "value": n} for n in (1, 3, 5, 10, 20, 50)]), "top-n"),
                field("Sort by", dcc.Dropdown(id="sort-order", clearable=False, value="largest", className="share-select",
                    options=[{"label": "Largest first", "value": "largest"}, {"label": "Smallest first", "value": "smallest"}, {"label": "Category A–Z", "value": "category"}]), "sort-order"),
                field("Chart layout", dcc.Dropdown(id="chart-direction", clearable=False, value="horizontal", className="share-select",
                    options=[{"label": "Horizontal bars", "value": "horizontal"}, {"label": "Vertical bars", "value": "vertical"}]), "chart-direction"),
                field("Search this result", dcc.Input(id="row-search", type="search", debounce=True, placeholder="Search categories or values…", className="share-search"), "row-search", True),
            ], className="share-filters"),
            html.P("Filters apply to every card, chart and table below. Clear categories to include all. Top N is applied after filtering.", className="share-helper"),
            ], className="share-filter-details"),
        ], className="share-panel share-filter-panel"),
        html.Section([
            html.Article([html.Div([html.H2("Category comparison"), html.P("Compare the values in your current selection.")], className="share-chart-heading"),
                          html.Div(dcc.Graph(id="result-chart", config={"displayModeBar": False, "responsive": True}, style={"height": "330px", "minHeight": "330px", "width": "100%"}), className="share-plot-scroll")], className="share-panel"),
            html.Article([html.Div([html.H2("Composition"), html.P(id="composition-caption")], className="share-chart-heading"),
                          dcc.Graph(id="composition-chart", config={"displayModeBar": False, "responsive": True}, style={"height": "330px", "minHeight": "330px", "width": "100%"})], className="share-panel",
                         style={} if LINEAGE.get("measure") == "count" else {"display": "none"}),
        ], className="share-charts" if LINEAGE.get("measure") == "count" else "share-charts share-charts-single"),
        html.Section([html.Div([html.Div([html.H2("Behind the charts"), html.P("The same filtered rows. Sort a column or export this selection.")]),
                               html.Div([html.Span(id="table-summary", className="share-badge"), html.Button("Export CSV", id="export-result", n_clicks=0, className="share-export"), dcc.Download(id="download-result")], className="share-table-actions")], className="share-panel-heading"),
            html.Div(dash_table.DataTable(id="result-table", data=[], columns=[], page_size=10, page_action="native", sort_action="native",
                style_table={"overflowX": "auto"},
                style_cell={"fontFamily": "inherit", "fontSize": "13px", "textAlign": "left", "padding": "13px 18px", "border": "none", "borderBottom": "1px solid #e9e9e4", "maxWidth": "360px", "whiteSpace": "normal", "height": "auto"},
                style_header={"backgroundColor": "#f6f6f3", "fontSize": "11px", "fontWeight": "600", "textTransform": "uppercase", "letterSpacing": "0.04em", "color": "#52514e"},
                style_data_conditional=[{"if": {"row_index": "odd"}, "backgroundColor": "#fcfcfa"}]), className="share-table-wrap"),
        ], className="share-panel share-table-panel"),
        html.Details([html.Summary("About this shared result"), html.P("This is a view of the reviewed SQL result, not a new calculation over the source table. "
            "The composition chart uses the displayed count total, so excluded categories are not part of its denominator. Query results may be limited by the server."),
            html.P("Dataset: " + LINEAGE["descriptor_id"] + " · Descriptor: " + LINEAGE["descriptor_version"]),
            html.P("Workflow: " + LINEAGE["workflow_id"] + " · Query: " + LINEAGE["query_digest"][:16])], className="share-about"),
    ], className="exakit-share")

    @app.callback(Output("download-result", "data"), Input("export-result", "n_clicks"),
                  State("result-table", "derived_virtual_data"), State("result-table", "data"), prevent_initial_call=True)
    def download(_, sorted_rows, rows):
        return {"content": export_csv(sorted_rows if sorted_rows is not None else rows or []), "filename": "shared-result.csv", "type": "text/csv"}

    @app.callback(Output("category-filter", "value"), Output("top-n", "value"), Output("sort-order", "value"),
                  Output("chart-direction", "value"), Output("row-search", "value"), Input("reset-filters", "n_clicks"), prevent_initial_call=True)
    def reset(_):
        return [], 10, "largest", "horizontal", ""

    @app.callback(Output("source-rows", "data"), Output("category-filter", "options"), Output("result-status", "children"), Input("refresh", "n_intervals"))
    def refresh(_):
        rows = helper.load_rows(server, metadata, __file__, "queries/business/result.sql")
        if helper.has_error(rows):
            return [], [], "Refresh failed · no stale values shown"
        if not rows:
            return [], [], "No rows returned"
        key = next(iter(rows[0]))
        options = {category_key(r.get(key)): "(missing)" if r.get(key) is None else str(r[key]) for r in rows}
        return rows, [{"label": label, "value": value} for value, label in sorted(options.items(), key=lambda p: p[1])], \
            "Live · refreshed " + datetime.now(timezone.utc).strftime("%H:%M UTC")

    @app.callback(Output("result-chart", "figure"), Output("composition-chart", "figure"), Output("result-table", "data"),
                  Output("result-table", "columns"), Output("count-summary", "children"), Output("category-summary", "children"),
                  Output("leading-summary", "children"), Output("table-summary", "children"), Output("composition-caption", "children"), Output("result-chart", "style"),
                  Input("source-rows", "data"), Input("category-filter", "value"), Input("top-n", "value"),
                  Input("chart-direction", "value"), Input("row-search", "value"), Input("sort-order", "value"))
    def render(rows, categories, top_n, direction, search, order):
        rows = rows or []
        visible = filtered_rows(rows, categories, top_n, search, order)
        bars, composition = go.Figure(), go.Figure()
        total, leading, highest = None, "No matching rows", None
        keys = list(rows[0]) if rows else []
        count = LINEAGE.get("measure") == "count"
        if count and rows and not visible:
            total = 0
        if visible:
            labels = ["(missing)" if r.get(keys[0]) is None else str(r[keys[0]]) for r in visible]
            numeric = len(keys) > 1 and all(number(r.get(keys[1])) is not None for r in visible)
            if numeric:
                values = [number(r[keys[1]]) for r in visible]
                best = max(range(len(values)), key=lambda i: values[i])
                leading, highest = labels[best], values[best]
                palette = {category_key(r.get(keys[0])): COLORS[i % len(COLORS)] for i, r in enumerate(rows)}
                colors = [palette[category_key(r.get(keys[0]))] for r in visible]
                horizontal = direction == "horizontal"
                bars.add_bar(x=values if horizontal else labels, y=labels if horizontal else values, orientation="h" if horizontal else "v",
                             marker_color=colors, marker_line_width=0, name=keys[1], text=values, texttemplate="%{text:,.0f}" if count else "%{text:,.3~g}", textposition="auto")
                bars.update_layout(xaxis_title="Count" if horizontal and count else (keys[1] if horizontal else None), yaxis_title=None if horizontal else ("Count" if count else keys[1]))
                if horizontal:
                    bars.update_yaxes(autorange="reversed", automargin=True, tickmode="array", tickvals=labels, ticktext=[label if len(label) <= 40 else label[:37] + "…" for label in labels])
                if count and all(v >= 0 for v in values):
                    total = sum(values)
                    if total > 0:
                        pie_labels, pie_values, pie_colors = composition_series(labels, values, colors)
                        composition.add_pie(labels=pie_labels, values=pie_values, hole=0.68, sort=False, marker_colors=pie_colors,
                                            textinfo="none", hovertemplate="%{label}<br>%{value:,} · %{percent}<extra></extra>")
                        composition.add_annotation(text=f"{total:,.0f}<br><span style='font-size:11px'>displayed total</span>", showarrow=False, font_size=23)
            if not numeric:
                bars.add_annotation(text="No numeric measure to plot.<br>Inspect the result table below.", showarrow=False)
        else:
            bars.add_annotation(text="No matching rows<br>Try clearing your filters.", showarrow=False)
        if not composition.data:
            composition.add_annotation(text="Composition needs a positive<br>reviewed count measure.", showarrow=False)
        for figure in (bars, composition):
            figure.update_layout(template="plotly_white", height=330, paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)",
                font={"family": "system-ui, -apple-system, Segoe UI, sans-serif", "size": 12, "color": "#52514e"}, margin={"l": 26, "r": 24, "t": 12, "b": 38},
                legend={"orientation": "h", "y": -0.08, "x": 0.5, "xanchor": "center", "font": {"size": 11}}, uniformtext_minsize=10, uniformtext_mode="hide")
            figure.update_xaxes(gridcolor="#e9e9e4", zeroline=False, automargin=True)
            figure.update_yaxes(gridcolor="#e9e9e4", zeroline=False, automargin=True)
        bar_height = max(330, min(1400, len(visible) * 26 + 65)) if direction == "horizontal" else 330
        bars.update_layout(height=bar_height)
        def stat(label, value, note):
            return [html.P(label, className="share-stat-label"), html.Div(value, className="share-stat-value"), html.P(note, className="share-stat-note")]
        count_card = stat("Displayed count" if count else "Highest value", (f"{total:,.0f}" if total is not None else "—") if count else (f"{highest:,.3g}" if highest is not None else "—"),
                          "Across the current selection" if count else "Individual value · not a sum")
        category_card = stat("Categories shown", str(len(visible)), "of " + str(len(rows)) + " returned by the query")
        leading_card = stat("Leading category", leading, (f"{highest:,.0f}" if count else f"{highest:,.3g}") + " in the selected result" if highest is not None else "Reset filters to see the full result")
        return bars, composition, visible, [{"name": k.replace("_", " "), "id": k} for k in keys], count_card, category_card, leading_card, \
            str(len(visible)) + " rows", (("Share of displayed counts. Smaller categories are grouped as Other." if len(visible) > 8 else "Share of the displayed count, after filtering and Top N.") if count else "Totals are disabled for measures not declared as counts."), {"height": str(bar_height) + "px", "minHeight": str(bar_height) + "px", "width": "100%"}
    return app
'''

APP_CSS = r'''
.share-plot-scroll{max-height:430px;overflow-y:auto;overflow-x:hidden}.share-charts{align-items:start}
.share-charts.share-charts-single{grid-template-columns:minmax(0,1fr)}
.share-table-actions{display:flex;align-items:center;gap:12px}.share-export{font:inherit;font-size:11px;color:var(--share-accent);border:1px solid var(--share-grid);border-radius:6px;background:var(--share-surface);padding:7px 12px;cursor:pointer}.share-export:focus-visible{outline:2px solid var(--share-accent);outline-offset:2px}
:root{--share-page:#f9f9f7;--share-surface:#fcfcfb;--share-ink:#0b0b0b;--share-muted:#52514e;--share-grid:#e1e0d9;--share-accent:#2a78d6}
body{margin:0;background:var(--share-page)}
.exakit-share,.exakit-share *{box-sizing:border-box}
.exakit-share{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;color:var(--share-ink);max-width:1320px;margin:0 auto;padding:0 36px 110px;font-size:14px;line-height:1.5}
.share-topbar{height:70px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--share-grid);gap:16px}
.share-topbar>div{display:flex;align-items:center;gap:18px}.share-brand{font-size:22px;font-weight:750;letter-spacing:-.7px}.share-section{padding-left:18px;border-left:1px solid var(--share-grid);font-size:12px;color:var(--share-muted)}
.share-badge{display:inline-block;border:1px solid var(--share-grid);border-radius:6px;padding:5px 9px;font-size:11px;color:var(--share-muted);white-space:nowrap;background:var(--share-surface)}
.share-heading{display:flex;justify-content:space-between;align-items:flex-end;gap:24px;padding:32px 0 24px}.share-eyebrow{font-size:10px;letter-spacing:.12em;font-weight:650;color:var(--share-muted);margin:0 0 7px}.exakit-share h1{font-size:32px;line-height:1.16;letter-spacing:-1px;margin:0 0 10px;font-weight:650}.share-subtitle{color:var(--share-muted);font-size:13px;margin:0;max-width:650px}.share-freshness{font-size:11px;color:#246247;white-space:nowrap;padding-bottom:2px}
.share-stats{display:grid;grid-template-columns:1fr 1fr 1.2fr;gap:16px;margin:0 0 20px}.share-stat{background:var(--share-surface);border:1px solid var(--share-grid);border-radius:12px;padding:20px 22px;min-width:0}.share-stat-primary{border-top:3px solid var(--share-accent);padding-top:18px}.share-stat-label{font-size:11px;color:var(--share-muted);margin:0 0 8px}.share-stat-value{font-size:30px;letter-spacing:-.8px;line-height:1.2;font-weight:650;overflow-wrap:anywhere}.share-stat:last-child .share-stat-value{font-size:23px;line-height:1.56}.share-stat-note{font-size:11px;color:var(--share-muted);margin:8px 0 0}
.share-panel{background:var(--share-surface);border:1px solid var(--share-grid);border-radius:12px;min-width:0;overflow:hidden}.share-panel-heading{padding:18px 22px;display:flex;align-items:center;justify-content:space-between;gap:16px}.exakit-share h2{font-size:14px;font-weight:650;letter-spacing:-.1px;line-height:1.35;margin:0}.share-panel-heading p,.share-chart-heading p{font-size:11px;color:var(--share-muted);margin:5px 0 0}.share-reset{font:inherit;font-size:11px;font-weight:600;background:transparent;color:var(--share-accent);border:0;padding:7px 0 7px 12px;cursor:pointer}.share-reset:hover{text-decoration:underline}.share-reset:focus-visible,.share-about summary:focus-visible{outline:2px solid var(--share-accent);outline-offset:3px}
.share-filters{display:grid;grid-template-columns:2fr 1fr 1.25fr 1.3fr 1.6fr;gap:14px;padding:0 22px}.share-field{min-width:0}.share-field label{display:block;font-size:10px;color:var(--share-muted);font-weight:600;margin-bottom:6px}.share-select{font-size:12px}.share-search{width:100%;height:38px;border:1px solid #cecec6;border-radius:5px;background:var(--share-surface);font:inherit;font-size:12px;padding:8px 10px;color:var(--share-ink)}.share-search:focus{outline:2px solid var(--share-accent);outline-offset:1px}.share-helper{margin:12px 22px 18px;color:var(--share-muted);font-size:10px;line-height:1.6}
.share-charts{display:grid;grid-template-columns:minmax(0,1.3fr) minmax(0,1fr);gap:20px;margin:20px 0}.share-chart-heading{padding:20px 22px 12px}.share-charts .js-plotly-plot{padding:0 10px 10px}.share-table-panel .share-panel-heading{border-bottom:1px solid var(--share-grid)}.share-table-wrap{padding:0 4px 8px}.share-table-wrap .dash-spreadsheet-container{font-family:inherit}.share-table-wrap .dash-spreadsheet-menu{padding:10px 16px}.share-table-wrap button{font-family:inherit;cursor:pointer}.share-table-wrap .export{background:transparent;color:var(--share-accent);border:1px solid var(--share-grid);border-radius:5px;padding:6px 12px;font-size:11px}.share-table-wrap .previous-next-container{padding:8px 16px;font-size:12px}.share-about{margin-top:24px;border-top:1px solid var(--share-grid);padding:16px 2px;color:var(--share-muted);font-size:11px;overflow-wrap:anywhere}.share-about summary{cursor:pointer;font-weight:600}.share-about p{max-width:900px;line-height:1.7;margin:10px 0}
@media(max-width:1100px){.share-filters{grid-template-columns:repeat(3,minmax(0,1fr))}.share-field-wide{grid-column:span 1}.share-heading{align-items:flex-start}.share-freshness{white-space:normal;min-width:130px}.share-charts{grid-template-columns:minmax(0,1fr) minmax(0,1fr)}}
@media(max-width:760px){.exakit-share{padding:0 20px 100px}.share-topbar{height:58px}.share-brand{font-size:20px}.share-section{font-size:10px;padding-left:12px}.share-topbar>div{gap:12px}.share-heading{display:block;padding:24px 0 18px}.exakit-share h1{font-size:27px;letter-spacing:-.6px}.share-subtitle{font-size:12px}.share-freshness{margin-top:10px;font-size:10px}.share-stats{grid-template-columns:1fr 1fr;gap:12px;margin-bottom:16px}.share-stat{padding:15px 16px}.share-stat-primary{padding-top:13px}.share-stat-value{font-size:27px}.share-stat:last-child{grid-column:span 2;display:grid;grid-template-columns:1fr 1fr;align-items:center;column-gap:14px}.share-stat:last-child .share-stat-label{grid-column:1;margin:0}.share-stat:last-child .share-stat-value{grid-column:2;grid-row:1/3;font-size:20px;text-align:right;line-height:1.3}.share-stat:last-child .share-stat-note{grid-column:1;margin:4px 0 0}.share-filters{grid-template-columns:1fr 1fr;gap:12px;padding:0 16px}.share-field-wide{grid-column:span 2}.share-panel-heading{padding:15px 16px}.share-helper{margin:10px 16px 15px}.share-charts{grid-template-columns:1fr;gap:16px;margin:16px 0}.share-chart-heading{padding:17px 16px 8px}.share-charts .js-plotly-plot{padding:0 2px 8px}.share-badge{font-size:10px;padding:4px 7px}}
@media(prefers-reduced-motion:reduce){.exakit-share *{scroll-behavior:auto!important;animation:none!important;transition:none!important}}

.share-filter-panel{position:relative}.share-filter-panel>.share-reset{position:absolute;right:22px;top:11px;z-index:1;padding:7px 0}
.share-filter-details>summary{list-style-position:inside;padding:18px 132px 18px 22px;font-size:12px;font-weight:650;cursor:pointer;min-height:56px}.share-filter-details>summary:focus-visible{outline:2px solid var(--share-accent);outline-offset:-4px}.share-filter-details[open]>summary{border-bottom:1px solid var(--share-grid);margin-bottom:16px}
@media(max-width:760px){.share-stat:last-child{display:none}.share-filter-details>summary{padding-left:16px;font-size:12px}.share-filter-panel>.share-reset{right:16px}.share-heading{padding:21px 0 16px}}
'''
