-- 01_create_schema.sql - prescription directions ("sigs") as prescribers write them.
-- Loads into its own MEDSIGS schema; the dedicated read-only MCP user reads it via database-wide read
-- (USE ANY SCHEMA + SELECT ANY TABLE), no per-schema grant.
-- Where it came from and its terms: README.md and manifest.json.
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- exakit data-load --force) without manual cleanup.

CREATE SCHEMA IF NOT EXISTS MEDSIGS;
OPEN SCHEMA MEDSIGS;

-- medication_sigs (one row per direction, from data/medication_sigs.csv). PK: sig_id.
CREATE OR REPLACE TABLE MEDICATION_SIGS (
    SIG_ID      DECIMAL(4,0)  NOT NULL,
    WORD_COUNT  DECIMAL(3,0)  NOT NULL,
    SIG_TEXT    VARCHAR(300)  NOT NULL,   -- as written: abbreviations (po, bid, prn) and all
    CONSTRAINT MEDICATION_SIGS_PK PRIMARY KEY (SIG_ID)
);

-- Semantics travel WITH the tables (see the note in tpch/01_create_schema.sql):
-- the MCP describe path reads these comments. COMMENT is idempotent.

COMMENT ON TABLE  MEDICATION_SIGS IS 'Prescription directions as prescribers write them, one per row. PK sig_id.';
COMMENT ON COLUMN MEDICATION_SIGS.SIG_ID IS 'Direction id (PK)';
COMMENT ON COLUMN MEDICATION_SIGS.WORD_COUNT IS 'Words in the direction';
COMMENT ON COLUMN MEDICATION_SIGS.SIG_TEXT IS 'The direction, as written (po = by mouth, bid = twice a day, prn = as needed, ...)';
