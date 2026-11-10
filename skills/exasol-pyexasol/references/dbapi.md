# DB-API 2.0

Use `exasol.driver.websocket.dbapi2` only when a framework needs PEP 249, such
as the SQLAlchemy Exasol dialect. Prefer direct `pyexasol` for OLAP queries,
bulk transfer, and Exasol-specific helpers. Do not use the removed
`pyexasol.db2` module.

The adapter reports `apilevel="2.0"`, `threadsafety=1`, and
`paramstyle="qmark"`. Use `?` parameters. It is intentionally not fully PEP
249 compliant.

Connect with `dbapi2.connect()`. Its user argument is `username`.
Autocommit, TLS, and certificate validation are enabled by default. The
connection is not a context manager, so close it explicitly or use
`contextlib.closing`. Cursors do support `with`.

Important limits:

- `execute()` with parameters uses the prepared-statement path.
- `executemany()` validates the number of input values.
- fetch methods return tuples; `description` provides DB-API column metadata.
- `arraysize` is read-only and equals `1`.
- `callproc()` and `nextset()` are unsupported.
- `setinputsizes()` and `setoutputsize()` do nothing.

The default fetch mapper is
`pyexasol.data_types.convert_websocket_to_python`. It returns Python values such
as `int`, `decimal.Decimal`, `datetime.date`, `datetime.datetime`, and
`ExaTimeDelta`. It validates `NLS_DATE_FORMAT` and `NLS_TIMESTAMP_FORMAT`; a
custom mapper must handle its own date and timestamp formats.
