-- 03_verify_setup.sql - post-load verification for the amazon_sales dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset loaded.
OPEN SCHEMA AMAZON;

SELECT 'row_count: order_lines' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 128975 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 128975, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM ORDER_LINES
UNION ALL
SELECT 'sanity: cancelled lines',
       CASE WHEN SUM(CANCELLED) = 18332 THEN 'OK' ELSE 'FAIL' END,
       'expected 18332, found ' || CAST(SUM(CANCELLED) AS VARCHAR(20))
FROM ORDER_LINES;
