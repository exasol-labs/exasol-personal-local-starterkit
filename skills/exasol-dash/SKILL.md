---
name: exasol-dash
addon: dash-server
description: "Exasol's own guide (from the dash-server repository) to writing the Dash app itself for a dashboard hosted on dash-server — layout, callbacks, the queries behind each figure, and patching or reviewing an existing app. Use it with the dash-server skill, which covers installing, starting and registering the server."
---

> **Exasol starter kit:** Exasol's own skill, copied unchanged from [exasol-labs/dash-server](https://github.com/exasol-labs/dash-server) at `v0.2.1`. On this machine the `exakit` skill comes first: how to connect, how to load data and which tool to reach for.

# Skill: Exasol Dash for Claude Code / Codex

Use this skill when you need to design, generate, patch, or review Dash dashboards that query Exasol directly from Python. It is optimized for the `dash-server` workflow, but the patterns also apply to standalone Dash apps.

Companion skill:

- Read [pyexasol_skill.md](pyexasol_skill.md) when you need connector-specific details, placeholder syntax, bulk I/O, metadata helpers, or low-level connection tuning. **Note its scope banner:** inside a hosted dashboard you never open a connection yourself.

## Currency and authority

Verified against `dash-server` at Dash 4.4, pyexasol 2.3, plotly 6.9, dash-ag-grid 35.2 (July 25, 2026).

This file is prose and can drift. The MCP resources are generated from the running code, so **when they disagree, the resource is right**:

| Read this | For |
| --- | --- |
| `dash://meta/app-authoring-guide` | the required `create_dash_app` factory shape |
| `dash://exasol/help/sql-placeholders` | the full placeholder table and failure modes |
| `dash://exasol/help/dashboard-patterns` | which scaffold pattern emits real SQL vs demo stubs |
| `dash://exasol/help/agent-workflow` | how to combine dash-server with a separate Exasol MCP server |
| `dash://exasol/help/semantic-layer` | building on a governed Exasol Semantic Views model, when the database has one |
| `dash://meta/session-channel-guide` | inspecting a live dashboard in the user's browser (local mode) |
| `dash://meta/workflows` | the canonical create → validate → build → preview → promote sequence |

Read the relevant resource before generating code; use this skill for design judgment.

## What this skill is for

- Turning Exasol data into polished, responsive Dash dashboards.
- Choosing chart and table patterns that fit Exasol’s strengths.
- Structuring SQL, callbacks, and refresh logic so the app is fast, maintainable, and agent-editable.
- Avoiding common mistakes like import-time queries, oversized result sets, and charts that should have been aggregated in SQL.

## Core design rule

**Let Exasol compute. Let Dash orchestrate and render.**

That means:

- push filters, joins, aggregations, bucketing, ranking, and window logic into SQL
- return relatively small, presentation-ready result sets
- keep Python callbacks focused on:
  - selecting parameters
  - calling queries
  - small formatting / figure assembly
  - coordinating UI state

Do not use Dash callbacks to simulate a database engine.

## Non-negotiable rules

1. Never query Exasol at module import time.
2. Never open Exasol connections inside `create_dash_app()` just to build the layout.
3. In `dash-server`, always use:
   - `routes_pathname_prefix="/"`,
   - `requests_pathname_prefix=url_base_pathname.rstrip("/") + "/"`,
   - `app.callback`, not global `dash.callback`.
4. Keep secrets out of app source, manifests, Git, logs, and visible UI.
5. **Never call `pyexasol.connect(...)` in a hosted app.** Validation rejects it outright, along with `password=` / `access_token=` / `refresh_token=` assignments and `EXA_*` env reads. Hosted apps name a profile and go through the runtime helpers; the server owns the credential.
6. **Use pyexasol format-style placeholders, never `:name`.** `:name` is not supported and fails at runtime with `Feature not supported: host parameter specification`. See *Parameterizing SQL* below.
7. **Check `has_error(rows)` before iterating any query result.** The helpers never raise on a data-layer failure — they return an error envelope. See *The data-layer return contract* below.
8. Return only the columns and rows the component actually needs.
9. Prefer one good query per visual state over shipping a giant raw dataset to Python and slicing it there.

## Check for a semantic layer before writing metric SQL

If the database has a governed semantic model (Exasol Semantic Views), build on it. Its metrics are the certified definitions, and it combines multi-grain and multi-source data correctly. Hand-written metric SQL over the raw tables can disagree with the certified number and still pass every check.

```sql
SELECT MODEL_NAME, PUBLISHED_SCHEMA, DESCRIPTION
FROM SEMANTIC_AGENT.MODELS_FOR_AGENT
WHERE MODEL_STATUS = 'PUBLISHED';
```

`exasol_profile_validate` also lists them (`semantic_layer.models`). If a model covers the question:

- Give the profile `session_init_sql = ["ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"]` (for an existing profile: `exasol_profile_create_local` with `name`, `overwrite: true` and `session_init_sql`; other settings are kept) and confirm `session_init.status == "applied"` with `exasol_profile_validate`. `EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()`, the form `INSTRUCTIONS_FOR_AGENT` names, works too.
- Query the published views from `queries/*.sql`: `SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES GROUP BY customer_region`. Metrics are already aggregated; don't wrap them in `SUM()`.
- Never paste `COMPILE_SQL` / `COMPILE_REQUEST_JSON` output into `queries/*.sql`: it freezes today's definition. `app_run_healthcheck` degrades on such files (`semantic_models` → `frozen_files`).
- Take labels and formats from `SEMANTIC_AGENT.FIELDS_FOR_AGENT` instead of hard-coding them.
- Live Semantic SQL in `queries/*.sql` is the lane dash-server hosts; Semantic Views' per-request compile lane (`COMPILE_REQUEST_JSON` on every request) isn't supported.
- Prototyping through the Exasol MCP server: run Semantic SQL calls one at a time. A pooled session without the preprocessor fails with `not a valid GROUP BY expression`; set the preprocessor again and rerun.
- For a starting point, `app_scaffold_from_schema` with `schema_name` set to the model's published schema generates a dashboard over its certified metrics. It reads labels, formats and certification from the model at runtime and shows the model's validation state; keep its query columns unaliased so they match `FIELDS_FOR_AGENT.SQL_COLUMN_NAME`.
- After a build, `app_run_healthcheck` reports metric definitions that changed since that revision was built (`semantic_models` → `changed_since_build`), and `dash://exasol/semantic-usage` shows which dashboards use a given metric, plus the ones that bypass the model (`bypasses`).

`dash://exasol/help/semantic-layer` has the full recipe, including grants for a non-SYS profile user and how SQL smoke and the `semantic_models` healthcheck probe treat semantic queries.

Without a semantic layer, aggregate each measure at its own grain before joining: freight stored once per order, summed over a join to order lines, is counted once per line.

## Choosing a creation path

`dash://exasol/help/dashboard-patterns` (`choosing_a_creation_path`) is authoritative. In short:

1. **`app_create_from_files`** with `template="exasol-analytics"` — the default once you know what you are building. It takes your `app.py` and `queries/*.sql` and injects `dash_server_exasol.py`, so skipping a scaffold costs nothing. This is also the path for dashboards on a semantic model.
2. **`app_scaffold_from_schema`** — while you are still exploring an unfamiliar schema. It picks analytically useful columns and date columns and emits **catalog-backed SQL**; keep what it taught you and delete the rest.
3. **`app_create_exasol_dashboard`** with `pattern="analytics-hub"` — a prebuilt multi-tab dashboard (system health, query history, and a business placeholder ready for your SQL).
4. **`app_create_exasol_dashboard`** with `pattern="overview"` or `"kpi-trend"` — **demo-only.** Their generated `queries/*.sql` are `SELECT … FROM DUAL` stubs with hard-coded numbers. Use them to look at layout shape, never as a starting point for real data.

The `sql_kind` field on each pattern in `dash://exasol/help/dashboard-patterns` says `real` or `demo_placeholder`.

## The data-layer return contract

This is the single most common way agent-generated Exasol dashboards go wrong, because the failure is silent.

`query_rows` / `query_one` / `query_scalar` (and the generated `load_rows` / `load_row` / `load_scalar` wrappers) **never raise** when a query fails. They return a single-row envelope instead:

```python
[{"_error": "<message>"}]     # from load_rows / query_rows
{"_error": "<message>"}       # from load_row / query_one
```

So this is a bug, and it renders the error message as if it were data:

```python
rows = load_rows(server, metadata, __file__, "queries/trend.sql")
figure = px.line(rows, x="DAY", y="REVENUE")   # WRONG: no error check
```

Always branch first:

```python
from dash_server_runtime import has_error   # or the generated helper of the same name

rows = load_rows(server, metadata, __file__, "queries/trend.sql")
if has_error(rows):
    return render_error_panel(rows[0]["_error"])
# rows is now safe to iterate
```

Why the contract is shaped this way: a raising helper would turn one bad query into a Dash callback exception and a blank component, with the reason buried in server logs. The envelope keeps the callback path stable and puts the message where the user and the agent can both see it.

The message is safe to show viewers: it is the database's own message (an Exasol or Semantic Views error such as `SEMANTIC_QUERY_029 ...`) followed by `(error ref 1a2b3c4d)`. Connection details (DSN, user, session id) and the SQL text are left out. The full error is on `dash://apps/{name}/errors`; its `details.error_ref` matches the reference.

### Row values are typed

Successful rows hold Python values, not strings. `DECIMAL` columns arrive as `int` or `decimal.Decimal`, `DATE` as `datetime.date`, and `TIMESTAMP` as `datetime.datetime`. `INTERVAL` values and numbers with more than 15 significant digits stay `str`, because the browser couldn't show those exactly. Pass values straight to plotly or Dash, and format them with `strftime()` or format specs (`f"{value:,.2f}"`). Never slice them as strings (`row["DAY"][:7]` raises `TypeError`). Convert with `float()` before mixing a `Decimal` into float arithmetic.

Related platform behavior worth knowing:

- Data-layer failures are recorded and surface as the `data_layer` probe in `app_run_healthcheck` and on `dash://apps/{name}/errors`.
- An error stops counting once its SQL file runs successfully again in the same revision. To clear errors for files that won't run again soon (after fixing SQL in place, say), call `app_acknowledge_data_layer_errors`.

## Parameterizing SQL

`dash-server` executes `queries/*.sql` through pyexasol's **client-side format-style** placeholders. `:name` bind parameters are not supported at all.

| Syntax | Use for | Renders as |
| --- | --- | --- |
| `{x}` or `{x!s}` | string literal | `'EMEA'` (single-quoted) |
| `{x!d}` | validated integer/decimal | `1234`, unquoted |
| `{x!f}` | validated float | `1.23`, unquoted |
| `{x!i}` | safe identifier | `SALES` |
| `{x!q}` | quoted identifier — use for reserved words | `"DAY"` |
| `{x!r}` | raw SQL fragment | verbatim; **never** with user input |

```sql
-- queries/trend.sql
SELECT TRUNC(order_ts, 'DD') AS DAY, SUM(revenue) AS REVENUE
FROM SALES
WHERE order_ts >= ADD_DAYS(CURRENT_TIMESTAMP, -{days!d})
  AND region = {region!s}
GROUP BY 1 ORDER BY 1
```

```python
rows = load_rows(server, metadata, __file__, "queries/trend.sql",
                 params={"days": 30, "region": "EMEA"})
```

Two traps:

- **An empty Python string renders as SQL `NULL`**, so `region = {region!s}` with `region=""` matches nothing rather than matching empty-string rows. Branch on empty/None in Python instead of passing it through.
- **Declared parameters and used placeholders must match exactly.** Validation fails a registered output whose SQL uses an undeclared parameter *or* declares one the SQL never uses.

`dash://exasol/help/sql-placeholders` has the full table and the rendered examples.

## Default architecture for an Exasol-backed Dash app

For `dash-server`, prefer this shape:

- `dash-app.json`
  - bind `data_sources.primary.profile`
- `app.py`
  - define layout and callbacks
- `dash_server_exasol.py`
  - helper functions for query execution and result shaping
- `queries/`
  - one SQL file per dashboard concern

Recommended callback flow:

1. user changes filters
2. callback derives query params
3. helper executes one SQL file against the bound profile
4. callback converts rows into a figure, grid, KPI cards, or summary text

## Chart selection guidance

Choose charts based on the decision the user needs to make, not on chart novelty.

### KPI cards

Use for:

- totals
- rates
- deltas vs prior period
- SLA / threshold indicators

Exasol pattern:

- pre-compute KPI rows in SQL
- return one row with named metrics
- avoid multiple round-trips for adjacent KPIs

### Time-series line charts

Use for:

- trend over time
- seasonality
- comparing a small number of series

Exasol pattern:

- aggregate in SQL to the displayed grain:
  - minute
  - hour
  - day
  - week
  - month
- do not ship event-level rows when the chart shows daily values
- cap the number of series aggressively

### Bar charts

Use for:

- ranked categories
- small categorical comparisons
- deviations from target

Exasol pattern:

- compute `TOP N` in SQL
- sort in SQL
- optionally add an `OTHER` bucket in SQL instead of flooding the chart with long tails

### Stacked / grouped bars

Use for:

- composition across a modest number of categories
- comparison of parts across periods or segments

Exasol pattern:

- pre-aggregate the stacked grain in SQL
- avoid stacks with too many colors or too many categories

### Scatter plots

Use for:

- relationships between two measures
- clusters
- outlier detection

Exasol pattern:

- sample or aggregate first
- do not send hundreds of thousands of raw points unless the question truly needs it
- if density matters, consider hexbin / heatmap-style aggregation instead

### Heatmaps

Use for:

- hour-of-day by day-of-week
- segment vs metric intensity
- correlation-like operational views

Exasol pattern:

- compute the matrix in SQL
- return a compact grid

### Tables / grids

Use for:

- operational drill-down
- reconciliations
- downloadable detail

Prefer `dash-ag-grid` over `dash_table` for new work.

Reason:

- Dash docs now position AG Grid as the high-performance grid path, while `dash_table` is deprecated in core docs.

Exasol pattern:

- paginate or filter server-side for large result sets
- only use full client-side row payloads for modest result sizes

## Chart anti-patterns

Avoid:

- pie / donut charts with many categories
- dual-axis charts unless the relationship is genuinely worth the cognitive cost
- raw event scatter plots when a trend chart or binned view answers the question better
- dashboards with six charts that all repeat the same dimension at different angles

## SQL design patterns for Dash

### Prefer narrow queries

Each query should have a single clear purpose:

- KPI summary
- trend series
- top-N breakdown
- drill-down table

Do not write one mega-query that tries to feed the entire dashboard unless the dashboard is genuinely tiny.

### Keep SQL files organized by intent

Recommended naming:

- `queries/kpis.sql`
- `queries/trend_daily.sql`
- `queries/top_customers.sql`
- `queries/detail_grid.sql`

### Always aggregate to visual grain

Examples:

- line chart by day: query returns one row per day
- bar chart by region: query returns one row per region
- KPI card set: query returns one row with named metrics

### Use SQL for ranking, bucketing, and windows

Push down:

- `ROW_NUMBER()`, `RANK()`, `DENSE_RANK()`
- moving averages
- percent-of-total
- period-over-period deltas
- cohort bucketing
- date truncation / time bucketing

### Minimize type friction

Exasol docs emphasize appropriate and consistent data types.

So:

- avoid joining unlike types
- prefer exact numeric types for business metrics where practical
- cast deliberately in SQL, not ad hoc in Python

### Parameterize all user-driven filters

Examples:

- date range
- region
- product family
- customer segment
- threshold values

Never concatenate values into SQL strings.

## Exasol-first server-side aggregation strategies

### Strategy 1: summary row + small supporting dimensions

Good default for dashboards:

- one KPI summary query
- one trend query
- one ranked categorical query
- one detail query

This keeps each callback understandable and patchable.

### Strategy 2: pre-bucket for time-series

For high-volume facts:

- bucket in SQL
- compute only the displayed period
- push comparisons into SQL if they depend on the same grain

### Strategy 3: top-N with long-tail suppression

When categories explode:

- rank categories in SQL
- keep top N
- optionally fold the rest into `OTHER`

### Strategy 4: drill-down only when requested

Do not load detailed rows on first render unless the dashboard is explicitly detail-first.

Pattern:

- first callback loads summary views
- second callback loads drill-down grid from selected chart point / row / filter

## Refresh and caching patterns

### Default rule

If the query is cheap and user-driven, run it synchronously in the callback.

If the query is slow or expensive:

- cache by filter arguments
- or use Dash background callbacks when the UX truly benefits

### Where a cache actually lives (read before relying on one)

A module-level dict or `functools.lru_cache` in a hosted app is **not** a durable cache, and how not-durable depends on the server's runtime mode:

- **`isolated` mode** (the hosted default): the app runs in a per-app worker process. The cache is per worker, so it is empty after every worker start — and workers are **idle-stopped after `APP_WORKER_IDLE_STOP_SECONDS` (default 600s)** and re-spawned on the next request. A dashboard nobody has opened for ten minutes starts cold. Worker restarts (crash, `app_runtime_workers_restart`, promote) clear it too.
- **`in_process` mode** (the local-dev default): the cache lives in the control-plane process and survives as long as the server does — which makes a cache look far more effective in local development than it will be in hosted mode.

Consequences for design:

- Treat an in-process cache as a *within-session* optimization for repeated identical filters, never as a way to make first paint fast.
- Make first paint fast with SQL and grain, not with a warm cache.
- Never cache anything correctness-critical or user-specific in module state: in `in_process` mode all users of the app share that process.
- Size caches explicitly (`lru_cache(maxsize=…)`). An unbounded dict in a long-lived worker is a memory leak; worker RSS is visible on `dash://runtime/workers` (isolated mode only — that resource errors in `in_process` mode, which is the local default).

See `docs/runtime-modes.md` for the full matrix.

### Good refresh patterns

- explicit `Refresh` button for operational dashboards
- `dcc.Interval` for near-real-time monitoring
- time-bounded cache for repeated views

### Bad refresh patterns

- re-running every query on every tiny UI change
- polling at aggressive intervals without operational need
- storing giant result sets in the browser

### Browser state

Use `dcc.Store` for:

- active filters
- selected entity ids
- compact derived metadata

Do not use `dcc.Store` as a place to dump large Exasol query results.

## Dash interaction patterns that work well with Exasol

### Pattern: filter panel -> summary callbacks

Best for:

- executive and operational dashboards

Structure:

- top filter controls
- KPI row
- 2-4 summary visuals
- optional drill-down grid below

### Pattern: tabs for separate query families

Use tabs when each view has a meaningfully different query shape.

Example:

- Overview
- Geography
- Customers
- Operations

Do not use tabs just to hide an overstuffed dashboard.

### Pattern: click-to-drill

Use chart click or grid row selection to load a focused detail view.

Keep the detail callback separate from the summary callback.

### Pattern: loading feedback

Wrap slow outputs with `dcc.Loading`.

For long-running work, Dash docs support background callbacks. Use them selectively, not by default.

### Pattern: partial updates

If only a small part of the UI changes, consider Dash `Patch` / partial property updates rather than re-sending whole structures.

Good use cases:

- adding dynamic filters
- appending small UI elements
- minor figure/layout adjustments

## Grid guidance

For new dashboards, prefer `dash-ag-grid` (verified available at 35.2). `dash.dash_table` still imports under Dash 4.4, but AG Grid is the maintained high-performance path.

**Declare it in `requirements.txt`.** Under `per_app` dependency isolation each app gets its own environment built from its own requirements, so an undeclared `dash_ag_grid` import fails the import smoke check at validation time rather than at runtime. The same applies to `pandas`, `plotly` extras, and anything else beyond the base runtime.

Default AG Grid choices:

- size the grid explicitly
- use pagination or constrained scrolling
- enable filtering/sorting where it helps the workflow
- keep row payloads modest

If the result can become large:

- page server-side
- or constrain the query by default date / entity filters

## Figure-building guidance

### Prefer clear over ornate

- direct labels
- consistent colors
- stable category ordering
- obvious units
- readable tick formats

### Avoid over-formatting in Python

If a label, bucket, or ordering belongs to the data model, do it in SQL.

Use Python for:

- figure assembly
- annotation placement
- light display formatting
- interaction wiring

## Debugging a dashboard that is already running

Do not debug by adding `print()`, rebuilding, and promoting. That costs several round-trips and puts a junk revision in permanent history. Use the platform's inspection surface instead.

### Server-side signals

- `app_run_healthcheck` — route, layout, dependency, asset, `data_layer`, `sql_smoke`, and `semantic_models` probes; in isolated mode also `worker_alive` and `worker_http`.
- `app_collect_diagnostics` / `app_inspect_traceback` — captured errors with parsed tracebacks and attribution.
- `app_tail_logs` — channels: `latest`, `build`, `runtime`, `health`, `worker`, `worker.events`, `session.commands`.
- `dash://apps/{name}/errors` and `/callback-failures` — the failure ledgers, including the `_error` envelopes described above.

### The user's live browser session (local mode only)

Dash keeps interaction state in the browser, so no server-side signal can tell you what the user has selected. `app_session_eval_js` runs ephemeral JavaScript in their open tab:

```js
// what is selected right now, including components no callback reads
ctx.props(['region-filter', 'date-range', 'metric-toggle'])
```

```js
// chart looks blank: is it an empty trace, a client-side exception, or scrolled out of view?
({plots: ctx.plots(), chart: ctx.dom(['revenue-chart']).nodes['revenue-chart']})
```

```js
// what happens if the region changes — sets the real prop and lets Dash react
await ctx.setProps('region-filter', {value: ['APAC']});
const fired = await ctx.waitForIdle(3000);
({fired, plots: ctx.plots()})
```

Use `app_sessions_list` to find the tab. Read `dash://meta/session-channel-guide` for the full `ctx` reference before writing the code — it is the API surface, and guessing a helper name costs a round trip. This is unavailable in hosted mode; there, fall back to the server-side signals above.

## Registered outputs (governed export)

If the user wants to download, schedule, or share a dataset or view from the dashboard, do not hand-roll a CSV button. Declare it in the manifest's `consumption.outputs` contract and let the platform own execution, limits, and audit:

- `kind: "dataset"` — sourced from a `queries/*.sql` file, exported as `csv` / `xlsx`.
- `kind: "view"` — sourced from an app-relative Dash route, rendered as `pdf` / `png` / `pptx`.
- Each output declares `classification` (`public` … `restricted`), a JSON-Schema `parameters` block, and optional `limits` (`max_rows`, `max_bytes`).

Two rules that trip up generated manifests: dataset sources must be `queries/*.sql` under a declared Exasol datasource alias, and the SQL's placeholders must match the declared `parameters` **exactly** in both directions. Then use `app_outputs_list` / `app_export_create` / `export_get`, and see `docs/consumption.md`.

## Review checklist for agent-generated Exasol dashboards

Before shipping, check:

1. Does every query run only inside callbacks or explicit refresh helpers?
2. Are all user-driven values parameterized with `{x!s}` / `{x!d}` style placeholders — and no `:name` anywhere?
3. **Does every query result go through `has_error(...)` before it is iterated or rendered?**
4. Is Exasol doing the aggregation instead of Python?
5. Are returned result sets small enough for the target component?
6. Does each visual answer a distinct question?
7. Is the default page fast enough on first load *without* a warm cache?
8. Are slow outputs wrapped with loading feedback?
9. Are secrets absent from source, manifests, logs, and visible text — and is there no `pyexasol.connect` call anywhere in the app?
10. Does `create_dash_app()` follow the required hosted pattern (`dash://meta/app-authoring-guide`)?
11. Is every third-party import declared in `requirements.txt`?
12. If the scaffold came from `overview` or `kpi-trend`, has every `FROM DUAL` demo query been replaced with real SQL?
13. Would a human be able to patch the SQL and callback flow without reverse-engineering magic?

## Default build recipe

When generating an Exasol dashboard from scratch, prefer this sequence:

1. Define the dashboard questions first:
   - what decision should the user make?
   - what filters matter?
   - what grain should each visual show?
2. Pick 3-5 visuals maximum for the first version.
3. Write one SQL file per visual concern.
4. Ensure every SQL file returns presentation-ready rows.
5. Build simple, explicit callbacks.
6. Add drill-down only after the summary view works.
7. Add caching / background execution only when query latency justifies it.

## What “amazing” means here

An amazing Exasol dashboard is not the one with the most charts. It is the one that:

- opens quickly
- answers a real business question
- uses Exasol for the heavy lifting
- gives the user clean interactions
- is easy for an agent to extend safely
- still looks deliberate and polished

Optimize for clarity, speed, and maintainability first. The polish should reinforce the data story, not distract from it.
