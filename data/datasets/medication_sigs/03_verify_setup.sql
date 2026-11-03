-- 03_verify_setup.sql - post-load verification for the medication_sigs dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset loaded.
OPEN SCHEMA MEDSIGS;

SELECT 'row_count: medication_sigs' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 50 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 50, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM MEDICATION_SIGS;
