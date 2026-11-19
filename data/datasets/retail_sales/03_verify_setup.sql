-- 03_verify_setup.sql - post-load verification for the retail sales dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset loaded.
OPEN SCHEMA RETAIL_SALES;

SELECT 'row_count: retail_sales' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 1000 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 1000, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM RETAIL_SALES
UNION ALL
SELECT 'sanity: total = quantity x price',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' inconsistent row(s)'
FROM RETAIL_SALES
WHERE TOTAL_AMOUNT <> QUANTITY * PRICE_PER_UNIT;
