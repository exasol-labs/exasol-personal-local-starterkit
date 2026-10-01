-- 01_create_schema.sql - daily weather history dataset schema.
-- Loads into its own WEATHER schema; the dedicated read-only MCP user reads it
-- via database-wide read (USE ANY SCHEMA + SELECT ANY TABLE), no per-schema
-- grant. Tables keep the WEATHER_ prefix so fully-qualified names stay clear.
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- exakit data-load --force) without manual cleanup.

CREATE SCHEMA IF NOT EXISTS WEATHER;
OPEN SCHEMA WEATHER;

-- weather_cities (10 rows, from data/weather_cities.csv). PK: city_id.
CREATE OR REPLACE TABLE WEATHER_CITIES (
    CITY_ID DECIMAL(9,0) NOT NULL,
    CITY    VARCHAR(30)  NOT NULL,
    COUNTRY VARCHAR(30)  NOT NULL,
    CONSTRAINT WEATHER_CITIES_PK PRIMARY KEY (CITY_ID)
);

-- weather_daily (10 cities x 2023-01-01..2025-12-31, from data/weather_daily.csv).
-- FK (documented, not enforced): city_id -> weather_cities.
CREATE OR REPLACE TABLE WEATHER_DAILY (
    CITY_ID    DECIMAL(9,0) NOT NULL,
    W_DATE     DATE         NOT NULL,
    TEMP_AVG_C DECIMAL(5,1) NOT NULL,
    TEMP_MIN_C DECIMAL(5,1) NOT NULL,
    TEMP_MAX_C DECIMAL(5,1) NOT NULL,
    PRECIP_MM  DECIMAL(6,1) NOT NULL,
    WIND_KMH   DECIMAL(5,1) NOT NULL,
    CONSTRAINT WEATHER_DAILY_PK PRIMARY KEY (CITY_ID, W_DATE)
);

-- Semantics travel WITH the tables (see the note in tpch/01_create_schema.sql):
-- the MCP describe path reads these comments. COMMENT is idempotent.

COMMENT ON TABLE  WEATHER_CITIES IS 'One city with weather history (10 rows). PK city_id.';
COMMENT ON COLUMN WEATHER_CITIES.CITY_ID IS 'City id (PK)';
COMMENT ON COLUMN WEATHER_CITIES.CITY IS 'City name';
COMMENT ON COLUMN WEATHER_CITIES.COUNTRY IS 'Country the city is in';

COMMENT ON TABLE  WEATHER_DAILY IS 'One row per city per day, 2023-01-01..2025-12-31. PK (city_id, w_date); city_id -> weather_cities.';
COMMENT ON COLUMN WEATHER_DAILY.CITY_ID IS 'City (FK -> weather_cities.city_id)';
COMMENT ON COLUMN WEATHER_DAILY.W_DATE IS 'Calendar day of the observation';
COMMENT ON COLUMN WEATHER_DAILY.TEMP_AVG_C IS 'Daily mean temperature, degrees Celsius';
COMMENT ON COLUMN WEATHER_DAILY.TEMP_MIN_C IS 'Daily minimum temperature, degrees Celsius';
COMMENT ON COLUMN WEATHER_DAILY.TEMP_MAX_C IS 'Daily maximum temperature, degrees Celsius';
COMMENT ON COLUMN WEATHER_DAILY.PRECIP_MM IS 'Total precipitation for the day, millimetres';
COMMENT ON COLUMN WEATHER_DAILY.WIND_KMH IS 'Mean wind speed, km/h';
