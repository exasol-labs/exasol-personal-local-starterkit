-- 03_verify_setup.sql - post-load verification for the weather dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset
-- loaded (same contract as the TPC-H verify script).
OPEN SCHEMA WEATHER;

SELECT 'row_count: weather_cities' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 10 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 10, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM WEATHER_CITIES
UNION ALL
SELECT 'row_count: weather_daily',
       CASE WHEN COUNT(*) = 10960 THEN 'OK' ELSE 'FAIL' END,
       'expected 10960, found ' || CAST(COUNT(*) AS VARCHAR(20))
FROM WEATHER_DAILY
UNION ALL
SELECT 'sanity: min <= avg <= max for every day',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' inconsistent row(s)'
FROM WEATHER_DAILY
WHERE TEMP_MIN_C > TEMP_AVG_C OR TEMP_AVG_C > TEMP_MAX_C
UNION ALL
SELECT 'sanity: precipitation and wind are non-negative',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' negative value row(s)'
FROM WEATHER_DAILY
WHERE PRECIP_MM < 0 OR WIND_KMH < 0
UNION ALL
SELECT 'fk: weather_daily.city_id -> weather_cities',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
FROM WEATHER_DAILY d
WHERE NOT EXISTS (SELECT 1 FROM WEATHER_CITIES c WHERE c.CITY_ID = d.CITY_ID);
