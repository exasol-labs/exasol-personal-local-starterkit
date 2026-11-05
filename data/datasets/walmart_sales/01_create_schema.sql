-- 01_create_schema.sql - Walmart weekly sales (the Kaggle "Walmart Data Analysis and Forecasting" set).
-- Loads into its own WALMART schema; the dedicated read-only MCP user reads it via database-wide
-- read (USE ANY SCHEMA + SELECT ANY TABLE), no per-schema grant.
-- Where it came from and its licence: README.md and manifest.json.
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- exakit data-load --force) without manual cleanup.

CREATE SCHEMA IF NOT EXISTS WALMART;
OPEN SCHEMA WALMART;

-- weekly_sales (one row per store and week, from data/weekly_sales.csv). PK: sales_id.
CREATE OR REPLACE TABLE WEEKLY_SALES (
    SALES_ID      DECIMAL(5,0)   NOT NULL,
    STORE         DECIMAL(2,0)   NOT NULL,   -- store number, 1 to 45
    WEEK_DATE     DATE           NOT NULL,   -- the Friday that ends the sales week
    WEEKLY_SALES  DECIMAL(12,2)  NOT NULL,   -- the store's sales that week, US dollars
    HOLIDAY_WEEK  DECIMAL(1,0)   NOT NULL,   -- 1 when a holiday falls in the week
    TEMPERATURE_F DECIMAL(5,2)   NOT NULL,   -- average temperature in the store's region, Fahrenheit
    FUEL_PRICE    DECIMAL(5,3)   NOT NULL,   -- fuel price in the region, dollars per gallon
    CPI           DECIMAL(12,7)  NOT NULL,   -- consumer price index
    UNEMPLOYMENT  DECIMAL(6,3)   NOT NULL,   -- unemployment rate, percent
    ABOVE_STORE_MEDIAN DECIMAL(1,0) NOT NULL, -- 1 when the week sold more than the store's median week: the label
    CONSTRAINT WEEKLY_SALES_PK PRIMARY KEY (SALES_ID)
);

-- Semantics travel WITH the tables (see the note in tpch/01_create_schema.sql):
-- the MCP describe path reads these comments. COMMENT is idempotent.

COMMENT ON TABLE  WEEKLY_SALES IS 'Weekly sales of 45 Walmart stores, February 2010 - October 2012 (Kaggle, Walmart Data Analysis and Forecasting; licence not confirmed). PK sales_id; one row per store and week; ABOVE_STORE_MEDIAN is the label.';
COMMENT ON COLUMN WEEKLY_SALES.SALES_ID IS 'Row number, by store then week (PK)';
COMMENT ON COLUMN WEEKLY_SALES.STORE IS 'Store number, 1 to 45';
COMMENT ON COLUMN WEEKLY_SALES.WEEK_DATE IS 'The date that ends the sales week';
COMMENT ON COLUMN WEEKLY_SALES.WEEKLY_SALES IS 'The store''s sales that week, US dollars';
COMMENT ON COLUMN WEEKLY_SALES.HOLIDAY_WEEK IS '1 when a holiday (Super Bowl, Labor Day, Thanksgiving, Christmas) falls in the week';
COMMENT ON COLUMN WEEKLY_SALES.TEMPERATURE_F IS 'Average temperature in the store''s region that week, Fahrenheit';
COMMENT ON COLUMN WEEKLY_SALES.FUEL_PRICE IS 'Fuel price in the region, US dollars per gallon';
COMMENT ON COLUMN WEEKLY_SALES.CPI IS 'Consumer price index';
COMMENT ON COLUMN WEEKLY_SALES.UNEMPLOYMENT IS 'Unemployment rate in the region, percent';
COMMENT ON COLUMN WEEKLY_SALES.ABOVE_STORE_MEDIAN IS '1 when the week sold more than this store''s median week, else 0: the label (added by the kit from WEEKLY_SALES)';
