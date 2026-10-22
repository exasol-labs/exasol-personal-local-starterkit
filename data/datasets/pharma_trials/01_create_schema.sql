-- 01_create_schema.sql - pharma clinical trials (a ClinicalTrials.gov snapshot).
-- Loads into its own PHARMA schema; the dedicated read-only MCP user reads it
-- via database-wide read (USE ANY SCHEMA + SELECT ANY TABLE), no per-schema
-- grant. Tables keep the PHARMA_ prefix so fully-qualified names stay clear.
-- What the snapshot holds and where it came from: README.md and manifest.json.
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- exakit data-load --force) without manual cleanup.

CREATE SCHEMA IF NOT EXISTS PHARMA;
OPEN SCHEMA PHARMA;

-- pharma_trials (one row per trial, from data/pharma_trials.csv). PK: nct_id.
CREATE OR REPLACE TABLE PHARMA_TRIALS (
    NCT_ID                  VARCHAR(11)   NOT NULL,
    BRIEF_TITLE             VARCHAR(400)  NOT NULL,
    PHASE                   VARCHAR(20)   NOT NULL,   -- PHASE2, PHASE3, PHASE1/PHASE2, PHASE2/PHASE3
    OVERALL_STATUS          VARCHAR(12)   NOT NULL,   -- COMPLETED / TERMINATED
    TERMINATED              DECIMAL(1,0)  NOT NULL,   -- 1 when the trial was terminated early: the label
    START_DATE              DATE          NOT NULL,
    PRIMARY_COMPLETION_DATE DATE,
    ENROLLMENT              DECIMAL(9,0),
    LEAD_SPONSOR            VARCHAR(200)  NOT NULL,
    ALLOCATION              VARCHAR(20),
    PRIMARY_PURPOSE         VARCHAR(40),
    MASKING                 VARCHAR(12),
    HAS_RESULTS             DECIMAL(1,0)  NOT NULL,
    BRIEF_SUMMARY           VARCHAR(2100) NOT NULL,
    ELIGIBILITY_CRITERIA    VARCHAR(2100),            -- who may take part; empty when a record has no criteria
    CONSTRAINT PHARMA_TRIALS_PK PRIMARY KEY (NCT_ID)
);

-- pharma_sponsors (who runs and who helps run a trial: the lead sponsor, then the collaborators).
-- FK (documented, not enforced): nct_id -> pharma_trials. LEAD_SPONSOR in pharma_trials is its SEQ 1 row.
CREATE OR REPLACE TABLE PHARMA_SPONSORS (
    NCT_ID        VARCHAR(11)  NOT NULL,
    SEQ           DECIMAL(4,0) NOT NULL,
    SPONSOR_ROLE  VARCHAR(12)  NOT NULL,   -- LEAD / COLLABORATOR
    SPONSOR_NAME  VARCHAR(200) NOT NULL,
    SPONSOR_CLASS VARCHAR(12),             -- INDUSTRY, NIH, FED, OTHER_GOV, INDIV, NETWORK, AMBIG, OTHER, UNKNOWN
    CONSTRAINT PHARMA_SPONSORS_PK PRIMARY KEY (NCT_ID, SEQ)
);

-- pharma_conditions (the conditions a trial studies). FK (documented, not enforced): nct_id -> pharma_trials.
CREATE OR REPLACE TABLE PHARMA_CONDITIONS (
    NCT_ID         VARCHAR(11)  NOT NULL,
    CONDITION_NAME VARCHAR(200) NOT NULL,
    CONSTRAINT PHARMA_CONDITIONS_PK PRIMARY KEY (NCT_ID, CONDITION_NAME)
);

-- pharma_interventions (the drugs, devices and procedures a trial tests, in protocol order).
CREATE OR REPLACE TABLE PHARMA_INTERVENTIONS (
    NCT_ID            VARCHAR(11)  NOT NULL,
    SEQ               DECIMAL(4,0) NOT NULL,
    INTERVENTION_TYPE VARCHAR(30)  NOT NULL,
    INTERVENTION_NAME VARCHAR(200),
    CONSTRAINT PHARMA_INTERVENTIONS_PK PRIMARY KEY (NCT_ID, SEQ)
);

-- pharma_stop_reasons (why a trial stopped, as the sponsor wrote it). Kept apart from
-- pharma_trials: it gives the label away, so it is for reading, never a model feature.
CREATE OR REPLACE TABLE PHARMA_STOP_REASONS (
    NCT_ID      VARCHAR(11)  NOT NULL,
    WHY_STOPPED VARCHAR(600) NOT NULL,
    CONSTRAINT PHARMA_STOP_REASONS_PK PRIMARY KEY (NCT_ID)
);

-- Semantics travel WITH the tables (see the note in tpch/01_create_schema.sql):
-- the MCP describe path reads these comments. COMMENT is idempotent.

COMMENT ON TABLE  PHARMA_TRIALS IS 'Industry-sponsored interventional Phase 2/3 trials started 2016-2018 that completed or were terminated (ClinicalTrials.gov snapshot). PK nct_id.';
COMMENT ON COLUMN PHARMA_TRIALS.NCT_ID IS 'ClinicalTrials.gov identifier (PK)';
COMMENT ON COLUMN PHARMA_TRIALS.BRIEF_TITLE IS 'Short title of the trial';
COMMENT ON COLUMN PHARMA_TRIALS.PHASE IS 'Trial phase: PHASE2, PHASE3, PHASE1/PHASE2 or PHASE2/PHASE3';
COMMENT ON COLUMN PHARMA_TRIALS.OVERALL_STATUS IS 'How the trial ended: COMPLETED or TERMINATED';
COMMENT ON COLUMN PHARMA_TRIALS.TERMINATED IS '1 when the trial was terminated early, else 0 (the label to predict)';
COMMENT ON COLUMN PHARMA_TRIALS.START_DATE IS 'Start date (the first of the month when only the month is published)';
COMMENT ON COLUMN PHARMA_TRIALS.PRIMARY_COMPLETION_DATE IS 'Primary completion date, actual or as last reported';
COMMENT ON COLUMN PHARMA_TRIALS.ENROLLMENT IS 'Participants enrolled (actual for ended trials)';
COMMENT ON COLUMN PHARMA_TRIALS.LEAD_SPONSOR IS 'Lead sponsor (the company running the trial)';
COMMENT ON COLUMN PHARMA_TRIALS.ALLOCATION IS 'RANDOMIZED, NON_RANDOMIZED or NA';
COMMENT ON COLUMN PHARMA_TRIALS.PRIMARY_PURPOSE IS 'Primary purpose, e.g. TREATMENT, PREVENTION';
COMMENT ON COLUMN PHARMA_TRIALS.MASKING IS 'Blinding: NONE, SINGLE, DOUBLE, TRIPLE or QUADRUPLE';
COMMENT ON COLUMN PHARMA_TRIALS.HAS_RESULTS IS '1 when results are posted on ClinicalTrials.gov';
COMMENT ON COLUMN PHARMA_TRIALS.BRIEF_SUMMARY IS 'Brief summary of the trial (whitespace folded; a longer one is cut on a word and ends in …, at most 2000 characters)';
COMMENT ON COLUMN PHARMA_TRIALS.ELIGIBILITY_CRITERIA IS 'Inclusion and exclusion criteria (whitespace folded; longer ones are cut on a word and end in …, at most 2000 characters)';
COMMENT ON TABLE  PHARMA_SPONSORS IS 'Who runs a trial: the lead sponsor (SEQ 1), then its collaborators. PK (nct_id, seq).';
COMMENT ON COLUMN PHARMA_SPONSORS.NCT_ID IS 'Trial (FK to pharma_trials)';
COMMENT ON COLUMN PHARMA_SPONSORS.SEQ IS '1 for the lead sponsor, then the collaborators in record order';
COMMENT ON COLUMN PHARMA_SPONSORS.SPONSOR_ROLE IS 'LEAD or COLLABORATOR';
COMMENT ON COLUMN PHARMA_SPONSORS.SPONSOR_NAME IS 'Organisation name as the record gives it';
COMMENT ON COLUMN PHARMA_SPONSORS.SPONSOR_CLASS IS 'Organisation class: INDUSTRY, NIH, FED, OTHER_GOV, INDIV, NETWORK, AMBIG, OTHER, UNKNOWN';
COMMENT ON TABLE  PHARMA_CONDITIONS IS 'Conditions a trial studies, one row each. PK (nct_id, condition_name).';
COMMENT ON COLUMN PHARMA_CONDITIONS.NCT_ID IS 'Trial (FK to pharma_trials)';
COMMENT ON COLUMN PHARMA_CONDITIONS.CONDITION_NAME IS 'Condition as the sponsor named it';
COMMENT ON TABLE  PHARMA_INTERVENTIONS IS 'Interventions a trial tests, in protocol order. PK (nct_id, seq).';
COMMENT ON COLUMN PHARMA_INTERVENTIONS.NCT_ID IS 'Trial (FK to pharma_trials)';
COMMENT ON COLUMN PHARMA_INTERVENTIONS.SEQ IS 'Position in the protocol, from 1';
COMMENT ON COLUMN PHARMA_INTERVENTIONS.INTERVENTION_TYPE IS 'DRUG, BIOLOGICAL, DEVICE, PROCEDURE, OTHER, ...';
COMMENT ON COLUMN PHARMA_INTERVENTIONS.INTERVENTION_NAME IS 'Intervention name, e.g. the drug or placebo';
COMMENT ON TABLE  PHARMA_STOP_REASONS IS 'Why a trial stopped, as the sponsor wrote it. Gives the label away: read it, never use it as a feature.';
COMMENT ON COLUMN PHARMA_STOP_REASONS.NCT_ID IS 'Trial (FK to pharma_trials)';
COMMENT ON COLUMN PHARMA_STOP_REASONS.WHY_STOPPED IS 'Reason given for stopping';
