-- 03_verify_setup.sql - post-load verification for the sample dataset.
-- Run by setup/load-data.sh (via exapump) right after the CSV load and any
-- 02_load_data.sql transform. Every row below should read STATUS = 'OK'.
-- A 'FAIL' row means the load is incomplete or the data is not
-- self-consistent - do not treat the kit's sample data as ready until every
-- row here passes; check the load-data-*.log under
-- ~/.exasol-starter-kit/logs for the failing step.
--
-- Numeric values are explicitly CAST to VARCHAR before concatenation rather
-- than relying on implicit conversion, so this script's behavior doesn't
-- depend on a specific Exasol version's type-coercion rules.
OPEN SCHEMA TPCH;

-- 1. Row counts. Seven tables have a fixed count at SF=0.02 (data/README.md);
--    lineitem's count is generator-dependent (~120K, 1-7 lines per order),
--    so it is checked against a broad but meaningful bound instead.
SELECT CHECK_NAME, STATUS, DETAIL FROM (
    SELECT 'row_count: region' AS CHECK_NAME,
           CASE WHEN COUNT(*) = 5 THEN 'OK' ELSE 'FAIL' END AS STATUS,
           'expected 5, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
    FROM REGION
    UNION ALL
    SELECT 'row_count: nation',
           CASE WHEN COUNT(*) = 25 THEN 'OK' ELSE 'FAIL' END,
           'expected 25, found ' || CAST(COUNT(*) AS VARCHAR(20))
    FROM NATION
    UNION ALL
    SELECT 'row_count: customer',
           CASE WHEN COUNT(*) = 3000 THEN 'OK' ELSE 'FAIL' END,
           'expected 3000, found ' || CAST(COUNT(*) AS VARCHAR(20))
    FROM CUSTOMER
    UNION ALL
    SELECT 'row_count: supplier',
           CASE WHEN COUNT(*) = 200 THEN 'OK' ELSE 'FAIL' END,
           'expected 200, found ' || CAST(COUNT(*) AS VARCHAR(20))
    FROM SUPPLIER
    UNION ALL
    SELECT 'row_count: part',
           CASE WHEN COUNT(*) = 4000 THEN 'OK' ELSE 'FAIL' END,
           'expected 4000, found ' || CAST(COUNT(*) AS VARCHAR(20))
    FROM PART
    UNION ALL
    SELECT 'row_count: partsupp',
           CASE WHEN COUNT(*) = 16000 THEN 'OK' ELSE 'FAIL' END,
           'expected 16000, found ' || CAST(COUNT(*) AS VARCHAR(20))
    FROM PARTSUPP
    UNION ALL
    SELECT 'row_count: orders',
           CASE WHEN COUNT(*) = 30000 THEN 'OK' ELSE 'FAIL' END,
           'expected 30000, found ' || CAST(COUNT(*) AS VARCHAR(20))
    FROM ORDERS
    UNION ALL
    SELECT 'row_count: lineitem',
           CASE WHEN COUNT(*) BETWEEN 30000 AND 210000 THEN 'OK' ELSE 'FAIL' END,
           'expected roughly 120000 (1-7 lines/order), found ' || CAST(COUNT(*) AS VARCHAR(20))
    FROM LINEITEM

    -- 2. Referential integrity: every FK documented in
    --    data/data-dictionary.md must resolve. Each check counts rows on
    --    the "many" side whose key has no match on the "one" side.
    UNION ALL
    SELECT 'fk: nation.n_regionkey -> region',
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
           CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
    FROM NATION n
    WHERE NOT EXISTS (SELECT 1 FROM REGION r WHERE r.r_regionkey = n.n_regionkey)
    UNION ALL
    SELECT 'fk: customer.c_nationkey -> nation',
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
           CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
    FROM CUSTOMER c
    WHERE NOT EXISTS (SELECT 1 FROM NATION n WHERE n.n_nationkey = c.c_nationkey)
    UNION ALL
    SELECT 'fk: supplier.s_nationkey -> nation',
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
           CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
    FROM SUPPLIER s
    WHERE NOT EXISTS (SELECT 1 FROM NATION n WHERE n.n_nationkey = s.s_nationkey)
    UNION ALL
    SELECT 'fk: partsupp -> part/supplier',
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
           CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
    FROM PARTSUPP ps
    WHERE NOT EXISTS (SELECT 1 FROM PART p WHERE p.p_partkey = ps.ps_partkey)
       OR NOT EXISTS (SELECT 1 FROM SUPPLIER s WHERE s.s_suppkey = ps.ps_suppkey)
    UNION ALL
    SELECT 'fk: orders.o_custkey -> customer',
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
           CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
    FROM ORDERS o
    WHERE NOT EXISTS (SELECT 1 FROM CUSTOMER c WHERE c.c_custkey = o.o_custkey)
    UNION ALL
    SELECT 'fk: lineitem.l_orderkey -> orders',
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
           CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
    FROM LINEITEM l
    WHERE NOT EXISTS (SELECT 1 FROM ORDERS o WHERE o.o_orderkey = l.l_orderkey)
    UNION ALL
    SELECT 'fk: lineitem -> partsupp (partkey, suppkey)',
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
           CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
    FROM LINEITEM l
    WHERE NOT EXISTS (
        SELECT 1 FROM PARTSUPP ps
        WHERE ps.ps_partkey = l.l_partkey AND ps.ps_suppkey = l.l_suppkey
    )

    -- 3. Business-sanity checks: catch a truncated/partial load that
    --    happens to satisfy the row-count and FK checks above (e.g. a
    --    reload that mixed rows from two runs).
    UNION ALL
    SELECT 'sanity: every order has at least one line item',
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
           CAST(COUNT(*) AS VARCHAR(20)) || ' order(s) with zero line items'
    FROM ORDERS o
    WHERE NOT EXISTS (SELECT 1 FROM LINEITEM l WHERE l.l_orderkey = o.o_orderkey)
    UNION ALL
    SELECT 'sanity: total lineitem revenue is positive',
           CASE WHEN SUM(l_extendedprice * (1 - l_discount)) > 0 THEN 'OK' ELSE 'FAIL' END,
           'total revenue = ' || CAST(SUM(l_extendedprice * (1 - l_discount)) AS VARCHAR(40))
    FROM LINEITEM
) verification_report
ORDER BY CHECK_NAME;
