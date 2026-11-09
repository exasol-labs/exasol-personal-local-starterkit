-- 01_create_schema.sql - Amazon sales (the Kaggle "Amazon Sale Report": one fashion seller on Amazon.in).
-- Loads into its own AMAZON schema; the dedicated read-only MCP user reads it via database-wide
-- read (USE ANY SCHEMA + SELECT ANY TABLE), no per-schema grant.
-- Where it came from and its licence: README.md and manifest.json.
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- exakit data-load --force) without manual cleanup.

CREATE SCHEMA IF NOT EXISTS AMAZON;
OPEN SCHEMA AMAZON;

-- order_lines (one row per order line, from data/order_lines.csv). PK: order_line_id.
CREATE OR REPLACE TABLE ORDER_LINES (
    ORDER_LINE_ID      DECIMAL(6,0)  NOT NULL,
    ORDER_ID           VARCHAR(19)   NOT NULL,   -- one order can have several lines
    ORDER_DATE         DATE          NOT NULL,
    STATUS             VARCHAR(30)   NOT NULL,   -- Shipped, Cancelled, Shipped - Delivered to Buyer, ...
    FULFILMENT         VARCHAR(8)    NOT NULL,   -- Amazon or Merchant
    SALES_CHANNEL      VARCHAR(10)   NOT NULL,   -- Amazon.in or Non-Amazon
    SHIP_SERVICE_LEVEL VARCHAR(9)    NOT NULL,   -- Expedited or Standard
    STYLE_CODE         VARCHAR(8)    NOT NULL,   -- the seller's style (STYLE is a reserved word)
    SKU                VARCHAR(30)   NOT NULL,
    CATEGORY           VARCHAR(13)   NOT NULL,   -- Set, kurta, Western Dress, Top, ...
    SIZE               VARCHAR(4)    NOT NULL,
    ASIN               VARCHAR(10)   NOT NULL,   -- Amazon's product number
    COURIER_STATUS     VARCHAR(9),               -- Shipped, Unshipped, Cancelled; empty when unknown
    QTY                DECIMAL(3,0)  NOT NULL,
    CURRENCY           VARCHAR(3),               -- INR; empty with the amount
    AMOUNT             DECIMAL(9,2),             -- the line's amount in rupees; empty for some cancelled lines
    SHIP_CITY          VARCHAR(50),
    SHIP_STATE         VARCHAR(25),
    SHIP_POSTAL_CODE   VARCHAR(6),
    SHIP_COUNTRY       VARCHAR(2),
    HAS_PROMOTION      DECIMAL(1,0)  NOT NULL,   -- 1 when the line carried a promotion
    IS_B2B             DECIMAL(1,0)  NOT NULL,   -- 1 for a business customer
    FULFILLED_BY       VARCHAR(9),               -- Easy Ship, or empty
    CANCELLED          DECIMAL(1,0)  NOT NULL,   -- 1 when STATUS is Cancelled: the label
    CONSTRAINT ORDER_LINES_PK PRIMARY KEY (ORDER_LINE_ID)
);

-- Semantics travel WITH the tables (see the note in tpch/01_create_schema.sql):
-- the MCP describe path reads these comments. COMMENT is idempotent.

COMMENT ON TABLE  ORDER_LINES IS 'Order lines of one fashion seller on Amazon.in, March 31 - June 29 2022 (Kaggle, Amazon Sale Report; licence not confirmed). PK order_line_id; CANCELLED is the label.';
COMMENT ON COLUMN ORDER_LINES.ORDER_LINE_ID IS 'Row number in the source file, from 1 (PK)';
COMMENT ON COLUMN ORDER_LINES.ORDER_ID IS 'Amazon order number; an order can have several lines';
COMMENT ON COLUMN ORDER_LINES.ORDER_DATE IS 'Day the order was placed';
COMMENT ON COLUMN ORDER_LINES.STATUS IS 'Where the order stands: Shipped, Cancelled, Shipped - Delivered to Buyer, Shipped - Returned to Seller and nine more';
COMMENT ON COLUMN ORDER_LINES.FULFILMENT IS 'Who ships it: Amazon or Merchant';
COMMENT ON COLUMN ORDER_LINES.SALES_CHANNEL IS 'Amazon.in or Non-Amazon';
COMMENT ON COLUMN ORDER_LINES.SHIP_SERVICE_LEVEL IS 'Expedited or Standard';
COMMENT ON COLUMN ORDER_LINES.STYLE_CODE IS 'The seller''s style code';
COMMENT ON COLUMN ORDER_LINES.SKU IS 'Stock keeping unit: style, colour and size';
COMMENT ON COLUMN ORDER_LINES.CATEGORY IS 'Product category: Set, kurta, Western Dress, Top and five more';
COMMENT ON COLUMN ORDER_LINES.SIZE IS 'Garment size, XS to 6XL or Free';
COMMENT ON COLUMN ORDER_LINES.ASIN IS 'Amazon Standard Identification Number of the product';
COMMENT ON COLUMN ORDER_LINES.COURIER_STATUS IS 'Shipped, Unshipped or Cancelled; NULL when not given. Known only after the order moves: leave it out of a model of cancellations';
COMMENT ON COLUMN ORDER_LINES.QTY IS 'Units ordered; 0 on most cancelled lines, so leave it out of a model of cancellations';
COMMENT ON COLUMN ORDER_LINES.CURRENCY IS 'INR; NULL with the amount';
COMMENT ON COLUMN ORDER_LINES.AMOUNT IS 'Amount of the line in Indian rupees; NULL for some cancelled lines';
COMMENT ON COLUMN ORDER_LINES.SHIP_CITY IS 'City shipped to, upper case';
COMMENT ON COLUMN ORDER_LINES.SHIP_STATE IS 'Indian state shipped to, upper case';
COMMENT ON COLUMN ORDER_LINES.SHIP_POSTAL_CODE IS 'PIN code shipped to';
COMMENT ON COLUMN ORDER_LINES.SHIP_COUNTRY IS 'Country shipped to (IN)';
COMMENT ON COLUMN ORDER_LINES.HAS_PROMOTION IS '1 when the line carried a promotion';
COMMENT ON COLUMN ORDER_LINES.IS_B2B IS '1 when the buyer is a business';
COMMENT ON COLUMN ORDER_LINES.FULFILLED_BY IS 'Easy Ship for merchant-fulfilled lines, else NULL';
COMMENT ON COLUMN ORDER_LINES.CANCELLED IS '1 when the order was cancelled (STATUS = Cancelled), else 0: the label';
