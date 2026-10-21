-- 03_verify_setup.sql - post-load verification for the bank_marketing dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset loaded.
OPEN SCHEMA BANKMKT;

SELECT 'row_count: bank_clients' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 45211 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 45211, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM BANK_CLIENTS
UNION ALL
SELECT 'sanity: subscribed clients',
       CASE WHEN SUM(SUBSCRIBED) = 5289 THEN 'OK' ELSE 'FAIL' END,
       'expected 5289, found ' || CAST(SUM(SUBSCRIBED) AS VARCHAR(20))
FROM BANK_CLIENTS;
