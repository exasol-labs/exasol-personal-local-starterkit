#!/usr/bin/env bash
# Guard the database clock check in `exakit status`.
#
# Exasol Personal on macOS runs the database in a VM whose clock does not catch
# up after the Mac sleeps or hibernates (measured: 2 h 26 min, 1 h 25 min and
# 32 min behind). Queries still answer; the first symptom is a remote source's
# certificate that is "not yet valid" by the database's clock. status measures
# the skew with one query and, past the limit, says so with the fix.
#
# The database is a stub exapump that answers the clock query with this
# computer's time shifted by FAKE_SKEW seconds. Run:
#
#   bash tests/db-clock-skew.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"; mkdir -p "$HOME"
export EXAKIT_HOME="$WORK/kit-home"; mkdir -p "$EXAKIT_HOME"
export EXAKIT_BIN_DIR="$WORK/bin"; mkdir -p "$EXAKIT_BIN_DIR"
cat > "$EXAKIT_HOME/manifest.json" <<'JSON'
{
  "kit_level": 1,
  "runtime": { "type": "personal", "dsn": "127.0.0.1:8563" },
  "steps_completed": ["launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper"],
  "components": {
    "exapump":    { "validated": true, "version": "0.12.0", "profile": "starter-kit" },
    "mcp_server": { "validated": true, "version": "2.0.0" },
    "pyexasol":   { "validated": true, "version": "2.3.1" }
  }
}
JSON

# The stub database. FAKE_MODE=down fails the way a stopped database does;
# FAKE_MODE=hang never answers. Any other query answers like an empty database.
export EXAKIT_EXAPUMP_BIN="$WORK/exapump"
cat > "$EXAKIT_EXAPUMP_BIN" <<'STUB'
#!/bin/sh
case "${FAKE_MODE:-}" in
    down) echo "connection refused" >&2; exit 1 ;;
    hang) exec sleep 30 ;;   # one process, as exapump is
esac
case "$*" in
    *EXAKIT_CLOCK*) printf 'T\nEXAKIT_CLOCK=%s\n1 statement executed, 0 failed\n' $(( $(date +%s) + ${FAKE_SKEW:-0} )) ;;
    *) printf 'X\n1 statement executed, 0 failed\n' ;;
esac
STUB
chmod +x "$EXAKIT_EXAPUMP_BIN"

# --- the helpers --------------------------------------------------------------
helpers() {
    bash -c '. "$1/setup/lib/common.sh" >/dev/null 2>&1; . "$1/setup/lib/exapump.sh" >/dev/null 2>&1; shift; "$@"' _ "$ROOT" "$@"
}

skew="$(FAKE_SKEW=-1955 helpers exakit_db_clock_skew)"
case "$skew" in -195[4-6]) pass "a database 1955 s behind measures as $skew" ;; *) fail "a database 1955 s behind measured as '$skew'" ;; esac
skew="$(FAKE_SKEW=0 helpers exakit_db_clock_skew)"
case "$skew" in -1|0|1) pass "an in-sync database measures as $skew" ;; *) fail "an in-sync database measured as '$skew'" ;; esac

out="$(FAKE_MODE=down helpers exakit_db_clock_skew)"; rc=$?
expect "a database that cannot be asked prints nothing" "" "$out"
[ "$rc" -ne 0 ] && pass "...and answers non-zero" || fail "...and answers non-zero (got 0)"

start="$(date +%s)"
FAKE_MODE=hang EXAKIT_CLOCK_SQL_TIMEOUT=2 helpers exakit_db_clock_skew >/dev/null; rc=$?
took=$(( $(date +%s) - start ))
[ "$rc" -ne 0 ] && [ "$took" -le 6 ] && pass "a database that never answers is given up on (${took}s)" \
    || fail "a database that never answers held the check ${took}s (rc $rc)"

for pair in "0|0 min ahead of" "-1955|33 min behind" "-5100|1 h 25 min behind" "-8760|2 h 26 min behind" "150|3 min ahead of"; do
    expect "words for ${pair%%|*}" "${pair#*|}" "$(helpers exakit_clock_skew_words "${pair%%|*}")"
done
for pair in "0|no" "-119|no" "119|no" "-120|yes" "120|yes" "-1955|yes" "|no"; do
    got="$(helpers exakit_clock_skewed "${pair%%|*}" && echo yes || echo no)"
    expect "skewed? ${pair%%|*}" "${pair#*|}" "$got"
done
expect "the limit can be raised" "no" "$(EXAKIT_CLOCK_SKEW_LIMIT=3600 helpers exakit_clock_skewed -1955 && echo yes || echo no)"

# --- through exakit status ------------------------------------------------------
# exakit with personal_status answering "running", injected right after the
# module that defines the real probe (which would look for a launcher), so it
# overrides it. The anchor was the json-tables.sh source line until aaffaae
# moved the add-ons to Python and dropped that line: sed then matched nothing,
# the stub landed after the command dispatch, and status asked the real probe.
# So the anchor must be there exactly once, or the stub is not built at all.
STUB_CLI="$WORK/exakit"
ln -s "$ROOT/setup/lib" "$WORK/lib"
[ "$(grep -c '^\. "\$_lib_dir/runtime-personal\.sh"$' "$ROOT/setup/exakit")" = 1 ] ||
    { printf 'FAIL could not build the exakit stub (injection point moved)\n'; exit 1; }
{
    sed -n '1,/^\. "\$_lib_dir\/runtime-personal\.sh"$/p' "$ROOT/setup/exakit"
    cat <<'STUB_EOF'
personal_status() { printf '%s\n' "${FAKE_DB_STATE:-running}"; }
STUB_EOF
    sed -n '/^\. "\$_lib_dir\/runtime-personal\.sh"$/,$p' "$ROOT/setup/exakit" | tail -n +2
} > "$STUB_CLI"
grep -q 'FAKE_DB_STATE' "$STUB_CLI" || { printf 'FAIL could not build the exakit stub (injection point moved)\n'; exit 1; }
bash -n "$STUB_CLI" || { printf 'FAIL the exakit stub does not parse\n'; exit 1; }

field() { python3 -c 'import json, sys
d = json.loads(sys.stdin.read())
v = d
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("null" if v is None else v)' "$1"; }

json="$(FAKE_SKEW=-1955 bash "$STUB_CLI" status --json 2>/dev/null)"; rc=$?
expect "status --json still exits 0 for a running database whose clock is behind" 0 "$rc"
case "$(printf '%s' "$json" | field clock_skew_seconds)" in -195[4-6]) pass "clock_skew_seconds carries the measurement" ;;
    *) fail "clock_skew_seconds: $(printf '%s' "$json" | field clock_skew_seconds)" ;; esac
expect "remedies.clock is the first half of a restart" "exakit stop" "$(printf '%s' "$json" | field remedies.clock)"
case "$(printf '%s' "$json" | field remedy_hints.clock)" in
    *"33 min behind"*"exakit start"*) pass "remedy_hints.clock says how far and how to finish" ;;
    *) fail "remedy_hints.clock: $(printf '%s' "$json" | field remedy_hints.clock)" ;; esac
expect "the top-level remedy does not stop a database that answers" "null" "$(printf '%s' "$json" | field remedy)"

screen="$(FAKE_SKEW=-1955 bash "$STUB_CLI" status 2>/dev/null)"
case "$screen" in *"Clock"*"33 min behind this computer"*"exakit stop, then exakit start"*) pass "the screen names the skew and the fix" ;;
    *) fail "the screen has no clock row:"; printf '%s\n' "$screen" | head -8 ;; esac

json="$(FAKE_SKEW=3 bash "$STUB_CLI" status --json 2>/dev/null)"
case "$(printf '%s' "$json" | field clock_skew_seconds)" in 2|3|4) pass "a clock in sync is reported as measured" ;;
    *) fail "an in-sync clock: $(printf '%s' "$json" | field clock_skew_seconds)" ;; esac
expect "...with no clock remedy" "null" "$(printf '%s' "$json" | field remedies.clock)"
screen="$(FAKE_SKEW=3 bash "$STUB_CLI" status 2>/dev/null)"
case "$screen" in *"Clock "*) fail "an in-sync clock still drew a clock row" ;; *) pass "...and no clock row" ;; esac

json="$(FAKE_DB_STATE=stopped FAKE_SKEW=-1955 bash "$STUB_CLI" status --json 2>/dev/null)"
expect "a stopped database is not asked" "null" "$(printf '%s' "$json" | field clock_skew_seconds)"
expect "...and its remedy stays exakit start" "exakit start" "$(printf '%s' "$json" | field remedy)"
expect "...with no clock remedy" "null" "$(printf '%s' "$json" | field remedies.clock)"

# --- the twin --------------------------------------------------------------------
for fn in Get-ExakitDbClockSkew Format-ExakitClockSkew Test-ExakitClockSkewed; do
    grep -q "^function $fn " "$ROOT/setup/lib/exapump.ps1" && pass "PowerShell twin $fn exists" || fail "PowerShell twin $fn is missing"
done
for key in 'clock_skew_seconds' '$remedies\["clock"\] = "exakit stop"' 'Write-StatusPanelRow "Clock"'; do
    grep -q "$key" "$ROOT/setup/exakit.ps1" && pass "exakit.ps1 status has $key" || fail "exakit.ps1 status lacks $key"
done

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
