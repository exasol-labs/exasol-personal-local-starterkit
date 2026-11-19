# Bulk Transfer

Use HTTP transport helpers instead of row-by-row SQL for large data:

- files or byte streams: `export_to_file()` / `import_from_file()`
- Python rows: `export_to_list()` / `import_from_iterable()`
- pandas: `export_to_pandas()` / `import_from_pandas()`
- Polars: `export_to_polars()` / `import_from_polars()`
- Parquet: `export_to_parquet()` / `import_from_parquet()`
- custom streams: `export_to_callback()` / `import_from_callback()`

For exports, a tuple such as `("SCHEMA", "TABLE")` is a qualified table name.
A string containing an ordinary space is treated as a query; otherwise it is
treated as an unqualified table name. Write queries with ordinary spaces rather
than only tabs or newlines, and pass placeholders through `query_params`.
For imports, a tuple is a qualified destination table and a string is an
unqualified destination table.

`export_to_file()` and `import_from_file()` accept a path or a file-like object;
caller-provided file objects must be opened in binary mode. Parquet helpers use
filesystem paths, while list, DataFrame, Polars, and iterable helpers exchange
the corresponding Python objects.

Current `export_params` are `columns`, `comment`, `encoding`, `format`, `null`,
`csv_cols`, `column_separator`, `column_delimiter`, `row_separator`, `delimit`,
and `with_column_names`. Current `import_params` replace the last two with
`skip` and `trim`. The builders reject unknown or unsafe values.

Use `format="csv"`, `"gz"`, `"bz2"`, or `"zip"` (not `"bzip2"`).
Pandas, Polars, and Parquet exports force `with_column_names=True`.

`callback_params` go to the external library or custom callback. An export
callback reads `(pipe, dst, **callback_params)`; an import callback writes
`(pipe, src, **callback_params)`.

Parquet export expects an empty destination directory by default. Do not
silently overwrite files. DataFrame and list exports hold the result in memory.

Use `connection.ext.insert_multi()` only for small inserts of about 10,000 rows
or fewer. It materializes the input and rejects an empty input. Use an
`import_from_*` method for larger loads.

After transfer, `last_statement()` provides the SQL row count and timing.
