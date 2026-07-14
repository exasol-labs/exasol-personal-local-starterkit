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
