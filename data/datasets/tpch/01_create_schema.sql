-- 01_create_schema.sql - sample dataset schema (TPC-H, SF=0.02).
-- Run by setup/load-data.sh via exapump before the CSV files in data/ are
-- loaded. Column order in every table matches the header row of the
-- matching data/<table>.csv exactly, and column types match the "Type"
-- column in data/data-dictionary.md. Column widths follow the standard
-- TPC-H spec.
--
-- Idempotent: CREATE OR REPLACE TABLE means this can be re-run (e.g. via
-- setup/load-data.sh --force) without manual cleanup. Tables are created in
-- dependency order (region -> nation -> ... -> lineitem); primary keys are
-- declared, foreign keys are documented in comments and in
-- data/data-dictionary.md rather than enforced, so re-running this script
-- never fails on constraint drop-order (dropping a table that a FOREIGN KEY
-- elsewhere points at would otherwise block CREATE OR REPLACE).

CREATE SCHEMA IF NOT EXISTS TPCH;
OPEN SCHEMA TPCH;

-- region (5 rows). PK: r_regionkey.
CREATE OR REPLACE TABLE REGION (
    r_regionkey  INTEGER NOT NULL,
    r_name       VARCHAR(25),
    r_comment    VARCHAR(152),
    CONSTRAINT region_pk PRIMARY KEY (r_regionkey)
);

-- nation (25 rows). PK: n_nationkey. FK (documented only): n_regionkey -> region.
CREATE OR REPLACE TABLE NATION (
    n_nationkey  INTEGER NOT NULL,
    n_name       VARCHAR(25),
    n_regionkey  INTEGER,
    n_comment    VARCHAR(152),
    CONSTRAINT nation_pk PRIMARY KEY (n_nationkey)
);

-- customer (3,000 rows). PK: c_custkey. FK (documented only): c_nationkey -> nation.
CREATE OR REPLACE TABLE CUSTOMER (
    c_custkey     INTEGER NOT NULL,
    c_name        VARCHAR(25),
    c_address     VARCHAR(40),
    c_nationkey   INTEGER,
    c_phone       VARCHAR(15),
    c_acctbal     DECIMAL(15,2),
    c_mktsegment  VARCHAR(10),
    c_comment     VARCHAR(117),
    CONSTRAINT customer_pk PRIMARY KEY (c_custkey)
);

-- supplier (200 rows). PK: s_suppkey. FK (documented only): s_nationkey -> nation.
CREATE OR REPLACE TABLE SUPPLIER (
    s_suppkey    INTEGER NOT NULL,
    s_name       VARCHAR(25),
    s_address    VARCHAR(40),
    s_nationkey  INTEGER,
    s_phone      VARCHAR(15),
    s_acctbal    DECIMAL(15,2),
    s_comment    VARCHAR(101),
    CONSTRAINT supplier_pk PRIMARY KEY (s_suppkey)
);

-- part (4,000 rows). PK: p_partkey.
CREATE OR REPLACE TABLE PART (
    p_partkey      INTEGER NOT NULL,
    p_name         VARCHAR(55),
    p_mfgr         VARCHAR(25),
    p_brand        VARCHAR(10),
    p_type         VARCHAR(25),
    p_size         INTEGER,
    p_container    VARCHAR(10),
    p_retailprice  DECIMAL(15,2),
    p_comment      VARCHAR(23),
    CONSTRAINT part_pk PRIMARY KEY (p_partkey)
);

-- partsupp (16,000 rows). PK: (ps_partkey, ps_suppkey).
-- FK (documented only): ps_partkey -> part, ps_suppkey -> supplier.
CREATE OR REPLACE TABLE PARTSUPP (
    ps_partkey     INTEGER NOT NULL,
    ps_suppkey     INTEGER NOT NULL,
    ps_availqty    INTEGER,
    ps_supplycost  DECIMAL(15,2),
    ps_comment     VARCHAR(199),
    CONSTRAINT partsupp_pk PRIMARY KEY (ps_partkey, ps_suppkey)
);

-- orders (30,000 rows). PK: o_orderkey. FK (documented only): o_custkey -> customer.
CREATE OR REPLACE TABLE ORDERS (
    o_orderkey      INTEGER NOT NULL,
    o_custkey       INTEGER,
    o_orderstatus   CHAR(1),
    o_totalprice    DECIMAL(15,2),
    o_orderdate     DATE,
    o_orderpriority VARCHAR(15),
    o_clerk         VARCHAR(15),
    o_shippriority  INTEGER,
    o_comment       VARCHAR(79),
    CONSTRAINT orders_pk PRIMARY KEY (o_orderkey)
);

-- lineitem (~120K rows, fact table). PK: (l_orderkey, l_linenumber).
-- FK (documented only): l_orderkey -> orders, l_partkey -> part,
-- l_suppkey -> supplier, (l_partkey, l_suppkey) -> partsupp.
CREATE OR REPLACE TABLE LINEITEM (
    l_orderkey      INTEGER NOT NULL,
    l_partkey       INTEGER,
    l_suppkey       INTEGER,
    l_linenumber    INTEGER NOT NULL,
    l_quantity      DECIMAL(15,2),
    l_extendedprice DECIMAL(15,2),
    l_discount      DECIMAL(15,2),
    l_tax           DECIMAL(15,2),
    l_returnflag    CHAR(1),
    l_linestatus    CHAR(1),
    l_shipdate      DATE,
    l_commitdate    DATE,
    l_receiptdate   DATE,
    l_shipinstruct  VARCHAR(25),
    l_shipmode      VARCHAR(10),
    l_comment       VARCHAR(44),
    CONSTRAINT lineitem_pk PRIMARY KEY (l_orderkey, l_linenumber)
);

-- Semantics travel WITH the tables: agents discover meaning through the MCP
-- describe/summarize path, which reads these comments — without them a table's
-- shape is visible but its meaning lives only in data/data-dictionary.md, a
-- file no SQL client can see. Kept short; the dictionary stays the deep
-- reference. COMMENT is idempotent, so re-runs simply reapply.

COMMENT ON TABLE  REGION IS 'One geographic region (5 rows). PK r_regionkey.';
COMMENT ON COLUMN REGION.R_REGIONKEY IS 'Region id (PK)';
COMMENT ON COLUMN REGION.R_NAME IS 'Region name: AFRICA, AMERICA, ASIA, EUROPE, MIDDLE EAST';
COMMENT ON COLUMN REGION.R_COMMENT IS 'Free-text note';

COMMENT ON TABLE  NATION IS 'One nation, in a region (25 rows). PK n_nationkey; n_regionkey -> region.';
COMMENT ON COLUMN NATION.N_NATIONKEY IS 'Nation id (PK)';
COMMENT ON COLUMN NATION.N_NAME IS 'Nation name, e.g. UNITED STATES, GERMANY, JAPAN';
COMMENT ON COLUMN NATION.N_REGIONKEY IS 'Region this nation is in (FK -> region.r_regionkey)';
COMMENT ON COLUMN NATION.N_COMMENT IS 'Free-text note';

COMMENT ON TABLE  CUSTOMER IS 'One customer (3,000 rows). PK c_custkey; c_nationkey -> nation.';
COMMENT ON COLUMN CUSTOMER.C_CUSTKEY IS 'Customer id (PK)';
COMMENT ON COLUMN CUSTOMER.C_NAME IS 'Customer name (Customer#NNNNNNNNN)';
COMMENT ON COLUMN CUSTOMER.C_ADDRESS IS 'Street address';
COMMENT ON COLUMN CUSTOMER.C_NATIONKEY IS 'Customer''s nation (FK -> nation.n_nationkey)';
COMMENT ON COLUMN CUSTOMER.C_PHONE IS 'Phone number';
COMMENT ON COLUMN CUSTOMER.C_ACCTBAL IS 'Account balance, can be negative';
COMMENT ON COLUMN CUSTOMER.C_MKTSEGMENT IS 'Market segment: AUTOMOBILE, BUILDING, FURNITURE, HOUSEHOLD, MACHINERY';
COMMENT ON COLUMN CUSTOMER.C_COMMENT IS 'Free-text note';

COMMENT ON TABLE  SUPPLIER IS 'One supplier (200 rows). PK s_suppkey; s_nationkey -> nation.';
COMMENT ON COLUMN SUPPLIER.S_SUPPKEY IS 'Supplier id (PK)';
COMMENT ON COLUMN SUPPLIER.S_NAME IS 'Supplier name (Supplier#NNNNNNNNN)';
COMMENT ON COLUMN SUPPLIER.S_ADDRESS IS 'Street address';
COMMENT ON COLUMN SUPPLIER.S_NATIONKEY IS 'Supplier''s nation (FK -> nation.n_nationkey)';
COMMENT ON COLUMN SUPPLIER.S_PHONE IS 'Phone number';
COMMENT ON COLUMN SUPPLIER.S_ACCTBAL IS 'Account balance, can be negative';
COMMENT ON COLUMN SUPPLIER.S_COMMENT IS 'Free-text note';

COMMENT ON TABLE  PART IS 'One sellable product (4,000 rows). PK p_partkey.';
COMMENT ON COLUMN PART.P_PARTKEY IS 'Part id (PK)';
COMMENT ON COLUMN PART.P_NAME IS 'Descriptive name (color words)';
COMMENT ON COLUMN PART.P_MFGR IS 'Manufacturer (Manufacturer#N)';
COMMENT ON COLUMN PART.P_BRAND IS 'Brand (Brand#NN)';
COMMENT ON COLUMN PART.P_TYPE IS 'Type/material/finish, e.g. PROMO BURNISHED COPPER';
COMMENT ON COLUMN PART.P_SIZE IS 'Size code';
COMMENT ON COLUMN PART.P_CONTAINER IS 'Container, e.g. JUMBO PKG';
COMMENT ON COLUMN PART.P_RETAILPRICE IS 'List retail price';
COMMENT ON COLUMN PART.P_COMMENT IS 'Free-text note';

COMMENT ON TABLE  PARTSUPP IS 'One part supplied by one supplier (16,000 rows). PK (ps_partkey, ps_suppkey); FKs -> part, supplier.';
COMMENT ON COLUMN PARTSUPP.PS_PARTKEY IS 'Part (PK part, FK -> part.p_partkey)';
COMMENT ON COLUMN PARTSUPP.PS_SUPPKEY IS 'Supplier (PK part, FK -> supplier.s_suppkey)';
COMMENT ON COLUMN PARTSUPP.PS_AVAILQTY IS 'Quantity this supplier has available';
COMMENT ON COLUMN PARTSUPP.PS_SUPPLYCOST IS 'Cost to source the part from this supplier';
COMMENT ON COLUMN PARTSUPP.PS_COMMENT IS 'Free-text note';

COMMENT ON TABLE  ORDERS IS 'One customer order header (30,000 rows). PK o_orderkey; o_custkey -> customer. Line detail in LINEITEM.';
COMMENT ON COLUMN ORDERS.O_ORDERKEY IS 'Order id (PK)';
COMMENT ON COLUMN ORDERS.O_CUSTKEY IS 'Customer who placed it (FK -> customer.c_custkey)';
COMMENT ON COLUMN ORDERS.O_ORDERSTATUS IS 'Status flag: O = open, F = fulfilled, P = partial';
COMMENT ON COLUMN ORDERS.O_TOTALPRICE IS 'Order total incl. tax (sum of its line items)';
COMMENT ON COLUMN ORDERS.O_ORDERDATE IS 'Date the order was placed';
COMMENT ON COLUMN ORDERS.O_ORDERPRIORITY IS 'Priority: 1-URGENT, 2-HIGH, 3-MEDIUM, 4-NOT SPECIFIED, 5-LOW';
COMMENT ON COLUMN ORDERS.O_CLERK IS 'Clerk who handled it (Clerk#NNNNNNNNN)';
COMMENT ON COLUMN ORDERS.O_SHIPPRIORITY IS 'Ship priority (usually 0)';
COMMENT ON COLUMN ORDERS.O_COMMENT IS 'Free-text note';

COMMENT ON TABLE  LINEITEM IS 'Fact table: one product line within an order (~120K rows). PK (l_orderkey, l_linenumber). Revenue = l_extendedprice * (1 - l_discount).';
COMMENT ON COLUMN LINEITEM.L_ORDERKEY IS 'Order this line belongs to (FK -> orders.o_orderkey)';
COMMENT ON COLUMN LINEITEM.L_PARTKEY IS 'Part sold (FK -> part.p_partkey)';
COMMENT ON COLUMN LINEITEM.L_SUPPKEY IS 'Supplier of the part (FK -> supplier.s_suppkey)';
COMMENT ON COLUMN LINEITEM.L_LINENUMBER IS 'Line number within the order (part of PK)';
COMMENT ON COLUMN LINEITEM.L_QUANTITY IS 'Units on this line';
COMMENT ON COLUMN LINEITEM.L_EXTENDEDPRICE IS 'quantity x part price, pre-discount';
COMMENT ON COLUMN LINEITEM.L_DISCOUNT IS 'Discount fraction, 0.00-0.10 (revenue = l_extendedprice * (1 - l_discount))';
COMMENT ON COLUMN LINEITEM.L_TAX IS 'Tax fraction applied after discount';
COMMENT ON COLUMN LINEITEM.L_RETURNFLAG IS 'Return flag: R = returned, A = accepted, N = none';
COMMENT ON COLUMN LINEITEM.L_LINESTATUS IS 'Line status: O = open, F = fulfilled';
COMMENT ON COLUMN LINEITEM.L_SHIPDATE IS 'Date the line shipped';
COMMENT ON COLUMN LINEITEM.L_COMMITDATE IS 'Committed delivery date';
COMMENT ON COLUMN LINEITEM.L_RECEIPTDATE IS 'Date the customer received it';
COMMENT ON COLUMN LINEITEM.L_SHIPINSTRUCT IS 'Shipping instructions, e.g. DELIVER IN PERSON';
COMMENT ON COLUMN LINEITEM.L_SHIPMODE IS 'Ship mode: AIR, FOB, MAIL, RAIL, REG AIR, SHIP, TRUCK';
COMMENT ON COLUMN LINEITEM.L_COMMENT IS 'Free-text note';
