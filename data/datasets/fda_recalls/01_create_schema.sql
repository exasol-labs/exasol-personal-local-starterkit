-- 01_create_schema.sql - FDA recalls (an openFDA recall enforcement report snapshot).
-- Loads into its own FDA schema; the dedicated read-only MCP user reads it
-- via database-wide read (USE ANY SCHEMA + SELECT ANY TABLE), no per-schema
-- grant. Tables keep the FDA_ prefix so fully-qualified names stay clear.
-- What the snapshot holds and where it came from: README.md and manifest.json.
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- exakit data-load --force) without manual cleanup.

CREATE SCHEMA IF NOT EXISTS FDA;
OPEN SCHEMA FDA;

-- fda_recalls (one row per recalled product, from data/fda_recalls.csv). PK: recall_number.
CREATE OR REPLACE TABLE FDA_RECALLS (
    RECALL_NUMBER          VARCHAR(20)   NOT NULL,
    EVENT_ID               DECIMAL(10,0) NOT NULL,   -- one recall event can recall several products
    PRODUCT_TYPE           VARCHAR(20)   NOT NULL,   -- Food / Drugs / Devices
    RECALLING_FIRM         VARCHAR(200)  NOT NULL,
    FIRM_STATE             VARCHAR(40),              -- empty (NULL) when openFDA has none or says N/A
    FIRM_COUNTRY           VARCHAR(60),
    VOLUNTARY_MANDATED     VARCHAR(60),              -- Voluntary: Firm initiated / FDA Mandated
    INITIAL_NOTIFICATION   VARCHAR(100),             -- Letter / E-Mail / Telephone / ... (never cut)
    RECALL_STATUS          VARCHAR(20),              -- Ongoing / Completed / Terminated
    DISTRIBUTION_PATTERN   VARCHAR(420),             -- free text, cut on a word at 400 characters
    PRODUCT_DESCRIPTION    VARCHAR(620)  NOT NULL,   -- free text, cut on a word at 600 characters
    REASON_FOR_RECALL      VARCHAR(620)  NOT NULL,   -- free text, cut on a word at 600 characters
    RECALL_INITIATION_DATE DATE,
    REPORT_DATE            DATE          NOT NULL,
    SERIOUS                DECIMAL(1,0)  NOT NULL,   -- 1 when the FDA classified it Class I: the label
    CONSTRAINT FDA_RECALLS_PK PRIMARY KEY (RECALL_NUMBER)
);

-- fda_classifications (the FDA's classification of each recall). Kept apart from
-- fda_recalls: the label is derived from it, so it is for reading, never a model feature.
-- FK (documented, not enforced): recall_number -> fda_recalls.
CREATE OR REPLACE TABLE FDA_CLASSIFICATIONS (
    RECALL_NUMBER       VARCHAR(20) NOT NULL,
    CLASSIFICATION      VARCHAR(20) NOT NULL,        -- Class I / Class II / Class III
    CLASSIFICATION_DATE DATE,
    CONSTRAINT FDA_CLASSIFICATIONS_PK PRIMARY KEY (RECALL_NUMBER)
);

-- Semantics travel WITH the tables (see the note in tpch/01_create_schema.sql):
-- the MCP describe path reads these comments. COMMENT is idempotent.

COMMENT ON TABLE  FDA_RECALLS IS 'Food, drug and device recalls the FDA reported in 2024 (openFDA recall enforcement reports). PK recall_number. A recall report is the record of a firm''s action, not medical advice.';
COMMENT ON COLUMN FDA_RECALLS.RECALL_NUMBER IS 'FDA recall number (PK), e.g. F-1671-2024';
COMMENT ON COLUMN FDA_RECALLS.EVENT_ID IS 'Recall event; one event can cover several recalled products';
COMMENT ON COLUMN FDA_RECALLS.PRODUCT_TYPE IS 'Food, Drugs or Devices';
COMMENT ON COLUMN FDA_RECALLS.RECALLING_FIRM IS 'The firm that recalled the product';
COMMENT ON COLUMN FDA_RECALLS.FIRM_STATE IS 'The firm''s U.S. state (two letters) or a foreign region; NULL when openFDA gives none (its N/A included)';
COMMENT ON COLUMN FDA_RECALLS.FIRM_COUNTRY IS 'The firm''s country, e.g. United States, China, India';
COMMENT ON COLUMN FDA_RECALLS.VOLUNTARY_MANDATED IS 'Voluntary: Firm initiated or FDA Mandated; NULL when openFDA gives none (its N/A included)';
COMMENT ON COLUMN FDA_RECALLS.INITIAL_NOTIFICATION IS 'How the firm first told its customers: Letter, E-Mail, Telephone, Press Release, Visit, Other, or Two or more of the following: Email, Fax, Letter, Press Release, Telephone, Visit; NULL when openFDA gives none (its N/A included)';
COMMENT ON COLUMN FDA_RECALLS.RECALL_STATUS IS 'Ongoing, Completed or Terminated';
COMMENT ON COLUMN FDA_RECALLS.DISTRIBUTION_PATTERN IS 'Where the product went, in the FDA''s words (free text, cut on a word at 400 characters, ending in …)';
COMMENT ON COLUMN FDA_RECALLS.PRODUCT_DESCRIPTION IS 'The recalled product, in the FDA''s words (free text, cut on a word at 600 characters, ending in …)';
COMMENT ON COLUMN FDA_RECALLS.REASON_FOR_RECALL IS 'Why it was recalled (free text, cut on a word at 600 characters, ending in …): the text the notebooks classify';
COMMENT ON COLUMN FDA_RECALLS.RECALL_INITIATION_DATE IS 'When the firm started the recall';
COMMENT ON COLUMN FDA_RECALLS.REPORT_DATE IS 'When the FDA published the recall in its enforcement report';
COMMENT ON COLUMN FDA_RECALLS.SERIOUS IS '1 when the FDA classified the recall Class I (a reasonable probability of serious harm), else 0: the label';
COMMENT ON TABLE  FDA_CLASSIFICATIONS IS 'The FDA classification of each recall: Class I (serious harm likely), II (temporary or reversible harm), III (harm unlikely). The label''s source - for reading, never a feature.';
COMMENT ON COLUMN FDA_CLASSIFICATIONS.RECALL_NUMBER IS 'FDA recall number (PK; refers to FDA_RECALLS)';
COMMENT ON COLUMN FDA_CLASSIFICATIONS.CLASSIFICATION IS 'Class I, Class II or Class III';
COMMENT ON COLUMN FDA_CLASSIFICATIONS.CLASSIFICATION_DATE IS 'When the FDA classified it';
