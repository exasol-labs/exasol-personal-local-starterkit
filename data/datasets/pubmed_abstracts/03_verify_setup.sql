-- 03_verify_setup.sql - post-load verification for the pubmed_abstracts dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset loaded.
OPEN SCHEMA PUBMED;

SELECT 'row_count: pubmed_abstracts' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 1409 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 1409, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM PUBMED_ABSTRACTS
UNION ALL
SELECT 'sanity: structured abstracts',
       CASE WHEN COUNT(FIRST_SECTION) = 749 THEN 'OK' ELSE 'FAIL' END,
       'expected 749, found ' || CAST(COUNT(FIRST_SECTION) AS VARCHAR(20))
FROM PUBMED_ABSTRACTS;
