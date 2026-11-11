# SQL recipes for data science on Exasol

Every query here ran on the kit's database against the practice datasets
(`AMAZON.ORDER_LINES`, `FRAUD.TRANSACTIONS`). Replace the names with the
columns your approved column map names. Run them through the read-only MCP
server: none of them writes.

## Profile a table

```sql
-- Shape and one column's spread
SELECT COUNT(*)                                                         AS ROWS_,
       APPROXIMATE_COUNT_DISTINCT("USER_ID")                            AS USERS,
       AVG("FRAUDULENT")                                                AS TARGET_RATE,
       MEDIAN("TRANSACTION_AMOUNT")                                     AS MEDIAN_AMOUNT,
       PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY "TRANSACTION_AMOUNT") AS P90_AMOUNT,
       STDDEV("TRANSACTION_AMOUNT")                                     AS SD_AMOUNT,
       SUM(CASE WHEN "TRANSACTION_AMOUNT" IS NULL THEN 1 ELSE 0 END)    AS NULL_AMOUNTS
FROM "FRAUD"."TRANSACTIONS";

-- Top values of a category, with their share
SELECT "DEVICE_USED", COUNT(*) AS N,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS PCT
FROM "FRAUD"."TRANSACTIONS"
GROUP BY "DEVICE_USED"
ORDER BY N DESC
LIMIT 20;

-- Repeated keys: a key that should be unique but is not
SELECT "TRANSACTION_ID", COUNT(*) AS N
FROM "FRAUD"."TRANSACTIONS"
GROUP BY "TRANSACTION_ID"
HAVING COUNT(*) > 1
ORDER BY N DESC
LIMIT 20;

-- A first look at a relationship
SELECT CORR("ACCOUNT_AGE", "FRAUDULENT") AS CORR_AGE_FRAUD
FROM "FRAUD"."TRANSACTIONS";
```

`APPROXIMATE_COUNT_DISTINCT` is fast on large tables. Use `COUNT(DISTINCT ...)`
when the exact number matters.

## Features

```sql
SELECT "ORDER_LINE_ID",
       EXTRACT(MONTH FROM "ORDER_DATE")                    AS MONTH_,
       TO_CHAR("ORDER_DATE", 'D')                          AS WEEKDAY,
       -- days since the previous order in the same state
       DAYS_BETWEEN("ORDER_DATE",
                    LAG("ORDER_DATE") OVER (PARTITION BY "SHIP_STATE"
                                            ORDER BY "ORDER_DATE", "ORDER_LINE_ID")) AS DAYS_SINCE_PREV,
       -- frequency encoding: how common the category is
       COUNT(*) OVER (PARTITION BY "CATEGORY")             AS CATEGORY_FREQ,
       -- log scale for a skewed amount; NULL kept as 0 here, say so
       LN(1 + COALESCE("AMOUNT", 0))                       AS LOG_AMOUNT,
       -- five equal-sized amount bins
       NTILE(5) OVER (ORDER BY "AMOUNT")                   AS AMOUNT_BIN,
       -- one-hot for a few values
       CASE WHEN "FULFILMENT" = 'Amazon' THEN 1 ELSE 0 END AS IS_AMAZON_FULFILLED,
       "CANCELLED"                                         AS TARGET
FROM "AMAZON"."ORDER_LINES";
```

Leave out every column written after the outcome. In `amazon_sales`, `STATUS`
says `Cancelled` exactly when the target is 1, and `COURIER_STATUS` follows it.

## Target rate per group, without leakage

A group's target rate is a strong feature, but computed on all rows it leaks
the test rows' answers into training. Compute it on the training fold only:

```sql
WITH folds AS (
    SELECT t.*,
           MOD(TO_NUMBER(SUBSTR(HASH_MD5(TO_CHAR("ROW_ID")), 1, 7), 'XXXXXXX'), 5) AS FOLD
    FROM "FRAUD"."TRANSACTIONS" t
), train_rates AS (
    SELECT "LOCATION", AVG("FRAUDULENT") AS LOCATION_RATE, COUNT(*) AS LOCATION_N
    FROM folds
    WHERE FOLD <> 0
    GROUP BY "LOCATION"
)
SELECT f."ROW_ID", f.FOLD, r.LOCATION_RATE, r.LOCATION_N, f."FRAUDULENT" AS TARGET
FROM folds f
LEFT JOIN train_rates r ON r."LOCATION" = f."LOCATION";
```

## A repeatable train and test split

A hash of the key puts each row in the same fold on every run, unlike a random
sample:

```sql
SELECT MOD(TO_NUMBER(SUBSTR(HASH_MD5("TRANSACTION_ID"), 1, 7), 'XXXXXXX'), 5) AS FOLD,
       COUNT(*) AS N
FROM "FRAUD"."TRANSACTIONS"
GROUP BY 1
ORDER BY 1;
```

Fold 0 is the test set (about 20%). For a model that predicts the future,
split by time instead: train before a cut-off date, test after it.

Hash the entity, not the row, when one customer has many rows. Otherwise the
same customer lands on both sides and the score is too good.

## Per-group statistics for a test

```sql
-- Two proportions: one row per group
SELECT "FULFILMENT"                AS GRP,
       COUNT(*)                    AS N,
       SUM("CANCELLED")            AS SUCCESSES,
       AVG("CANCELLED")            AS RATE
FROM "AMAZON"."ORDER_LINES"
GROUP BY "FULFILMENT";

-- Two means: count, mean and variance per group
SELECT "FULFILMENT"        AS GRP,
       COUNT("AMOUNT")     AS N,
       AVG("AMOUNT")       AS MEAN_,
       VARIANCE("AMOUNT")  AS VAR_
FROM "AMAZON"."ORDER_LINES"
GROUP BY "FULFILMENT";
```

Feed these numbers to the tests in `python-recipes.md`. The rows stay in the
database.

## A sample to train on

```sql
-- The newest 20,000 rows: the same rows on every run
SELECT * FROM "AMAZON"."ORDER_LINES"
ORDER BY "ORDER_DATE" DESC, "ORDER_LINE_ID" DESC
LIMIT 20000;
```

Prefer a fixed sample (newest rows, or a hash fold) to `RANDOM()`, so a rerun
reads the same rows.
