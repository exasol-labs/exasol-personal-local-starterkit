#!/usr/bin/env bash
# model-live-check.sh — AC-ML4.1 on a real machine: `exakit model put` copies a
# file into the deployment's bucket directory, and a UDF reads it back at the
# /buckets path the command printed. The go/no-go for ML-4: if the folder is not
# visible to the UDF sandbox, the item is dropped.
#
#   EXAKIT_LIVE_TESTS=1 bash tests/model-live-check.sh
#
# OPT-IN, and against the INSTALLED kit (the `exakit` on PATH, its database and
# its udf-devkit add-on with Python UDFs set up): it is skipped (exit 0) unless
# EXAKIT_LIVE_TESTS=1 is set and `exakit status` answers running. It writes one
# small file, models/exakit-live-check.txt, into the bucket directory and one
# UDF, EXAKIT_UDF.EXAKIT_READ_BUCKET_FILE, and removes the UDF again; the file
# stays, so `exakit model list` shows what the check put. No password is read
# or printed here: `exakit sql` connects with the kit's own profile.

set -u
if [ "${EXAKIT_LIVE_TESTS:-0}" != "1" ]; then
    echo "model-live-check.sh: skipped (set EXAKIT_LIVE_TESTS=1 to run it against the installed kit)"
    exit 0
fi
command -v exakit >/dev/null 2>&1 || { echo "model-live-check.sh: skipped (no exakit on PATH)"; exit 0; }
if ! exakit status --json >/dev/null 2>&1; then
    echo "model-live-check.sh: skipped (the database is not running: exakit status)"
    exit 0
fi

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; exakit sql --write "DROP SCRIPT IF EXISTS EXAKIT_UDF.EXAKIT_READ_BUCKET_FILE" >/dev/null 2>&1' EXIT
check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}

TOKEN="exakit-live-$(date +%s)-$$"
printf '%s' "$TOKEN" > "$WORK/exakit-live-check.txt"

echo "exakit model put copies the file and prints the /buckets path:"
answer="$(exakit model put "$WORK/exakit-live-check.txt" --replace --json)"; rc=$?
check "exit 0" "0" "$rc"
path="$(printf '%s' "$answer" | python3 -c 'import json, sys; print(json.load(sys.stdin)["path"])' 2>/dev/null)"
case "$path" in
    /buckets/*) PASS=$((PASS + 1)); printf '  ok   the path is under /buckets: %s\n' "$path" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL no /buckets path in: %s\n' "$answer" ;;
esac

echo "a UDF reads it at that path:"
exakit sql --write "CREATE SCHEMA IF NOT EXISTS EXAKIT_UDF" >/dev/null 2>&1
cat > "$WORK/udf.sql" <<'SQL'
CREATE OR REPLACE PYTHON3 SCALAR SCRIPT EXAKIT_UDF.EXAKIT_READ_BUCKET_FILE(p VARCHAR(2000)) RETURNS VARCHAR(2000) AS
def run(ctx):
    with open(ctx.p) as handle:
        return handle.read()
SQL
out="$(exakit sql --write --file "$WORK/udf.sql" 2>&1)"; rc=$?
check "the reading UDF is created" "0" "$rc"
[ "$rc" -eq 0 ] || printf '       %s\n' "$out"
read_back="$(exakit sql --json "SELECT EXAKIT_UDF.EXAKIT_READ_BUCKET_FILE('$path') AS CONTENT" 2>&1 | python3 -c '
import json, sys
doc = json.load(sys.stdin)
rows = doc.get("rows") or []
print(list(rows[0].values())[0] if rows and isinstance(rows[0], dict) else (rows[0][0] if rows else doc.get("error")))' 2>&1)"
check "the UDF returns the file's content (AC-ML4.1)" "$TOKEN" "$read_back"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
