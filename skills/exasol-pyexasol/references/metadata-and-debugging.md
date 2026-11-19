# Metadata and Debugging

Prefer `connection.meta` for new metadata code:

- `sql_columns()` inspects a query without running it.
- `schema_exists()`, `table_exists()`, and `view_exists()` check objects.
- `list_schemas()`, `list_tables()`, `list_views()`, `list_columns()`,
  `list_objects()`, `list_object_sizes()`, `list_indices()`, and
  `list_sql_keywords()` return metadata with case-sensitive `LIKE` patterns.

For other lock-free metadata reads, use a separate connection with
`snapshot_transactions=True`; do not use that connection for normal work.

Deprecated `connection.ext` metadata methods include `get_columns*()`,
`get_sys_*()`, and `get_reserved_words()`. Other `ext` helpers still include
`insert_multi()`, `get_disk_space_usage()`, `export_to_pandas_with_dtype()`,
and `explain_last()`.

`execute_udf_output()` returns a statement and log-file paths. Exasol nodes
must be able to connect back to the Python host. The caller must protect and
delete the logs. Restrict inbound access to Exasol nodes; do not expose the
callback service publicly. Use `udf_output_bind_address`,
`udf_output_connect_address`, and `udf_output_dir` only when needed.

Use `last_statement()`, `session_id()`, `protocol_version()`,
`exasol_db_version`, `get_attr()`, `set_attr()`, and `get_nodes()` for session
diagnostics. `debug=True` or `debug_logdir` may expose SQL and data, so keep
debug output private and temporary. Avoid the low-level `req()` method unless
the task is explicitly about the WebSocket protocol.
