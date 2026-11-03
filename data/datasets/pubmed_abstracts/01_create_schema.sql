-- 01_create_schema.sql - PubMed abstracts of clinical studies, the input for medical text extraction.
-- Loads into its own PUBMED schema; the dedicated read-only MCP user reads it via database-wide read
-- (USE ANY SCHEMA + SELECT ANY TABLE), no per-schema grant.
-- Where it came from and its terms: README.md and manifest.json.
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- exakit data-load --force) without manual cleanup.

CREATE SCHEMA IF NOT EXISTS PUBMED;
OPEN SCHEMA PUBMED;

-- pubmed_abstracts (one row per abstract, from data/pubmed_abstracts.csv). PK: abstract_id.
CREATE OR REPLACE TABLE PUBMED_ABSTRACTS (
    ABSTRACT_ID    DECIMAL(5,0)   NOT NULL,
    FIRST_SECTION  VARCHAR(40),              -- the opening heading (BACKGROUND, OBJECTIVE, ...); empty when unstructured
    WORD_COUNT     DECIMAL(5,0)   NOT NULL,
    ABSTRACT_TEXT  VARCHAR(8000)  NOT NULL,
    CONSTRAINT PUBMED_ABSTRACTS_PK PRIMARY KEY (ABSTRACT_ID)
);

-- Semantics travel WITH the tables (see the note in tpch/01_create_schema.sql):
-- the MCP describe path reads these comments. COMMENT is idempotent.

COMMENT ON TABLE  PUBMED_ABSTRACTS IS 'Abstracts of clinical studies as published in PubMed, one per row. PK abstract_id.';
COMMENT ON COLUMN PUBMED_ABSTRACTS.ABSTRACT_ID IS 'Abstract id (PK)';
COMMENT ON COLUMN PUBMED_ABSTRACTS.FIRST_SECTION IS 'The heading the abstract opens with (BACKGROUND, OBJECTIVE, ...); empty for an unstructured abstract';
COMMENT ON COLUMN PUBMED_ABSTRACTS.WORD_COUNT IS 'Words in the abstract';
COMMENT ON COLUMN PUBMED_ABSTRACTS.ABSTRACT_TEXT IS 'The abstract, as published';
