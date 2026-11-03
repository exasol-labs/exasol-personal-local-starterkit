-- 01_create_schema.sql - the ADE corpus (ADE-Corpus-V2: PubMed sentences annotated for adverse drug effects).
-- Loads into its own ADE schema; the dedicated read-only MCP user reads it via database-wide read
-- (USE ANY SCHEMA + SELECT ANY TABLE), no per-schema grant.
-- Where it came from and its terms: README.md and manifest.json.
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- exakit data-load --force) without manual cleanup.

CREATE SCHEMA IF NOT EXISTS ADE;
OPEN SCHEMA ADE;

-- ade_sentences (one row per sentence, from data/ade_sentences.csv). PK: sentence_id.
CREATE OR REPLACE TABLE ADE_SENTENCES (
    SENTENCE_ID  DECIMAL(6,0)   NOT NULL,
    PUBMED_ID    DECIMAL(9,0)   NOT NULL,   -- the PubMed article the sentence is from
    SENTENCE     VARCHAR(1000)  NOT NULL,
    HAS_ADE      DECIMAL(1,0)   NOT NULL,   -- 1 when the sentence reports an adverse drug effect: the label
    CONSTRAINT ADE_SENTENCES_PK PRIMARY KEY (SENTENCE_ID)
);

-- ade_drug_effects (one row per drug and adverse effect named in a sentence). PK: pair_id.
-- FK (documented, not enforced): sentence_id -> ade_sentences.
CREATE OR REPLACE TABLE ADE_DRUG_EFFECTS (
    PAIR_ID         DECIMAL(6,0)  NOT NULL,
    SENTENCE_ID     DECIMAL(6,0)  NOT NULL,
    DRUG            VARCHAR(100)  NOT NULL,
    ADVERSE_EFFECT  VARCHAR(200)  NOT NULL,
    CONSTRAINT ADE_DRUG_EFFECTS_PK PRIMARY KEY (PAIR_ID)
);

-- ade_drug_doses (one row per drug and dose named in a sentence). PK: pair_id.
-- FK (documented, not enforced): sentence_id -> ade_sentences.
CREATE OR REPLACE TABLE ADE_DRUG_DOSES (
    PAIR_ID      DECIMAL(6,0)  NOT NULL,
    SENTENCE_ID  DECIMAL(6,0)  NOT NULL,
    DRUG         VARCHAR(100)  NOT NULL,
    DOSE         VARCHAR(100)  NOT NULL,
    CONSTRAINT ADE_DRUG_DOSES_PK PRIMARY KEY (PAIR_ID)
);

-- Semantics travel WITH the tables (see the note in tpch/01_create_schema.sql):
-- the MCP describe path reads these comments. COMMENT is idempotent.

COMMENT ON TABLE  ADE_SENTENCES IS 'Sentences from PubMed case-report abstracts, each annotated for an adverse drug effect (ADE-Corpus-V2). PK sentence_id. HAS_ADE is the label.';
COMMENT ON COLUMN ADE_SENTENCES.SENTENCE_ID IS 'Sentence id (PK)';
COMMENT ON COLUMN ADE_SENTENCES.PUBMED_ID IS 'PubMed id of the article the sentence is from';
COMMENT ON COLUMN ADE_SENTENCES.SENTENCE IS 'The sentence, as published';
COMMENT ON COLUMN ADE_SENTENCES.HAS_ADE IS '1 when the sentence reports an adverse drug effect, else 0 (the label to predict)';
COMMENT ON TABLE  ADE_DRUG_EFFECTS IS 'The drug and the adverse effect each positive sentence names. Derived from the label: read it, never use it as a feature.';
COMMENT ON COLUMN ADE_DRUG_EFFECTS.PAIR_ID IS 'Pair id (PK)';
COMMENT ON COLUMN ADE_DRUG_EFFECTS.SENTENCE_ID IS 'Sentence (FK to ade_sentences)';
COMMENT ON COLUMN ADE_DRUG_EFFECTS.DRUG IS 'Drug, as written in the sentence';
COMMENT ON COLUMN ADE_DRUG_EFFECTS.ADVERSE_EFFECT IS 'Adverse effect, as written in the sentence';
COMMENT ON TABLE  ADE_DRUG_DOSES IS 'The drug and the dose a sentence names, where it names one.';
COMMENT ON COLUMN ADE_DRUG_DOSES.PAIR_ID IS 'Pair id (PK)';
COMMENT ON COLUMN ADE_DRUG_DOSES.SENTENCE_ID IS 'Sentence (FK to ade_sentences)';
COMMENT ON COLUMN ADE_DRUG_DOSES.DRUG IS 'Drug, as written in the sentence';
COMMENT ON COLUMN ADE_DRUG_DOSES.DOSE IS 'Dose, as written in the sentence';
