# Skill: PyExasol for Claude Code / Codex

Use this skill when you need to write Python code that talks directly to Exasol through `pyexasol`, especially when you care about performance, bulk data transfer, Exasol-specific SQL formatting, metadata inspection, UDF log capture, or multi-process parallel I/O.

Verified against pyexasol 2.3 (July 25, 2026).

## Scope: do not apply the connection patterns inside a hosted dashboard

This skill covers **standalone** Python that owns its own Exasol connection: scripts, notebooks, ETL, authoring-time exploration.

**Inside a `dash-server` hosted app, you never open a connection.** The server owns the profile and the secret; the app names a profile and calls the runtime helpers. Every connection pattern below — including the canonical one — would be *rejected by validation* in a hosted app, which fails on:

- any `pyexasol.connect(...)` call in app source,
- `password=` / `access_token=` / `refresh_token=` / `saas_pat=` assignments,
- reads of `EXA_`/`EXASOL_`-prefixed credential env vars (`_DSN`, `_USER`, `_PASS`, `_PASSWORD`, `_PAT`, `_ACCESS_TOKEN`, `_REFRESH_TOKEN`),
- credential keys (`dsn`, `user`, `password`, `secret`, …) embedded in the manifest's `data_sources.primary` instead of a `profile` reference.

That is a deliberate boundary, not an obstacle to work around: it is what keeps credentials out of app source, manifests, Git, and prompts.

For hosted dashboards read [exasol_dash_skill.md](exasol_dash_skill.md) and use:

```python
from dash_server_runtime import has_error, query_one, query_rows, query_scalar
```

What is still worth reading here for hosted work: the **placeholder formatter** (the same syntax `queries/*.sql` uses), Exasol SQL and type guidance, and `.meta` helpers for authoring-time schema exploration.

## What PyExasol is best at

- Direct Exasol access from Python with low overhead over the Exasol WebSocket protocol.
- Fast bulk export / import over HTTP transport.
- Clean bridges to `pandas`, `polars`, and `pyarrow/parquet`.
- Exasol-specific SQL formatting and safe identifier / literal handling.
- Lock-free metadata access through `.meta`.
- Multi-process parallel export / import for a single SQL statement.

## Agent decision rules

1. **Use `pyexasol` when talking directly to Exasol.** Prefer it over generic DB layers when the task needs Exasol features, performance, HTTP transport, metadata helpers, or UDF debugging.
2. **Use context managers** for both connections and statements whenever practical.
3. **For normal SQL:** use `C.execute(...)` and consume the returned `ExaStatement`.
4. **For large data movement:** prefer `export_to_*` / `import_from_*` over row-by-row SQL.
5. **For small inserts only:** `C.ext.insert_multi(...)` is acceptable, but only for relatively small datasets.
6. **For metadata:** prefer `C.meta.*`; only use older `.ext.get_*` metadata helpers for legacy code.
7. **For parallelism:** use **multiple processes**, never shared connections across threads.
8. **For remote or bandwidth-constrained links:** enable `compression=True`.
9. **For production security:** keep TLS verification enabled; do not use `nocertcheck` except local throwaway testing.
10. **For agent-generated SQL:** use PyExasol’s placeholder formatter rather than string concatenation.

## Installation

```bash
pip install pyexasol
```

Optional extras:

```bash
pip install pyexasol[pandas]
pip install pyexasol[polars]
pip install pyexasol[pyarrow]
pip install pyexasol[orjson]
pip install pyexasol[rapidjson]
pip install pyexasol[ujson]
```

## Canonical connection pattern

Standalone code only — see the scope banner. Read credentials from the environment or a secret store rather than literals, even in throwaway scripts.

```python
import os

import pyexasol

with pyexasol.connect(
    dsn=os.environ["EXA_DSN"],
    user=os.environ["EXA_USER"],
    password=os.environ["EXA_PASSWORD"],
    schema="MY_SCHEMA",
    compression=True,
) as C:
    with C.execute("SELECT * FROM MY_TABLE") as stmt:
        rows = stmt.fetchall()
```

## Connection parameters you should know

Commonly useful:

- `dsn`: Exasol DSN / connection string.
- `user`, `password`: standard auth.
- `access_token` or `refresh_token`: SaaS / OpenID auth.
- `schema`: schema to open after connect.
- `autocommit`: defaults to `True`.
- `compression`: compresses both WebSocket and HTTP transport.
- `encryption`: TLS on/off, default `True`.
- `query_timeout`: server-side query timeout in seconds.
- `fetch_dict`: fetch rows as dicts.
- `fetch_mapper`: custom value conversion during fetch.
- `lower_ident`: lowercase identifiers returned by relevant helpers.
- `quote_ident`: auto-quote identifiers passed into relevant helper functions.
- `json_lib`: one of `json`, `orjson`, `rapidjson`, `ujson`.
- `debug` / `debug_logdir`: low-level protocol debugging.
- `websocket_sslopt`: TLS verification and CA settings.
- `http_proxy`: proxy support.
- `client_name`, `client_version`, `client_os_username`: session labeling.
- `protocol_version`: WebSocket protocol version, default is `pyexasol.PROTOCOL_V3`.

### SaaS example

```python
C = pyexasol.connect(
    dsn="abc.cloud.exasol.com:8563",
    user="my_user",
    refresh_token="...",
)
```

### Config-file based connection

Use `connect_local_config()` when credentials and defaults live in `~/.pyexasol.ini`.

```python
import pyexasol

C = pyexasol.connect_local_config("my_connection")
```

Extra kwargs override config-file values.

## DSN notes

PyExasol supports Exasol-style DSNs, including:

- single host + port
- host ranges
- multiple hosts
- fingerprints in the DSN
- redundancy / failover host lists

Example patterns seen in the official examples:

```python
"127.0.0.10..19:8564"
"127.0.0.10..19:8564,127.0.0.20,localhost:8565"
"myhost/FINGERPRINT:8563"
```

When connecting to a cluster, provide the full DSN rather than a single node.

## Security and TLS

Current secure defaults matter:

- `encryption=True` is the default.
- Certificate verification is enabled by default in current releases.
- SaaS requires TLS.

For private CA or self-signed setups, pass TLS options explicitly:

```python
import ssl
import pyexasol

C = pyexasol.connect(
    dsn="myexasol:8563",
    user="user",
    password="password",
    websocket_sslopt={
        "cert_reqs": ssl.CERT_REQUIRED,
        "ca_certs": "/path/to/rootCA.crt",
    },
)
```

Fingerprint-based verification is supported in the DSN:

```python
C = pyexasol.connect(
    dsn="myexasol/135a1d2dce102de866f58267521f4232153545a075dc85f8f7596f57e588a181:8563",
    user="user",
    password="password",
)
```

Never generate production code that disables certificate verification unless the user explicitly wants a local test-only setup.

## Executing queries

### Standard execution

```python
stmt = C.execute(
    "SELECT * FROM {table!i} WHERE status = {status}",
    {"table": "USERS", "status": "ACTIVE"},
)
```

`C.execute()` returns an `ExaStatement`.

Useful statement methods:

- `fetchone()`
- `fetchmany(n)`
- `fetchall()`
- `fetchval()`
- `fetchcol()`
- iteration (`for row in stmt:`)
- `columns()`
- `column_names()`
- `rowcount()`
- `close()`

### Preferred fetch styles

Tuple rows:

```python
with pyexasol.connect(..., fetch_dict=False) as C:
    rows = C.execute("SELECT * FROM users").fetchall()
```

Dict rows:

```python
with pyexasol.connect(..., fetch_dict=True) as C:
    rows = C.execute("SELECT * FROM users").fetchall()
```

Custom mapper:

```python
def mapper(value, data_type, data_type_name):
    return value

with pyexasol.connect(..., fetch_mapper=mapper) as C:
    rows = C.execute("SELECT * FROM users").fetchall()
```

For result sets, iterator syntax is often the cleanest:

```python
stmt = C.execute("SELECT * FROM users")
for row in stmt:
    print(row)
```

## SQL formatting: use PyExasol placeholders

PyExasol has an Exasol-aware formatter. Prefer it to manual string interpolation.

**These are client-side format-style placeholders, not driver bind parameters.** `:name` style is not supported and fails with `Feature not supported: host parameter specification`. This is the same syntax `dash-server` uses in `queries/*.sql`.

Also note: an empty Python string passed to `{x!s}` renders as SQL `NULL`, so `col = {x!s}` with `x=""` matches nothing rather than matching empty-string rows. Branch on empty/None in Python.

### Placeholder types

- `{x}` or `{x!s}`: quoted value
- `{x!d}`: validated decimal, unquoted
- `{x!f}`: validated float, unquoted
- `{x!i}`: safe identifier, unquoted
- `{x!q}`: quoted identifier
- `{x!r}`: raw SQL fragment, no escaping

Examples:

```python
C.execute(
    "SELECT * FROM {table!i} WHERE id = {id!d}",
    {"table": "USERS", "id": 42},
)

C.execute(
    "SELECT * FROM {schema!q}.{table!q}",
    {"schema": "my_schema", "table": "my_table"},
)

C.execute(
    "SELECT * FROM users ORDER BY user_id {direction!r}",
    {"direction": "DESC"},
)
```

Rules for agents:

- Use `!i` for normal identifiers when you want PyExasol-safe identifier handling.
- Use `!q` when exact quoted identifier semantics matter.
- Use `!d` / `!f` for numeric clauses like `LIMIT`, arithmetic, offsets.
- Use `!r` only for tightly controlled SQL fragments.
- Do not concatenate user values into SQL strings.

## Transactions and session settings

Autocommit defaults to `True`. Keep it that way unless you explicitly need a transaction.

```python
C = pyexasol.connect(..., autocommit=False)
C.execute("INSERT INTO t VALUES (1)")
C.execute("INSERT INTO t VALUES (2)")
C.commit()
```

Or rollback:

```python
C.rollback()
```

Helpers:

```python
C.set_autocommit(False)
C.set_query_timeout(60)
C.open_schema("MY_SCHEMA")
current = C.current_schema()
```

## Bulk export / import: the main performance path

For anything beyond small datasets, use HTTP transport helpers.

### Export to pandas

```python
df = C.export_to_pandas("SELECT * FROM MY_TABLE")
```

### Import from pandas

```python
C.import_from_pandas(df, "MY_TARGET_TABLE")
print(C.last_statement().rowcount())
```

### Export to polars

```python
df = C.export_to_polars("SELECT * FROM MY_TABLE")
```

### Import from polars

```python
C.import_from_polars(df, "MY_TARGET_TABLE")
```

### Export to parquet

```python
from pathlib import Path

out_dir = Path("./parquet_export")
C.export_to_parquet(out_dir, "SELECT * FROM MY_TABLE")
```

### Import from parquet

```python
from pathlib import Path

C.import_from_parquet(Path("./parquet_export"), "MY_TARGET_TABLE")
```

`import_from_parquet()` accepts:

- `list[Path]`
- a single `Path`
- a glob string like `"/tmp/data/*.parquet"`

### Export to file

```python
with open("users.csv", "wb") as f:
    C.export_to_file(f, "users")
```

### Import from file

```python
with open("users.csv", "rb") as f:
    C.import_from_file(f, "users_copy")
```

### Export to list

```python
rows = C.export_to_list("users")
```

### Import from iterable

```python
rows = [
    (1, "Alice"),
    (2, "Bob"),
]
C.import_from_iterable(rows, "users_copy")
```

### Custom callback path

Use callback-based APIs when you need custom pipes or transformations:

```python
def my_export_callback(pipe, dst, **kwargs):
    return pipe.read()

payload = C.export_to_callback(my_export_callback, None, "SELECT * FROM users")
```

```python
def my_import_callback(pipe, src, **kwargs):
    pipe.write(src)

C.import_from_callback(my_import_callback, b"1,\"Alice\"\n", "users_copy")
```

## Export / import parameters

`export_params` and `import_params` map to Exasol `EXPORT` / `IMPORT` options.

Common ones:

- `columns`
- `comment`
- `encoding`
- `format` (`gz`, `bzip2`, `zip`)
- `null`
- `skip`
- `with_column_names`
- `csv_cols`
- `column_separator`
- `column_delimiter`
- `row_separator`

Examples:

```python
C.export_to_file(
    f,
    "users",
    export_params={
        "with_column_names": True,
        "format": "gz",
        "comment": "Export users for downstream ETL",
    },
)
```

```python
C.import_from_file(
    f,
    "users_copy",
    import_params={
        "skip": 1,
        "encoding": "UTF8",
    },
)
```

### Important built-in behavior

`export_to_pandas()`, `export_to_parquet()`, and `export_to_polars()` force `with_column_names=True`.

## Which import / export API to choose

Use this decision table:

- Already have a `pandas.DataFrame` -> `import_from_pandas()` / `export_to_pandas()`
- Already have a `polars.DataFrame` -> `import_from_polars()` / `export_to_polars()`
- Need filesystem-friendly bulk format -> parquet helpers
- Need generic CSV / byte stream -> file helpers
- Need custom processing pipeline -> callback helpers
- Need a quick in-memory row source -> `import_from_iterable()`

## Small inserts: `insert_multi`

Use only for relatively small datasets.

```python
rows = [
    (1, "Alice"),
    (2, "Bob"),
]
C.ext.insert_multi("USERS", rows, columns=["USER_ID", "USER_NAME"])
```

Guidance:

- Good for small batches, especially around 10k rows or less.
- Prefer HTTP transport imports for larger loads.
- If omitting table columns, Exasol uses `NULL` or `DEFAULT`.

## Metadata: prefer `.meta`

`.meta` is the modern metadata API. Use it instead of deprecated `.ext.get_*` metadata helpers.

### Column discovery for a query without executing it

```python
cols = C.meta.sql_columns(
    "SELECT a.*, a.user_id + 1 AS next_user_id FROM users a"
)
```

### Existence checks

```python
C.meta.schema_exists("MY_SCHEMA")
C.meta.table_exists("USERS")
C.meta.table_exists(("MY_SCHEMA", "USERS"))
C.meta.view_exists("USERS_VIEW")
```

### Listings

```python
C.meta.list_schemas(schema_name_pattern="MY%")
C.meta.list_tables(table_schema_pattern="MY%", table_name_pattern="USER%")
C.meta.list_views(view_schema_pattern="MY%")
C.meta.list_columns(column_schema_pattern="MY%", column_name_pattern="%ID%")
C.meta.list_objects(object_name_pattern="USER%", object_type_pattern="TABLE")
C.meta.list_object_sizes(object_name_pattern="USER%", object_type_pattern="TABLE")
C.meta.list_indices(index_schema_pattern="MY%")
C.meta.list_sql_keywords()
```

Notes:

- `.meta` uses lock-free metadata requests and snapshot execution where appropriate.
- Keyword lists should never be hard-coded.
- Pattern matching is case-sensitive.

## Legacy `.ext` helpers

Still useful in existing codebases:

- `insert_multi()`
- `export_to_pandas_with_dtype()`
- deprecated metadata helpers like `get_columns()`, `get_sys_tables()`, etc.

For new code, avoid the deprecated metadata calls.

## Parallel HTTP transport

This is one of PyExasol’s most important advanced capabilities.

### Core rule

- One PyExasol connection == one Exasol session.
- One session can run only one SQL query at a time.
- `ExaConnection.threadsafety == 1` (DBAPI level 1: the module is thread-safe, connections are not). Note there is no `pyexasol.threadsafety` module attribute — it lives on the connection class. (The old `pyexasol.db2` compatibility module was removed in pyexasol 3.0.)
- Do **not** share a connection across threads.
- For real parallelism, use **multiple processes**.

### Two valid parallel strategies

1. Multiple independent processes, each with its own connection.
2. One parent SQL statement + multiple child processes using `http_transport()` for parallel export/import.

### Official parallel export shape

Parent process:

- open main connection
- call `get_nodes(pool_size)`
- start child processes
- gather each child’s `.exa_address`
- call `export_parallel(exa_address_list, ...)`

Child process:

- call `pyexasol.http_transport(ipaddr, port)`
- send `http.exa_address` back to parent
- call `http.export_to_callback(...)`

### Official parallel import shape

Same structure, but child processes call `http.import_from_callback(...)` and the parent calls `import_parallel(...)`.

### Minimal pattern

```python
import multiprocessing
import pyexasol
import pyexasol.callback as cb

class ExportProc(multiprocessing.Process):
    def __init__(self, node):
        self.node = node
        self.read_pipe, self.write_pipe = multiprocessing.Pipe(False)
        super().__init__()

    def start(self):
        super().start()
        self.write_pipe.close()

    @property
    def exa_address(self):
        return self.read_pipe.recv()

    def run(self):
        self.read_pipe.close()
        http = pyexasol.http_transport(self.node["ipaddr"], self.node["port"])
        self.write_pipe.send(http.exa_address)
        self.write_pipe.close()
        df = http.export_to_callback(cb.export_to_pandas, None)
        print(len(df))
```

### `get_nodes()` behavior

Returns dictionaries like:

```python
{"ipaddr": "...", "port": 8563, "idx": 0}
```

If requested `pool_size` exceeds the number of active nodes, the node list wraps and repeats nodes with different `idx` values.

### Parallelism limits

Do not blindly crank up process count. Practical parallel query counts are much lower than theoretical server maxima. Usually keep concurrency moderate.

## UDF output debugging

Use `execute_udf_output()` when you need logs from UDF script execution.

```python
stmt, log_files = C.execute_udf_output(
    "SELECT my_python_udf(col1) FROM my_table"
)
```

Use this only when Exasol can open a connection back to the machine running the script. This often works in the same data center, but often fails from a local laptop behind NAT or restrictive networking.

Relevant connection options:

- `udf_output_bind_address`
- `udf_output_connect_address`
- `udf_output_dir`

## Debugging and operational helpers

Useful connection helpers:

```python
C.last_statement()
C.session_id()
C.protocol_version()
C.exasol_db_version
C.get_attr()
C.set_attr({...})
C.get_nodes()
C.abort_query()
```

Use `debug=True` or `debug_logdir="..."` when diagnosing connection/protocol issues.

## Performance rules for agents

1. Default to `compression=True` for large transfers or remote clients.
2. Use `export_to_*` / `import_from_*` for bulk data.
3. Avoid row-by-row insert loops.
4. Prefer iterator consumption over repeated `fetchone()` in general-purpose result scanning.
5. Prefer `orjson`, `rapidjson`, or `ujson` when JSON parsing is a measurable bottleneck.
6. Use multi-process parallel transport only when the dataset and environment justify the extra complexity.
7. Use `.meta` instead of querying system tables manually when a helper already exists.

## Common pitfalls

- Sharing a connection across threads.
- Using `insert_multi()` for large loads.
- Building SQL with raw string concatenation.
- Forgetting that `export_to_list()` and DataFrame exports can exhaust memory.
- Using `execute_udf_output()` from a network location Exasol cannot reach.
- Writing parquet export into a non-empty directory without handling the directory behavior.
- Disabling certificate checks outside local tests.
- Passing identifiers as raw strings instead of `!i` or `!q` placeholders.

## Recommended agent coding style

When generating code with PyExasol, prefer this shape:

```python
import pyexasol


def main() -> None:
    with pyexasol.connect(
        dsn="host:8563",
        user="user",
        password="password",
        schema="MY_SCHEMA",
        compression=True,
    ) as C:
        df = C.export_to_pandas(
            "SELECT * FROM {table!i} WHERE created_at >= {cutoff}",
            {"table": "EVENTS", "cutoff": "2026-01-01"},
        )
        print(df.head())


if __name__ == "__main__":
    main()
```

## What to prefer in new code

- `C.meta.*` over deprecated metadata helpers in `C.ext.*`
- `export_to_*` / `import_from_*` over row-oriented SQL for bulk movement
- placeholder formatting over string concatenation
- context managers over manual close calls
- multiprocessing over threading for parallel work

## What to avoid unless specifically needed

- `!r` raw placeholders
- disabled TLS verification
- shared connections across threads
- manual CSV piping when a built-in DataFrame / parquet helper already fits
- overusing parallel transport for small jobs

## References

Official:

- PyExasol repo: https://github.com/exasol/pyexasol
- PyExasol User Guide: https://exasol.github.io/pyexasol/master/user_guide/index.html
- PyExasol API Reference: https://exasol.github.io/pyexasol/master/api.html
- Exasol Developer Guide: https://exasol.github.io/developer-documentation/main/index.html
- Exasol AI Lab: https://github.com/exasol/ai-lab

