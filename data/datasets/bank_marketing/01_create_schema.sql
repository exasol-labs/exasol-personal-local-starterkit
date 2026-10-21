-- 01_create_schema.sql - bank marketing (the UCI Machine Learning Repository's Bank Marketing set).
-- Loads into its own BANKMKT schema (BANKING holds the CFPB complaints); the dedicated read-only
-- MCP user reads it via database-wide read (USE ANY SCHEMA + SELECT ANY TABLE), no per-schema grant.
-- Where it came from and its licence: README.md and manifest.json.
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- exakit data-load --force) without manual cleanup.

CREATE SCHEMA IF NOT EXISTS BANKMKT;
OPEN SCHEMA BANKMKT;

-- bank_clients (one row per client the campaign phoned, from data/bank_clients.csv). PK: client_id.
CREATE OR REPLACE TABLE BANK_CLIENTS (
    CLIENT_ID           DECIMAL(6,0)  NOT NULL,
    AGE                 DECIMAL(3,0)  NOT NULL,
    JOB                 VARCHAR(20)   NOT NULL,   -- admin., blue-collar, management, ... unknown
    MARITAL             VARCHAR(10)   NOT NULL,   -- married / single / divorced (divorced includes widowed)
    EDUCATION           VARCHAR(10)   NOT NULL,   -- primary / secondary / tertiary / unknown
    CREDIT_IN_DEFAULT   DECIMAL(1,0)  NOT NULL,   -- 1 when the client has credit in default
    BALANCE             DECIMAL(9,0)  NOT NULL,   -- average yearly balance, euros
    HOUSING_LOAN        DECIMAL(1,0)  NOT NULL,
    PERSONAL_LOAN       DECIMAL(1,0)  NOT NULL,
    CONTACT_TYPE        VARCHAR(10)   NOT NULL,   -- cellular / telephone / unknown
    LAST_CONTACT_DAY    DECIMAL(2,0)  NOT NULL,   -- day of the month of the last contact
    LAST_CONTACT_MONTH  VARCHAR(3)    NOT NULL,   -- jan .. dec
    CALL_DURATION       DECIMAL(6,0)  NOT NULL,   -- seconds of the last call: known only after the call, so not a feature
    CAMPAIGN_CONTACTS   DECIMAL(3,0)  NOT NULL,   -- contacts in this campaign, the last one included
    DAYS_SINCE_PREVIOUS DECIMAL(4,0)  NOT NULL,   -- days since a previous campaign's contact; -1 when never contacted
    PREVIOUS_CONTACTS   DECIMAL(4,0)  NOT NULL,   -- contacts before this campaign
    PREVIOUS_OUTCOME    VARCHAR(10)   NOT NULL,   -- success / failure / other / unknown
    SUBSCRIBED          DECIMAL(1,0)  NOT NULL,   -- 1 when the client subscribed a term deposit: the label
    CONSTRAINT BANK_CLIENTS_PK PRIMARY KEY (CLIENT_ID)
);

COMMENT ON TABLE  BANK_CLIENTS IS 'Clients a Portuguese bank phoned in its term-deposit campaigns, May 2008 - Nov 2010 (Moro, Rita and Cortez 2014, UCI Bank Marketing, CC BY 4.0). PK client_id; SUBSCRIBED is the label.';
COMMENT ON COLUMN BANK_CLIENTS.CLIENT_ID IS 'Row number (PK)';
COMMENT ON COLUMN BANK_CLIENTS.BALANCE IS 'Average yearly balance in euros';
COMMENT ON COLUMN BANK_CLIENTS.CALL_DURATION IS 'Seconds of the last call. Known only after the call ends and strongly tied to the outcome: leave it out of a model meant to choose whom to call';
COMMENT ON COLUMN BANK_CLIENTS.DAYS_SINCE_PREVIOUS IS 'Days since the client was last contacted in a previous campaign; -1 when never';
COMMENT ON COLUMN BANK_CLIENTS.SUBSCRIBED IS '1 when the client subscribed a term deposit, else 0: the label';
