-- 02_load_data.sql - generate the hourly readings (deterministic, no CSV).
-- 50 meters x 2160 hours (90 days from 2025-01-01) = 108,000 rows. Each value
-- is a daily sine curve on top of the meter's baseline, a weekend bump, and a
-- deterministic jitter derived from (meter, hour) - so re-runs produce the
-- exact same data. TRUNCATE first so a --force re-run cannot double-insert.

OPEN SCHEMA ENERGY;

TRUNCATE TABLE ENERGY_READINGS;

INSERT INTO ENERGY_READINGS (METER_ID, READING_TS, KWH)
WITH d AS (
    SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
    UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
    UNION ALL SELECT 8 UNION ALL SELECT 9
),
hours AS (
    SELECT a.n * 1000 + b.n * 100 + c.n * 10 + e.n AS h
    FROM d a, d b, d c, d e
    WHERE a.n * 1000 + b.n * 100 + c.n * 10 + e.n < 2160
)
SELECT
    m.METER_ID,
    ADD_HOURS(TIMESTAMP '2025-01-01 00:00:00', hrs.h),
    ROUND(
        0.25
        + m.BASE_LOAD_KWH
        + m.BASE_LOAD_KWH * 0.6 * SIN((MOD(hrs.h, 24) - 6) * PI() / 12)
        + CASE WHEN MOD(FLOOR(hrs.h / 24), 7) IN (5, 6)
               THEN m.BASE_LOAD_KWH * 0.2 ELSE 0 END
        + MOD(m.METER_ID * 7919 + hrs.h * 104729, 100) / 400.0,
        3)
FROM ENERGY_METERS m, hours hrs;
