#!/usr/bin/env bash
# mcp-readonly-sql-matrix.sh — integration test proving the dedicated MCP
# read-only database user can run the full breadth of read/analytic SQL that AI
# clients issue (aggregation, window functions, CTEs, set ops, ROLLUP/CUBE,
# statistics, ...) while every write/DDL is rejected — and that its database-wide
# read (USE ANY SCHEMA + SELECT ANY TABLE) automatically covers newly created
# tables in any schema.
#
#   bash tests/mcp-readonly-sql-matrix.sh
#
# Requires a running local deployment plus the kit's stored credentials. If any
# are missing it SKIPs (exit 0) so it is safe in a dry CI environment. It runs
# only SELECTs as the read-only user; the one mutation (a probe table to prove
# read-all covers future tables) is created and dropped as the admin user.

set -u
EXAKIT_HOME="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}"
CREDS="$EXAKIT_HOME/credentials"
MANIFEST="$EXAKIT_HOME/manifest.json"
# The TPC-H sample tables this matrix exercises load into the TPCH schema; the
# grant-coverage probe also lands here (any granted dataset schema would do).
S=TPCH

skip() { echo "SKIP: $1"; exit 0; }

EXAPUMP="$(command -v exapump || echo "$HOME/.local/bin/exapump")"
[ -x "$EXAPUMP" ] || skip "exapump not found (kit not installed)"
[ -f "$CREDS/mcp_readonly_password" ] || skip "no mcp_readonly credential (kit not installed)"
[ -f "$MANIFEST" ] || skip "no manifest"

# Admin credential: prefer the manifest's runtime.password_file (the stored
# filename varies by runtime: runtime_sys_password / personal_sys_password).
ADMIN_PW_FILE="$(grep -oE '"password_file"[[:space:]]*:[[:space:]]*"[^"]+"' "$MANIFEST" \
    | sed -E 's/.*"([^"]+)"$/\1/' | grep -v 'mcp_readonly' | head -1)"
if [ -z "$ADMIN_PW_FILE" ] || [ ! -f "$ADMIN_PW_FILE" ]; then
    for _cand in "$CREDS/runtime_sys_password" "$CREDS/personal_sys_password"; do
        [ -f "$_cand" ] && ADMIN_PW_FILE="$_cand" && break
    done
fi
[ -n "$ADMIN_PW_FILE" ] && [ -f "$ADMIN_PW_FILE" ] || skip "no admin credential to run the grant-coverage check"

# DSN host/port from the manifest (default to the local Personal endpoint).
DSN="$(grep -oE '"dsn"[[:space:]]*:[[:space:]]*"[^"]+"' "$MANIFEST" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
HOSTP="${DSN%%:*}"; PORTP="${DSN##*:}"
HOSTP="${HOSTP:-127.0.0.1}"; PORTP="${PORTP:-8563}"
(exec 3<>"/dev/tcp/$HOSTP/$PORTP") 2>/dev/null && exec 3>&- 3<&- || skip "database not reachable at $HOSTP:$PORTP (start it with: exakit start)"

# Isolated exapump profiles in a throwaway HOME so the real config is untouched.
TMP="$(mktemp -d)"
trap 'printf "DROP TABLE IF EXISTS %s.EXAKIT_GRANT_PROBE;" "$S" | HOME="$TMP" "$EXAPUMP" sql -p sysadm >/dev/null 2>&1; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.exapump"
{
  printf '[mcpro]\nhost = "%s"\nport = %s\nuser = "mcp_readonly"\npassword = "%s"\ntls = true\nvalidate_certificate = false\n\n' \
        "$HOSTP" "$PORTP" "$(cat "$CREDS/mcp_readonly_password")"
  printf '[sysadm]\nhost = "%s"\nport = %s\nuser = "sys"\npassword = "%s"\ntls = true\nvalidate_certificate = false\n' \
        "$HOSTP" "$PORTP" "$(cat "$ADMIN_PW_FILE")"
} > "$TMP/.exapump/config.toml"
chmod 600 "$TMP/.exapump/config.toml"

PASS=0; FAIL=0
# check <label> <ok|fail> <sql>  — ok: must succeed as mcp_readonly;
#                                  fail: must be rejected (read-only integrity).
check() {
    _label="$1"; _expect="$2"; _sql="$3"
    _out="$(printf '%s' "$_sql" | HOME="$TMP" "$EXAPUMP" sql -p mcpro -f csv 2>&1)"; _rc=$?
    if [ "$_expect" = ok ]; then
        if [ "$_rc" -eq 0 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$_label"
        else FAIL=$((FAIL+1)); printf '  FAIL %s: %s\n' "$_label" "$(printf '%s' "$_out" | tr '\n' ' ' | cut -c1-120)"; fi
    else
        if [ "$_rc" -ne 0 ]; then PASS=$((PASS+1)); printf '  ok   %s [rejected]\n' "$_label"
        else FAIL=$((FAIL+1)); printf '  FAIL %s: WRITE ALLOWED — read-only breached!\n' "$_label"; fi
    fi
}

echo "read / aggregation / analytic (must succeed as mcp_readonly):"
check "select+where+order+limit" ok "SELECT C_NAME FROM $S.CUSTOMER WHERE C_ACCTBAL>5000 ORDER BY C_ACCTBAL DESC LIMIT 5;"
check "agg+group+having"         ok "SELECT C_MKTSEGMENT,COUNT(*) n,AVG(C_ACCTBAL) a,MIN(C_ACCTBAL) mn,MAX(C_ACCTBAL) mx FROM $S.CUSTOMER GROUP BY C_MKTSEGMENT HAVING COUNT(*)>100;"
check "count distinct"           ok "SELECT COUNT(DISTINCT C_NATIONKEY) FROM $S.CUSTOMER;"
check "window row_number"        ok "SELECT C_CUSTKEY,ROW_NUMBER() OVER(PARTITION BY C_NATIONKEY ORDER BY C_ACCTBAL DESC) rn FROM $S.CUSTOMER LIMIT 10;"
check "window rank/dense_rank"   ok "SELECT RANK() OVER(ORDER BY C_ACCTBAL DESC) r,DENSE_RANK() OVER(ORDER BY C_ACCTBAL DESC) d FROM $S.CUSTOMER LIMIT 10;"
check "window lag/lead"          ok "SELECT LAG(O_TOTALPRICE) OVER(ORDER BY O_ORDERDATE) pv,LEAD(O_TOTALPRICE) OVER(ORDER BY O_ORDERDATE) nx FROM $S.ORDERS LIMIT 10;"
check "window running total"     ok "SELECT SUM(O_TOTALPRICE) OVER(ORDER BY O_ORDERDATE ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) rt FROM $S.ORDERS LIMIT 10;"
check "ratio_to_report"          ok "SELECT C_MKTSEGMENT,RATIO_TO_REPORT(COUNT(*)) OVER() FROM $S.CUSTOMER GROUP BY C_MKTSEGMENT;"
check "cte"                      ok "WITH t AS (SELECT C_NATIONKEY,COUNT(*) c FROM $S.CUSTOMER GROUP BY C_NATIONKEY) SELECT AVG(c) FROM t;"
check "correlated exists"        ok "SELECT C_CUSTKEY FROM $S.CUSTOMER c WHERE EXISTS(SELECT 1 FROM $S.ORDERS o WHERE o.O_CUSTKEY=c.C_CUSTKEY) LIMIT 5;"
check "scalar subquery"          ok "SELECT C_CUSTKEY,(SELECT COUNT(*) FROM $S.ORDERS o WHERE o.O_CUSTKEY=c.C_CUSTKEY) oc FROM $S.CUSTOMER c LIMIT 5;"
check "in subquery"              ok "SELECT COUNT(*) FROM $S.ORDERS WHERE O_CUSTKEY IN (SELECT C_CUSTKEY FROM $S.CUSTOMER WHERE C_MKTSEGMENT='BUILDING');"
check "union all"                ok "SELECT 'a' k,COUNT(*) FROM $S.ORDERS UNION ALL SELECT 'b',COUNT(*) FROM $S.LINEITEM;"
check "intersect"                ok "SELECT C_NATIONKEY FROM $S.CUSTOMER INTERSECT SELECT S_NATIONKEY FROM $S.SUPPLIER;"
check "minus"                    ok "SELECT C_NATIONKEY FROM $S.CUSTOMER MINUS SELECT N_NATIONKEY FROM $S.NATION WHERE N_NAME='FRANCE';"
check "self join"                ok "SELECT a.C_CUSTKEY FROM $S.CUSTOMER a JOIN $S.CUSTOMER b ON a.C_NATIONKEY=b.C_NATIONKEY AND a.C_CUSTKEY<b.C_CUSTKEY LIMIT 5;"
check "left anti-join"           ok "SELECT c.C_CUSTKEY FROM $S.CUSTOMER c LEFT JOIN $S.ORDERS o ON o.O_CUSTKEY=c.C_CUSTKEY WHERE o.O_ORDERKEY IS NULL LIMIT 5;"
check "full outer join"          ok "SELECT n.N_NAME,r.R_NAME FROM $S.NATION n FULL OUTER JOIN $S.REGION r ON n.N_REGIONKEY=r.R_REGIONKEY LIMIT 5;"
check "cross join"               ok "SELECT COUNT(*) FROM $S.REGION CROSS JOIN $S.NATION;"
check "case"                     ok "SELECT CASE WHEN C_ACCTBAL<0 THEN 'neg' ELSE 'pos' END b,COUNT(*) FROM $S.CUSTOMER GROUP BY 1;"
check "rollup"                   ok "SELECT C_MKTSEGMENT,C_NATIONKEY,COUNT(*) FROM $S.CUSTOMER GROUP BY ROLLUP(C_MKTSEGMENT,C_NATIONKEY);"
check "cube"                     ok "SELECT C_MKTSEGMENT,C_NATIONKEY,COUNT(*) FROM $S.CUSTOMER GROUP BY CUBE(C_MKTSEGMENT,C_NATIONKEY);"
check "grouping sets"            ok "SELECT C_MKTSEGMENT,C_NATIONKEY,COUNT(*) FROM $S.CUSTOMER GROUP BY GROUPING SETS((C_MKTSEGMENT),(C_NATIONKEY));"
check "stddev/median/percentile" ok "SELECT STDDEV(C_ACCTBAL),MEDIAN(C_ACCTBAL),PERCENTILE_CONT(0.9) WITHIN GROUP(ORDER BY C_ACCTBAL) FROM $S.CUSTOMER;"
check "approx_count_distinct"    ok "SELECT APPROXIMATE_COUNT_DISTINCT(O_CUSTKEY) FROM $S.ORDERS;"
check "string fns"               ok "SELECT UPPER(SUBSTR(C_NAME,1,4)),LENGTH(C_ADDRESS),C_NAME||'!' FROM $S.CUSTOMER LIMIT 3;"
check "date fns"                 ok "SELECT MIN(O_ORDERDATE),ADD_MONTHS(MAX(O_ORDERDATE),1),MONTHS_BETWEEN(MAX(O_ORDERDATE),MIN(O_ORDERDATE)) FROM $S.ORDERS;"
check "numeric fns"              ok "SELECT ROUND(AVG(C_ACCTBAL),1),MOD(10,3),POWER(2,5) FROM $S.CUSTOMER;"
check "cast"                     ok "SELECT CAST(C_ACCTBAL AS DECIMAL(10,0)),CAST(C_CUSTKEY AS VARCHAR(20)) FROM $S.CUSTOMER LIMIT 3;"
check "null handling"            ok "SELECT COALESCE(NULLIF(C_MKTSEGMENT,'BUILDING'),'x'),NVL2(C_COMMENT,'y','n') FROM $S.CUSTOMER LIMIT 3;"
check "nested aggregation"       ok "SELECT AVG(s) FROM (SELECT O_CUSTKEY,SUM(O_TOTALPRICE) s FROM $S.ORDERS GROUP BY O_CUSTKEY);"
check "distinct+offset"          ok "SELECT DISTINCT C_MKTSEGMENT FROM $S.CUSTOMER ORDER BY 1 LIMIT 2 OFFSET 1;"

echo "write / DDL (must be rejected):"
check "insert"        fail "INSERT INTO $S.NATION VALUES (99,'X',0,'x');"
check "update"        fail "UPDATE $S.CUSTOMER SET C_ACCTBAL=0 WHERE C_CUSTKEY=1;"
check "delete"        fail "DELETE FROM $S.CUSTOMER WHERE C_CUSTKEY=1;"
check "create table"  fail "CREATE TABLE $S.HACK (x INT);"
check "drop table"    fail "DROP TABLE $S.NATION;"
check "create schema" fail "CREATE SCHEMA HACKZONE;"
check "truncate"      fail "TRUNCATE TABLE $S.NATION;"

echo "database-wide read covers newly created tables:"
# Create+populate a probe table as admin (simulates a user data-load) in a
# schema, then confirm the read-only user can query it with no per-schema grant
# (USE ANY SCHEMA + SELECT ANY TABLE cover it).
printf 'CREATE TABLE %s.EXAKIT_GRANT_PROBE (ID DECIMAL(9), LABEL VARCHAR(20));\nINSERT INTO %s.EXAKIT_GRANT_PROBE VALUES (1,'\''a'\''),(2,'\''b'\'');' "$S" "$S" \
    | HOME="$TMP" "$EXAPUMP" sql -p sysadm >/dev/null 2>&1
check "read newly created table" ok "SELECT COUNT(*) FROM $S.EXAKIT_GRANT_PROBE;"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
