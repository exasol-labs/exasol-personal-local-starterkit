-- 03_verify_setup.sql - post-load verification for the esophageal_posts dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset
-- loaded (same contract as the TPC-H verify script). The row count is the
-- manifest's (manifest.json, written by tools/datasets/esophageal_posts.py).
OPEN SCHEMA ESOPHAGEAL;

SELECT 'row_count: esophageal_posts' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 40987 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 40987, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM ESOPHAGEAL_POSTS
UNION ALL
SELECT 'sanity: the label matches the sentiment',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' post(s) whose IS_NEGATIVE disagrees with SENTIMENT'
FROM ESOPHAGEAL_POSTS
WHERE IS_NEGATIVE <> CASE WHEN SENTIMENT = 'NEGATIVE' THEN 1 ELSE 0 END
UNION ALL
SELECT 'privacy: no handle, link or e-mail in the text',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' post(s) with an @handle other than @user, a link or an e-mail address'
FROM ESOPHAGEAL_POSTS
WHERE REGEXP_INSTR(COALESCE(TITLE, '') || ' ' || COALESCE(MESSAGE, ''), '(?i)https?:|\bwww\.|[\w.+-]+@[\w-]+\.\w|(?<![\w@])@(?!user\b)\w') > 0;
