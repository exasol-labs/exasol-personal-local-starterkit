-- 03_verify_setup.sql - post-load verification for the ade_corpus dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset loaded.
OPEN SCHEMA ADE;

SELECT 'row_count: ade_sentences' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 20960 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 20960, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM ADE_SENTENCES
UNION ALL
SELECT 'sanity: sentences with an adverse effect',
       CASE WHEN SUM(HAS_ADE) = 4272 THEN 'OK' ELSE 'FAIL' END,
       'expected 4272, found ' || CAST(SUM(HAS_ADE) AS VARCHAR(20))
FROM ADE_SENTENCES
UNION ALL
SELECT 'row_count: ade_drug_effects',
       CASE WHEN COUNT(*) = 6633 THEN 'OK' ELSE 'FAIL' END,
       'expected 6633, found ' || CAST(COUNT(*) AS VARCHAR(20))
FROM ADE_DRUG_EFFECTS
UNION ALL
SELECT 'row_count: ade_drug_doses',
       CASE WHEN COUNT(*) = 269 THEN 'OK' ELSE 'FAIL' END,
       'expected 269, found ' || CAST(COUNT(*) AS VARCHAR(20))
FROM ADE_DRUG_DOSES
UNION ALL
SELECT 'integrity: every pair names a positive sentence',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' pairs without a positive sentence'
FROM ADE_DRUG_EFFECTS E LEFT JOIN ADE_SENTENCES S ON S.SENTENCE_ID = E.SENTENCE_ID AND S.HAS_ADE = 1
WHERE S.SENTENCE_ID IS NULL;
