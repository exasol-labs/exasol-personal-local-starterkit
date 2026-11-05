# Parallel HTTP Transport

Use one of these designs:

1. Start independent processes and open a new PyExasol connection inside each
   process.
2. Run one parent `IMPORT` or `EXPORT` statement and use child processes for
   its HTTP streams.

Never reuse a parent connection in children or share one connection across
threads. Separate connections in threads are not the recommended performance
design because one Python process remains limited by the GIL.

For parallel HTTP transfer:

1. The parent opens the main connection and calls `get_nodes(pool_size)`.
2. Each child calls `pyexasol.http_transport(ipaddr, port, ...)` and sends
   `transport.exa_address` to the parent.
3. The parent calls `export_parallel()` or `import_parallel()` once with all
   addresses while the children call the matching callback methods.
4. On success, the parent joins every child and checks its exit status. On
   failure, terminate live children before joining them, then re-raise the
   error.

Use `.exa_address`; `get_proxy()` is deprecated, and `.address` does not exist.
Child `encryption` must match the main connection. When `export_params` or
`import_params` contains an explicit `format`, set child `compression=False`;
otherwise match the main connection's compression setting.

Each worker needs outbound access to the Exasol node IP and port passed to
`http_transport()` from `get_nodes()`. The transport creates a tunnel to that
node; it does not open an inbound worker listener. PyExasol provides transport
primitives, not worker-pool cleanup.

`get_nodes()` repeats nodes when `pool_size` exceeds the active node count.
Measure the workload; more processes do not guarantee better performance.
