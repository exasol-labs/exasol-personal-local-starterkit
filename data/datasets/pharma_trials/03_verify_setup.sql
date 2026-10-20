-- 03_verify_setup.sql - post-load verification for the pharma_trials dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset
-- loaded (same contract as the TPC-H verify script). The row counts are the
-- manifest's (manifest.json, written by tools/datasets/pharma_trials.py).
OPEN SCHEMA PHARMA;

SELECT 'row_count: pharma_trials' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 5169 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 5169, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM PHARMA_TRIALS
UNION ALL
SELECT 'row_count: pharma_conditions',
       CASE WHEN COUNT(*) = 7291 THEN 'OK' ELSE 'FAIL' END,
       'expected 7291, found ' || CAST(COUNT(*) AS VARCHAR(20))
FROM PHARMA_CONDITIONS
UNION ALL
SELECT 'row_count: pharma_interventions',
       CASE WHEN COUNT(*) = 12384 THEN 'OK' ELSE 'FAIL' END,
       'expected 12384, found ' || CAST(COUNT(*) AS VARCHAR(20))
FROM PHARMA_INTERVENTIONS
UNION ALL
SELECT 'row_count: pharma_stop_reasons',
       CASE WHEN COUNT(*) = 887 THEN 'OK' ELSE 'FAIL' END,
       'expected 887, found ' || CAST(COUNT(*) AS VARCHAR(20))
FROM PHARMA_STOP_REASONS
UNION ALL
SELECT 'sanity: the label matches the status',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' trial(s) whose TERMINATED disagrees with OVERALL_STATUS'
FROM PHARMA_TRIALS
WHERE TERMINATED <> CASE WHEN OVERALL_STATUS = 'TERMINATED' THEN 1 ELSE 0 END
UNION ALL
SELECT 'fk: pharma_conditions.nct_id -> pharma_trials',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
FROM PHARMA_CONDITIONS c
WHERE NOT EXISTS (SELECT 1 FROM PHARMA_TRIALS t WHERE t.NCT_ID = c.NCT_ID)
UNION ALL
SELECT 'fk: pharma_interventions.nct_id -> pharma_trials',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
FROM PHARMA_INTERVENTIONS c
WHERE NOT EXISTS (SELECT 1 FROM PHARMA_TRIALS t WHERE t.NCT_ID = c.NCT_ID)
UNION ALL
SELECT 'fk: pharma_stop_reasons.nct_id -> pharma_trials',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
FROM PHARMA_STOP_REASONS c
WHERE NOT EXISTS (SELECT 1 FROM PHARMA_TRIALS t WHERE t.NCT_ID = c.NCT_ID);
