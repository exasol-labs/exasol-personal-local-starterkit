-- 03_verify_setup.sql - post-load verification for the energy dataset.
-- Every row must read STATUS = 'OK'; a 'FAIL' row blocks marking the dataset
-- loaded (same contract as the TPC-H verify script).
OPEN SCHEMA ENERGY;

SELECT 'row_count: energy_meters' AS CHECK_NAME,
       CASE WHEN COUNT(*) = 50 THEN 'OK' ELSE 'FAIL' END AS STATUS,
       'expected 50, found ' || CAST(COUNT(*) AS VARCHAR(20)) AS DETAIL
FROM ENERGY_METERS
UNION ALL
SELECT 'row_count: energy_readings',
       CASE WHEN COUNT(*) = 108000 THEN 'OK' ELSE 'FAIL' END,
       'expected 108000, found ' || CAST(COUNT(*) AS VARCHAR(20))
FROM ENERGY_READINGS
UNION ALL
SELECT 'sanity: every meter has 2160 readings',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' meter(s) with a wrong reading count'
FROM (
    SELECT METER_ID FROM ENERGY_READINGS
    GROUP BY METER_ID HAVING COUNT(*) <> 2160
)
UNION ALL
SELECT 'sanity: all readings are positive',
       CASE WHEN MIN(KWH) > 0 THEN 'OK' ELSE 'FAIL' END,
       'minimum kwh = ' || CAST(MIN(KWH) AS VARCHAR(20))
FROM ENERGY_READINGS
UNION ALL
SELECT 'fk: readings.meter_id -> energy_meters',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END,
       CAST(COUNT(*) AS VARCHAR(20)) || ' orphaned row(s)'
FROM ENERGY_READINGS r
WHERE NOT EXISTS (SELECT 1 FROM ENERGY_METERS m WHERE m.METER_ID = r.METER_ID);
