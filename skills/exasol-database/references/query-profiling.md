# Query Profiling

## Enable and Capture Profiles

```sql
-- Enable profiling for the current session
ALTER SESSION SET PROFILE = 'ON';

-- Run the query to profile
SELECT ...;

-- Disable profiling and flush statistics
ALTER SESSION SET PROFILE = 'OFF';
FLUSH STATISTICS;
```

## Analyze Results

```sql
-- View profile for recent queries
SELECT * FROM EXA_USER_PROFILE_LAST_DAY
WHERE SESSION_ID = CURRENT_SESSION
ORDER BY STMT_ID DESC, PART_ID;
```

Key columns: `PART_NAME` (SCAN, JOIN, GROUP BY, ORDER BY), `DURATION`, `ROWS`, `OUT_ROWS`

## Per-Node Detail (Finding Data Imbalances)

```sql
SELECT * FROM "$EXA_PROFILE_DETAILS_LAST_DAY"
WHERE SESSION_ID = CURRENT_SESSION
ORDER BY STMT_ID DESC, PART_ID, IPROC;
```

Look for nodes with significantly more `ROWS` than others — indicates distribution skew.

## DELETE Marking and REORGANIZE

Exasol doesn't physically remove rows on DELETE. Rows are marked as deleted.

- Auto-reorganize triggers when >25% of rows are marked deleted
- One large DELETE is faster than many small DELETEs

```sql
-- Check delete percentage
SELECT TABLE_NAME, DELETE_PERCENTAGE
FROM EXA_ALL_TABLES
WHERE TABLE_SCHEMA = 'MY_SCHEMA' AND DELETE_PERCENTAGE > 10;

-- Manual reorganize
REORGANIZE TABLE my_schema.my_table;
COMMIT;

-- Force reorganize (even below threshold)
REORGANIZE TABLE my_schema.my_table ENFORCE;
```

## ORDER BY FALSE — Force Materialization

The top Exasol query optimization trick. Forces a subquery to materialize, preventing the optimizer from choosing bad join orders:

```sql
SELECT *
FROM (
    SELECT customer_id, SUM(amount) AS total
    FROM orders
    WHERE order_date > ADD_MONTHS(CURRENT_DATE, -12)
    GROUP BY customer_id
    ORDER BY FALSE
) sub
JOIN customers c ON c.id = sub.customer_id;
```

Use when the optimizer chooses a bad join order due to inaccurate selectivity estimates.

## Refresh Column Statistics

```sql
-- After major data changes
ANALYZE TABLE my_table ESTIMATE STATISTICS;
ANALYZE SCHEMA my_schema ESTIMATE STATISTICS;
```
