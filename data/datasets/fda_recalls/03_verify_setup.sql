-- 03_verify_setup.sql - post-load verification for the fda_recalls dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset
-- loaded (same contract as the TPC-H verify script). The row counts are the
-- manifest's (manifest.json, written by tools/datasets/fda_recalls.py).
OPEN SCHEMA FDA;

SELECT 'row_count: fda_recalls' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 5459 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 5459, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM FDA_RECALLS
UNION ALL
SELECT 'row_count: fda_classifications',
       CASE WHEN COUNT(*) = 5459 THEN 'OK' ELSE 'FAIL' END,
       'expected 5459, found ' || CAST(COUNT(*) AS VARCHAR(20))
FROM FDA_CLASSIFICATIONS
UNION ALL
SELECT 'sanity: the label matches the classification',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' recall(s) whose SERIOUS disagrees with CLASSIFICATION'
FROM FDA_RECALLS r
JOIN FDA_CLASSIFICATIONS c ON c.RECALL_NUMBER = r.RECALL_NUMBER
WHERE r.SERIOUS <> CASE WHEN c.CLASSIFICATION = 'Class I' THEN 1 ELSE 0 END
UNION ALL
SELECT 'fk: fda_classifications.recall_number -> fda_recalls',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
FROM FDA_CLASSIFICATIONS c
WHERE NOT EXISTS (SELECT 1 FROM FDA_RECALLS r WHERE r.RECALL_NUMBER = c.RECALL_NUMBER);
