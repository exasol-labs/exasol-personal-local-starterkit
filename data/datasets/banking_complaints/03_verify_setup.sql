-- 03_verify_setup.sql - post-load verification for the banking_complaints dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset
-- loaded (same contract as the TPC-H verify script). The row counts are the
-- manifest's (manifest.json, written by tools/datasets/banking_complaints.py).
OPEN SCHEMA BANKING;

SELECT 'row_count: banking_complaints' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 6754 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 6754, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM BANKING_COMPLAINTS
UNION ALL
SELECT 'row_count: banking_responses',
       CASE WHEN COUNT(*) = 6754 THEN 'OK' ELSE 'FAIL' END,
       'expected 6754, found ' || CAST(COUNT(*) AS VARCHAR(20))
FROM BANKING_RESPONSES
UNION ALL
SELECT 'sanity: the label matches the response',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' complaint(s) whose MONETARY_RELIEF disagrees with COMPANY_RESPONSE'
FROM BANKING_COMPLAINTS c
JOIN BANKING_RESPONSES r ON r.COMPLAINT_ID = c.COMPLAINT_ID
WHERE c.MONETARY_RELIEF <> CASE WHEN r.COMPANY_RESPONSE = 'Closed with monetary relief' THEN 1 ELSE 0 END
UNION ALL
SELECT 'fk: banking_responses.complaint_id -> banking_complaints',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
FROM BANKING_RESPONSES r
WHERE NOT EXISTS (SELECT 1 FROM BANKING_COMPLAINTS c WHERE c.COMPLAINT_ID = r.COMPLAINT_ID);
