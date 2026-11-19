-- 03_verify_setup.sql - post-load verification for the bank transaction dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset loaded.
OPEN SCHEMA BANK_TRANSACTION;

SELECT 'row_count: bank_transactions' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 2512 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 2512, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM BANK_TRANSACTIONS
UNION ALL
SELECT 'sanity: debit or credit only',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' other row(s)'
FROM BANK_TRANSACTIONS
WHERE TRANSACTION_TYPE NOT IN ('Debit', 'Credit');
