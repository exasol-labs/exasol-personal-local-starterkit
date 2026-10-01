#!/usr/bin/env bash
# dataset-load-progress.sh — proves a bundled dataset load narrates itself on
# ONE line instead of a dozen per file.
#
#   bash tests/dataset-load-progress.sh
#
# The exapump binary is stubbed, so this runs with no database and no network:
# what is under test is what reaches the SCREEN, what still reaches the LOGFILE,
# and that a failed verification still shows everything it used to.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The width checks below drive the FANCY renderer by hand, so they need a
# locale in which its glyphs can be measured. See the helper for the whole
# reason; without it this suite reports seven failures about the locale.
. "$ROOT/tests/lib/utf8-locale.sh"
PASS=0
FAIL=0

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

has() { # has <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "present" "present" ;; *) check "$1" "present" "MISSING" ;; esac
}

lacks() { # lacks <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "absent" "PRESENT" ;; *) check "$1" "absent" "absent" ;; esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
HOME="$WORK/fake-home"
export HOME
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$HOME"

# shellcheck source=/dev/null
. "$ROOT/setup/lib/ui.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/exapump.sh"

# The glyph palette follows whether stdout is a terminal, and a test run is
# never one. Force the fancy table so the bar is asserted on the characters a
# user actually sees, not on the ASCII fallback.
UI_FANCY=1
UI_BAR_FULL="$(printf '\xe2\x96\x88')"
UI_BAR_EMPTY="$(printf '\xe2\x96\x91')"

printf '\n== the bar renders as a string, for embedding in a label ==\n'

# COUNT NOTHING IN BYTES: COMPARE THE WHOLE BAR.
#
# These used to count full blocks with `ui_bar 50 | tr -dc "$UI_BAR_FULL" |
# wc -c | awk '{print $1/3}'`, and it was wrong in a way only Linux showed.
# GNU tr is BYTE-oriented, and the two glyphs share their first two bytes --
# U+2588 is e2 96 88, U+2591 is e2 96 91 -- so a filter meant to keep only
# FULL blocks also kept two bytes out of every EMPTY one. At 50% that is 30
# bytes of full plus 20 bytes of empty, and 50/3 = 16.6667: a count of
# characters came out fractional, which is the tell. BSD tr on macOS treats
# the argument as one multibyte character and drops the empties, so the same
# line passed there and failed only on ubuntu.
#
# The two clamping checks passed everywhere for a reason worth keeping in
# mind: both clamp to a COMPLETELY FULL bar, so there were no empty blocks to
# contaminate the count. The idiom was equally broken in all three; only the
# mixed bar could ever reveal it.
#
# So compare the entire rendered string. No byte arithmetic, no locale, no
# division -- and it asserts the ORDER too (filled first, then remaining),
# which counting never did. bar_glyphs deliberately does not call ui_repeat:
# an expected value must not be built by the code under test.
bar_glyphs() { # bar_glyphs <glyph> <count>
    _bg_out=""
    _bg_i=0
    while [ "$_bg_i" -lt "$2" ]; do
        _bg_out="$_bg_out$1"
        _bg_i=$((_bg_i + 1))
    done
    printf '%s' "$_bg_out"
}

check "0% is all empty"   "$(bar_glyphs "$UI_BAR_EMPTY" 20)" "$(ui_bar 0)"
check "100% is all full"  "$(bar_glyphs "$UI_BAR_FULL" 20)" "$(ui_bar 100)"
check "50% is half full"  "$(bar_glyphs "$UI_BAR_FULL" 10)$(bar_glyphs "$UI_BAR_EMPTY" 10)" "$(ui_bar 50)"
check "over 100% is clamped" "$(bar_glyphs "$UI_BAR_FULL" 20)" "$(ui_bar 140)"
check "a narrower bar is honoured" "$(bar_glyphs "$UI_BAR_FULL" 8)" "$(ui_bar 100 8)"

printf '\n== the row total is readable ==\n'

check "thousands are grouped"  "173,745" "$(exakit_group_digits 173745)"
check "millions too"           "1,234,567" "$(exakit_group_digits 1234567)"
check "small numbers untouched" "25" "$(exakit_group_digits 25)"

printf '\n== the load is weighted by bytes, not by step count ==\n'

# TPC-H is twelve steps and lineitem.csv is fifteen megabytes of twenty-one.
# Counted as steps the bar reached 25% while the file that is most of the job was
# still going; weighted by bytes it reports what is actually left.
BIG="$WORK/big.csv"; SMALL="$WORK/small.csv"
head -c 400000 /dev/zero | tr '\0' 'x' > "$BIG"
head -c 1000 /dev/zero   | tr '\0' 'x' > "$SMALL"
check "a file weighs its bytes" "400000" "$(exakit_load_weight_of "$BIG")"
check "a small one weighs less" "1000"   "$(exakit_load_weight_of "$SMALL")"
check "a file that is not there weighs nothing" "0" "$(exakit_load_weight_of "$WORK/absent.csv")"

# Seconds are an estimate, and a floor keeps a tiny file from claiming zero.
check "a big file is given time"   "2" "$(exakit_load_secs_for 2097152)"
check "a tiny one gets the floor"  "2" "$(exakit_load_secs_for 10)"

# The step reports where it is and where the stage ends, as percentages of the
# whole weight.
LOAD_STATE="$WORK/load-state"
exakit_load_step "$LOAD_STATE" 0 400000 500000 4 "tpch · big.csv"
check "it starts at nought"        "0"  "$(cut -d'|' -f1 "$LOAD_STATE")"
check "and ends at four fifths"    "80" "$(cut -d'|' -f2 "$LOAD_STATE")"
has "naming the file"              "big.csv" "$(cut -d'|' -f5 "$LOAD_STATE")"
exakit_load_step "$LOAD_STATE" 400000 100000 500000 2 "tpch · small.csv"
check "the next stage starts where that ended" "80" "$(cut -d'|' -f1 "$LOAD_STATE")"
check "and finishes the job"                   "100" "$(cut -d'|' -f2 "$LOAD_STATE")"
# A weightless total must not divide by zero.
exakit_load_step "$LOAD_STATE" 0 0 0 2 "empty"
check "an empty load reports nought" "0" "$(cut -d'|' -f1 "$LOAD_STATE")"

printf '\n== a SQL script is quiet when the caller narrates ==\n'

QUIET_OUT="$(EXAKIT_UPLOAD_QUIET=1 exapump_run_sql_file "$WORK/missing.sql" "x" 2>&1 || true)"
has "a missing file still warns" "SQL file missing or empty" "$QUIET_OUT"
EXAPUMP_SH="$(cat "$ROOT/setup/lib/exapump.sh")"
has "the narration is gated on entry" '[ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || info "Running' "$EXAPUMP_SH"
has "and on the way out"              '[ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || ok "${2:-' "$EXAPUMP_SH"

printf '\n== a dataset load prints two lines, not a hundred ==\n'

# A stub exapump: uploads succeed silently, a row count answers with the token
# the real one emits, and the verify script gets a canned result grid.
cat > "$EXAKIT_BIN_DIR/exapump" <<'STUBEOF'
#!/bin/sh
case "$1" in
    upload) exit 0 ;;
    sql)
        shift; shift; shift
        if [ -n "${1:-}" ]; then
            case "$1" in *EXAKIT_RC*) echo "EXAKIT_RC[3000]" ;; esac
            exit 0
        fi
        body="$(cat)"
        case "$body" in
            *CHECK_NAME*)
                echo "CHECK_NAME,STATUS,DETAIL"
                echo "fk: customer.c_nationkey -> nation,${EXAKIT_STUB_STATUS:-OK},0 orphaned row(s)"
                echo 'row_count: customer,OK,"expected 3000, found 3000"'
                ;;
        esac
        exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$EXAKIT_BIN_DIR/exapump"
exapump_cli() { printf '%s\n' "$EXAKIT_BIN_DIR/exapump"; }
EXAKIT_EXAPUMP_PROFILE="starter-kit"
manifest_get() { [ "$1" = "components.exapump.profile" ] && printf 'starter-kit\n'; return 0; }
manifest_set() { return 0; }
exakit_dataset_loaded() { return 1; }
exakit_schema_present() { return 0; }

EXAKIT_LOG_FILE="$WORK/install.log"
: > "$EXAKIT_LOG_FILE"
OUT="$(exakit_load_dataset_dir "$ROOT" tpch 2>&1)"
RC=$?

check "the load succeeds" "0" "$RC"
check "two lines on screen" "2" "$(printf '%s\n' "$OUT" | grep -c .)"
has "line 1 names the dataset and schema" "Loading the 'tpch' dataset into schema TPCH" "$OUT"
has "line 2 is the result"                "Dataset 'tpch' loaded and verified"          "$OUT"

lacks "no per-file loading line"  "Loading customer.csv into"  "$OUT"
lacks "no per-file loaded line"   "customer.csv loaded"        "$OUT"
lacks "no per-script line"        "01_create_schema.sql) done" "$OUT"
lacks "no verification header"    "Verification (tpch"         "$OUT"
lacks "no verification rows"      "CHECK_NAME,STATUS,DETAIL"   "$OUT"
lacks "no orphaned-row chatter"   "orphaned row(s)"            "$OUT"
lacks "no row-count panel"        "Row counts"                 "$OUT"

printf '\n== the result line carries what the panel used to ==\n'

has "the table count" "8 tables" "$OUT"
# 8 stubbed tables at 3000 rows each, grouped.
has "the row total, grouped" "24,000 rows" "$OUT"
has "and how long it took"   "s)"          "$OUT"

printf '\n== nothing is lost: the logfile still has all of it ==\n'

LOG="$(cat "$EXAKIT_LOG_FILE")"
check "every table is counted in the log" "8" "$(grep -c 'DATA  TPCH\.' "$EXAKIT_LOG_FILE")"
has "with its schema and rows"    "TPCH.CUSTOMER" "$LOG"
has "the verification is logged"  "CHECK_NAME,STATUS,DETAIL" "$LOG"
has "so are the commands"         "exapump" "$LOG"

printf '\n== a FAILED verification still shows everything ==\n'

: > "$EXAKIT_LOG_FILE"
OUT="$(EXAKIT_STUB_STATUS=FAIL exakit_load_dataset_dir "$ROOT" tpch 2>&1)"
RC=$?
check "a failed dataset fails the run" "1" "$RC"
has "it says which dataset"      "Verification failed for dataset 'tpch'" "$OUT"
has "it prints the checks"       "CHECK_NAME,STATUS,DETAIL"               "$OUT"
has "including the failing row"  ",FAIL,"                                 "$OUT"
has "and names the remedy"       "re-run with --force"                    "$OUT"
# The rows are printed AND logged, but only once each: exakit_stream_foreign
# would have logged them a second time on top of the capture.
check "the checks are logged once" "1" "$(grep -c 'CHECK_NAME,STATUS,DETAIL' "$EXAKIT_LOG_FILE")"

printf '\n== the PowerShell twin moves with it ==\n'

UI_PS1="$(cat "$ROOT/setup/lib/ui.ps1")"
EXAPUMP_PS1="$(cat "$ROOT/setup/lib/exapump.ps1")"
has "ui.ps1 has the bar helper"        "function Get-ExakitBar"           "$UI_PS1"
has "exapump.ps1 weighs its files"     "function Get-ExakitLoadWeight"  "$EXAPUMP_PS1"
has "...and reports each stage"        "function Set-ExakitLoadStep"    "$EXAPUMP_PS1"
has "...driving the shared bar"        "Start-ExakitProgress -Pct 0"    "$EXAPUMP_PS1"
has "ui.ps1 has the progress line"     "function Write-ExakitProgressLine" "$UI_PS1"
has "...and the animator"              "function Start-ExakitProgress"     "$UI_PS1"
has "it groups the row total"          "function Get-ExakitGroupedDigits"   "$EXAPUMP_PS1"
lacks "no row-count panel on Windows either" 'Start-ExakitPanel "Row counts"' "$EXAPUMP_PS1"
lacks "no unconditional verify header" 'Info "Verification ($Id 03_verify_setup.sql):"' "$EXAPUMP_PS1"
has "its SQL narration is gated too"   'if (-not $script:ExakitUploadQuiet) { Info "Running $Description" }' "$EXAPUMP_PS1"

printf '\n== the datasets table is the menu AND the progress ==\n'

UI_TABLE_TITLE="Datasets to load"
exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\nweather|City weather daily history\n'
}
TBL="$WORK/table"
exakit_data_table_build "$TBL"

check "a row per dataset, plus the group, the file row and Skip" "6" "$(grep -c '.' "$TBL")"
check "the group row leads"        "group"      "$(sed -n 1p "$TBL" | cut -d'|' -f1)"
check "the last dataset corners"   "corner"     "$(sed -n 4p "$TBL" | cut -d'|' -f1)"
check "the file row is 5"          "5"          "$EXAKIT_TABLE_ROW_LOCAL"
check "Skip is 6, and exclusive"   "6"          "$EXAKIT_TABLE_EXCLUSIVE"
check "the group is all-or-none"   "1:2:4:all"  "$EXAKIT_TABLE_GROUP"
check "everything loadable is pre-ticked" "1,2,3,4" "$EXAKIT_TABLE_DEFAULTS"
# A label with spaces in it is ONE row: an accumulator split on whitespace turned
# "TPC-H retail benchmark" into three rows of the table.
check "a multi-word label stays one row" "TPC-H retail benchmark" "$(sed -n 2p "$TBL" | cut -d'|' -f2)"
check "a dataset knows its own row"      "3" "$(exakit_data_table_row energy)"
check "and a non-dataset does not"       "0" "$(exakit_data_table_row nonesuch)"

# With every bundled dataset in, the pre-ticked row is the local-file one — the
# only thing the screen can still do. Enter must never be a no-op.
exakit_pending_datasets() { :; }
exakit_data_table_build "$TBL"
check "nothing pending: the file row is pre-ticked" "$EXAKIT_TABLE_ROW_LOCAL" "$EXAKIT_TABLE_DEFAULTS"
lacks "...and Skip is not"  ",$EXAKIT_TABLE_ROW_SKIP," ",$EXAKIT_TABLE_DEFAULTS,"

printf '\n== a row carries its own state, and keeps its clock ==\n'

exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\nweather|City weather daily history\n'
}
exakit_data_table_build "$TBL"
ui_table_set "$TBL" 2 running 10 40 8 "creating schema TPCH"
check "the row is running"  "running"              "$(sed -n 2p "$TBL" | cut -d'|' -f4)"
check "at its milestone"    "10"                   "$(sed -n 2p "$TBL" | cut -d'|' -f5)"
check "with a ceiling"      "40"                   "$(sed -n 2p "$TBL" | cut -d'|' -f6)"
has "and a phase"           "creating schema TPCH" "$(sed -n 2p "$TBL" | cut -d'|' -f9)"
CLOCK="$(sed -n 2p "$TBL" | cut -d'|' -f8)"
# A new PHASE inside the same job must not restart the elapsed count the reader
# is watching.
ui_table_set "$TBL" 2 running 40 88 20 "loading 8 data files"
check "a phase change keeps the clock" "$CLOCK" "$(sed -n 2p "$TBL" | cut -d'|' -f8)"
check "...but moves the bar"           "40"     "$(sed -n 2p "$TBL" | cut -d'|' -f5)"
ui_table_set "$TBL" 2 done "" "" "" "" "completed · 8 tables, 173,745 rows (23s)"
check "finishing clears the clock" "" "$(sed -n 2p "$TBL" | cut -d'|' -f8)"
has "and states the outcome" "8 tables, 173,745 rows" "$(sed -n 2p "$TBL" | cut -d'|' -f10)"
# Only the named row changes.
check "its neighbour is untouched" "idle" "$(sed -n 3p "$TBL" | cut -d'|' -f4)"

printf '\n== it draws square, at every width ==\n'

UI_FANCY=1
UI_BAR_FULL="$(printf '\xe2\x96\x88')"; UI_BAR_EMPTY="$(printf '\xe2\x96\x91')"
UI_VB="$(printf '\xe2\x94\x82')"; UI_HR="$(printf '\xe2\x94\x80')"
UI_TL="$(printf '\xe2\x95\xad')"; UI_TR="$(printf '\xe2\x95\xae')"
UI_BL="$(printf '\xe2\x95\xb0')"; UI_BR="$(printf '\xe2\x95\xaf')"
UI_TEE="$(printf '\xe2\x94\x9c\xe2\x94\x80')"; UI_CORNER="$(printf '\xe2\x94\x94\xe2\x94\x80')"
UI_TICK="$(printf '\xe2\x9c\x93')"
UI_PROGRESS_EIGHTHS=' ▏▎▍▌▋▊▉'
ui_table_set "$TBL" 3 running 42 88 12 "loading 1 data file"
if [ -z "$EXAKIT_TEST_UTF8_LOCALE" ]; then
    check "width checks need a UTF-8 locale" "skipped" "skipped"
fi
for _w in 80 100 120; do
    [ -n "$EXAKIT_TEST_UTF8_LOCALE" ] || break
    OUT="$(COLUMNS=$_w ui_table_render "$TBL" 0)"
    # Every row of a table has to be the same width, or the right border walks.
    # _ui_visible_len prints WITHOUT a trailing newline, so the loop has to add
    # one or every row's width runs into the next.
    WIDTHS="$(printf '%s\n' "$OUT" | while IFS= read -r _l; do printf '%s\n' "$(_ui_visible_len "$_l")"; done | sort -u | grep -c .)"
    check "at $_w columns every row is one width" "1" "$WIDTHS"
    FITS="$(printf '%s\n' "$OUT" | while IFS= read -r _l; do printf '%s\n' "$(_ui_visible_len "$_l")"; done | sort -rn | sed -n 1p)"
    check "at $_w columns it fits the screen" "yes" \
        "$([ "$FITS" -le "$_w" ] && echo yes || echo "no: $FITS")"
done
# The status column must NOT change width when the last row finishes, or the
# whole table would jump at the end.
W_RUNNING="$(COLUMNS=110 ui_table_render "$TBL" 0 | sed -n 1p | wc -c)"
ui_table_set "$TBL" 3 done "" "" "" "" "completed · 2 tables, 108,050 rows (4s)"
W_DONE="$(COLUMNS=110 ui_table_render "$TBL" 0 | sed -n 1p | wc -c)"
check "the table does not resize when work finishes" "$W_RUNNING" "$W_DONE"

printf '\n== off a terminal it prints once and takes the defaults ==\n'

UI_FANCY=0
exakit_data_table_build "$TBL"
# NOT in $( ): the function reports through EXAKIT_TABLE_SELECTION, which a
# command substitution's subshell would throw away.
EXAKIT_TABLE_SELECTION=""
# A width the labels actually fit in: at 80 the name column shrinks to 24 and
# the assertion below would be measuring the truncation, not the printing.
COLUMNS=110
ui_table_menu "$TBL" > "$WORK/plain.out" 2>&1
PLAIN="$(cat "$WORK/plain.out")"
check "the selection is the defaults" "$EXAKIT_TABLE_DEFAULTS" "$EXAKIT_TABLE_SELECTION"
has "and the table was printed"       "TPC-H retail benchmark" "$PLAIN"
lacks "with no keyboard hint"         "Space to toggle"        "$PLAIN"

printf '\n== a byteless step is worth more than a share of the bytes ==\n'

# energy is the counter-example that broke this: 1,882 bytes of CSV and an
# 02_load_data.sql that GENERATES 108,000 readings. Five percent of 1,882 is 94,
# so the step that was the whole job got four percent of the bar, the upload
# segment capped at 86% and sat there.
check "a tiny dataset gets the floor"  "262144" "$(exakit_load_nominal 1882)"
check "so does an empty one"           "262144" "$(exakit_load_nominal 0)"
# A big one is still a share of itself, because there the files ARE the cost.
check "a big dataset scales with its bytes" "1083337" "$(exakit_load_nominal 21666755)"
check "the floor is the larger of the two" "yes" \
    "$([ "$(exakit_load_nominal 21666755)" -gt "$(exakit_load_nominal 1882)" ] && echo yes || echo no)"

# Measured on the datasets the kit actually ships: the generator-driven one must
# not hand its whole bar to an upload worth two kilobytes.
_wt_share() {   # _wt_share <dataset-dir> -> "<upload-pct> <script-pct>"
    _ws_b=0
    for _ws_f in "$1"/data/*.csv; do
        [ -s "$_ws_f" ] && _ws_b=$(( _ws_b + $(exakit_load_weight_of "$_ws_f") ))
    done
    _ws_n="$(exakit_load_nominal "$_ws_b")"
    _ws_t=$(( _ws_b + _ws_n + _ws_n ))
    [ -s "$1/02_load_data.sql" ]    && _ws_t=$(( _ws_t + _ws_n ))
    [ -s "$1/03_verify_setup.sql" ] && _ws_t=$(( _ws_t + _ws_n ))
    printf '%s %s\n' "$(( _ws_b * 100 / _ws_t ))" "$(( _ws_n * 100 / _ws_t ))"
}
set -- $(_wt_share "$ROOT/data/datasets/energy")
check "energy's uploads are almost nothing" "yes" "$([ "$1" -le 5 ] && echo yes || echo "no: $1%")"
check "and its scripts carry the bar"       "yes" "$([ "$2" -ge 15 ] && echo yes || echo "no: $2%")"
set -- $(_wt_share "$ROOT/data/datasets/tpch")
check "tpch's uploads still carry its bar"  "yes" "$([ "$1" -ge 70 ] && echo yes || echo "no: $1%")"

printf '\n== the label drops the estimate the Status column measures ==\n'

exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark (~175k rows)\nenergy|Smart-meter energy readings (time series, ~108k rows)\n'
}
exakit_data_table_build "$TBL"
check "the hint is gone"      "TPC-H retail benchmark"      "$(sed -n 2p "$TBL" | cut -d'|' -f2)"
check "...on every row"       "Smart-meter energy readings" "$(sed -n 3p "$TBL" | cut -d'|' -f2)"
# Only a TRAILING parenthetical goes: a name that legitimately contains brackets
# in the middle keeps them.
exakit_pending_datasets() { printf 'x|Orders (EU) by quarter\n'; }
exakit_data_table_build "$TBL"
check "brackets in the middle survive" "Orders (EU) by quarter" "$(sed -n 2p "$TBL" | cut -d'|' -f2)"

printf '\n== BOTH callers drive the table, not just the standalone one ==\n'

# This is the gap that shipped: exakit_data_load_menu started the table and the
# installer's own loop did not, so during an install the table drew, stayed
# empty, and every dataset fell back to the single-line bar underneath it. The
# install path is the one that matters and it was the one untested.
COMMON_SH="$(cat "$ROOT/setup/lib/common.sh")"
EXAPUMP_SH2="$(cat "$ROOT/setup/lib/exapump.sh")"
has "the standalone command starts it" 'ui_table_begin "$EXAKIT_TABLE_STATE"' "$EXAPUMP_SH2"
has "...and stops it"                  'ui_table_end "$EXAKIT_TABLE_STATE"'   "$EXAPUMP_SH2"
has "the installer offer starts it"    'ui_table_begin "$EXAKIT_TABLE_STATE"' "$COMMON_SH"
has "...and stops it"                  'ui_table_end "$EXAKIT_TABLE_STATE"'   "$COMMON_SH"
# A warning printed into a frame that is still being repainted lands inside the
# box, so the installer collects them and speaks after the table has stopped.
has "warnings wait for the table"      '_data_notes="${_data_notes}warn|'      "$COMMON_SH"
has "...and are said afterwards"       'EXAKIT_DATA_NOTES_EOF'                "$COMMON_SH"

printf '\n== under a REAL terminal, one table is left, not three ==\n'

# Cursor-up PRESERVES the column. So a frame drawn while the cursor sits mid-row
# -- left there by anything that printed without a newline, a spinner frame or a
# progress line -- starts at that column, and clear-to-end only clears from there
# rightwards. What stays on screen is the first N columns of the old frame with a
# new one starting inside it: several top borders side by side on ONE line, at
# differing widths, which is exactly what was reported. One carriage return in
# front of every frame makes it impossible, whoever left the cursor where.
CR_STATE="$WORK/cr-table"
printf 'group|Select All|1|idle|0|0|0|0||\n' > "$CR_STATE"
UI_TABLE_LINES=5
CR_FIRST="$(ui_table_redraw "$CR_STATE" 0 2>/dev/null | head -c 1 | od -An -c | tr -d ' \n')"
check "every frame starts at column 0" '\r' "$CR_FIRST"

# And the frame is OVERWRITTEN, not cleared and redrawn. \033[0J erases from the
# cursor to the end of the screen and lands before the new frame does, so every
# redraw had a real instant with nothing on it -- "something, empty, something",
# five times a second. Redrawing faster would only show that gap more often.
# Every line is padded to the full box width, so when the geometry has not moved
# an overwrite cannot leave anything stale. Written to files, not $( ), because a
# subshell would not carry the previous geometry between the two draws.
UI_TABLE_LINES=5
_UI_TABLE_PREV_INNER=''
ui_table_redraw "$CR_STATE" 0 > "$WORK/draw1" 2>/dev/null
ui_table_redraw "$CR_STATE" 0 > "$WORK/draw2" 2>/dev/null
has   "a frame whose geometry moved still erases the old one" '[0J' \
    "$(cat -v "$WORK/draw1")"
lacks "a steady frame is overwritten, never cleared"          '[0J' \
    "$(cat -v "$WORK/draw2")"
UI_TABLE_LINES=0

# And only ONE animation at a time: ui_spin_begin takes a nesting reference when
# something is already animating, but ui_table_begin overwrote the pid instead --
# orphaning a live step spinner, which then printed its own line forever and left
# the cursor mid-row for the frame that followed. The PowerShell twin has always
# refused to start a second one.
# Assigned first: a sed range with a `{` in an address is brace-expanded by
# bash 3.2 in argument position. This one survives only because its addresses
# carry no quotes - the next edit would not. See tests/bash32-guard.sh.
_table_begin_sh="$(sed -n '/^ui_table_begin() {/,/printf .\\033\[?25l./p' "$ROOT/setup/lib/ui.sh")"
has "the table stops a live animation first" '_ui_step_stop_spinner' "$_table_begin_sh"

# Everything above reads the state file or a captured string, and neither can see
# the bug that shipped twice: the table STACKED. The first stack was an animator
# whose opening frame printed instead of overwriting; the second was an animator
# killed part-way through a frame, after which every cursor-up landed inside the
# frame before it.
#
# Both are invisible without a terminal to be wrong in. tests/lib/tty-replay.py
# runs the scenario under a pty and replays the escape codes the way a terminal
# would — cursor-up, clear-to-end, carriage return — then asserts what is left on
# screen. It is the only test here that could have caught either.
if command -v python3 >/dev/null 2>&1; then
    if python3 "$ROOT/tests/lib/tty-replay.py" \
            "$ROOT/tests/lib/table-scenario.sh" "$ROOT" > "$WORK/tty.out" 2>&1; then
        check "exactly one table survives" "yes" "yes"
    else
        check "exactly one table survives" "yes" \
            "no: $(grep 'tables on screen' "$WORK/tty.out" || echo 'replay failed')"
    fi
    SCREEN="$(sed -n '/=== FINAL SCREEN ===/,/=== tables/p' "$WORK/tty.out")"
    has "and it is the finished one"  "173,745 rows" "$SCREEN"
    has "with every row accounted for" "10,970 rows" "$SCREEN"
    lacks "no half-drawn bar left behind" "loading 8 data files" "$SCREEN"

    # And the same table again in the shape an INSTALL gives it: every load in a
    # subshell. That is the difference `exakit data-load` does not have, and it
    # was enough to stack the table a third time -- not through a bad redraw, but
    # because killing the animator made bash print the job's own source into the
    # frame. installer-scenario.sh fails with two top borders without the disown.
    if python3 "$ROOT/tests/lib/tty-replay.py" \
            "$ROOT/tests/lib/installer-scenario.sh" "$ROOT" > "$WORK/tty2.out" 2>&1; then
        check "one table when the loads run in subshells" "yes" "yes"
    else
        check "one table when the loads run in subshells" "yes" \
            "no: $(grep 'tables on screen' "$WORK/tty2.out" || echo 'replay failed')"
    fi
    has "and the shell announced no dying job" "job announcements: 0" \
        "$(cat "$WORK/tty2.out")"
    # And NOTHING else animates while the table owns the line. Each load runs in
    # a subshell that calls ui_table_detach, which drops _UI_SPIN_PID -- and that
    # pid was the only thing ui_spin_begin looked at, so run_logged's spinner
    # started a real second animator in there and painted its own line, without a
    # newline, into the row the table owns. Six frames of it on the old code.
    has "no second animator writes into the table" "spinner frames in stream: 0" \
        "$(cat "$WORK/tty2.out")"

    # And the standalone `exakit data-load` shape, where a load die()s. die()
    # exits, so called straight from the menu it ended the command with the table
    # still animating: the orphan's next frame wiped the error message and left a
    # table frozen at 99% with no explanation, which is precisely what a user
    # reported. What has to be true afterwards: one table, the row told the
    # truth, the NEXT dataset still animated, and the reason is on screen.
    if python3 "$ROOT/tests/lib/tty-replay.py" \
            "$ROOT/tests/lib/dying-load-scenario.sh" "$ROOT" > "$WORK/tty3.out" 2>&1; then
        check "one table when a load dies" "yes" "yes"
    else
        check "one table when a load dies" "yes" \
            "no: $(grep 'tables on screen' "$WORK/tty3.out" || echo 'replay failed')"
    fi
    SCREEN3="$(sed -n '/=== FINAL SCREEN ===/,/=== tables/p' "$WORK/tty3.out")"
    has "the dead row says so"            "did not finish" "$SCREEN3"
    has "the reason survives on screen"   "Row count mismatch" "$SCREEN3"
    has "and the next dataset still ran"  "108,050 rows" "$SCREEN3"

    # A SECOND width, because the bug that made this table flicker into two was
    # invisible at one: the box is sized to the terminal, so whether its last row
    # fills the final column depends on how wide that terminal is. 110 is a
    # normal window, and the width the flicker was first reported at.
    if TTY_REPLAY_COLS=110 python3 "$ROOT/tests/lib/tty-replay.py" \
            "$ROOT/tests/lib/installer-scenario.sh" "$ROOT" > "$WORK/tty5.out" 2>&1; then
        check "one table in a 110-column window too" "yes" "yes"
    else
        check "one table in a 110-column window too" "yes" \
            "no: $(grep 'tables on screen' "$WORK/tty5.out" || echo 'replay failed')"
    fi
    lacks "and no arithmetic error reaches the screen" "substring expression" \
        "$(cat "$WORK/tty5.out")"
else
    check "exactly one table survives" "skipped" "skipped"
fi

printf '\n== the SAME table, driven by the MCP client menu ==\n'

# The live table is a shared component and this suite is where its guards live,
# so its second caller is checked here too. The MCP step's own new thing is the
# DISABLED row: an AI client this machine does not have is still drawn, with the
# reason, and can never be picked. A list that quietly omitted those clients
# would read as "the kit supports four clients", and a reader has no way to tell
# a short list from a filtered one.

MTBL="$WORK/mcp-table"
UI_TABLE_TITLE="AI clients to connect"
UI_TABLE_COL1="Client"
cat > "$MTBL" <<'MROWS'
group|Select All|1|idle||||||
tee|Claude|1|idle||||||
tee|Cursor|0|idle||||||
corner|Continue|0|idle||||||
plain|Skip|0|idle||||||
MROWS
ui_table_disable "$MTBL" 3 "not installed"
ui_table_disable "$MTBL" 4 "already connected"
ui_table_frame "$MTBL" 0
MFRAME="$UI_TABLE_FRAME"
has "the first column is named by its caller" "Client" "$MFRAME"
# The reason lives in the STATUS COLUMN now, not glued to the name with a
# separator. A disabled row keeps its columns like every other row -- the change
# that stopped an installed add-on reading "json-tables · Installed (0.2)" with
# the Version column empty beside it. So the two halves are asserted apart.
has "a client this machine lacks says so"     "Cursor"          "$MFRAME"
has "...with the reason in its own column"    "not installed"   "$MFRAME"
has "and one already connected too"           "already connected" "$MFRAME"
lacks "the reason is not glued to the name"   "Cursor · not installed" "$MFRAME"
# The checkbox is what invites a keypress, so a row that cannot take one must
# not draw an empty box for the reader to aim at.
lacks "no checkbox on a row nobody can pick" "[ ]" \
    "$(printf '%s\n' "$MFRAME" | grep 'Cursor')"
# The mark inside the box follows the palette (a plain run has no glyphs), so
# this asks for the box, not for what is in it.
has "the rows beside it still have theirs" "] ├─ Claude" "$MFRAME"

# Select All spans the client rows, and the defaults are built by the caller:
# the tick has to be refused at the row, which is the one place both pass
# through. "1,2,3,4,5" is the worst either can ask for.
ui_table_tick "$MTBL" "1,2,3,4,5"
check "a disabled row refuses a tick"        "0" "$(sed -n 3p "$MTBL" | cut -d'|' -f3)"
check "...and so does the second one"        "0" "$(sed -n 4p "$MTBL" | cut -d'|' -f3)"
check "the row above it still takes one"     "1" "$(sed -n 2p "$MTBL" | cut -d'|' -f3)"
# ...and the group helper never asks in the first place, because ui_table_menu
# publishes the pickable rows the same way ui_checkbox_menu does.
_UI_CHECKBOX_SELECTABLE="2 5"
check "Select All expands to the pickable rows only" "2" \
    "$(_ui_checkbox_group_children 2 4)"
_UI_CHECKBOX_SELECTABLE=""

if command -v python3 >/dev/null 2>&1; then
    # The selection AND the progress in one table, under a real terminal, with
    # the keystrokes typed in: 'jj' walks two rows down from Claude, which is
    # Gemini CLI only because the cursor steps over the two rows this machine
    # cannot offer. Space unticks it, Enter confirms. A build that lets the
    # cursor rest on a disabled row unticks something else, and the finished
    # table says so — three clients configured, not four.
    if python3 "$ROOT/tests/lib/tty-replay.py" \
            "$ROOT/tests/lib/mcp-table-scenario.sh" "$ROOT" \
            "AI clients to connect" 'jj \r' > "$WORK/tty3.out" 2>&1; then
        check "exactly one client table survives" "yes" "yes"
    else
        check "exactly one client table survives" "yes" \
            "no: $(grep 'tables on screen' "$WORK/tty3.out" || echo 'replay failed')"
    fi
    MSCREEN="$(sed -n '/=== FINAL SCREEN ===/,/=== tables/p' "$WORK/tty3.out")"
    has "the cursor stepped over the rows nobody can pick" \
        "configured · 3 clients" "$MSCREEN"
    check "so the row two down is the one left out" "no status" \
        "$(printf '%s\n' "$MSCREEN" | grep 'Gemini CLI' | grep -q 'configured' \
            && echo "configured" || echo "no status")"
    check "each client row says what happened to it" "yes" \
        "$(printf '%s\n' "$MSCREEN" | grep '├─ Claude' | grep -q '✓ configured' \
            && echo yes || echo no)"
    # Same split as above: the reason is a Status cell, not part of the name.
    check "the rows that cannot be picked keep their reason" "yes" \
        "$(printf '%s\n' "$MSCREEN" | grep 'Cursor' | grep -q 'not installed' \
            && echo yes || echo no)"
    lacks "and no bar is left half-drawn" "writing client configs" "$MSCREEN"
    has "the shell announced no dying job" "job announcements: 0" "$(cat "$WORK/tty3.out")"

    # And the way back: 'jjjj ' ticks Skip, Enter confirms it, 'n' declines the
    # "are you sure" — which must return the reader to the SAME table. The
    # warning and the question are printed under the frame, so the menu has to
    # reclaim those lines too; drawing a fresh table under them leaves two on
    # screen, which is what this run would catch.
    if python3 "$ROOT/tests/lib/tty-replay.py" \
            "$ROOT/tests/lib/mcp-table-scenario.sh" "$ROOT" \
            "AI clients to connect" 'jjjj \rn\r\r' > "$WORK/tty4.out" 2>&1; then
        check "one table after a skip is taken back" "yes" "yes"
    else
        check "one table after a skip is taken back" "yes" \
            "no: $(grep 'tables on screen' "$WORK/tty4.out" || echo 'replay failed')"
    fi
    MSCREEN2="$(sed -n '/=== FINAL SCREEN ===/,/=== tables/p' "$WORK/tty4.out")"
    lacks "the question it answered is gone from the screen" \
        "No AI client will be connected" "$MSCREEN2"
    has "every client is back to pre-selected"  "3 of 4 clients configured" "$MSCREEN2"
    has "and a client the run did not write says so" "not configured" "$MSCREEN2"
else
    check "exactly one client table survives" "skipped" "skipped"
fi

printf '\n== what the table says is not said again underneath it ==\n'

# Python for the two readers below. The suite has no kit installed, so the real
# resolver would try to bootstrap uv; python3 is already required by the replay
# above.
if command -v python3 >/dev/null 2>&1; then
    require_python3() { return 0; }
    exakit_can_run_python() { return 0; }
    run_python() { python3 "$@"; }

    cat > "$WORK/mcp-result.json" <<'MJSON'
{"status":"success",
 "selected_clients":["claude_code","cursor"],
 "details":{"configured_clients":["claude_code"],
            "skipped_clients":[{"client":"cursor","reason":"its config file could not be parsed"}]},
 "next_actions":[{"message":"Start a new Claude Code session to load the updated MCP configuration."}]}
MJSON
    # Where each row's final cell comes from: the run's own record of what it
    # wrote, not the exit status — which cannot tell one client's unusable
    # config file from nothing having been configured at all.
    check "the result file names each client's outcome" \
        "claude_code configured cursor skipped" \
        "$(_exakit_mcp_result_states "$WORK/mcp-result.json" | tr '\n' ' ' | sed 's/ $//')"

    MSUM_TABLE="$(exakit_print_mcp_setup_summary "$WORK/mcp-result.json" 1 2>&1)"
    MSUM_PLAIN="$(exakit_print_mcp_setup_summary "$WORK/mcp-result.json" 2>&1)"
    lacks "the table's rows are not repeated as a line" "MCP configured for" "$MSUM_TABLE"
    has "the skipped client is still named"   "Skipped Cursor"      "$MSUM_TABLE"
    has "and its next step still stands"      "new Claude Code session" "$MSUM_TABLE"
    has "with no table, the headline stays"   "MCP configured for"  "$MSUM_PLAIN"
else
    check "the result file names each client's outcome" "skipped" "skipped"
fi

printf '\n== an import connection cut mid-transfer is tried again, quietly ==\n'

# The database reads each file through its own import proxy; when the client
# side closes before the last byte it says ETL-5105 "transfer closed with
# outstanding read data remaining". On Windows with exapump 0.12 that hit one
# or two of eight files per run, a different file each time, and the same file
# loaded fine a moment later. The stub below fails a file's first N attempts
# with exactly that message (N from a knob file), then succeeds.
RETRY_DIR="$WORK/retry"; mkdir -p "$RETRY_DIR/data"
for _rf in alpha beta gamma; do printf 'id\n1\n2\n' > "$RETRY_DIR/data/$_rf.csv"; done
cat > "$EXAKIT_BIN_DIR/exapump" <<'STUBEOF'
#!/bin/sh
if [ "$1" = sql ]; then printf '%s\n' "$4" >> "$EXAKIT_RETRY_KNOBS/sql.log"; exit 0; fi
[ "$1" = upload ] || exit 0
name="$(basename "$2" .csv)"
printf '%s' "$4" > "$EXAKIT_RETRY_KNOBS/$name.table"
count_file="$EXAKIT_RETRY_KNOBS/$name.count"; n=0; [ -f "$count_file" ] && n="$(cat "$count_file")"
n=$((n + 1)); printf '%s' "$n" > "$count_file"
fail_first=0; [ -f "$EXAKIT_RETRY_KNOBS/$name.fail" ] && fail_first="$(cat "$EXAKIT_RETRY_KNOBS/$name.fail")"
if [ "$n" -le "$fail_first" ]; then
    case "${EXAKIT_RETRY_KIND:-cut}" in
        silent) : ;;
        cut) echo "Error: SQL execution failed: Protocol error: ETL-5105: Following error occured while reading data from external connection [http://172.25.78.139:41705/001.csv failed after 393216 bytes. [transfer closed with outstanding read data remaining],[18],[Transferred a partial file]]" ;;
        *)   echo "Error: SQL execution failed: Protocol error: ETL-2109: Error while parsing row=2" ;;
    esac
    exit 1
fi
echo "Imported 2 rows"
exit 0
STUBEOF
chmod +x "$EXAKIT_BIN_DIR/exapump"
export EXAKIT_RETRY_KNOBS="$RETRY_DIR/knobs"
retry_reset() { rm -rf "$EXAKIT_RETRY_KNOBS"; mkdir -p "$EXAKIT_RETRY_KNOBS"; : > "$EXAKIT_LOG_FILE"; }
retry_attempts() { cat "$EXAKIT_RETRY_KNOBS/$1.count" 2>/dev/null || echo 0; }

check "a cut transfer is recognised"      "0" "$(exakit_upload_cut_short "ETL-5105: ... [transfer closed with outstanding read data remaining]"; echo $?)"
check "so is a reset connection"          "0" "$(exakit_upload_cut_short "read: Connection reset by peer"; echo $?)"
check "a malformed row is not"            "1" "$(exakit_upload_cut_short "ETL-2109: Error while parsing row=2"; echo $?)"
check "a refused login is not"            "1" "$(exakit_upload_cut_short "authentication failed"; echo $?)"
check "the default is two more attempts"  "2" "$(exakit_upload_retries)"
check "EXAKIT_UPLOAD_RETRIES=0 disables"  "0" "$(EXAKIT_UPLOAD_RETRIES=0 exakit_upload_retries)"

retry_reset; printf '1' > "$EXAKIT_RETRY_KNOBS/beta.fail"
OUT="$(EXAKIT_UPLOAD_QUIET=1 exapump_upload_many TPCH "$RETRY_DIR/data/alpha.csv" "$RETRY_DIR/data/beta.csv" "$RETRY_DIR/data/gamma.csv" 2>&1; echo "rc=$?")"
check "one file cut once -> the batch succeeds"      "rc=0" "$(printf '%s\n' "$OUT" | tail -1)"
check "...that file was tried twice"                 "2"    "$(retry_attempts beta)"
check "...the others once"                           "1"    "$(retry_attempts alpha)"
has   "...the log says why it was retried"           "beta.csv: the import connection was cut mid-transfer - attempt 2 of 3" "$(cat "$EXAKIT_LOG_FILE")"
check "...and the screen heard nothing about it"     ""     "$(printf '%s\n' "$OUT" | sed '$d')"

retry_reset; printf '9' > "$EXAKIT_RETRY_KNOBS/beta.fail"
EXAKIT_UPLOAD_QUIET=1 exapump_upload_many TPCH "$RETRY_DIR/data/alpha.csv" "$RETRY_DIR/data/beta.csv" >/dev/null 2>&1; RC=$?
check "cut every time -> three attempts, then failure" "3" "$(retry_attempts beta)"
check "...reported as a failure"                       "1" "$RC"
has   "...naming the file"                             "beta.csv -> TPCH.BETA" "${EXAKIT_UPLOAD_FAILED:-}"

retry_reset; printf '9' > "$EXAKIT_RETRY_KNOBS/beta.fail"
OUT="$(EXAKIT_RETRY_KIND=parse EXAKIT_UPLOAD_QUIET=1 exapump_upload_many TPCH "$RETRY_DIR/data/beta.csv" 2>&1; echo "rc=$?")"
check "a malformed file is never retried"            "1"    "$(retry_attempts beta)"
check "...and fails at once"                         "rc=1" "$(printf '%s\n' "$OUT" | tail -1)"

retry_reset; printf '1' > "$EXAKIT_RETRY_KNOBS/beta.fail"
OUT="$(EXAKIT_UPLOAD_RETRIES=0 EXAKIT_UPLOAD_QUIET=1 exapump_upload_many TPCH "$RETRY_DIR/data/beta.csv" 2>&1; echo "rc=$?")"
check "EXAKIT_UPLOAD_RETRIES=0 -> one attempt only"  "1"    "$(retry_attempts beta)"
check "...and the cut is a failure"                  "rc=1" "$(printf '%s\n' "$OUT" | tail -1)"

printf '\n== a file the import keeps cutting is re-sent in pieces, all or nothing ==\n'

# Against Exasol Personal on Windows the engine loses the LAST 10-90 KB of a
# file, and the same file mostly loses it again: retrying whole does not help,
# pieces small enough to arrive whole do. EXAKIT_UPLOAD_PIECE_KB=1 makes a
# 5 KB fixture several pieces.
{
    printf 'id,note\n'
    _bi=0
    while [ "$_bi" -lt 120 ]; do
        _bi=$((_bi + 1))
        if [ "$_bi" = 40 ]; then printf '%s,"a quoted note\nthat spans, a line"\n' "$_bi"
        else printf '%s,plain note number %s for padding\n' "$_bi" "$_bi"; fi
    done
} > "$RETRY_DIR/data/big.csv"
PIECE_DIR="$WORK/pieces"; mkdir -p "$PIECE_DIR"
exakit_split_csv_pieces "$RETRY_DIR/data/big.csv" "$PIECE_DIR" 1024
tail -n +2 "$RETRY_DIR/data/big.csv" > "$WORK/big.body"
for _pf in "$PIECE_DIR"/*; do tail -n +2 "$_pf"; done > "$WORK/pieces.body"
check "a 5 KB file cut at 1 KB -> several pieces"   "yes"  "$( [ "$(ls "$PIECE_DIR" | wc -l | tr -d ' ')" -ge 4 ] && echo yes || echo no)"
check "...every piece starts with the header"       "0"    "$(for _pf in "$PIECE_DIR"/*; do head -1 "$_pf"; done | grep -vc '^id,note$')"
check "...the rows put back together are the file"  "same" "$(cmp -s "$WORK/big.body" "$WORK/pieces.body" && echo same || echo differ)"
check "...and no cut falls inside a quoted field"   "0"    "$(for _pf in "$PIECE_DIR"/*; do _q="$(tr -cd '"' < "$_pf" | wc -c | tr -d ' ')"; [ $((_q % 2)) = 0 ] || echo odd; done | grep -c odd)"

retry_reset; printf '9' > "$EXAKIT_RETRY_KNOBS/big.fail"
OUT="$(EXAKIT_UPLOAD_PIECE_KB=1 EXAKIT_UPLOAD_QUIET=1 exapump_upload_many TPCH "$RETRY_DIR/data/big.csv" 2>&1; echo "rc=$?")"
check "cut every time -> re-sent in pieces, batch succeeds" "rc=0" "$(printf '%s\n' "$OUT" | tail -1)"
check "...the whole file was tried once"            "1" "$(retry_attempts big)"
check "...each piece went to the staging table"     "TPCH.BIG__EXAKIT_PIECES" "$(cat "$EXAKIT_RETRY_KNOBS/big.piece0002.table" 2>/dev/null)"
has   "...which is a copy of the target"            "CREATE TABLE TPCH.BIG__EXAKIT_PIECES LIKE TPCH.BIG" "$(cat "$EXAKIT_RETRY_KNOBS/sql.log")"
has   "...moved across in one statement"            "INSERT INTO TPCH.BIG SELECT * FROM TPCH.BIG__EXAKIT_PIECES" "$(cat "$EXAKIT_RETRY_KNOBS/sql.log")"
has   "...and the log says why"                     "big.csv: re-sending it as" "$(cat "$EXAKIT_LOG_FILE")"

retry_reset; printf '9' > "$EXAKIT_RETRY_KNOBS/big.fail"; printf '9' > "$EXAKIT_RETRY_KNOBS/big.piece0002.fail"
EXAKIT_UPLOAD_PIECE_KB=1 EXAKIT_UPLOAD_QUIET=1 exapump_upload_many TPCH "$RETRY_DIR/data/big.csv" >/dev/null 2>&1; RC=$?
check "a piece that never lands -> the file fails"  "1" "$RC"
check "...after its own three attempts"             "3" "$(retry_attempts big.piece0002)"
check "...the pieces after it are not sent"         "0" "$(retry_attempts big.piece0003)"
lacks "...the target never sees the pieces"         "INSERT INTO TPCH.BIG" "$(cat "$EXAKIT_RETRY_KNOBS/sql.log")"
check "...and the staging table is dropped"         "DROP TABLE IF EXISTS TPCH.BIG__EXAKIT_PIECES" "$(tail -1 "$EXAKIT_RETRY_KNOBS/sql.log")"

retry_reset; printf '9' > "$EXAKIT_RETRY_KNOBS/big.fail"
EXAKIT_UPLOAD_PIECE_KB=0 EXAKIT_UPLOAD_QUIET=1 exapump_upload_many TPCH "$RETRY_DIR/data/big.csv" >/dev/null 2>&1
check "EXAKIT_UPLOAD_PIECE_KB=0 -> whole-file retries only" "3" "$(retry_attempts big)"
check "...and no staging table"                     ""  "$(cat "$EXAKIT_RETRY_KNOBS/sql.log" 2>/dev/null)"

retry_reset; printf '1' > "$EXAKIT_RETRY_KNOBS/beta.fail"
OUT="$(EXAKIT_RETRY_KIND=silent EXAKIT_UPLOAD_QUIET=1 exapump_upload_many TPCH "$RETRY_DIR/data/beta.csv" 2>&1; echo "rc=$?")"
check "a failure that printed nothing is retried"   "rc=0" "$(printf '%s\n' "$OUT" | tail -1)"
check "...once"                                     "2"    "$(retry_attempts beta)"
has   "...and the log keeps the exit code"          "beta.csv: exapump exited with code 1 and printed nothing" "$(cat "$EXAKIT_LOG_FILE")"

printf '\n== a binary that cannot start YET is waited for, not called broken ==\n'

# A freshly written, unsigned 20 MB exe is held open by Windows Defender and by
# corporate EDR agents while they scan it: "Access is denied" for three and a
# half minutes on a managed laptop, during which all six SELECT 1 attempts
# failed and the install blamed a database that was healthy the whole time.
check "Access is denied is a not-yet"        "0" "$(exakit_binary_not_runnable_yet "Program 'exapump.exe' failed to run: Access is denied"; echo $?)"
check "so is a file held by another process" "0" "$(exakit_binary_not_runnable_yet "The process cannot access the file because it is being used by another process"; echo $?)"
check "so is Defender's virus wording"       "0" "$(exakit_binary_not_runnable_yet "Operation did not complete successfully because the file contains a virus"; echo $?)"
check "a glibc fault is NOT a not-yet"       "1" "$(exakit_binary_not_runnable_yet "/lib/x86_64-linux-gnu/libc.so.6: version GLIBC_2.38 not found"; echo $?)"
check "an ordinary error is not either"      "1" "$(exakit_binary_not_runnable_yet "unknown flag: --nope"; echo $?)"

# The wait is bounded and only the not-yet error is waited for, so a genuinely
# broken binary still fails in the same second it always did.
VR_BIN="$WORK/vr-exapump"
cat > "$VR_BIN" <<'VREOF'
#!/bin/sh
n=0; [ -f "$EXAKIT_VR_COUNT" ] && n="$(cat "$EXAKIT_VR_COUNT")"
n=$((n + 1)); printf '%s' "$n" > "$EXAKIT_VR_COUNT"
[ "$n" -ge "${EXAKIT_VR_OK_AT:-1}" ] && { echo "exapump 0.13.0"; exit 0; }
echo "${EXAKIT_VR_ERR:-Program 'exapump.exe' failed to run: Access is denied}"
exit 1
VREOF
chmod +x "$VR_BIN"
EXAKIT_EXAPUMP_BIN="$VR_BIN"
export EXAKIT_VR_COUNT="$WORK/vr.count"

: > "$EXAKIT_VR_COUNT"; printf '1' > "$EXAKIT_VR_COUNT"
OUT="$(EXAKIT_VR_OK_AT=1 exapump_verify_runs 2>&1; echo "rc=$?")"
check "a binary that runs at once is not waited for" "rc=0" "$(printf '%s\n' "$OUT" | tail -1)"

: > "$EXAKIT_VR_COUNT"
OUT="$(EXAKIT_VR_OK_AT=2 EXAKIT_EXAPUMP_READY_TIMEOUT=30 exapump_verify_runs 2>&1; echo "rc=$?")"
check "a locked binary is waited for, then runs"  "rc=0" "$(printf '%s\n' "$OUT" | tail -1)"
check "...it took a second attempt"               "2"    "$(cat "$EXAKIT_VR_COUNT")"
has   "...and the wait was announced once"        "cannot start yet" "$OUT"

: > "$EXAKIT_VR_COUNT"
# die() exits, so the status is captured outside the substitution, not inside.
OUT="$(EXAKIT_VR_OK_AT=99 EXAKIT_EXAPUMP_READY_TIMEOUT=5 exapump_verify_runs 2>&1)"; RC=$?
check "locked past the budget -> failure"         "1" "$RC"
has   "...naming the scanner, not the database"   "virus scanner or endpoint-security agent" "$OUT"
lacks "...and never mentioning SELECT"            "SELECT" "$OUT"

: > "$EXAKIT_VR_COUNT"
OUT="$(EXAKIT_VR_OK_AT=99 EXAKIT_VR_ERR="unknown flag: --nope" EXAKIT_EXAPUMP_READY_TIMEOUT=60 exapump_verify_runs 2>&1)"; RC=$?
check "a broken binary fails at once, unwaited"   "1"    "$(cat "$EXAKIT_VR_COUNT")"
check "...reported as a failure"                  "1" "$RC"

printf '\n== a dataset whose marker tables are empty is not loaded ==\n'
# The dataset's DDL creates its tables before a single file is uploaded, so an
# upload that failed left empty tables that the marker check called "loaded",
# and `exakit data-load` answered "already loaded - nothing to do" over two
# tables with 0 rows. The listing asks for rows, and carries a sentinel so an
# answered-but-empty database is not mistaken for one that could not be asked.
EXAPUMP_SH3="$(cat "$ROOT/setup/lib/exapump.sh")"
# The listing now CARRIES the row count instead of filtering on it, because the
# folder load needs the third answer the filtered form threw away: a table that
# exists with no rows is neither absent nor loaded, and a failed import leaves
# exactly that behind. The rows>0 set these dataset checks want is derived from
# the counted listing, so there is still one query, not two.
has "the listing carries the row count"  "TABLE_NAME || '|' || TABLE_ROW_COUNT" "$EXAPUMP_SH3"
has "...and says when it was answered"   "SELECT 'EXAKIT.LISTING_ANSWERED|1' AS QUALIFIED FROM DUAL UNION ALL" "$EXAPUMP_SH3"
has "the PowerShell twin asks the same"  "TABLE_NAME || '|' || TABLE_ROW_COUNT" "$(cat "$ROOT/setup/lib/exapump.ps1")"
# The sentinel carries |1 so it survives the rows>0 filter. A |0 sentinel would
# be filtered out with the empty tables, handing every caller an empty listing
# on a database whose tables merely happen to be empty - which they all read as
# "could not be asked".
has "the derived listing drops the empty tables" "grep -v '|0\$'" "$EXAPUMP_SH3"
# Behaviour: a stub listing that answers with the sentinel, and where ORDERS is
# present BUT EMPTY - the exact shape a failed upload leaves behind.
cat > "$EXAKIT_BIN_DIR/exapump" <<'STUBEOF'
#!/bin/sh
case "$*" in
    *LISTING_ANSWERED*) printf 'QUALIFIED\nEXAKIT.LISTING_ANSWERED|1\nTPCH.REGION|150\nTPCH.NATION|25\nTPCH.ORDERS|0\n'; exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$EXAKIT_BIN_DIR/exapump"
exakit_clear_table_listing
unset -f exakit_dataset_loaded
. "$ROOT/setup/lib/exapump.sh"
exapump_cli() { printf '%s\n' "$EXAKIT_BIN_DIR/exapump"; }
_exakit_sync_dataset_flag() { :; }
check "markers with rows -> loaded"          "0" "$(exakit_dataset_loaded data.datasets.tpch.loaded "region,nation" TPCH tpch; echo $?)"
check "a marker standing empty -> not loaded" "1" "$(exakit_dataset_loaded data.datasets.tpch.loaded "region,orders" TPCH tpch; echo $?)"
# ...and the count itself is readable now, which is what the folder load needs.
exakit_clear_table_listing
check "an empty table reads as 0, not as absent" "0"      "$(exakit_table_rows_of TPCH.ORDERS)"
check "a table with rows reads as its count"     "150"    "$(exakit_table_rows_of TPCH.REGION)"
check "a table that is not there reads as absent" "absent" "$(exakit_table_rows_of TPCH.NOSUCH)"
# A database that answers with nothing but empty tables is ANSWERED, not
# unreachable - the |1 sentinel is what keeps that true.
cat > "$EXAKIT_BIN_DIR/exapump" <<'STUBEOF'
#!/bin/sh
case "$*" in
    *LISTING_ANSWERED*) printf 'QUALIFIED\nEXAKIT.LISTING_ANSWERED|1\nTPCH.ORDERS|0\n'; exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$EXAKIT_BIN_DIR/exapump"
exakit_clear_table_listing
check "a database of only-empty tables still answers" "EXAKIT.LISTING_ANSWERED" "$(exakit_table_listing)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
