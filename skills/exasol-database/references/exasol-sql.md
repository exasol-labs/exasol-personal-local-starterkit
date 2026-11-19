# Exasol SQL Reference

A comprehensive reference for Exasol's SQL dialect — covering behavior that differs from standard SQL, PostgreSQL, MySQL, or Oracle.

## Data Types

| Type | Parameters | Limits | Notes |
|------|-----------|--------|-------|
| `BOOLEAN` | — | `TRUE`, `FALSE`, `NULL` | Accepts `1`/`0`, `'true'`/`'false'` |
| `DECIMAL(p,s)` | p: 1–36 (default 18), s: 0–p (default 0) | Up to 36 digits precision | Default `DECIMAL` = `DECIMAL(18,0)` |
| `DOUBLE PRECISION` | — | ~15 significant digits | NaN → NULL, Infinity unsupported |
| `DATE` | — | 0001-01-01 to 9999-12-31 | |
| `TIMESTAMP(p)` | p: 0–9 (default 3) | 0001-01-01 to 9999-12-31 23:59:59.999999999 | No timezone; return limited to microsecond precision (p>6 truncated) |
| `TIMESTAMP(p) WITH LOCAL TIME ZONE` | p: 0–9 (default 3) | Same range as TIMESTAMP | Internally stored as UTC |
| `INTERVAL YEAR(p) TO MONTH` | p: 1–9 (default 2) | ±999999999-11 | |
| `INTERVAL DAY(p) TO SECOND(fsp)` | p: 1–9 (default 2), fsp: 0–9 (default 3) | ±999999999 23:59:59.999 | Accuracy limited to milliseconds |
| `CHAR(n)` | n: 1–2,000 (default 1) | | Padded with spaces; ASCII or UTF-8 |
| `VARCHAR(n)` | n: 1–2,000,000 | | Empty string = NULL; UTF-8 default |
| `HASHTYPE(n BYTE)` | n: 1–1,024 (default 16) | Bit variant: 8–8,192, multiple of 8 | Accepts hex, UUID (16 byte only), base64 |
| `GEOMETRY(srid)` | srid: optional (default 0) | | WKT/WKB; POINT, LINESTRING, POLYGON, MULTI*, GEOMETRYCOLLECTION |

**No TIME type:** Exasol has no standalone `TIME` data type. Use `TIMESTAMP` (ignore date), `VARCHAR(8)` (`HH:MM:SS`), or `INTERVAL DAY TO SECOND`.

`VARCHAR2` and `NVARCHAR2` are accepted as aliases for `VARCHAR` (Oracle compatibility).

---

## Identifier Handling

### Unquoted Identifiers Are UPPERCASED
```sql
CREATE TABLE customers (name VARCHAR(100));
-- Actually creates: TABLE "CUSTOMERS" ("NAME" VARCHAR(100))

SELECT name FROM customers;     -- works (both get uppercased)
SELECT "name" FROM customers;   -- ERROR: column "name" not found (table has "NAME")
SELECT "NAME" FROM "CUSTOMERS"; -- works
```

### Quoted Identifiers Are Case-Sensitive
```sql
CREATE TABLE "myTable" ("myColumn" INT);
SELECT "myColumn" FROM "myTable";  -- works
SELECT mycolumn FROM myTable;      -- ERROR: "MYTABLE" not found
```

**Rule of thumb:** Never use quoted identifiers in DDL statements. Always double-quote **every** identifier in SELECT (and all DML) statements — columns, tables, schemas — unconditionally, not just reserved words.

---

## Constraints

### No CHECK Constraints
```sql
CREATE TABLE t (age INT CHECK (age >= 0));  -- ERROR
```
Workaround: Validate in application logic or use a view with a WHERE clause.

### UNIQUE Requires NOT NULL
All columns in a UNIQUE constraint must be `NOT NULL`:
```sql
CREATE TABLE t (a INT, UNIQUE(a));          -- ERROR: nullable column in UNIQUE
CREATE TABLE t (a INT NOT NULL, UNIQUE(a)); -- OK
```

### PRIMARY KEY Implies NOT NULL and UNIQUE
Same as standard SQL, but worth noting given the UNIQUE restriction above.

### Foreign Keys Are Not Enforced
Exasol accepts `FOREIGN KEY` syntax but **does not enforce referential integrity**. Foreign keys are hints for the optimizer only.

---

## Regular Expressions (PCRE2)

Exasol uses **PCRE2** syntax, not POSIX. This means full Perl-compatible regex support.

### Functions

```sql
-- Test if pattern matches
SELECT REGEXP_LIKE('hello123', '^\w+\d+$');  -- TRUE

-- Find position of match
SELECT REGEXP_INSTR('abc 123 def', '\d+');  -- 5

-- Replace matches
SELECT REGEXP_REPLACE('foo  bar', '\s+', ' ');  -- 'foo bar'

-- Extract matching substring
SELECT REGEXP_SUBSTR('abc 123 def', '\d+');  -- '123'

-- With capture groups
SELECT REGEXP_SUBSTR('2024-01-15', '(\d{4})-(\d{2})-(\d{2})', 1, 1, '', 2);  -- '01' (2nd group)
```

### PCRE2 Features Available
- Lookahead/lookbehind: `(?=...)`, `(?<=...)`
- Non-greedy quantifiers: `*?`, `+?`, `??`
- Named groups: `(?P<name>...)`
- Character classes: `\d`, `\w`, `\s`, `\b`
- Unicode support

---

## Set Operations

### MINUS and EXCEPT
Exasol supports both `MINUS` (Oracle-compatible) and `EXCEPT` for set difference:
```sql
SELECT * FROM a EXCEPT SELECT * FROM b;  -- works
SELECT * FROM a MINUS SELECT * FROM b;   -- also works (identical behavior)
```

`UNION`, `UNION ALL`, and `INTERSECT` also work as in standard SQL.

---

## Reserved Keywords

Exasol reserves many keywords beyond the SQL standard. Using these as unquoted identifiers causes syntax errors. **Always double-quote identifiers that match reserved words.**

**Do not rely on a hardcoded list — query the live database instead:**

```bash
# Get ALL reserved keywords (authoritative, always up-to-date)
exapump sql "SELECT KEYWORD FROM EXA_SQL_KEYWORDS WHERE RESERVED ORDER BY KEYWORD"

# Check if a specific word is reserved
exapump sql "SELECT * FROM EXA_SQL_KEYWORDS WHERE KEYWORD = 'PROFILE'"

# Search for keywords matching a pattern
exapump sql "SELECT KEYWORD FROM EXA_SQL_KEYWORDS WHERE RESERVED AND KEYWORD LIKE '%CONNECT%'"

# Count total reserved keywords
exapump sql "SELECT COUNT(*) FROM EXA_SQL_KEYWORDS WHERE RESERVED"
```

The `EXA_SQL_KEYWORDS` system table has two columns: `KEYWORD` (VARCHAR) and `RESERVED` (BOOLEAN). This is the single source of truth for keyword reservation status and reflects the exact version of Exasol running.

### Escaping Reserved Words
```sql
-- These fail because PROFILE and RANDOM are reserved:
CREATE TABLE stats (profile VARCHAR(100), random INT);  -- ERROR

-- Double-quote to escape:
CREATE TABLE stats ("PROFILE" VARCHAR(100), "RANDOM" INT);  -- OK

-- When querying, you must also quote:
SELECT "PROFILE", "RANDOM" FROM stats;
```

### Common Traps
Some frequently-used words that are reserved in Exasol but not in other databases:

**Exasol-specific:**
`EMITS`, `GEOMETRY`, `HASHTYPE`, `PROFILE`, `RANDOM`, `SCRIPT`, `SESSION`, `STATEMENT`

**Date/time (common aliases that are reserved):**
`YEAR`, `MONTH`, `DAY`, `HOUR`, `MINUTE`, `SECOND`, `ZONE`, `TIMESTAMP`

**Analytics / window functions:**
`GROUP_CONCAT`, `LISTAGG`, `PREFERRING`, `QUALIFY`

**Oracle-compatible:**
`CONNECT_BY_ROOT`, `MINUS`, `NOCYCLE`, `NVARCHAR2`, `PRIOR`, `VARCHAR2`

**Other commonly surprising reserved words:**
`ABSOLUTE`, `ACTION`, `ADD`, `AFTER`, `BEFORE`, `CONDITION`, `CONNECTION`, `CONSTRAINT`,
`CYCLE`, `DATA`, `DISABLED`, `ENABLE`, `ENABLED`, `END`, `EXCEPTION`, `EXPORT`, `FILE`,
`FORMAT`, `FOUND`, `GENERAL`, `GRANTED`, `IMPORT`, `INDEX`, `INSTANCE`, `LEVEL`, `LIMIT`,
`LOG`, `NAMES`, `NCLOB`, `NEW`, `NVARCHAR`, `OBJECT`, `OFF`, `OLD`, `OPEN`, `PATH`,
`POSITION`, `READ`, `RENAME`, `REPLACE`, `RESTORE`, `RESULT`, `ROW`, `SCHEMA`, `SCOPE`,
`SEQUENCE`, `SOURCE`, `START`, `STATE`, `STRUCTURE`, `SYSTEM`, `TEMPORARY`, `TEXT`, `VALUE`

**Always check identifiers against this list before writing SQL.** If a query fails with an unexpected syntax error, verify against the live database: `exapump sql "SELECT KEYWORD FROM EXA_SQL_KEYWORDS WHERE RESERVED AND KEYWORD = '<word>'"`

---

## Useful System Tables

| Table | Contents |
|-------|----------|
| `EXA_ALL_TABLES` | All accessible tables |
| `EXA_ALL_COLUMNS` | All accessible columns with types |
| `EXA_ALL_SCHEMAS` | All accessible schemas |
| `EXA_ALL_VIEWS` | All accessible views |
| `EXA_ALL_SCRIPTS` | All accessible UDF scripts |
| `EXA_DBA_CONNECTIONS` | All connection objects (DBA only) |
| `EXA_SQL_KEYWORDS` | All SQL keywords and their reservation status |
| `EXA_METADATA` | Database metadata (version, etc.) |
| `EXA_STATISTICS` | Query statistics |

```sql
-- Check if a word is reserved
SELECT * FROM EXA_SQL_KEYWORDS WHERE KEYWORD = 'PROFILE';

-- Get all reserved keywords
SELECT KEYWORD FROM EXA_SQL_KEYWORDS WHERE RESERVED;
```

---

## Other Noteworthy Behaviors

### LIKE Is Case-Sensitive
```sql
SELECT * FROM t WHERE name LIKE '%John%';  -- won't match 'john'
SELECT * FROM t WHERE UPPER(name) LIKE '%JOHN%';  -- case-insensitive workaround
```

### String Concatenation
Both `||` and `CONCAT()` work:
```sql
SELECT 'hello' || ' ' || 'world';
SELECT CONCAT('hello', ' ', 'world');
```

### LIMIT and OFFSET
Exasol supports `LIMIT` and `OFFSET` (unlike older Oracle):
```sql
SELECT * FROM t ORDER BY id LIMIT 10 OFFSET 20;
```

### CREATE TABLE AS SELECT (CTAS)
```sql
CREATE TABLE new_table AS SELECT * FROM old_table WHERE condition;
```

### MERGE (Upsert)
```sql
MERGE INTO target t
USING source s ON (t.id = s.id)
WHEN MATCHED THEN UPDATE SET t.value = s.value
WHEN NOT MATCHED THEN INSERT VALUES (s.id, s.value);
```

### Date/Time Functions
```sql
SELECT CURRENT_TIMESTAMP;                          -- now
SELECT ADD_DAYS(CURRENT_DATE, 7);                 -- 7 days from now
SELECT DAYS_BETWEEN('2024-01-01', '2024-12-31');  -- day difference
SELECT TO_CHAR(CURRENT_TIMESTAMP, 'YYYY-MM-DD');  -- format
```
