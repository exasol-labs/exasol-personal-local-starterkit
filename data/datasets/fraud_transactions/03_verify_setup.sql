-- 03_verify_setup.sql - post-load verification for the fraud_transactions dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset loaded.
OPEN SCHEMA FRAUD;

SELECT 'row_count: transactions' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 51000 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 51000, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM TRANSACTIONS
UNION ALL
SELECT 'sanity: fraud label and users',
       CASE WHEN SUM(FRAUDULENT) = 2510 AND COUNT(DISTINCT USER_ID) = 4000 THEN 'OK' ELSE 'FAIL' END,
       'expected 2510 frauds and 4000 users, found ' || CAST(SUM(FRAUDULENT) AS VARCHAR(20))
           || ' and ' || CAST(COUNT(DISTINCT USER_ID) AS VARCHAR(20))
FROM TRANSACTIONS
UNION ALL
SELECT 'sanity: the duplicates and gaps are kept',
       CASE WHEN COUNT(DISTINCT TRANSACTION_ID) = 50000 AND COUNT(TRANSACTION_AMOUNT) = 48480 THEN 'OK' ELSE 'FAIL' END,
       'expected 50000 distinct ids and 48480 amounts, found ' || CAST(COUNT(DISTINCT TRANSACTION_ID) AS VARCHAR(20))
           || ' and ' || CAST(COUNT(TRANSACTION_AMOUNT) AS VARCHAR(20))
FROM TRANSACTIONS;
