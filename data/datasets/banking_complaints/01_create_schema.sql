-- 01_create_schema.sql - banking complaints (a CFPB Consumer Complaint Database snapshot).
-- Loads into its own BANKING schema; the dedicated read-only MCP user reads it
-- via database-wide read (USE ANY SCHEMA + SELECT ANY TABLE), no per-schema
-- grant. Tables keep the BANKING_ prefix so fully-qualified names stay clear.
-- What the snapshot holds and where it came from: README.md and manifest.json.
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- exakit data-load --force) without manual cleanup.

CREATE SCHEMA IF NOT EXISTS BANKING;
OPEN SCHEMA BANKING;

-- banking_complaints (one row per complaint, from data/banking_complaints.csv). PK: complaint_id.
CREATE OR REPLACE TABLE BANKING_COMPLAINTS (
    COMPLAINT_ID            DECIMAL(12,0) NOT NULL,
    DATE_RECEIVED           DATE          NOT NULL,
    DATE_SENT_TO_COMPANY    DATE,
    PRODUCT                 VARCHAR(60)   NOT NULL,   -- Credit card / Mortgage / Checking or savings account
    SUB_PRODUCT             VARCHAR(100),
    ISSUE                   VARCHAR(120)  NOT NULL,
    SUB_ISSUE               VARCHAR(200),
    COMPANY                 VARCHAR(200)  NOT NULL,
    CONSUMER_STATE          VARCHAR(2),
    SUBMITTED_VIA           VARCHAR(20)   NOT NULL,
    TAGS                    VARCHAR(40),              -- Servicemember / Older American, when the consumer said so
    TIMELY                  DECIMAL(1,0)  NOT NULL,   -- 1 when the company answered in time
    MONETARY_RELIEF         DECIMAL(1,0)  NOT NULL,   -- 1 when closed with monetary relief: the label
    COMPANY_PUBLIC_RESPONSE VARCHAR(300),
    CONSTRAINT BANKING_COMPLAINTS_PK PRIMARY KEY (COMPLAINT_ID)
);

-- banking_responses (how the company closed each complaint). Kept apart from
-- banking_complaints: the label is derived from it, so it is for reading, never a model feature.
-- FK (documented, not enforced): complaint_id -> banking_complaints.
CREATE OR REPLACE TABLE BANKING_RESPONSES (
    COMPLAINT_ID     DECIMAL(12,0) NOT NULL,
    COMPANY_RESPONSE VARCHAR(60)   NOT NULL,
    CONSTRAINT BANKING_RESPONSES_PK PRIMARY KEY (COMPLAINT_ID)
);

-- Semantics travel WITH the tables (see the note in tpch/01_create_schema.sql):
-- the MCP describe path reads these comments. COMMENT is idempotent.

COMMENT ON TABLE  BANKING_COMPLAINTS IS 'Consumer complaints about credit cards, mortgages and checking or savings accounts received by the CFPB 2025-01-01..2025-01-14. PK complaint_id. A complaint is not a finding against the company.';
COMMENT ON COLUMN BANKING_COMPLAINTS.COMPLAINT_ID IS 'CFPB complaint id (PK)';
COMMENT ON COLUMN BANKING_COMPLAINTS.DATE_RECEIVED IS 'Date the CFPB received the complaint';
COMMENT ON COLUMN BANKING_COMPLAINTS.DATE_SENT_TO_COMPANY IS 'Date the CFPB sent it to the company';
COMMENT ON COLUMN BANKING_COMPLAINTS.PRODUCT IS 'Product: Credit card, Mortgage, or Checking or savings account';
COMMENT ON COLUMN BANKING_COMPLAINTS.SUB_PRODUCT IS 'Sub-product the consumer chose';
COMMENT ON COLUMN BANKING_COMPLAINTS.ISSUE IS 'Issue the consumer chose';
COMMENT ON COLUMN BANKING_COMPLAINTS.SUB_ISSUE IS 'Sub-issue the consumer chose';
COMMENT ON COLUMN BANKING_COMPLAINTS.COMPANY IS 'Company the complaint is about';
COMMENT ON COLUMN BANKING_COMPLAINTS.CONSUMER_STATE IS 'U.S. state of the consumer (two letters)';
COMMENT ON COLUMN BANKING_COMPLAINTS.SUBMITTED_VIA IS 'Channel: Web, Phone, Referral, ...';
COMMENT ON COLUMN BANKING_COMPLAINTS.TAGS IS 'Servicemember and/or Older American, when given';
COMMENT ON COLUMN BANKING_COMPLAINTS.TIMELY IS '1 when the company responded in time';
COMMENT ON COLUMN BANKING_COMPLAINTS.MONETARY_RELIEF IS '1 when the complaint was closed with monetary relief, else 0 (the label to predict)';
COMMENT ON COLUMN BANKING_COMPLAINTS.COMPANY_PUBLIC_RESPONSE IS 'The company''s optional public response (one of a few set phrases)';
COMMENT ON TABLE  BANKING_RESPONSES IS 'How the company closed each complaint. The label is derived from it: read it, never use it as a feature.';
COMMENT ON COLUMN BANKING_RESPONSES.COMPLAINT_ID IS 'Complaint (FK to banking_complaints)';
COMMENT ON COLUMN BANKING_RESPONSES.COMPANY_RESPONSE IS 'Closed with explanation / non-monetary relief / monetary relief, or Untimely response';
