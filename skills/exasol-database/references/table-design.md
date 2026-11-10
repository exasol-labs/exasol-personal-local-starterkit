# Table Design: DISTRIBUTE BY & PARTITION BY

## DISTRIBUTE BY

Controls how rows are spread across cluster nodes. Correct distribution enables **local joins** (no data shuffling between nodes).

### Decision Guide

1. **Pick the column used in your most frequent/expensive JOINs**
2. **Single column is usually optimal** — more joins and aggregations can benefit
3. **High cardinality required** — many distinct values prevent data skew
4. **Both sides of a JOIN** should be distributed by their respective join columns

### Envelope Matching Rule

Distributing by `(x, y)` enables local joins on `(x, y)`, `(x, y, z)`, etc. — but **NOT** on just `x` or just `y` alone. The distribution key must be a *subset* of the join/GROUP BY columns.

### Syntax

```sql
-- At creation
CREATE TABLE orders (
    order_id    INT,
    customer_id INT,
    order_date  DATE,
    amount      DECIMAL(10,2),
    DISTRIBUTE BY customer_id
);

-- Alter existing table
ALTER TABLE orders DISTRIBUTE BY customer_id;
```

### Preview Distribution

```sql
-- Check current row distribution across nodes
SELECT iproc() AS node, COUNT(*) FROM my_table GROUP BY 1 ORDER BY 1;

-- Preview what distribution would look like with candidate columns
SELECT value2proc(customer_id) AS future_node, COUNT(*) FROM orders GROUP BY 1 ORDER BY 1;
```

### Monitoring

```sql
-- Find which columns are distribution keys
SELECT COLUMN_NAME, COLUMN_IS_DISTRIBUTION_KEY
FROM EXA_ALL_COLUMNS
WHERE COLUMN_TABLE = 'ORDERS' AND COLUMN_SCHEMA = 'MY_SCHEMA';
```

### Anti-Patterns

- **Low cardinality columns** (e.g., `status`, `country_code`) — causes severe data skew
- **WHERE-only columns** — distribution helps JOINs and GROUP BY, not single-table filters
- **Distributing by a column not used in JOINs** — gains nothing, may worsen other joins

---

## PARTITION BY

Controls physical data layout within each node. Enables **range pruning** — the database skips partitions that don't match the WHERE clause.

### Decision Guide

- Partition by columns used in **WHERE range filters** — dates are ideal
- Best for time-series queries: `WHERE order_date BETWEEN '2024-01-01' AND '2024-03-31'`
- Don't over-partition — too many small partitions reduce performance

### Supported Types

`DECIMAL`, `DATE`, `TIMESTAMP`, `DOUBLE`, `BOOLEAN`, `INTERVAL YEAR TO MONTH`, `INTERVAL DAY TO SECOND`, `HASHTYPE`

### Syntax

```sql
-- Combined with DISTRIBUTE BY
CREATE TABLE orders (
    order_id    INT,
    customer_id INT,
    order_date  DATE,
    amount      DECIMAL(10,2),
    DISTRIBUTE BY customer_id,
    PARTITION BY order_date
);

-- Alter existing table
ALTER TABLE orders PARTITION BY order_date;
```
