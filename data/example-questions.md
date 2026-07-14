# Example questions for your AI assistant

Copy any of these into your AI client (Claude, Cursor, Codex) once the kit
is installed and the MCP server is connected. They all run against the bundled
**TPC-H** sample data in the `TPCH` schema, using nothing but the read-only
SELECT access the MCP server is given — so they are safe to ask verbatim.

Every question below has been validated end-to-end against the sample data as the
dedicated `mcp_readonly` user. The **reference SQL** is included so you can practice
the kit's workflow: **ASK → INSPECT the SQL → RUN → VALIDATE → RERUN**. Ask your
assistant to *"show me the SQL before you run it"* and compare.

> **Revenue** (kit convention): `l_extendedprice * (1 - l_discount)` — net of line
> discount, excludes tax, does not subtract returns. See
> [data-dictionary.md](data-dictionary.md) for every table and column.

---

## Revenue & sales

**1. Who are the top 10 customers by total revenue?**

```sql
SELECT c.C_CUSTKEY, c.C_NAME, SUM(l.L_EXTENDEDPRICE * (1 - l.L_DISCOUNT)) AS REVENUE
FROM TPCH.CUSTOMER c
JOIN TPCH.ORDERS o   ON o.O_CUSTKEY = c.C_CUSTKEY
JOIN TPCH.LINEITEM l ON l.L_ORDERKEY = o.O_ORDERKEY
GROUP BY c.C_CUSTKEY, c.C_NAME
ORDER BY REVENUE DESC
LIMIT 10;
```

**2. What is the total revenue and order count per market segment (`C_MKTSEGMENT`)?**

```sql
SELECT c.C_MKTSEGMENT,
       COUNT(DISTINCT o.O_ORDERKEY) AS ORDER_COUNT,
       SUM(l.L_EXTENDEDPRICE * (1 - l.L_DISCOUNT)) AS REVENUE
FROM TPCH.CUSTOMER c
JOIN TPCH.ORDERS o   ON o.O_CUSTKEY = c.C_CUSTKEY
JOIN TPCH.LINEITEM l ON l.L_ORDERKEY = o.O_ORDERKEY
GROUP BY c.C_MKTSEGMENT
ORDER BY REVENUE DESC;
```

**3. Which parts generate the most revenue, and what's their share of the total?**

```sql
SELECT p.P_PARTKEY, p.P_NAME,
       SUM(l.L_EXTENDEDPRICE * (1 - l.L_DISCOUNT)) AS REVENUE,
       RATIO_TO_REPORT(SUM(l.L_EXTENDEDPRICE * (1 - l.L_DISCOUNT))) OVER () AS SHARE
FROM TPCH.PART p
JOIN TPCH.LINEITEM l ON l.L_PARTKEY = p.P_PARTKEY
GROUP BY p.P_PARTKEY, p.P_NAME
ORDER BY REVENUE DESC
LIMIT 10;
```

**4. What is the monthly / yearly revenue trend based on `O_ORDERDATE`?**

```sql
SELECT EXTRACT(YEAR FROM o.O_ORDERDATE)  AS YR,
       EXTRACT(MONTH FROM o.O_ORDERDATE) AS MO,
       SUM(l.L_EXTENDEDPRICE * (1 - l.L_DISCOUNT)) AS REVENUE
FROM TPCH.ORDERS o
JOIN TPCH.LINEITEM l ON l.L_ORDERKEY = o.O_ORDERKEY
GROUP BY 1, 2
ORDER BY 1, 2;
```

---

## Customer & geography

**5. How many customers are in each nation and region?**

```sql
SELECT r.R_NAME AS REGION, n.N_NAME AS NATION, COUNT(*) AS CUSTOMERS
FROM TPCH.CUSTOMER c
JOIN TPCH.NATION n ON n.N_NATIONKEY = c.C_NATIONKEY
JOIN TPCH.REGION r ON r.R_REGIONKEY = n.N_REGIONKEY
GROUP BY r.R_NAME, n.N_NAME
ORDER BY r.R_NAME, n.N_NAME;
```

**6. Which region has the highest average customer account balance (`C_ACCTBAL`)?**

```sql
SELECT r.R_NAME, AVG(c.C_ACCTBAL) AS AVG_BAL
FROM TPCH.CUSTOMER c
JOIN TPCH.NATION n ON n.N_NATIONKEY = c.C_NATIONKEY
JOIN TPCH.REGION r ON r.R_REGIONKEY = n.N_REGIONKEY
GROUP BY r.R_NAME
ORDER BY AVG_BAL DESC;
```

**7. Which customers have a positive account balance but have never placed an order?**

```sql
SELECT c.C_CUSTKEY, c.C_NAME, c.C_ACCTBAL
FROM TPCH.CUSTOMER c
WHERE c.C_ACCTBAL > 0
  AND NOT EXISTS (SELECT 1 FROM TPCH.ORDERS o WHERE o.O_CUSTKEY = c.C_CUSTKEY)
ORDER BY c.C_ACCTBAL DESC
LIMIT 20;
```

---

## Orders & fulfillment

**8. What is the distribution of orders across order priorities (`O_ORDERPRIORITY`)?**

```sql
SELECT O_ORDERPRIORITY, COUNT(*) AS ORDERS
FROM TPCH.ORDERS
GROUP BY O_ORDERPRIORITY
ORDER BY O_ORDERPRIORITY;
```

**9. What percentage of line items were shipped after their commit date (late shipments)?**

```sql
SELECT ROUND(100.0 * SUM(CASE WHEN L_SHIPDATE > L_COMMITDATE THEN 1 ELSE 0 END) / COUNT(*), 2)
       AS PCT_LATE
FROM TPCH.LINEITEM;
```

**10. What is the average number of line items per order?**

```sql
SELECT ROUND(CAST(COUNT(*) AS DECIMAL(18,4)) / COUNT(DISTINCT L_ORDERKEY), 2)
       AS AVG_LINES_PER_ORDER
FROM TPCH.LINEITEM;
```

**11. Which orders have the highest total price, and who placed them?**

```sql
SELECT o.O_ORDERKEY, o.O_TOTALPRICE, c.C_NAME
FROM TPCH.ORDERS o
JOIN TPCH.CUSTOMER c ON c.C_CUSTKEY = o.O_CUSTKEY
ORDER BY o.O_TOTALPRICE DESC
LIMIT 10;
```

---

## Suppliers & parts

**12. Who are the top suppliers by revenue and quantity supplied?**

```sql
SELECT s.S_SUPPKEY, s.S_NAME,
       SUM(l.L_EXTENDEDPRICE * (1 - l.L_DISCOUNT)) AS REVENUE,
       SUM(l.L_QUANTITY) AS QTY
FROM TPCH.SUPPLIER s
JOIN TPCH.LINEITEM l ON l.L_SUPPKEY = s.S_SUPPKEY
GROUP BY s.S_SUPPKEY, s.S_NAME
ORDER BY REVENUE DESC
LIMIT 10;
```

**13. Which suppliers offer parts at the lowest cost within a given region (min-cost sourcing)?**

```sql
SELECT r.R_NAME, ps.PS_PARTKEY, MIN(ps.PS_SUPPLYCOST) AS MIN_COST
FROM TPCH.PARTSUPP ps
JOIN TPCH.SUPPLIER s ON s.S_SUPPKEY = ps.PS_SUPPKEY
JOIN TPCH.NATION n   ON n.N_NATIONKEY = s.S_NATIONKEY
JOIN TPCH.REGION r   ON r.R_REGIONKEY = n.N_REGIONKEY
WHERE r.R_NAME = 'EUROPE'
GROUP BY r.R_NAME, ps.PS_PARTKEY
ORDER BY MIN_COST ASC
LIMIT 10;
```

**14. For each part, how many suppliers provide it, and what's the price spread?**

```sql
SELECT ps.PS_PARTKEY,
       COUNT(DISTINCT ps.PS_SUPPKEY) AS SUPPLIERS,
       MIN(ps.PS_SUPPLYCOST) AS MIN_COST,
       MAX(ps.PS_SUPPLYCOST) AS MAX_COST,
       MAX(ps.PS_SUPPLYCOST) - MIN(ps.PS_SUPPLYCOST) AS SPREAD
FROM TPCH.PARTSUPP ps
GROUP BY ps.PS_PARTKEY
ORDER BY SPREAD DESC
LIMIT 10;
```

---

*Exasol SQL notes: identifiers fold to UPPERCASE (no quoting needed), row limits use
`LIMIT n` (not `FETCH FIRST`/`TOP`), and `RATIO_TO_REPORT(...) OVER ()` gives a share of
total. More in [data-dictionary.md](data-dictionary.md).*
