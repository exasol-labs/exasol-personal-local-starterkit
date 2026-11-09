# Analytics: Window Functions & QUALIFY

## Window Functions / Analytic Functions

Window functions compute values across a set of rows related to the current row without collapsing them into groups.

### Syntax

```sql
<function>(<args>) OVER (
    [PARTITION BY <expr>, ...]
    [ORDER BY <expr> [ASC|DESC], ...]
    [<frame_clause>]
)
```

### Frame Clauses

```sql
-- Default when ORDER BY is present: RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING
ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
RANGE BETWEEN INTERVAL '7' DAY PRECEDING AND CURRENT ROW
```

- **ROWS**: Physical row count
- **RANGE**: Logical value range (requires ORDER BY on a single numeric/date column)

### Ranking Functions

```sql
SELECT department, employee, salary,
    ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) AS rn,
    RANK()       OVER (PARTITION BY department ORDER BY salary DESC) AS rnk,
    DENSE_RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS dense_rnk,
    NTILE(4)     OVER (ORDER BY salary DESC) AS quartile
FROM employees;
```

### Navigation Functions

```sql
SELECT order_date, revenue,
    LAG(revenue, 1)  OVER (ORDER BY order_date) AS prev_day,
    LEAD(revenue, 1) OVER (ORDER BY order_date) AS next_day,
    FIRST_VALUE(employee) OVER (PARTITION BY dept ORDER BY salary DESC) AS top_earner,
    LAST_VALUE(employee) OVER (
        PARTITION BY dept ORDER BY salary DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS lowest_earner
FROM daily_sales;
```

### Aggregates as Window Functions

All standard aggregates work with `OVER()`:

```sql
SELECT department, employee, salary,
    COUNT(*) OVER (PARTITION BY department) AS dept_size,
    SUM(salary) OVER (PARTITION BY department) AS dept_total,
    AVG(salary) OVER (PARTITION BY department) AS dept_avg,
    SUM(amount) OVER (ORDER BY order_date) AS running_total,
    AVG(revenue) OVER (
        ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS moving_avg_7d
FROM employees;
```

### Distribution Functions

```sql
SELECT employee, salary,
    PERCENT_RANK() OVER (ORDER BY salary) AS pct_rank,
    CUME_DIST()    OVER (ORDER BY salary) AS cum_dist
FROM employees;
```

### LISTAGG (String Aggregation)

```sql
SELECT department,
    LISTAGG(employee, ', ') WITHIN GROUP (ORDER BY employee) AS members
FROM employees
GROUP BY department;
```

### Grouping Sets, Rollup, Cube

```sql
-- GROUPING SETS: specific aggregation levels
SELECT region, product, SUM(sales) FROM sales
GROUP BY GROUPING SETS ((region, product), (region), ());

-- ROLLUP: hierarchical subtotals
SELECT region, product, SUM(sales) FROM sales
GROUP BY ROLLUP (region, product);

-- CUBE: all dimension combinations
SELECT region, product, SUM(sales) FROM sales
GROUP BY CUBE (region, product);
```

---

## QUALIFY Clause

`QUALIFY` filters rows based on window function results — like `HAVING` for window functions. Avoids wrapping in a subquery.

### Deduplication (Keep Latest per Group)

```sql
SELECT *
FROM orders
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC) = 1;
```

### Top-N per Group

```sql
SELECT department, employee, salary
FROM employees
QUALIFY RANK() OVER (PARTITION BY department ORDER BY salary DESC) <= 3;
```

### Filter on Running Total

```sql
SELECT order_date, amount,
    SUM(amount) OVER (ORDER BY order_date) AS running_total
FROM orders
QUALIFY SUM(amount) OVER (ORDER BY order_date) <= 10000;
```

**Note:** `QUALIFY` is a reserved keyword in Exasol.
