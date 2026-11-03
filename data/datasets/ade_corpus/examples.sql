-- examples.sql - questions the ade_corpus dataset answers, one query each.
-- Every query runs as it stands against the loaded ADE schema (the kit's tests
-- run them all). Read-only: the MCP user can run them too.

-- 1. How many sentences report an adverse drug effect?
SELECT HAS_ADE, COUNT(*) AS SENTENCES, ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS PCT
FROM ADE.ADE_SENTENCES
GROUP BY HAS_ADE
ORDER BY HAS_ADE;

-- 2. Which drugs are named with an adverse effect most often?
SELECT LOWER(DRUG) AS DRUG, COUNT(*) AS PAIRS, COUNT(DISTINCT SENTENCE_ID) AS SENTENCES
FROM ADE.ADE_DRUG_EFFECTS
GROUP BY LOWER(DRUG)
ORDER BY PAIRS DESC
LIMIT 15;

-- 3. Which adverse effects come up most often?
SELECT LOWER(ADVERSE_EFFECT) AS ADVERSE_EFFECT, COUNT(*) AS PAIRS
FROM ADE.ADE_DRUG_EFFECTS
GROUP BY LOWER(ADVERSE_EFFECT)
ORDER BY PAIRS DESC
LIMIT 15;

-- 4. Which adverse effects are reported for methotrexate?
SELECT LOWER(ADVERSE_EFFECT) AS ADVERSE_EFFECT, COUNT(*) AS PAIRS
FROM ADE.ADE_DRUG_EFFECTS
WHERE LOWER(DRUG) IN ('methotrexate', 'mtx')
GROUP BY LOWER(ADVERSE_EFFECT)
ORDER BY PAIRS DESC
LIMIT 10;

-- 5. Are sentences with an adverse effect longer than the others?
SELECT HAS_ADE, ROUND(AVG(LENGTH(SENTENCE)), 0) AS AVG_CHARS, MAX(LENGTH(SENTENCE)) AS MAX_CHARS
FROM ADE.ADE_SENTENCES
GROUP BY HAS_ADE
ORDER BY HAS_ADE;

-- 6. How many sentences does each article contribute, and how many of them report an effect?
SELECT PUBMED_ID, COUNT(*) AS SENTENCES, SUM(HAS_ADE) AS WITH_ADE
FROM ADE.ADE_SENTENCES
GROUP BY PUBMED_ID
ORDER BY SENTENCES DESC
LIMIT 10;

-- 7. Which sentences name more than one drug-effect pair?
SELECT S.SENTENCE_ID, COUNT(*) AS PAIRS, S.SENTENCE
FROM ADE.ADE_SENTENCES S JOIN ADE.ADE_DRUG_EFFECTS E ON E.SENTENCE_ID = S.SENTENCE_ID
GROUP BY S.SENTENCE_ID, S.SENTENCE
HAVING COUNT(*) > 2
ORDER BY PAIRS DESC
LIMIT 10;

-- 8. Which doses are given for the drugs that also have an adverse effect in the same sentence?
SELECT LOWER(D.DRUG) AS DRUG, D.DOSE, LOWER(E.ADVERSE_EFFECT) AS ADVERSE_EFFECT
FROM ADE.ADE_DRUG_DOSES D
JOIN ADE.ADE_DRUG_EFFECTS E ON E.SENTENCE_ID = D.SENTENCE_ID AND LOWER(E.DRUG) = LOWER(D.DRUG)
ORDER BY 1, 2
LIMIT 20;

-- 9. Which sentences mention a drug from the effect table without being labelled as an adverse effect?
SELECT COUNT(*) AS NEGATIVE_SENTENCES_NAMING_LITHIUM
FROM ADE.ADE_SENTENCES
WHERE HAS_ADE = 0 AND LOWER(SENTENCE) LIKE '%lithium%';

-- 10. How many distinct drugs and adverse effects does the corpus name?
SELECT COUNT(DISTINCT LOWER(DRUG)) AS DRUGS, COUNT(DISTINCT LOWER(ADVERSE_EFFECT)) AS ADVERSE_EFFECTS
FROM ADE.ADE_DRUG_EFFECTS;
