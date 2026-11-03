-- examples.sql - questions the medication_sigs dataset answers, one query each.
-- Every query runs as it stands against the loaded MEDSIGS schema (the kit's tests
-- run them all). Read-only: the MCP user can run them too.

-- 1. How many directions are there, and how long are they?
SELECT COUNT(*) AS SIGS, ROUND(AVG(WORD_COUNT), 1) AS AVG_WORDS, MAX(WORD_COUNT) AS MAX_WORDS
FROM MEDSIGS.MEDICATION_SIGS;

-- 2. Which directions are taken by mouth (po, oral, by mouth)?
SELECT SIG_ID, SIG_TEXT
FROM MEDSIGS.MEDICATION_SIGS
WHERE LOWER(SIG_TEXT) LIKE '% po %' OR LOWER(SIG_TEXT) LIKE '%oral%' OR LOWER(SIG_TEXT) LIKE '%by mouth%'
ORDER BY SIG_ID;

-- 3. How often a day? Twice-daily directions in any spelling.
SELECT SIG_ID, SIG_TEXT
FROM MEDSIGS.MEDICATION_SIGS
WHERE LOWER(SIG_TEXT) LIKE '%bid%' OR LOWER(SIG_TEXT) LIKE '%twice%' OR LOWER(SIG_TEXT) LIKE '%2 times%'
   OR LOWER(SIG_TEXT) LIKE '%two times%'
ORDER BY SIG_ID;

-- 4. Which directions are as needed (prn)?
SELECT SIG_ID, SIG_TEXT
FROM MEDSIGS.MEDICATION_SIGS
WHERE LOWER(SIG_TEXT) LIKE '%prn%' OR LOWER(SIG_TEXT) LIKE '%as needed%'
ORDER BY SIG_ID;

-- 5. Which directions give a duration in days?
SELECT SIG_ID, SIG_TEXT
FROM MEDSIGS.MEDICATION_SIGS
WHERE LOWER(SIG_TEXT) LIKE '%day%' AND (SIG_TEXT LIKE '%x%' OR LOWER(SIG_TEXT) LIKE '%for%')
ORDER BY SIG_ID;

-- 6. Which directions name a strength in mg?
SELECT SIG_ID, SIG_TEXT
FROM MEDSIGS.MEDICATION_SIGS
WHERE LOWER(SIG_TEXT) LIKE '%mg%' OR LOWER(SIG_TEXT) LIKE '%milligram%'
ORDER BY SIG_ID;

-- 7. Capsules or tablets?
SELECT CASE WHEN LOWER(SIG_TEXT) LIKE '%cap%' THEN 'capsule'
            WHEN LOWER(SIG_TEXT) LIKE '%tab%' THEN 'tablet' ELSE 'not named' END AS FORM,
       COUNT(*) AS SIGS
FROM MEDSIGS.MEDICATION_SIGS
GROUP BY 1
ORDER BY SIGS DESC;

-- 8. Which directions use only abbreviations (five words or fewer)?
SELECT SIG_ID, SIG_TEXT
FROM MEDSIGS.MEDICATION_SIGS
WHERE WORD_COUNT <= 5
ORDER BY SIG_ID;

-- 9. Which directions name the reason for the medicine?
SELECT SIG_ID, SIG_TEXT
FROM MEDSIGS.MEDICATION_SIGS
WHERE LOWER(SIG_TEXT) LIKE '%for %' AND (LOWER(SIG_TEXT) LIKE '%cough%' OR LOWER(SIG_TEXT) LIKE '%allergy%'
   OR LOWER(SIG_TEXT) LIKE '%infection%' OR LOWER(SIG_TEXT) LIKE '%pain%')
ORDER BY SIG_ID;

-- 10. Three times a day, in its spellings (tid, three times, 3 times, every 8 hours).
SELECT SIG_ID, SIG_TEXT
FROM MEDSIGS.MEDICATION_SIGS
WHERE LOWER(SIG_TEXT) LIKE '%tid%' OR LOWER(SIG_TEXT) LIKE '%three times%' OR LOWER(SIG_TEXT) LIKE '%3 times%'
   OR LOWER(SIG_TEXT) LIKE '%every 8%' OR LOWER(SIG_TEXT) LIKE '%q8%'
ORDER BY SIG_ID;
