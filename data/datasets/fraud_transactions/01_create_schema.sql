-- 01_create_schema.sql - card and bank transactions with a fraud label (the Kaggle "Fraud Detection Dataset").
-- Loads into its own FRAUD schema; the dedicated read-only MCP user reads it via database-wide
-- read (USE ANY SCHEMA + SELECT ANY TABLE), no per-schema grant.
-- Where it came from and its licence: README.md and manifest.json.
--
-- Messy on purpose: 1,000 transaction IDs occur twice, about 5% of five columns are NULL, and
-- 'Unknown Device' / 'Invalid Method' stand in for unknowns. The kit keeps them, so the Data
-- Scientist's Prepare and Validate steps have something real to find (README.md, "What to clean").
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- exakit data-load --force) without manual cleanup.

CREATE SCHEMA IF NOT EXISTS FRAUD;
OPEN SCHEMA FRAUD;

-- transactions (one row per line of the source file, from data/transactions.csv). PK: row_id.
CREATE OR REPLACE TABLE TRANSACTIONS (
    ROW_ID                           DECIMAL(6,0)   NOT NULL,   -- the line of the source file (the kit's key)
    TRANSACTION_ID                   VARCHAR(10)    NOT NULL,   -- the source's id, T1 to T50000 - NOT unique
    USER_ID                          DECIMAL(5,0)   NOT NULL,   -- the customer, 4,000 of them
    TRANSACTION_AMOUNT               DECIMAL(10,2),             -- US dollars; NULL in about 5% of rows
    TRANSACTION_TYPE                 VARCHAR(20)    NOT NULL,   -- ATM Withdrawal, Bill Payment, Bank Transfer, ...
    TRANSACTION_HOUR                 DECIMAL(2,0),              -- hour of day, 0 to 23 (there is no date); NULL in about 5%
    DEVICE_USED                      VARCHAR(20),               -- Desktop, Mobile, Tablet, or 'Unknown Device'; NULL in about 5%
    LOCATION                         VARCHAR(20),               -- the city; NULL in about 5%
    PREVIOUS_FRAUDULENT_TRANSACTIONS DECIMAL(2,0)   NOT NULL,   -- the user's earlier fraud count, 0 to 4
    ACCOUNT_AGE                      DECIMAL(4,0)   NOT NULL,   -- account age, 1 to 119 (the source gives no unit)
    TRANSACTIONS_LAST_24H            DECIMAL(3,0)   NOT NULL,   -- the user's transactions in the 24 hours before
    PAYMENT_METHOD                   VARCHAR(20),               -- UPI, Debit Card, ..., or 'Invalid Method'; NULL in about 5%
    FRAUDULENT                       DECIMAL(1,0)   NOT NULL,   -- 1 when the transaction was fraud: the label
    CONSTRAINT TRANSACTIONS_PK PRIMARY KEY (ROW_ID)
);

-- Semantics travel WITH the tables (see the note in tpch/01_create_schema.sql):
-- the MCP describe path reads these comments. COMMENT is idempotent.

COMMENT ON TABLE  TRANSACTIONS IS 'Card and bank transactions of 4,000 users with a fraud label (Kaggle, Fraud Detection Dataset; licence not confirmed). PK row_id; TRANSACTION_ID repeats for 1,000 transactions; FRAUDULENT is the label; there is no date, only TRANSACTION_HOUR.';
COMMENT ON COLUMN TRANSACTIONS.ROW_ID IS 'The line of the source file (PK, added by the kit because TRANSACTION_ID is not unique)';
COMMENT ON COLUMN TRANSACTIONS.TRANSACTION_ID IS 'The source''s transaction id; 1,000 of them occur twice (881 as exact copies)';
COMMENT ON COLUMN TRANSACTIONS.USER_ID IS 'The customer, 4,000 of them';
COMMENT ON COLUMN TRANSACTIONS.TRANSACTION_AMOUNT IS 'Amount in US dollars; NULL in about 5% of rows';
COMMENT ON COLUMN TRANSACTIONS.TRANSACTION_TYPE IS 'ATM Withdrawal, Bank Transfer, Bill Payment, Online Purchase or POS Payment';
COMMENT ON COLUMN TRANSACTIONS.TRANSACTION_HOUR IS 'Hour of day, 0 to 23 (the source has no date); NULL in about 5% of rows';
COMMENT ON COLUMN TRANSACTIONS.DEVICE_USED IS 'Desktop, Mobile, Tablet, or the placeholder Unknown Device; NULL in about 5% of rows';
COMMENT ON COLUMN TRANSACTIONS.LOCATION IS 'The city of the transaction; NULL in about 5% of rows';
COMMENT ON COLUMN TRANSACTIONS.PREVIOUS_FRAUDULENT_TRANSACTIONS IS 'How many earlier transactions of this user were fraud, 0 to 4';
COMMENT ON COLUMN TRANSACTIONS.ACCOUNT_AGE IS 'Age of the account, 1 to 119 (the source gives no unit)';
COMMENT ON COLUMN TRANSACTIONS.TRANSACTIONS_LAST_24H IS 'How many transactions the user made in the 24 hours before this one';
COMMENT ON COLUMN TRANSACTIONS.PAYMENT_METHOD IS 'UPI, Debit Card, Credit Card, Net Banking, or the placeholder Invalid Method; NULL in about 5% of rows';
COMMENT ON COLUMN TRANSACTIONS.FRAUDULENT IS '1 when the transaction was fraud, else 0: the label (4.9% of rows)';
