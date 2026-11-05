-- 03_verify_setup.sql - post-load verification for the walmart_sales dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset loaded.
OPEN SCHEMA WALMART;

SELECT 'row_count: weekly_sales' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 6435 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 6435, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM WEEKLY_SALES
UNION ALL
SELECT 'sanity: stores and holiday weeks',
       CASE WHEN COUNT(DISTINCT STORE) = 45 AND SUM(HOLIDAY_WEEK) = 450 THEN 'OK' ELSE 'FAIL' END,
       'expected 45 stores and 450 holiday weeks, found ' || CAST(COUNT(DISTINCT STORE) AS VARCHAR(20))
           || ' and ' || CAST(SUM(HOLIDAY_WEEK) AS VARCHAR(20))
FROM WEEKLY_SALES
UNION ALL
SELECT 'sanity: weeks above the store median',
       CASE WHEN SUM(ABOVE_STORE_MEDIAN) = 3195 THEN 'OK' ELSE 'FAIL' END,
       'expected 3195, found ' || CAST(SUM(ABOVE_STORE_MEDIAN) AS VARCHAR(20))
FROM WEEKLY_SALES;
