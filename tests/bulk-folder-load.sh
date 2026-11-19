#!/usr/bin/env bash
# bulk-folder-load.sh — proves `exakit data-load <folder>`: what a folder scan
# picks up, what it refuses, and what actually reaches the database.
#
#   bash tests/bulk-folder-load.sh
#
# The upload layer is stubbed, so this runs with no database, no network and no
# exapump binary: what is under test is the scan, the duplicate rules, the
# format selection and the per-file loop, not the engine underneath them.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

# Same isolation rule as the other suites: common.sh derives its paths at source
# time, so the kit home and HOME are redirected before it is read.
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

EXAKIT_LOG_FILE="$WORK/test.log"
: > "$EXAKIT_LOG_FILE"

# A folder shaped like a real export directory: two formats, both kinds of
# duplicate, a subfolder, a dotfile, an image, a readme and an empty file.
D="$WORK/exports"
mkdir -p "$D/archive"
printf 'a,b\n1,2\n'  > "$D/sales.csv"
printf 'a,b\n1,2\n'  > "$D/sales_copy.csv"    # byte-identical to sales.csv
printf 'x,y\n9,8\n'  > "$D/customers.csv"
printf 'PAR1\n'      > "$D/orders.parquet"
printf 'zzz\n'       > "$D/orders.pq"         # same target table as orders.parquet
printf '{"k":1}\n'   > "$D/events.json"
printf 'png\n'       > "$D/logo.png"
printf 'readme\n'    > "$D/README.txt"
: > "$D/empty.csv"
printf 'nested\n'    > "$D/archive/old.csv"
printf 'hidden\n'    > "$D/.hidden.csv"

PLAN="$(exakit_bulk_scan_folder "$D")"

printf '\n== the scan takes the data files and nothing else ==\n'

check "loadable files found" "4" "$(printf '%s\n' "$PLAN" | grep -c '^load|')"
has "csv is loadable"     "load|csv|SALES|"        "$PLAN"
has "another csv"         "load|csv|CUSTOMERS|"    "$PLAN"
has "parquet is loadable" "load|parquet|ORDERS|"   "$PLAN"
has "json is loadable"    "load|json|EVENTS|"      "$PLAN"

lacks "a subfolder is never descended into" "archive/old.csv" "$PLAN"
lacks "a dotfile is left alone"             ".hidden.csv"     "$PLAN"
has "an image is ignored"    "skip|unsupported||$D/logo.png"   "$PLAN"
# .txt is a fine CSV when someone names the file, and never a table when a
# folder is scanned: a README beside the exports is not data.
has "a README.txt is ignored" "skip|unsupported||$D/README.txt" "$PLAN"
has "an empty file is ignored" "skip|empty||$D/empty.csv"       "$PLAN"

printf '\n== both kinds of duplicate are refused, with the reason ==\n'

has "a byte-identical copy is skipped" "skip|duplicate-content|sales.csv|$D/sales_copy.csv" "$PLAN"
has "a same-table name is skipped"     "skip|duplicate-table|orders.parquet|$D/orders.pq"   "$PLAN"
# Which of the two wins must be the same answer on every machine: the scan
# orders by bytes (LC_ALL=C), not by the machine's collation, which folds
# punctuation on macOS and does not in CI.
has "the first in byte order wins" "load|csv|SALES|$D/sales.csv" "$PLAN"

printf '\n== a folder is never asked about its formats ==\n'

check "kinds present, in menu order" "csv parquet json" \
    "$(exakit_bulk_kinds_present "$PLAN" | tr '\n' ' ' | sed 's/ $//')"

# The question is GONE, not merely defaulted. A folder means "here is my data",
# so every loadable file is taken whatever its kind -- and the menu that used to
# ask was being drawn while the selection table was still on screen, which is
# what duplicated its borders.
lacks "no format selector survives"    "exakit_bulk_select_formats" "$(cat "$ROOT/setup/lib/exapump.sh")"
lacks "...nor on the PowerShell side"  "Select-ExakitBulkFormats"   "$(cat "$ROOT/setup/lib/exapump.ps1")"
lacks "no env var pre-answers it"      "EXAKIT_DATA_FORMATS"        "$(cat "$ROOT/setup/lib/exapump.sh")"
lacks "and the help stops promising it" "more than one format"      "$(cat "$ROOT/setup/help/exakit.json")"

# Behaviour, not just absence: a mixed folder yields every loadable row.
MIXED_ALL="$(printf '%s\n' "$PLAN" | grep -c '^load|' || true)"
check "every loadable file is taken from a mixed folder" "4" "$MIXED_ALL"

printf '\n== real-world CSV shapes: the kit is a bridge, and says what it sees ==\n'

# THE FILES PEOPLE ACTUALLY HAVE. Every CSV from a Windows machine, an Excel
# export or a public open-data portal has Windows line endings, most carry a
# byte-order mark, German exports are ';'-separated, and a GTFS feed is eleven
# CSVs all called .txt. exapump takes none of that as it comes: it builds its
# IMPORT without a row separator (so "7.4" arrives as "7.4<CR>" and fails to
# cast), splits on ',' unless told, and picks the format from the extension,
# refusing .tsv and .txt. Seven public datasets loaded ZERO tables through the
# kit before this.
#
# THE KIT DOES NOT REWRITE THE USER'S FILES. What it does is measured here at
# the binary's argv: the ORIGINAL path always, exapump's own --delimiter when
# the header calls for it, no upload at all for a file with nothing in it or a
# name exapump refuses - and a failure reason that names the cause. The real
# exapump_upload runs against a stub exapump, before the function stubs
# further down replace it.
SHAPES="$WORK/shapes"; mkdir -p "$SHAPES/bin" "$SHAPES/got"
cat > "$SHAPES/bin/exapump" <<'STUB'
#!/bin/sh
# Records argv, and a hash of the file it was handed, so the suite can prove
# it received the user's bytes and not a copy.
printf '%s\n' "$*" >> "$SHAPES_GOT/argv"
[ "$1" = upload ] && cksum < "$2" >> "$SHAPES_GOT/hashes"
[ "$1" = upload ] && cp "$2" "$SHAPES_GOT/received"
exit 0
STUB
chmod +x "$SHAPES/bin/exapump"
SHAPES_GOT="$SHAPES/got"; export SHAPES_GOT
CR="$(printf '\r')"; BOM="$(printf '\357\273\277')"; TAB="$(printf '\t')"
printf '%sdatum,gesamt%s\n2026.01.01,7%s\n' "$BOM" "$CR" "$CR" > "$SHAPES/windows.csv"      # BOM + CRLF
printf 'Row;LAT;NAME\n1;48,17;Zentrale\n' > "$SHAPES/german.csv"                           # ';' with decimal commas
printf "a${TAB}b\n1${TAB}2\n" > "$SHAPES/tabs.tsv"                                          # .tsv - exapump refuses the name
printf 'stop_id,stop_name\n1,Ostbahnhof\n' > "$SHAPES/stops.txt"                             # GTFS - same
printf 'shape_id,shape_pt_lat\n' > "$SHAPES/shapes.csv"                                      # a header with no shapes under it
printf 'a,b\n1,2\n' > "$SHAPES/plain.csv"                                                   # nothing to see
printf 'just some notes\nabout the exports\n' > "$SHAPES/README.txt"

# The inspector: it looks, it does not touch.
check "a plain file: comma, no flags"        ",|"        "$(exakit_csv_inspect "$SHAPES/plain.csv")"
check "a BOM+CRLF file is seen for what it is" ",|bom,crlf" "$(exakit_csv_inspect "$SHAPES/windows.csv")"
check "a ';' header selects the semicolon"   ";|"        "$(exakit_csv_inspect "$SHAPES/german.csv")"
check "a tab header selects the tab"         "$TAB|"     "$(exakit_csv_inspect "$SHAPES/tabs.tsv")"
check "a header with no rows is refused"     "1"         "$(exakit_csv_inspect "$SHAPES/shapes.csv" >/dev/null; echo $?)"
# A COMMA IN THE HEADER of a ';' file made it load as comma-separated: the
# header alone was read, and any comma won. The delimiter is now the one that
# splits the header and the first records into the same number of fields.
printf '"Name, first";Amount\n"Smith, J";12\n"Doe, A";7\n' > "$SHAPES/semi-quoted.csv"
printf 'Betrag (EUR, netto);Datum;Notiz\n1,50;2026-01-01;x\n12;2026-01-02;y\n' > "$SHAPES/semi-prose.csv"
printf 'Betrag (EUR, netto);Datum\n1,50;2026-01-01\n2,00;2026-01-02\n' > "$SHAPES/semi-tie.csv"
printf 'id,note\n1,"a;b"\n2,"c;d"\n' > "$SHAPES/comma-quoted-semi.csv"
check "a ';' file with a quoted comma in its header selects the semicolon" ";|" "$(exakit_csv_inspect "$SHAPES/semi-quoted.csv")"
check "...and with an unquoted one, read from the rows"                  ";|" "$(exakit_csv_inspect "$SHAPES/semi-prose.csv")"
check "a file both ',' and ';' split evenly is ';', named as a guess"   ";|ambiguous-delimiter" "$(exakit_csv_inspect "$SHAPES/semi-tie.csv")"
check "a ',' file with a ';' inside quotes stays comma"                 ",|" "$(exakit_csv_inspect "$SHAPES/comma-quoted-semi.csv")"
_before="$(cksum < "$SHAPES/windows.csv")"
check "...and the file is byte-for-byte what it was" "$_before" "$(cksum < "$SHAPES/windows.csv")"

# Through the real uploader, into the stub binary.
_real_bin="$EXAKIT_EXAPUMP_BIN"; EXAKIT_EXAPUMP_BIN="$SHAPES/bin/exapump"
: > "$SHAPES_GOT/argv"; : > "$SHAPES_GOT/hashes"
_win="$( ( EXAKIT_UPLOAD_QUIET=1 exapump_upload "$SHAPES/windows.csv" T.WINDOWS ) 2>&1 )"
# WINDOWS LINE ENDINGS: exapump 0.14.0 has no row-separator option, so a CRLF
# file failed on a numeric last column ("value='10.5<CR>'", seen live on
# Windows 11) and loaded a CR into a text one. The kit sends an LF copy; the
# user's file stays as it was.
lacks "a CRLF file is not handed over as it is" "upload $SHAPES/windows.csv " "$(cat "$SHAPES_GOT/argv")"
has "...but as a copy of the same name" "/windows.csv --table T.WINDOWS" "$(cat "$SHAPES_GOT/argv")"
check "...whose records end in LF, the BOM kept" "$(printf '%sdatum,gesamt\n2026.01.01,7\n' "$BOM" | cksum)" "$(cksum < "$SHAPES_GOT/received")"
check "...and the user's file is byte-for-byte what it was" "$_before" "$(cksum < "$SHAPES/windows.csv")"
lacks "...and no carriage-return warning is needed any more" "carriage return" "$_win"
check "...and the copy is gone afterwards" "0" "$(ls -d "${TMPDIR:-/tmp}"/exakit-lf.* 2>/dev/null | wc -l | tr -d ' ')"
lacks "...with no delimiter flag for a comma file" "--delimiter" "$(cat "$SHAPES_GOT/argv")"
# A CRLF inside a quoted field is data, not a record end: it stays.
printf 'id,note,amount\r\n1,"two\r\nlines",10.5\r\n2,"say ""hi""",7\r\n' > "$SHAPES/quoted.csv"
( EXAKIT_UPLOAD_QUIET=1 exapump_upload "$SHAPES/quoted.csv" T.QUOTED ) >/dev/null 2>&1
check "a CRLF inside quotes is kept, the record ends are made LF" \
    "$(printf 'id,note,amount\n1,"two\r\nlines",10.5\n2,"say ""hi""",7\n' | cksum)" "$(cksum < "$SHAPES_GOT/received")"
# A quote opens a field only at the start of one: an inch mark (27") in an
# unquoted field is data, and every record after it still ends in LF (it kept
# its CR when the quotes were merely counted per line).
printf 'sku,product,qty\r\n1,27" monitor,4\r\n2,USB cable,10\r\n3,mouse,7\r\n' > "$SHAPES/inch.csv"
_inch="$( ( EXAKIT_UPLOAD_QUIET=1 exapump_upload "$SHAPES/inch.csv" T.INCH ) 2>&1 )"
check "an inch mark does not keep the later records' CR" \
    "$(printf 'sku,product,qty\n1,27" monitor,4\n2,USB cable,10\n3,mouse,7\n' | cksum)" "$(cksum < "$SHAPES_GOT/received")"
lacks "...and needs no carriage-return warning" "carriage return" "$_inch"
# The field start is the file's own delimiter: in a tab file a quote after a
# tab opens a field, so the CRLF inside it is data.
printf 'id\tnote\r\n1\t"two\r\nlines"\r\n2\tx\r\n' > "$SHAPES/quoted-tab.tsv"
( EXAKIT_UPLOAD_QUIET=1 exapump_upload "$SHAPES/quoted-tab.tsv" T.QTAB ) >/dev/null 2>&1
check "a tab file's quoted CRLF is kept, its record ends made LF" \
    "$(printf 'id\tnote\n1\t"two\r\nlines"\n2\tx\n' | cksum)" "$(cksum < "$SHAPES_GOT/received")"
# A quote that never closes leaves CRLFs unconverted: the original goes over
# and the carriage-return warning is still said.
printf 'id,note\r\n1,"never closed\r\n2,x\r\n' > "$SHAPES/open.csv"
: > "$SHAPES_GOT/argv"
_open="$( ( EXAKIT_UPLOAD_QUIET=1 exapump_upload "$SHAPES/open.csv" T.OPEN ) 2>&1 )"
has "a quote that never closes: the original goes over" "upload $SHAPES/open.csv " "$(cat "$SHAPES_GOT/argv")"
has "...and the carriage-return warning stays" "carriage return" "$_open"
_pln="$( ( EXAKIT_UPLOAD_QUIET=1 exapump_upload "$SHAPES/plain.csv" T.PLAIN ) 2>&1 )"
lacks "a clean file gets no such warning" "carriage return" "$_pln"
( EXAKIT_UPLOAD_QUIET=1 exapump_upload "$SHAPES/german.csv" T.GERMAN ) >/dev/null 2>&1
has "a ';' file is uploaded with exapump's own --delimiter ;" "--delimiter ;" "$(cat "$SHAPES_GOT/argv")"
: > "$SHAPES_GOT/argv"
( EXAKIT_UPLOAD_QUIET=1 exapump_upload "$SHAPES/semi-quoted.csv" T.SEMI ) >/dev/null 2>&1
has "a ';' file with a comma in its header goes over with --delimiter ;" "--delimiter ;" "$(cat "$SHAPES_GOT/argv")"
_hdr="$( ( EXAKIT_UPLOAD_QUIET=1 EXAKIT_UPLOAD_SOFT=1 exapump_upload "$SHAPES/shapes.csv" T.SHAPES ) 2>&1; echo "RC=$?" )"
has "a header-only file is named, not sent to the engine" "has a header and no rows" "$_hdr"
has "...as a soft failure" "RC=1" "$_hdr"
lacks "...that never reached exapump" "shapes.csv" "$(cat "$SHAPES_GOT/argv")"
check "no temporary copy of anything exists" "0" "$(ls -d "${TMPDIR:-/tmp}"/exakit-csv* 2>/dev/null | wc -l | tr -d ' ')"
# A refused file must not leave an empty table behind (seen live on Windows:
# STARTER_KIT.GA_CSV_TEST, 0 rows). exapump creates the table before the
# import fails; the caller says the table was not there before.
cat > "$SHAPES/bin/failpump" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SHAPES_GOT/argv"
[ "$1" = upload ] && { echo "Error: SQL execution failed: Protocol error: ETL-3050: [Column=1 Row=0] [Transformation of value='x' failed - invalid character value for cast] (Session: 1)"; exit 1; }
exit 0
STUB
chmod +x "$SHAPES/bin/failpump"
EXAKIT_EXAPUMP_BIN="$SHAPES/bin/failpump"
eval "_saved_listing() $(declare -f exakit_table_rows_listing | sed 1d)"
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.GONE|0\n'; }
: > "$SHAPES_GOT/argv"
_gone="$( ( EXAKIT_UPLOAD_QUIET=1 EXAKIT_UPLOAD_TABLE_BEFORE=absent exapump_upload "$SHAPES/plain.csv" T.GONE ) 2>&1 )"
has "a refused file's empty new table is dropped" "DROP TABLE IF EXISTS T.GONE" "$(cat "$SHAPES_GOT/argv")"
has "...and the message says so" "no empty table left behind" "$_gone"
: > "$SHAPES_GOT/argv"
( EXAKIT_UPLOAD_QUIET=1 exapump_upload "$SHAPES/plain.csv" T.GONE ) >/dev/null 2>&1
lacks "...but a table that was there before is left alone" "DROP TABLE" "$(cat "$SHAPES_GOT/argv")"
eval "exakit_table_rows_listing() $(declare -f _saved_listing | sed 1d)"
EXAKIT_EXAPUMP_BIN="$_real_bin"

# The folder scan sees the same things, and says them.
SPLAN="$(exakit_bulk_scan_folder "$SHAPES")"
has "a tabular .txt is recognised as data" "skip|extension||$SHAPES/stops.txt" "$SPLAN"
has "...and so is a .tsv" "skip|extension||$SHAPES/tabs.tsv" "$SPLAN"
has "a README.txt is not" "skip|unsupported||$SHAPES/README.txt" "$SPLAN"
has "a header-only file is skipped by name" "skip|header-only||$SHAPES/shapes.csv" "$SPLAN"
lacks "nothing exapump refuses by name is queued for it" "load|csv|STOPS|" "$SPLAN"
_plan_out="$(exakit_bulk_print_plan "$SPLAN" "$(printf '%s\n' "$SPLAN" | grep '^load|' | cut -d'|' -f2-)" 2>&1)"
has "the plan tells the user the one thing that loads them" "rename to .csv to load" "$_plan_out"
has "...and counts the header-only file in words" "with a header and no rows" "$_plan_out"
printf '{"type":"FeatureCollection","features":[]}\n' > "$SHAPES/areas.geojson"
check ".geojson is JSON" "json" "$(exakit_data_file_kind "$SHAPES/areas.geojson")"
has "...in a folder scan too" "load|json|AREAS|" "$(exakit_bulk_scan_folder "$SHAPES")"

# The engine's reason survives to the screen, whole, with the cause the kit saw.
EXAKIT_LOG_FILE="$WORK/shape-reason.log"
printf "Error: SQL execution failed: Protocol error: ETL-3051: [Column=11 Row=0] [Transformation of value='7.4<CR>' failed - invalid character value for cast; Value: '7.4'] (Session: 1876)\n" > "$EXAKIT_LOG_FILE"
has "a <CR> in the engine's message is translated" "Windows line endings (CRLF)" "$(exakit_upload_failure_reason)"
printf "Error: SQL execution failed: Protocol error: ETL-3050: [Column=6 Row=0] [Transformation of value='x' failed - invalid character value for cast; Value: 'x'] (Session: 1876)\n" > "$EXAKIT_LOG_FILE"
has "an ETL detail in brackets is kept, not cut at the bracket" "ETL-3050: [Column=6 Row=0] [Transformation of value='x' failed" "$(EXAKIT_CSV_FLAGS="" exakit_upload_failure_reason)"
lacks "...and the session id is dropped" "Session" "$(EXAKIT_CSV_FLAGS="" exakit_upload_failure_reason)"
has "...and a file the inspector flagged as CRLF gets the cause appended" "Windows line endings (CRLF)" "$(EXAKIT_CSV_FLAGS="bom,crlf" exakit_upload_failure_reason)"
lacks "...but not a file that was clean" "Windows line endings" "$(EXAKIT_CSV_FLAGS="" exakit_upload_failure_reason)"
printf "Error: SQL execution failed: Protocol error: ETL-3050: [Column=2 Row=0] [Transformation of value='{\"sku\":\"A-1\",\"tags\":[\"x\"]}' failed - invalid character value for cast] (Session: 9)\n" > "$EXAKIT_LOG_FILE"
_json="$(EXAKIT_CSV_FLAGS="" exakit_upload_failure_reason)"
lacks "a JSON value the engine quotes stays in the log" '"sku"' "$_json"
has "...named, with what failed kept around it" "value='<JSON value>' failed - invalid character value for cast" "$_json"
printf 'Error: Failed to parse row: {"sku":"A-1","name":"a very long product name that runs on\n' > "$EXAKIT_LOG_FILE"
_json="$(EXAKIT_CSV_FLAGS="" exakit_upload_failure_reason)"
check "...and an unclosed one, cut by the engine, is dropped to the end" "Failed to parse row: <JSON value>" "$_json"
printf "Error: SQL execution failed: Protocol error: ETL-2105: Error while parsing row=0 (starting from 0) [CSV Parser found at byte 5385 (starting with 0 at the beginning of the row) of 5385 a single field delimiter or a row terminator directly after a quoted field] (Session: 1)\n" > "$EXAKIT_LOG_FILE"
_long="$(EXAKIT_CSV_FLAGS="" exakit_upload_failure_reason)"
has "a long detail is cut at a word, with an ellipsis" "field..." "$_long"
lacks "...never mid-word" "delimi" "$_long"

# A folder holding only what exapump refuses by name: a GTFS feed, as shipped.
GTFSDIR="$WORK/gtfs"; mkdir -p "$GTFSDIR"
printf 'stop_id,stop_name\n1,Ostbahnhof\n' > "$GTFSDIR/stops.txt"
printf 'route_id,route_short_name\n1,U1\n' > "$GTFSDIR/routes.txt"
_gt="$(exakit_load_local_folder "$GTFSDIR" 2>&1; echo "RC=$?")"
has "a folder of .txt tables is not 'no files'" "2 files in" "$_gt"
has "...it names the rename that loads them" "Rename them to .csv" "$_gt"
lacks "...and does not call it empty" "No CSV, Parquet or JSON files" "$_gt"
has "...and fails, as before" "RC=1" "$_gt"
EXAKIT_LOG_FILE="$WORK/test.log"

printf '\n== the loop loads every chosen file, one table each ==\n'

# Stub the layer below: this suite is about the folder flow, not the engine.
LOADED="$WORK/loaded"
: > "$LOADED"
FAIL_ON=""
exakit_ensure_schema()  { printf 'schema %s\n' "$1" >> "$LOADED"; return 0; }
# The real uploader, kept for the number-format section at the end.
eval "_real_exapump_upload() $(declare -f exapump_upload | sed 1d)"
exapump_upload()        {
    if [ -n "$FAIL_ON" ] && [ "$(basename "$1")" = "$FAIL_ON" ]; then return 1; fi
    printf 'upload %s -> %s\n' "$(basename "$1")" "$2" >> "$LOADED"; return 0
}
# The real one, kept for the single-JSON section at the end.
eval "_real_exakit_load_local_json() $(declare -f exakit_load_local_json | sed 1d)"
exakit_load_local_json() {
    EXAKIT_LAST_LOAD_TARGET="$2"
    printf 'json %s -> %s\n' "$(basename "$1")" "$2" >> "$LOADED"; return 0
}
manifest_set()          { printf 'manifest %s=%s\n' "$1" "$2" >> "$LOADED"; return 0; }

EXAKIT_BULK_CONFIRM=1
export EXAKIT_BULK_CONFIRM
EXAKIT_DATA_FORMATS=""
OUT="$(exakit_load_local_folder "$D" 2>&1)"
RC=$?
LOG="$(cat "$LOADED")"
check "a clean folder load succeeds" "0" "$RC"
check "every eligible file loaded" "4" "$(grep -cE '^(upload|json) ' "$LOADED")"
has "the schema is created once" "schema STARTER_KIT" "$LOG"
has "csv -> its own table"     "upload sales.csv -> STARTER_KIT.SALES"          "$LOG"
has "parquet -> its own table" "upload orders.parquet -> STARTER_KIT.ORDERS"    "$LOG"
has "json goes through the JSON path" "json events.json -> STARTER_KIT.EVENTS"  "$LOG"
lacks "the skipped duplicate never loads" "sales_copy.csv" "$LOG"
has "the folder is recorded" "manifest data.last_load.type=local_folder" "$LOG"
has "the file count is recorded" "manifest data.last_load.files=4" "$LOG"
has "the summary counts them" "STARTER_KIT: 4 files loaded" "$OUT"

# This is also the guard for a bash 3.2 trap: filtering the plan with a `case`
# inside $( ) returns the script's own text instead of the matches on the shell
# every macOS user runs, and `bash -n` does not catch it. A wrong filter shows
# up here as the wrong number of loads.
lacks "the filter returns matches, not script text" "esac" "$LOG"

printf '\n== one bad file does not end the job ==\n'

: > "$LOADED"
FAIL_ON="orders.parquet"
OUT="$(exakit_load_local_folder "$D" 2>&1)"
RC=$?
check "a failed file is reported" "1" "$RC"
check "the other three still loaded" "3" "$(grep -cE '^(upload|json) ' "$LOADED")"
has "the failure names the file" "orders.parquet" "$OUT"
# On its OWN ROW, against its own table. The reason used to be a warn printed
# inside a live progress bar, which a reader who looked away never saw.
check "...on a row that says it did not load" "1" \
    "$(printf '%s\n' "$OUT" | grep -c 'orders\.parquet.*not loaded')"
has "and the rest are counted" "STARTER_KIT: 3 files loaded, 1 not loaded" "$OUT"
# The installer asks for the names of the files that did not load, so its
# closing note can name them (EXAKIT_LOCAL_FILE_NAMES); only the failed one.
: > "$LOADED"
_lfn="$(mktemp)"
( EXAKIT_LOCAL_FILE_NAMES="$_lfn"; exakit_load_local_folder "$D" >/dev/null 2>&1 )
check "...and the installer is told which file did not load" "orders.parquet" "$(tr '\n' ' ' < "$_lfn" | sed 's/ $//')"
rm -f "$_lfn"
FAIL_ON=""

printf '\n== a file that will not load says why, and the rest still load ==\n'

# The engine explains itself well and the kit was throwing that away. One file of
# three failed as "could not be loaded (see log)", under a red "Upload failed"
# banner and a log path -- which reads as the whole job dying. It is one file.
EXAKIT_LOG_FILE="$WORK/reason.log"
cat > "$EXAKIT_LOG_FILE" <<'REASONLOG'
Error: SQL execution failed: Protocol error: ETL-2107: Error while parsing row=4 (starting from 0) [CSV Parser found at byte 8 of 76 single field delimiter in a not enclosed field]
REASONLOG
check "the commonest CSV fault is put into words" \
    "row 4 has a line break or an unescaped comma inside a quoted field" \
    "$(exakit_upload_failure_reason)"
printf 'Error: ETL-5000: something else entirely\n' > "$EXAKIT_LOG_FILE"
has "an unrecognised engine fault is passed through" "ETL-5000" "$(exakit_upload_failure_reason)"
: > "$EXAKIT_LOG_FILE"
check "and nothing is invented when the log says nothing" "" "$(exakit_upload_failure_reason || true)"
EXAKIT_LOG_FILE=""

# Soft mode is what stops one bad file announcing itself as a failed job.
EXAPUMP_SRC="$(cat "$ROOT/setup/lib/exapump.sh")"
EXAPUMP_PS_SRC="$(cat "$ROOT/setup/lib/exapump.ps1")"
has "the folder loop asks for soft failures" "EXAKIT_UPLOAD_SOFT=1 exapump_upload" "$EXAPUMP_SRC"
has "...and the uploader honours it" 'if [ "${EXAKIT_UPLOAD_SOFT:-0}" = 1 ]; then' "$EXAPUMP_SRC"
# Matched on the STATEMENT, not the phrase: the phrase appears in the comments
# that explain why it was dropped, and a needle that cannot tell code from prose
# fails on its own documentation.
lacks "no per-file line sends the reader to the log" 'warn "$(basename "$_blf_path") could not be loaded' "$EXAPUMP_SRC"
lacks "...nor on the PowerShell side" 'Warn2 "$(Split-Path $file -Leaf) could not be loaded' "$EXAPUMP_PS_SRC"
has "the twin keeps the reason instead of the banner" 'ExakitUploadReason = Get-ExakitUploadFailureReason' "$EXAPUMP_PS_SRC"

printf '\n== a mixed folder loads every kind in one pass ==\n'

# This block used to prove that EXAKIT_DATA_FORMATS narrowed the load. That
# narrowing is gone on purpose: the folder is the answer, so all four files go
# in together and no variable can hold any of them back.
: > "$LOADED"
OUT="$(EXAKIT_DATA_FORMATS=csv exakit_load_local_folder "$D" 2>&1)"
# Three UPLOADS, four files: JSON does not go through the uploader at all, it is
# shredded into tables by the ingest engine first. The "Loaded 4 file(s)" line
# below is the one that counts files.
check "every non-JSON kind uploads" "3" "$(grep -c '^upload ' "$LOADED")"
has "parquet is in"  "orders"    "$(cat "$LOADED")"
has "json is in"     "events"    "$(cat "$LOADED")"
has "and the old variable no longer narrows anything" "STARTER_KIT: 4 files loaded" "$OUT"

printf '\n== a folder with nothing to load says so ==\n'

EMPTY="$WORK/empty-dir"; mkdir -p "$EMPTY/sub"
printf 'x\n' > "$EMPTY/notes.md"
: > "$LOADED"
OUT="$(exakit_load_local_folder "$EMPTY" 2>&1)"
RC=$?
check "an ineligible folder fails" "1" "$RC"
has "and explains the rule" "No CSV, Parquet or JSON files in" "$OUT"
check "nothing was loaded" "0" "$(grep -c . "$LOADED")"

printf '\n== the same prompt takes a file or a folder ==\n'

: > "$LOADED"
OUT="$(EXAKIT_DATA_FILE="$D" exakit_load_local_file 2>&1)"
check "a folder path routes to the bulk load" "4" "$(grep -cE '^(upload|json) ' "$LOADED")"

: > "$LOADED"
OUT="$(EXAKIT_DATA_FILE="$D/customers.csv" EXAKIT_DATA_TABLE="STARTER_KIT.CUSTOMERS" \
    exakit_load_local_file 2>&1)"
check "a file path still loads one file" "1" "$(grep -c '^upload ' "$LOADED")"
has "...into the table it was given" "upload customers.csv -> STARTER_KIT.CUSTOMERS" "$(cat "$LOADED")"
# Which delimiter is used is said, and when more than one fits, that is said too.
printf '"Name, first";Amount\n"Smith, J";12\n' > "$WORK/semi-named.csv"
OUT="$(EXAKIT_DATA_FILE="$WORK/semi-named.csv" EXAKIT_DATA_TABLE="STARTER_KIT.SEMI" exakit_load_local_file 2>&1)"
has "a ';' file with a comma in its header is said to be semicolon-separated" "semi-named.csv is semicolon-separated" "$OUT"
printf 'Betrag (EUR, netto);Datum\n1,50;2026-01-01\n' > "$WORK/semi-guess.csv"
OUT="$(EXAKIT_DATA_FILE="$WORK/semi-guess.csv" EXAKIT_DATA_TABLE="STARTER_KIT.GUESS" exakit_load_local_file 2>&1)"
has "...and a file two delimiters fit says which one it loads with" "semi-guess.csv fits more than one separator — loading it as semicolon-separated." "$OUT"
OUT="$(EXAKIT_DATA_FILE="$D/customers.csv" EXAKIT_DATA_TABLE="STARTER_KIT.CUSTOMERS" exakit_load_local_file 2>&1)"
lacks "...while a plain comma file says nothing about it" "separat" "$OUT"

printf '\n== the CLI takes the path too ==\n'

CLI="$(cat "$ROOT/setup/exakit")"
has "data-load accepts a path argument" '_dl_path="$1"' "$CLI"
has "a path pre-answers the local-data question" 'EXAKIT_DATA_FILE="$_dl_norm"' "$CLI"
has "a missing path is refused" 'No such file, folder or dataset' "$CLI"
has "...unless it names a bundled dataset, which loads like EXAKIT_DATASETS" 'EXAKIT_DATASETS="$_dl_path"' "$CLI"
HELP="$(cat "$ROOT/setup/help/exakit.json")"
has "the help documents a folder" "A FOLDER is a bulk load" "$HELP"
lacks "the help no longer documents a format variable" "EXAKIT_DATA_FORMATS" "$HELP"

printf '\n== Windows loads JSON where the engine exists ==\n'

# The JSON Tables add-on publishes a build for windows/x86_64, so the add-on
# is applicable, offered and installable there - but exapump.ps1 refused every
# .json file unconditionally, with a message that contradicted itself by ending
# "Windows x86_64 is supported; ARM64 is not built yet." The refusal outlived
# the limitation it was written for, kept alive by a comment asserting it.
EXAPUMP_PS1="$(cat "$ROOT/setup/lib/exapump.ps1")"
EXAPUMP_SH_ALL="$(cat "$ROOT/setup/lib/exapump.sh")"

# The three shell helpers, and their twins.
has "the shell knows when it is ready"  "_exakit_json_tables_ready() {"        "$EXAPUMP_SH_ALL"
has "...and Windows does too"           "function Test-ExakitJsonTablesReady"  "$EXAPUMP_PS1"
has "the shell installs on demand"      "_exakit_json_tables_ensure() {"       "$EXAPUMP_SH_ALL"
has "...and Windows does too"           "function Confirm-ExakitJsonTablesReady" "$EXAPUMP_PS1"
has "the shell loads a JSON file"       "exakit_load_local_json() {"           "$EXAPUMP_SH_ALL"
has "...and Windows does too"           "function Import-ExakitLocalJson"      "$EXAPUMP_PS1"

# The refusal survives, but only where the engine can never exist.
has "the refusal asks first"            'if ($kind -eq "json" -and -not (Test-ExakitJsonTablesApplicable))' "$EXAPUMP_PS1"
check "both entry points ask"           "2" \
    "$(printf '%s\n' "$EXAPUMP_PS1" | grep -c 'json" -and -not (Test-ExakitJsonTablesApplicable)')"
# ...and never unconditionally, which is what shipped.
lacks "no blanket refusal"              'if ((Get-ExakitDataFileKind $path) -eq "json") {'  "$EXAPUMP_PS1"
lacks "...on either path"               'if ((Get-ExakitDataFileKind $name) -eq "json") {'  "$EXAPUMP_PS1"

# A local file, a downloaded one and a folder's JSON files take the same path.
check "all three routes reach the loader" "3" \
    "$(printf '%s\n' "$EXAPUMP_PS1" | grep -c 'Import-ExakitLocalJson -Path')"

# The install announces itself once, in the words the shell uses, with an ASCII
# hyphen because every .ps1 but ui.ps1 is ASCII-only.
# The announcement is LOGGED, not printed. It fires mid-folder-load, where the
# one-line progress bar owns the row and rewrites it continuously, so the line
# landed inside the bar. ok_step could not save it either: its pause looks for a
# spinner, and a progress bar is a different animator holding the same line.
lacks "no add-on line prints over the bar" 'ok_step "JSON Tables installed' "$EXAPUMP_SH_ALL"
lacks "...nor on Windows"                  'OkStep "JSON Tables installed'  "$EXAPUMP_PS1"
has "the shell logs it instead"   '_exakit_log_file "OK    JSON Tables installed' "$EXAPUMP_SH_ALL"
has "...and Windows logs it too"  'Write-ExakitLog "OK" "JSON Tables installed'   "$EXAPUMP_PS1"

# The comment that kept the refusal alive after the code outgrew it.
lacks "the stale claim is gone"         "Windows cannot run the"               "$EXAPUMP_PS1"
# ...and the advice no longer names three platforms, one of which is this one.
lacks "no misleading platform list"     "load it from macOS, Linux or WSL"     "$EXAPUMP_PS1"

# What the prompt offers is what it accepts.
has "the prompt offers JSON"            "Local CSV / Parquet / JSON file"      "$EXAPUMP_PS1"
has "...and so does the remote one"     "Remote CSV / Parquet / JSON URL"      "$EXAPUMP_PS1"

printf '\n== a FATAL upload failure names the reason too ==\n'

# The translator was used on the soft path and dropped on the fatal one, so the
# worse outcome got the worse message. exakit_explain_db_error, which the fatal
# path did call, knows connection, LIMIT and privilege faults - a malformed CSV
# is none of those, and it is the commonest upload failure there is, so a single
# file load died as "(see log)" while the folder loop above was already putting
# the very same engine line into words.
#
# exapump_upload is stubbed further up this suite, and `die` exits the shell it
# runs in, so the real function is exercised in a child bash: the engine fails
# and writes its Error: line to the logfile, which is the whole situation. An
# earlier, unrelated Error: line (the MCP write probe's) is already there: the
# reason is this upload's own, never that one.
FATAL_LOG="$WORK/fatal.log"
FATAL_SAYS="$WORK/fatal.says"
printf '%s\n' 'Error: Query execution failed: Protocol error: insufficient privileges for creating table (SQL state: 42500)' > "$FATAL_LOG"
cat > "$FATAL_SAYS" <<'FATALLOG'
Error: SQL execution failed: Protocol error: ETL-2107: Error while parsing row=412 (starting from 0) [CSV Parser found at byte 8 of 76 single field delimiter in a not enclosed field]
FATALLOG

fatal_upload() { # fatal_upload <log-file> -> the message a doomed upload prints
    EXAKIT_HOME="$WORK/home" EXAKIT_BIN_DIR="$WORK/bin" HOME="$WORK/fake-home" \
    bash -c '
        set -u
        . "$1/setup/lib/ui.sh"
        . "$1/setup/lib/common.sh"
        . "$1/setup/lib/exapump.sh"
        EXAKIT_LOG_FILE="$2"; SAYS="$4"
        # The layer below: the upload fails, and the engine says why in the logfile.
        run_logged() { cat "$SAYS" >> "$EXAKIT_LOG_FILE"; return 1; }
        exapump_upload "$3" "STARTER_KIT.SALES"
    ' _ "$ROOT" "$1" "$D/sales.csv" "$FATAL_SAYS" 2>&1
}

FATAL_OUT="$(fatal_upload "$FATAL_LOG" || true)"

has "the fatal path says what the engine said" \
    "row 412 has a line break or an unescaped comma inside a quoted field" "$FATAL_OUT"
has "...and names the file and the table it was going into" \
    "Could not load sales.csv into STARTER_KIT.SALES" "$FATAL_OUT"
lacks "the fatal path no longer sends the reader to the log" "Upload failed:" "$FATAL_OUT"

# The fallback survives: when this upload wrote nothing to translate, inventing a
# reason would be worse than the old wording - and an EARLIER failure's Error:
# line (the MCP probe's, still in the log) is not this upload's reason.
: > "$FATAL_SAYS"
FATAL_BARE="$(fatal_upload "$FATAL_LOG" || true)"
has "an untranslatable failure keeps the old wording" "Upload failed:" "$FATAL_BARE"
lacks "...and invents no reason" "Could not load sales.csv" "$FATAL_BARE"
lacks "...nor borrows an earlier failure's" "insufficient privileges" "$FATAL_BARE"

# Both paths call the same translator, on both sides of the kit.
FATAL_SH="$(cat "$ROOT/setup/lib/exapump.sh")"
FATAL_PS="$(cat "$ROOT/setup/lib/exapump.ps1")"
has "the shell fatal path asks for the reason" \
    '_upl_why="$(exakit_upload_failure_reason' "$FATAL_SH"
has "the twin asks for it on its fatal path too" \
    '$uploadWhy = Get-ExakitUploadFailureReason -Output $result.Output' "$FATAL_PS"
has "...and puts it in the message it dies with" \
    'Fail "Could not load $(Split-Path $Path -Leaf) into $Target - $uploadWhy$gone"' "$FATAL_PS"
check "the twin asks on both paths, not one" "2" \
    "$(printf '%s\n' "$FATAL_PS" | grep -c 'Get-ExakitUploadFailureReason -Output $result.Output')"

printf '\n== a stray double quote is named as one, not as a line break ==\n'

# Seen live on Windows, with both line endings: an inch mark in an unquoted
# field (1,27" monitor,4). "Field delimiter" is Exasol's name for the QUOTE
# character, so ETL-2107's "single field delimiter in a not enclosed field" is
# exactly that - and the kit told the reader to look for a line break or a comma
# inside quotes, which the file does not have. The same engine words still read
# as a line break when the file's quotes are in order, because they are.
INCH="$WORK/inch"; mkdir -p "$INCH"
printf 'id,item,qty\n1,27" monitor,4\n2,desk,1\n' > "$INCH/c_inch.csv"
printf 'id,item,qty\r\n1,27" monitor,4\r\n2,desk,1\r\n' > "$INCH/c_inch_crlf.csv"
printf 'id,item,qty\n1,"two\nlines",4\n2,"a ""quoted"" word",1\n' > "$INCH/c_break.csv"
printf 'id;item\n1;"ok"\n2;5 foot 11" tall\n' > "$INCH/c_semi.csv"
INCH_SAYS="$WORK/inch.says"
cat > "$INCH_SAYS" <<'INCHLOG'
Error: SQL execution failed: Protocol error: ETL-2107: Error while parsing row=0 (starting from 0) [CSV Parser found at byte 4 (starting with 1 at the beginning of the row) of 4 single field delimiter in a not enclosed field in file '001.csv'. Please check for unescaped field delimiters in data fields (they have to be escaped)] (Session: 1)
INCHLOG
INCH_WORDS='row 0 has a double quote (") inside a field that is not in quotes: put that field in quotes and double the quote (e.g. "27"" monitor")'
EXAKIT_LOG_FILE="$WORK/inch.log"
cp "$INCH_SAYS" "$EXAKIT_LOG_FILE"; EXAKIT_REASON_SINCE=0
check "an inch mark in an unquoted field is called a double quote" \
    "$INCH_WORDS" "$(exakit_upload_failure_reason "$INCH/c_inch.csv")"
check "...with Windows line endings too" \
    "$INCH_WORDS" "$(exakit_upload_failure_reason "$INCH/c_inch_crlf.csv")"
check "...and in a ';' file" \
    'row 0 has a double quote (") inside a field that is not in quotes: put that field in quotes and double the quote (e.g. "27"" monitor")' \
    "$(exakit_upload_failure_reason "$INCH/c_semi.csv")"
check "a file whose quotes are in order keeps the line-break reading" \
    "row 0 has a line break or an unescaped comma inside a quoted field" \
    "$(exakit_upload_failure_reason "$INCH/c_break.csv")"
check "...and so does a call that names no file" \
    "row 0 has a line break or an unescaped comma inside a quoted field" \
    "$(exakit_upload_failure_reason)"
EXAKIT_LOG_FILE="$WORK/test.log"

# The whole sentence, through the real uploader: exapump fails with the live
# message and leaves the empty table it created, which the kit drops.
inch_upload() { # inch_upload <file> <table> -> what the doomed upload prints
    : > "$WORK/inch.run.log"
    EXAKIT_HOME="$WORK/home" EXAKIT_BIN_DIR="$WORK/bin" HOME="$WORK/fake-home" \
    bash -c '
        set -u
        . "$1/setup/lib/ui.sh"
        . "$1/setup/lib/common.sh"
        . "$1/setup/lib/exapump.sh"
        EXAKIT_LOG_FILE="$2"; SAYS="$3"; TABLE="$5"
        run_logged() { cat "$SAYS" >> "$EXAKIT_LOG_FILE"; return 1; }
        run_python() { return 1; }
        exapump_cli() { printf "%s\n" true; }
        exakit_table_rows_listing() { printf "EXAKIT.LISTING_ANSWERED|1\n%s|0\n" "$TABLE"; }
        EXAKIT_UPLOAD_TABLE_BEFORE=absent exapump_upload "$4" "$TABLE"
    ' _ "$ROOT" "$WORK/inch.run.log" "$INCH_SAYS" "$1" "$2" 2>&1
}
INCH_OUT="$(inch_upload "$INCH/c_inch.csv" STARTER_KIT.C_INCH || true)"
has "the single-file load says it in one sentence" \
    "Could not load c_inch.csv into STARTER_KIT.C_INCH - $INCH_WORDS, no empty table left behind" \
    "$(printf '%s' "$INCH_OUT" | sed 's/ — / - /')"
lacks "...and no longer sends the reader looking for a line break" "line break" "$INCH_OUT"
INCH_OUT="$(inch_upload "$INCH/c_inch_crlf.csv" STARTER_KIT.C_INCH || true)"
has "...for a Windows-ended file as well" "$INCH_WORDS" "$INCH_OUT"

# The folder loop reads the reason in its own shell: it names the file too.
FOLD_SH="$(cat "$ROOT/setup/lib/exapump.sh")"
has "the folder loop names the file it is explaining" \
    '_blf_why="$(exakit_upload_failure_reason "$_blf_path"' "$FOLD_SH"

printf '\n== a second run of the same folder must not load it twice ==\n'

# THE BUG THIS SECTION EXISTS FOR. exapump's upload APPENDS. A folder loaded
# once and loaded again put every row in twice - no error, no warning, and no
# way to tell afterwards which half was which. A reader whose load stopped
# partway through and who simply ran it again got a schema of doubled tables.
#
# The database is stubbed at the listing, so the whole decision runs here with
# no engine: what is under test is which files the loop would touch, which is
# the part that was wrong.
RCPT="$WORK/rcpt"; mkdir -p "$RCPT/cache"
EXAKIT_CACHE_DIR="$RCPT/cache"
printf 'a,b\n1,2\n' > "$RCPT/sales.csv"
printf 'x,y\n9,8\n' > "$RCPT/customers.csv"
# The shape the loop actually passes: the plan with its "load|" prefix already
# cut off, which is three fields, not four.
DPLAN="csv|SALES|$RCPT/sales.csv
csv|CUSTOMERS|$RCPT/customers.csv"

# Nothing in the database yet: both files are new.
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\n'; }
rm -f "$RCPT/cache/load-receipts.tsv" "$RCPT/cache/load-inflight"
D1="$(exakit_bulk_decide "$DPLAN" T)"
check "an empty schema loads everything" "2" "$(printf '%s\n' "$D1" | grep -c '^load|')"

# sales.csv landed: 2 rows, and a receipt saying so.
exakit_load_receipt_record "T.SALES" "$RCPT/sales.csv" 2
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.SALES|2\n'; }
D2="$(exakit_bulk_decide "$DPLAN" T)"
has "the file already loaded is skipped, not re-sent" "done|$RCPT/sales.csv|2" "$D2"
has "...and the one that never landed still loads"    "load|$RCPT/customers.csv|" "$D2"

# The receipt is not a licence to skip forever. If the table no longer holds
# what we put there - dropped and rebuilt, truncated, added to - the rows are
# not ours to reason about, and the answer is a question, not an assumption.
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.SALES|7\n'; }
has "a receipt whose row count no longer matches is not trusted" \
    "clash|$RCPT/sales.csv|7" "$(exakit_bulk_decide "$DPLAN" T)"

# A table with rows and no receipt at all is the reader's own data.
rm -f "$RCPT/cache/load-receipts.tsv"
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.SALES|99\n'; }
has "rows this kit did not load are a clash" "clash|$RCPT/sales.csv|99" "$(exakit_bulk_decide "$DPLAN" T)"

# ...unless we said, before we started, that we were writing to it. That crumb
# is the only thing separating "we were interrupted mid-file" from "this is
# someone else's table", and it decides whether the rows get dropped.
exakit_load_inflight_set "T.SALES" absent
has "a table we were interrupted writing is resumed" "resume|$RCPT/sales.csv|99" "$(exakit_bulk_decide "$DPLAN" T)"
exakit_load_inflight_set "T.SALES" 0
has "...and so is one that was empty before" "resume|$RCPT/sales.csv|99" "$(exakit_bulk_decide "$DPLAN" T)"
# DAT-01: a table that held rows before the interrupted write was being
# APPENDED to. "resume" dropped it - the rows the kit never loaded with it -
# under the default "skip", exit 0. Now it is a question, never a drop.
exakit_load_inflight_set "T.SALES" 5000
_d01="$(exakit_bulk_decide "$DPLAN" T 2>"$WORK/d01.err")"
has "an interrupted APPEND is a clash, not a resume" "clash|$RCPT/sales.csv|99" "$_d01"
has "...and says why it is left as it is" "already held 5000 rows: part of the file may be in it now" "$(cat "$WORK/d01.err")"
has "...with the remedy" "EXAKIT_ON_EXISTING=replace" "$(cat "$WORK/d01.err")"
# A crumb written by an older kit says nothing about before: not enough to drop.
printf 'T.SALES\n' > "$RCPT/cache/load-inflight"
has "an old crumb with no 'before' is a clash too" "clash|$RCPT/sales.csv|99" "$(exakit_bulk_decide "$DPLAN" T 2>/dev/null)"
exakit_load_inflight_clear
has "...and once the crumb is swept it is a clash again" "clash|$RCPT/sales.csv|99" "$(exakit_bulk_decide "$DPLAN" T)"

# An EMPTY table is neither loaded nor a clash: a failed import leaves one
# behind, and refusing to load into it would strand the file forever.
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.SALES|0\n'; }
has "an empty table is loaded into, not treated as occupied" "load|$RCPT/sales.csv|" "$(exakit_bulk_decide "$DPLAN" T)"

# A database that cannot be ASKED is not an empty one, and must not stop a load.
exakit_table_rows_listing() { printf ''; }
check "an unreachable database still loads every file" "2" \
    "$(exakit_bulk_decide "$DPLAN" T | grep -c '^load|')"

# A JSON document does not become ONE table. json-tables shreds it into
# SCHEMA.<base>_<array> per array it finds, so the table the plan named never
# exists - and a target-keyed skip check answers "nothing there" every time,
# which is how a second run would shred the same document on top of itself.
printf '{"orders":[{"id":1}],"items":[{"id":2}]}\n' > "$RCPT/feed.json"
JPLAN="json|FEED|$RCPT/feed.json"
rm -f "$RCPT/cache/load-receipts.tsv"
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\n'; }
has "an unshredded JSON file loads" "load|$RCPT/feed.json|" "$(exakit_bulk_decide "$JPLAN" T)"

# It landed as two tables, neither of them T.FEED.
exakit_load_receipt_record "T.FEED_ORDERS" "$RCPT/feed.json" 1
exakit_load_receipt_record "T.FEED_ITEMS"  "$RCPT/feed.json" 1
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.FEED_ORDERS|1\nT.FEED_ITEMS|1\n'; }
has "a shredded JSON file is skipped on the second run" "done|$RCPT/feed.json|2" \
    "$(exakit_bulk_decide "$JPLAN" T)"

# EVERY table it made, not just the first: a document that shredded into two
# and lost one is a load to redo, not a load to skip.
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.FEED_ORDERS|1\n'; }
has "...but only while every table it made is still intact" "load|$RCPT/feed.json|" \
    "$(exakit_bulk_decide "$JPLAN" T)"
# ...and the same file loaded into a DIFFERENT schema is a different question.
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.FEED_ORDERS|1\nT.FEED_ITEMS|1\n'; }
has "a receipt in one schema does not skip a load into another" "load|$RCPT/feed.json|" \
    "$(exakit_bulk_decide "json|FEED|$RCPT/feed.json" OTHER)"
# The file-keyed lookup is for JSON only. A CSV whose named table is empty is a
# load, whatever receipts exist elsewhere.
exakit_load_receipt_record "T.ELSEWHERE" "$RCPT/sales.csv" 4
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.SALES|0\nT.ELSEWHERE|4\n'; }
has "a CSV is still decided on the table the plan names" "load|$RCPT/sales.csv|" \
    "$(exakit_bulk_decide "csv|SALES|$RCPT/sales.csv" T)"
rm -f "$RCPT/cache/load-receipts.tsv"

printf '\n== the clash question is asked once, and skip is the safe default ==\n'

exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.SALES|99\nT.CUSTOMERS|5\n'; }
CPLAN="$(exakit_bulk_decide "$DPLAN" T)"
check "two occupied tables are two clashes" "2" "$(printf '%s\n' "$CPLAN" | grep -c '^clash|')"
# Without a terminal the answer is skip. Appending by accident cannot be undone
# without knowing which rows were new; skipping costs a re-run.
CANS="$(_exakit_prompt_tty() { printf ''; }; exakit_bulk_ask_clashes "$CPLAN" T 2>/dev/null)"
check "no terminal means skip, and nothing else" "skip" "$CANS"
# THE BUG THAT SHIPPED IN THE FIRST DRAFT OF THIS FIX. The function is read
# through $(...), so a list or a sentence printed on stdout does not reach the
# screen - it becomes part of the answer, which then matches none of the three
# cases and falls through to appending. Every line of its UI goes to stderr.
CNOISE="$(_exakit_prompt_tty() { printf ''; }; exakit_bulk_ask_clashes "$CPLAN" T 2>/dev/null)"
check "the answer is the whole of stdout, with no UI mixed in" "1" \
    "$(printf '%s\n' "$CNOISE" | grep -c .)"
CERR="$(_exakit_prompt_tty() { printf ''; }; exakit_bulk_ask_clashes "$CPLAN" T 2>&1 >/dev/null)"
has "...and the list the reader needs is on stderr" "sales.csv" "$CERR"
has "...naming what is already in the table" "99 rows already" "$CERR"

printf '\n== a failed import leaves no empty table behind ==\n'

# exapump CREATES the table from the inferred schema before it imports a row,
# so a file the engine then refuses leaves an empty table standing. That table
# is worse than nothing: every "is it loaded?" check the kit has says yes over
# a table holding nothing. This is what the live database looked like after a
# CRLF file failed - STUDENTS_PERFORMANCE_DATASET, 0 rows, indistinguishable
# from a loaded one.
DROPPED="$WORK/dropped"; : > "$DROPPED"
exapump_cli() { printf '%s\n' "$WORK/fake-exapump"; }
cat > "$WORK/fake-exapump" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$DROPPED_LOG"
exit 0
STUB
chmod +x "$WORK/fake-exapump"
DROPPED_LOG="$DROPPED"; export DROPPED_LOG

exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.SALES|0\n'; }
GONE="$(exakit_drop_phantom_table T.SALES absent)"
has "a table we created and never filled is dropped" "DROP TABLE IF EXISTS T.SALES" "$(cat "$DROPPED")"
has "...and the reader is told it was" "no empty table left behind" "$GONE"

# Only ever OUR phantom. A table that was already there is the reader's, failed
# import or not, and dropping it would destroy data over a file that never
# loaded.
: > "$DROPPED"
check "a table that existed before is never dropped" "" "$(exakit_drop_phantom_table T.SALES 4)"
check "...and no DROP is issued for it" "0" "$(grep -c . "$DROPPED")"
# Nor one that DID take rows: a table with data in it is not a phantom.
: > "$DROPPED"
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.SALES|12\n'; }
check "a table that took rows is not dropped" "0" \
    "$(exakit_drop_phantom_table T.SALES absent >/dev/null; grep -c . "$DROPPED")"

printf '\n== the result names every file, and its remedy is a command that works ==\n'

OUT="$WORK/outcomes.tsv"
printf 'ok\tsales.csv\tSALES\t2 rows\t\n'                                            >  "$OUT"
printf 'skip\tcustomers.csv\tCUSTOMERS\t5 rows\talready loaded from this file\n'     >> "$OUT"
printf 'fail\twindows.csv\tWINDOWS\tnot loaded\tWindows line endings (CRLF)\n'       >> "$OUT"
REPORT="$(UI_TICK='[ok]' UI_CROSS='[x]' UI_BULLET='-' exakit_bulk_print_outcomes "$OUT" TESTING)"
has "the schema the files went into is named" "into TESTING"          "$REPORT"
has "a loaded file names its table and its row count" "sales.csv"     "$REPORT"
has "...with the rows it landed"                     "2 rows"         "$REPORT"
has "a skipped file says so"                         "already loaded from this file" "$REPORT"
has "a failed file is marked as failed"              "[x]"            "$REPORT"
has "...and its reason sits under it, not in a progress bar" "Windows line endings (CRLF)" "$REPORT"
has "every file appears, loaded or not"              "windows.csv"    "$REPORT"
# One column for the targets. The marks are different widths without colour,
# and padding only the names put every target in a different column.
check "the target column is aligned across all three rows" "1" \
    "$(printf '%s\n' "$REPORT" | grep -o '\->' | wc -l | tr -d ' ' >/dev/null; \
       printf '%s\n' "$REPORT" | grep -n '\->' | sed 's/:.*//' >/dev/null; \
       printf '%s\n' "$REPORT" | awk '/->/{print index($0,"->")}' | sort -u | wc -l | tr -d ' ')"

# THE MISMATCH THE READER HIT. The summary said "full detail: exakit logs", and
# `exakit logs` with no argument lists the log TARGETS and shows none of them -
# so following the remedy landed on a chooser, still not knowing what failed.
# A remedy has to be a command that shows the thing it promises.
BULK_SH="$(grep -v '^[[:space:]]*#' "$ROOT/setup/lib/exapump.sh")"
BULK_PS="$(grep -v '^[[:space:]]*#' "$ROOT/setup/lib/exapump.ps1")"
lacks "the summary no longer points at a command that lists targets" \
    "full detail: exakit logs)" "$BULK_SH"
lacks "...nor does the twin" "full detail: exakit logs)" "$BULK_PS"
has "it names the log that holds the answer" "exakit logs setup" "$BULK_SH"
has "...and so does the twin"                "exakit logs setup" "$BULK_PS"
check "no bare 'exakit logs' remedy survives in the data-load path" "0" \
    "$(printf '%s\n' "$BULK_SH" "$BULK_PS" | grep -c 'exakit logs)' || true)"

# "Loaded 0 of 3" was what a fully-resumed run said about a schema holding every
# row it was asked for: a true count of a number nobody wanted, reading as total
# failure.
lacks "the count no longer reports a resumed run as a failure" \
    'Loaded $_blf_done of $_blf_n' "$BULK_SH"
has "the summary names what was skipped, not just what loaded" \
    "already there and left alone" "$BULK_SH"
has "...on the PowerShell side too" "already there and left alone" "$BULK_PS"

# Both sides, same decisions, same names for them.
for _v in exakit_load_receipt_record exakit_load_receipt_match exakit_bulk_decide \
          exakit_drop_phantom_table exakit_load_inflight_set; do
    has "the shell side has $_v" "$_v" "$BULK_SH"
done
for _v in Write-ExakitLoadReceipt Get-ExakitLoadReceipt Get-ExakitBulkDecisions \
          Remove-ExakitPhantomTable Set-ExakitLoadInflight Show-ExakitBulkOutcomes; do
    has "the twin has $_v" "$_v" "$BULK_PS"
done

printf '\n== a single file is held to the same rule as a folder ==\n'

# THE SMALL DOOR HAD NO GUARD. The folder path asks EXAKIT_ON_EXISTING before it
# touches a table holding rows this kit did not load; the single-file path called
# exapump's upload - which APPENDS - without looking. So replace, skip and the
# default all appended, the policy was never mentioned, and someone meaning to
# rebuild a table doubled it instead (upstream issue #29). The database is
# stubbed at the listing and the count, as above: what is under test is the
# decision, the DROP, the receipt and the exit code.
SF="$WORK/single"; mkdir -p "$SF/cache"
EXAKIT_CACHE_DIR="$SF/cache"
printf 'A\nb\n' > "$SF/x.csv"
EXAKIT_DATA_FILE="$SF/x.csv"; EXAKIT_DATA_TABLE="T.X"
export EXAKIT_DATA_FILE EXAKIT_DATA_TABLE
# No terminal: the prompts take their defaults and the clash answer is skip.
_exakit_prompt_tty() { printf ''; }
# The verified count after an upload, which the receipt is written from.
FAKE_COUNT=1
exapump_count() { printf '%s\n' "$FAKE_COUNT"; }
# One file for both the DROP (fake exapump) and the upload (stub), so their
# ORDER can be read back: the drop has to come first.
DROPPED_LOG="$LOADED"; export DROPPED_LOG
sf_reset() { : > "$LOADED"; rm -f "$SF/cache/load-receipts.tsv" "$SF/cache/load-inflight"; }

# A table holding one row this kit did not load, and no policy given.
sf_reset
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.X|1\n'; }
SFO="$( (exakit_load_local_file) 2>&1 )"; SFRC=$?
check "rows this kit did not load are not loaded over, by default" "5" "$SFRC"
has "...and the refusal names the table and what it holds" "Not loaded: T.X already holds 1 row" "$SFO"
has "...and the remedy names both overrides" "EXAKIT_ON_EXISTING=replace" "$SFO"
has "...the append one too"                  "=append" "$SFO"
check "nothing reached the database"  "0" "$(grep -c . "$LOADED")"
check "...and no receipt was written" "0" "$(cat "$SF/cache/load-receipts.tsv" 2>/dev/null | grep -c . || true)"

# skip, said out loud, is the same answer.
sf_reset
SFO="$( (EXAKIT_ON_EXISTING=skip exakit_load_local_file) 2>&1 )"; SFRC=$?
check "skip declines the load" "5" "$SFRC"
check "...and sends nothing" "0" "$(grep -c . "$LOADED")"

# replace: the table is dropped BEFORE the file goes in - the half the issue
# was about, where a rebuild silently became a doubling.
sf_reset
SFO="$( (EXAKIT_ON_EXISTING=replace exakit_load_local_file) 2>&1 )"; SFRC=$?
check "replace loads" "0" "$SFRC"
has "replace drops the table"       "DROP TABLE IF EXISTS T.X" "$(cat "$LOADED")"
has "...then loads the file into it" "upload x.csv -> T.X"     "$(cat "$LOADED")"
check "...in that order" "yes" \
    "$(_d="$(grep -n 'DROP TABLE' "$LOADED" | head -1 | cut -d: -f1)"; _u="$(grep -n 'upload x.csv' "$LOADED" | head -1 | cut -d: -f1)"; [ -n "$_d" ] && [ -n "$_u" ] && [ "$_d" -lt "$_u" ] && echo yes || echo no)"
has "...and says which policy applied" "Replacing the 1 row already in T.X" "$SFO"
has "...naming the variable"           "EXAKIT_ON_EXISTING=replace" "$SFO"
has "a receipt is written for the file" "T.X	" "$(cat "$SF/cache/load-receipts.tsv" 2>/dev/null)"

# The receipt is what makes a second run of the same file safe: the table
# holds exactly what this file put there, so it is left as it is - exit 0,
# nothing sent, and the two overrides named for anyone who meant it.
: > "$LOADED"
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.X|1\n'; }
SFO="$( (exakit_load_local_file) 2>&1 )"; SFRC=$?
check "the same file again is recognised" "0" "$SFRC"
has "...and left as it is" "already holds the 1 row this file loaded" "$SFO"
has "...with the overrides named" "EXAKIT_ON_EXISTING=append" "$SFO"
check "...and nothing is sent twice" "0" "$(grep -c . "$LOADED")"
# ...but only while the count still matches: a table added to since is the
# reader's again, and the answer is a question, not an assumption.
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.X|7\n'; }
SFO="$( (exakit_load_local_file) 2>&1 )"; SFRC=$?
check "a receipt whose row count no longer matches is not trusted" "5" "$SFRC"
# ...and append on a recognised file is honoured, not refused.
: > "$LOADED"
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.X|1\n'; }
SFO="$( (EXAKIT_ON_EXISTING=append exakit_load_local_file) 2>&1 )"; SFRC=$?
check "append loads on top of a recognised file" "0" "$SFRC"
has "...saying so" "Appending to the 1 row already in T.X" "$SFO"
lacks "...without a DROP" "DROP TABLE" "$(cat "$LOADED")"
has "...and the file goes in" "upload x.csv -> T.X" "$(cat "$LOADED")"

# append over a clash: the rows stay, the file lands, the policy is named.
sf_reset
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.X|99\n'; }
SFO="$( (EXAKIT_ON_EXISTING=append exakit_load_local_file) 2>&1 )"; SFRC=$?
check "append over foreign rows loads" "0" "$SFRC"
lacks "...and drops nothing" "DROP TABLE" "$(cat "$LOADED")"
has "...and says which policy applied" "Appending to the 99 rows already in T.X (EXAKIT_ON_EXISTING=append)" "$SFO"

# NEW-12: a file EDITED since this kit loaded it. The receipts match on
# content, so it is not "already loaded" - and it was called "rows this kit did
# not load", which made append look safe: every unchanged row then landed
# twice. The receipt for the same path says what it is: the kit's own rows,
# from the earlier version.
sf_reset
printf 'A\nb\n' > "$SF/x.csv"
exakit_load_receipt_record "T.X" "$SF/x.csv" 1
printf 'A\nb\nc\n' > "$SF/x.csv"
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.X|1\n'; }
has "the receipt keeps the file's full path" "	$(cd "$SF" && pwd -P)/x.csv" "$(cat "$SF/cache/load-receipts.tsv")"
has "an edited file is recognised as this kit's own, changed" "x.csv|" "$(exakit_load_receipt_changed T.X "$SF/x.csv" 1)"
SFO="$( (exakit_load_local_file) 2>&1 )"; SFRC=$?
check "an edited file is not loaded over without an answer" "5" "$SFRC"
has "...and says the rows are this kit's, from that file" "Not loaded: T.X holds the 1 row this kit loaded from x.csv on 20" "$SFO"
has "...and that the file changed" "and the file has changed since." "$SFO"
has "...with replace as the remedy and append named for what it does" \
    "Load the new version with EXAKIT_ON_EXISTING=replace (drop and rebuild it); =append would add every row again on top of the old ones." "$SFO"
lacks "...never \"did not load\"" "did not load" "$SFO"
check "...and nothing reached the database" "0" "$(grep -c . "$LOADED")"
# At a terminal: replace is offered first and is the default.
eval "$(declare -f prompt_text | sed '1s/^prompt_text/_g2_real_prompt_text/')"
_exakit_prompt_tty() { printf 'stdin\n'; }
prompt_text() { printf '%s|%s\n' "$1" "$2" >> "$SF/asked"; printf '%s\n' "$2"; }
: > "$SF/asked"
SFO="$( (exakit_load_local_file) 2>&1 )"; SFRC=$?
_exakit_prompt_tty() { printf ''; }
check "at a terminal, Enter replaces the edited file's table" "0" "$SFRC"
has "...the question offers replace first, default r" \
    "That table: (r)eplace it with the new version, (a)ppend (adds every row again: unchanged rows end up twice), or (s)kip|r" "$(cat "$SF/asked")"
has "...after saying what the table holds" "T.X holds the 1 row this kit loaded from x.csv on 20" "$SFO"
has "...and the table is rebuilt" "DROP TABLE IF EXISTS T.X" "$(cat "$LOADED")"
# Another file's rows in that table are still "no load record for this file".
sf_reset
printf 'z\n1\n' > "$SF/other.csv"
exakit_load_receipt_record "T.X" "$SF/other.csv" 1
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.X|1\n'; }
SFO="$( (exakit_load_local_file) 2>&1 )"; SFRC=$?
check "another file's rows: declined" "5" "$SFRC"
has "...as rows with no load record for this file" "Not loaded: T.X already holds 1 row with no load record for this file" "$SFO"
# A receipt from before paths were kept is matched by the file's name.
sf_reset
printf 'T.X\t3\tdeadbeef\t1\t1763500000\tx.csv\n' > "$SF/cache/load-receipts.tsv"
has "an older receipt (no path) is matched by name" "x.csv|1763500000" "$(exakit_load_receipt_changed T.X "$SF/x.csv" 1)"
check "...but not once the table holds other rows" "" "$(exakit_load_receipt_changed T.X "$SF/x.csv" 2)"
# The folder: an edited file is named, and when every clash is one, replace
# is first and the default.
sf_reset
exakit_load_receipt_record "T.X" "$SF/x.csv" 1
printf 'A\nb\nc\nd\n' > "$SF/x.csv"
_bac_err="$(exakit_bulk_ask_clashes "clash|$SF/x.csv|1" T "csv|X|$SF/x.csv" 2>&1 >/dev/null)"
has "a folder names an edited file's rows as this kit's" "1 table in T already holding rows this kit loaded from an earlier version of the same file:" "$_bac_err"
has "...and without a terminal points at replace" "Load the new versions with EXAKIT_ON_EXISTING=replace; =append would add every row again" "$_bac_err"
check "...and skips" "skip" "$(exakit_bulk_ask_clashes "clash|$SF/x.csv|1" T "csv|X|$SF/x.csv" 2>/dev/null)"
printf 'q\n1\n' > "$SF/q.csv"
_bac_err="$(exakit_bulk_ask_clashes "clash|$SF/x.csv|1
clash|$SF/q.csv|5" T "csv|X|$SF/x.csv
csv|Q|$SF/q.csv" 2>&1 >/dev/null)"
has "a mixed folder keeps the general question" "2 tables in T already holding rows this kit did not load:" "$_bac_err"
has "...and marks the edited file" "x.csv ->" "$(printf '%s\n' "$_bac_err" | grep 'loaded by this kit from an earlier version of this file')"
_exakit_prompt_tty() { printf 'stdin\n'; }
: > "$SF/asked"
check "at a terminal, Enter replaces every edited file's table" "replace" "$(exakit_bulk_ask_clashes "clash|$SF/x.csv|1" T "csv|X|$SF/x.csv" 2>/dev/null)"
has "...asked with replace first" "Those files: (r)eplace each table with the new version, (a)ppend (adds every row again: unchanged rows end up twice), or (s)kip|r" "$(cat "$SF/asked")"
# One file, a table holding rows another file loaded: the warning speaks of
# this file, not of the kit - the kit may well have loaded those rows.
_fac_err="$(exakit_file_ask_clash "STARTER_KIT.R_CSV" 4 2>&1 >/dev/null)"
has "a single file's clash names this file" "STARTER_KIT.R_CSV already holds 4 rows that this file did not load." "$_fac_err"
lacks "...not the kit" "this kit did not load" "$_fac_err"
_exakit_prompt_tty() { printf ''; }
eval "$(declare -f _g2_real_prompt_text | sed '1s/^_g2_real_prompt_text/prompt_text/')"
printf 'A\nb\n' > "$SF/x.csv"

# An EMPTY table, an ABSENT one and a database that cannot be asked all load,
# exactly as the folder path decides for the same answers - and none of them
# prints a policy line, because no rows were at stake.
for _sf_case in 'T.X|0' absent unreachable; do
    sf_reset
    case "$_sf_case" in
        unreachable) exakit_table_rows_listing() { printf ''; } ;;
        absent)      exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\n'; } ;;
        *)           exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\n%s\n' "$_sf_case"; } ;;
    esac
    SFO="$( (exakit_load_local_file) 2>&1 )"; SFRC=$?
    check "$_sf_case: loads" "0" "$SFRC"
    has "$_sf_case: the file goes in" "upload x.csv -> T.X" "$(cat "$LOADED")"
    lacks "$_sf_case: no policy line for rows that were not there" "EXAKIT_ON_EXISTING" "$SFO"
    has "$_sf_case: a receipt is written" "T.X	" "$(cat "$SF/cache/load-receipts.tsv" 2>/dev/null)"
done

# An unusable value is a refusal (bad input, like an unsupported file), not a
# silent fallback to the most destructive reading.
sf_reset
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.X|1\n'; }
SFO="$( (EXAKIT_ON_EXISTING=nonsense exakit_load_local_file) 2>&1 )"; SFRC=$?
check "an unusable value is refused as bad input" "3" "$SFRC"
has "...naming the three answers" "must be skip, replace or append" "$SFO"
check "...and nothing was touched" "0" "$(grep -c . "$LOADED")"

# Both callers of the loader read exit 5 as "declined", not as a failed step:
# the installer must not write a failure note over the reader's own table.
# The branch itself - _exakit_offer_local_file, which both of the installer's
# paths to a file call (the table's file row and EXAKIT_DATA_FILE beside a
# dataset answer) - lifted out of common.sh and run over a loader that answers
# each status in turn. A grep for the `-eq 5` line passed a mutant that booked
# the decline as a failure right under it; this does not.
_ucs_branch="$(awk '/^_exakit_offer_local_file\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ROOT/setup/lib/common.sh")"
# ...with the helper that books a failure, which keeps every reason.
_ucs_fail="$(awk '/^_exakit_offer_fail\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ROOT/setup/lib/common.sh")"
check "the installer's local-load branch was lifted" "yes" "$(printf '%s' "$_ucs_branch" | grep -q '_local_status" -eq 5' && echo yes || echo no)"
check "...and both installer paths to a file run it" "2" "$(grep -c '^ *_exakit_offer_local_file$' "$ROOT/setup/lib/common.sh")"
_installer_books() { # _installer_books <loader exit status> -> "failed=<0|1> noted=<n> notes=<text>"
    bash -c '
        _data_failed=0; _data_notes=""; _noted=0
        exakit_load_local_file() { return '"$1"'; }
        exakit_note_failure() { _noted=$((_noted + 1)); }
        error() { :; }; printf() { command printf "$@"; }
        '"$_ucs_fail"'
        '"$_ucs_branch"'
        _exakit_offer_local_file
        command printf "failed=%s noted=%s notes=%s" "$_data_failed" "$_noted" "$(command printf "%s" "$_data_notes" | tr "\n" " ")"' 2>/dev/null
}
_b5="$(_installer_books 5)"
has   "a declined load (5) is not booked as a failed step" "failed=0 noted=0" "$_b5"
has   "...and the note says what to decide"      "its table already holds rows" "$_b5"
has   "...naming the switch"                     "EXAKIT_ON_EXISTING=replace" "$_b5"
_b3="$(_installer_books 3)"
has   "a refused file (3) is not booked either"  "failed=0 noted=0" "$_b3"
has   "...but is reported"                       "The local file was refused" "$_b3"
# A file that did not load is the file, not the install, too: booking it said
# "sample data is not installed" over loaded datasets and skipped the
# marketplace offer.
_b1="$(_installer_books 1)"
has   "a file that did not load (1) is not booked" "failed=0 noted=0" "$_b1"
has   "...but is reported, with the retry"       "did not load (reason above). Retry any time with: exakit data-load" "$_b1"
# The Windows twin: the installer's helper says it and does not throw, so
# Request-ExakitDataLoadOffer has no reason to book.
_ps_olf="$(sed -n '/^function Invoke-ExakitOfferLocalFile/,/^}/p' "$ROOT/setup/lib/exapump.ps1")"
has   "...on Windows too: the failure is a warning naming the file(s)" 'did not load (reason above).' "$_ps_olf"
lacks "...and it never rethrows"                 'throw' "$_ps_olf"
has   "...a folder's \"failed\" is said too"     '$failed = ($result -eq "failed")' "$_ps_olf"
has   "a clean load (0) leaves no note"          "failed=0 noted=0 notes=" "$(_installer_books 0)"
has "exakit data-load answers 5 for it" '_menu_status=5' "$BULK_SH"
# The help says the rule covers one file too.
has "the help holds a single file to the same rule" "A SINGLE FILE is held to the same rule" \
    "$(cat "$ROOT/setup/help/exakit.json")"
# Both sides, same decision, same names for it.
for _v in exakit_file_ask_clash exakit_clash_prompt EXAKIT_LAST_VERIFIED_ROWS; do
    has "the shell side has $_v" "$_v" "$BULK_SH"
done
for _v in Read-ExakitFileClashAnswer Read-ExakitClashPrompt ExakitLastVerifiedRows; do
    has "...and Windows does too: $_v" "$_v" "$BULK_PS"
done
has "the twin reads the policy on the single-file path" 'return "declined"' "$BULK_PS"
has "...and the Windows command answers 5 for it" 'if ($result -eq "declined") { $script:PendingExitCode = 5 }' "$BULK_PS"
unset EXAKIT_DATA_FILE EXAKIT_DATA_TABLE

printf '\n== a file name the database would misread still becomes a table ==\n'

# exapump writes the target into its CREATE TABLE unquoted. 2025-01.csv gave
# STARTER_KIT.2025_01 ("syntax error, unexpected UNSIGNED_NUMERIC_LITERAL_")
# and ORDER.csv gave STARTER_KIT.ORDER ("table name not allowed since it is a
# keyword: ORDER"), both seen on a live database: a folder of monthly exports
# loaded nothing. The derived name is a plain identifier now, and said.
check "a leading digit gets T_"       "T_2025_01" "$(exakit_table_name_from_path "$WORK/2025-01.csv")"
check "a reserved word gets T_"       "T_ORDER"   "$(exakit_table_name_from_path "$WORK/ORDER.csv")"
check "...whatever its case"          "T_USER"    "$(exakit_table_name_from_path "$WORK/user.csv")"
check "...and for Parquet too"        "T_DATE"    "$(exakit_table_name_from_path "$WORK/date.parquet")"
check "an ordinary name is untouched" "SALES"     "$(exakit_table_name_from_path "$WORK/sales.csv")"
check "a name is cut at 128 characters" "128" \
    "$(_n="$(exakit_table_name_from_path "$WORK/$(printf 'a%.0s' $(seq 1 200)).csv")"; printf '%s' "${#_n}")"
exakit_validate_table_target "STARTER_KIT.ORDER"; check "a typed reserved table name is refused" "1" "$?"
exakit_validate_table_target "2025.SALES";        check "...and a schema starting with a digit" "1" "$?"
exakit_validate_table_target "STARTER_KIT.T_ORDER"; check "...while T_ORDER is fine" "0" "$?"
has "the refusal says why" "ORDER is an SQL reserved word" "$(exakit_table_target_problem STARTER_KIT.ORDER)"

NM="$WORK/names"; mkdir -p "$NM/cache"
EXAKIT_CACHE_DIR="$NM/cache"
printf 'a,b\n1,2\n' > "$NM/2025-01.csv"
printf 'a,b\n3,4\n' > "$NM/ORDER.csv"
: > "$LOADED"
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\n'; }
NMO="$( (EXAKIT_DATA_FILE="$NM/2025-01.csv" exakit_load_local_file) 2>&1 )"; NMRC=$?
check "a single 2025-01.csv loads" "0" "$NMRC"
has "...into T_2025_01" "upload 2025-01.csv -> STARTER_KIT.T_2025_01" "$(cat "$LOADED")"
has "...and says the name it got" "2025-01.csv loads as T_2025_01" "$NMO"
: > "$LOADED"
NMO="$(exakit_load_local_folder "$NM" 2>&1)"; NMRC=$?
check "a folder of such files loads" "0" "$NMRC"
has "...ORDER.csv as T_ORDER" "upload ORDER.csv -> STARTER_KIT.T_ORDER" "$(cat "$LOADED")"
has "...2025-01.csv as T_2025_01" "upload 2025-01.csv -> STARTER_KIT.T_2025_01" "$(cat "$LOADED")"
has "...and the plan says why" "T_ goes in front of a name that starts with a digit" "$NMO"
NMO="$( (EXAKIT_DATA_FILE="$NM/ORDER.csv" EXAKIT_DATA_TABLE="STARTER_KIT.ORDER" exakit_load_local_file) 2>&1 )"; NMRC=$?
check "EXAKIT_DATA_TABLE naming a reserved word is refused" "1" "$NMRC"
has "...with the reason" "ORDER is an SQL reserved word" "$NMO"
# The JSON fan-out suffix is a part of a name, not a name: EVENTS_ORDER, not EVENTS_T_ORDER.
check "a name part is not prefixed" "ORDER" "$(_exakit_name_part_from_path "$WORK/order.parquet")"

printf '\n== a single file that fails leaves no empty table behind ==\n'
eval "_saved_upload() $(declare -f exapump_upload | sed 1d)"
exapump_upload() { printf 'before=%s\n' "${EXAKIT_UPLOAD_TABLE_BEFORE:-}" >> "$LOADED"; return 0; }
: > "$LOADED"; rm -f "$NM/cache/load-receipts.tsv"
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\n'; }
( EXAKIT_DATA_FILE="$NM/2025-01.csv" exakit_load_local_file ) >/dev/null 2>&1
has "a new table is announced as not there before" "before=absent" "$(cat "$LOADED")"
: > "$LOADED"
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nSTARTER_KIT.T_2025_01|0\n'; }
( EXAKIT_DATA_FILE="$NM/2025-01.csv" exakit_load_local_file ) >/dev/null 2>&1
check "...an existing empty one is not" "before=" "$(grep '^before=' "$LOADED")"
eval "exapump_upload() $(declare -f _saved_upload | sed 1d)"

printf '\n== one JSON file by name: named after the file, loaded once, failures said ==\n'

# Three defects of the single-JSON path, all seen on a live Windows 11 install
# or reproduced against the kit logic with the engine stubbed:
#  - it appended on every run (rows 3, 6, 9; EXAKIT_ON_EXISTING ignored, no receipt);
#  - its tables were named after the kit's temporary copy (GA_JSON_TEST_NORMALISED);
#  - an engine that could not run was reported as "this JSON file could not be read".
# The ingest engine is a stub that writes Parquet files the way the real one
# names them (<stem>.parquet, <stem>.<array>[].parquet); the database is a
# state file of TABLE|rows that the upload stub adds to and DROP takes from.
eval "exakit_load_local_json() $(declare -f _real_exakit_load_local_json | sed 1d)"
JS="$WORK/json1"; mkdir -p "$JS/cache"
EXAKIT_CACHE_DIR="$JS/cache"
printf '{\n  "id": 1,\n  "tags": ["a", "b"]\n}\n' > "$JS/ga_json_test.json"     # pretty-printed: the kit re-flows it
JSTATE="$JS/state"; : > "$JSTATE"; export JSTATE
cat > "$JS/engine" <<'STUB'
#!/bin/sh
[ -n "${FAKE_JT_FAIL:-}" ] && { echo "error: cannot execute the ingest engine: No such file or directory"; exit 127; }
in=""; out=""
while [ $# -gt 0 ]; do case "$1" in --input) in="$2"; shift ;; --output-dir) out="$2"; shift ;; esac; shift; done
stem="$(basename "$in")"; stem="${stem%.*}"
mkdir -p "$out" && : > "$out/$stem.parquet" && : > "$out/$stem.tags[].parquet"
STUB
chmod +x "$JS/engine"
_exakit_json_tables_ensure() { return 0; }
_exakit_json_tables_bin() { printf '%s\n' "$JS/engine"; }
_exakit_json_tables_logged() { "$@"; }
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\n'; cat "$JSTATE"; }
js_rows() { _r="$(grep "^$1|" "$JSTATE" | cut -d'|' -f2)"; printf '%s' "${_r:-0}"; }
exapump_upload() {
    printf 'upload %s -> %s\n' "$(basename "$1")" "$2" >> "$LOADED"
    _n="$(js_rows "$2")"; grep -v "^$2|" "$JSTATE" > "$JSTATE.t"; printf '%s|%s\n' "$2" "$((_n + 1))" >> "$JSTATE.t"; mv "$JSTATE.t" "$JSTATE"
}
exakit_verify_loaded_table() { EXAKIT_LAST_VERIFIED_ROWS="$(js_rows "$1")"; }
cat > "$WORK/fake-exapump" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$DROPPED_LOG"
case "$*" in *"DROP TABLE IF EXISTS "*) t="$(printf '%s' "$*" | sed 's/.*DROP TABLE IF EXISTS //; s/ .*//')"; grep -v "^$t|" "$JSTATE" > "$JSTATE.t"; mv "$JSTATE.t" "$JSTATE" ;; esac
exit 0
STUB
chmod +x "$WORK/fake-exapump"
js_run() { ( EXAKIT_DATA_FILE="$JS/ga_json_test.json" EXAKIT_DATA_TABLE="T.GA_JSON_TEST" exakit_load_local_file ) 2>&1; }

: > "$LOADED"
JO="$(js_run)"; JRC=$?
check "a JSON file loads" "0" "$JRC"
has "...and says Loaded with the tables it made (F-b: Windows said nothing, exit 5)" "into T.GA_JSON_TEST, T.GA_JSON_TEST_TAGS" "$JO"
has "...its documents into the table named after the file" "upload normalised.parquet -> T.GA_JSON_TEST" "$(cat "$LOADED")"
has "...its array into <table>_TAGS" "upload normalised.tags[].parquet -> T.GA_JSON_TEST_TAGS" "$(cat "$LOADED")"
lacks "...not after the kit's temporary copy" "T.GA_JSON_TEST_NORMALISED" "$(cat "$LOADED")$JO"
has "a receipt is written per table" "T.GA_JSON_TEST_TAGS	" "$(cat "$JS/cache/load-receipts.tsv" 2>/dev/null)"

: > "$LOADED"
JO="$(js_run)"; JRC=$?
check "the same file again is recognised" "0" "$JRC"
has "...and left as it is, naming its tables and the file" "T.GA_JSON_TEST, T.GA_JSON_TEST_TAGS already hold the 2 rows ga_json_test.json loaded" "$JO"
lacks "...and no copy note for the file itself" "has the same content as" "$JO"
check "...nothing is sent twice" "0" "$(grep -c '^upload' "$LOADED")"
check "...and the rows did not double" "1" "$(js_rows T.GA_JSON_TEST)"

# F-c (Windows 11 upgrade): a byte-identical copy matches the original's
# receipts. The message named the copy as the file that made the tables.
cp "$JS/ga_json_test.json" "$JS/ga_json_copy.json"
: > "$LOADED"
JO="$( ( EXAKIT_DATA_FILE="$JS/ga_json_copy.json" EXAKIT_DATA_TABLE="T.GA_JSON_COPY" exakit_load_local_file ) 2>&1 )"; JRC=$?
check "a byte-identical copy is recognised as already loaded" "0" "$JRC"
has "...naming the tables and the file that made them" "T.GA_JSON_TEST, T.GA_JSON_TEST_TAGS already hold the 2 rows ga_json_test.json loaded" "$JO"
has "...and that the copy has the same content" "ga_json_copy.json has the same content as ga_json_test.json" "$JO"
check "...nothing is sent" "0" "$(grep -c '^upload' "$LOADED")"
rm -f "$JS/ga_json_copy.json"

: > "$LOADED"
JO="$( (EXAKIT_ON_EXISTING=replace js_run) 2>&1 )"; JRC=$?
check "replace rebuilds it" "0" "$JRC"
has "...dropping what it loaded before" "DROP TABLE IF EXISTS T.GA_JSON_TEST_TAGS" "$(cat "$LOADED")"
check "...and the table holds one load, not two" "1" "$(js_rows T.GA_JSON_TEST)"

: > "$LOADED"; rm -f "$JS/cache/load-receipts.tsv"; printf 'T.GA_JSON_TEST|40\n' > "$JSTATE"
JO="$(js_run)"; JRC=$?
check "rows this kit did not load are not loaded over, by default" "5" "$JRC"
has "...and the refusal names the table" "Not loaded: T.GA_JSON_TEST already holds 40 rows" "$JO"
check "...nothing was sent" "0" "$(grep -c '^upload' "$LOADED")"
JO="$( (EXAKIT_ON_EXISTING=append js_run) 2>&1 )"; JRC=$?
check "append loads on top" "0" "$JRC"
lacks "...without a DROP" "DROP TABLE" "$(cat "$LOADED")"
check "...on top of the 40" "41" "$(js_rows T.GA_JSON_TEST)"
JO="$( (EXAKIT_ON_EXISTING=nonsense js_run) 2>&1 )"; JRC=$?
check "an unusable EXAKIT_ON_EXISTING is refused for JSON too" "3" "$JRC"

: > "$LOADED"; rm -f "$JS/cache/load-receipts.tsv"; : > "$JSTATE"
EXAKIT_LOG_FILE="$WORK/json-fail.log"; : > "$EXAKIT_LOG_FILE"
run_logged() { "$@" >> "$EXAKIT_LOG_FILE" 2>&1; }
JO="$( (FAKE_JT_FAIL=1 js_run) 2>&1 )"; JRC=$?
check "an engine that cannot run fails the load" "1" "$JRC"
has "...and says it is the engine" "The JSON Tables engine could not load" "$JO"
has "...with the engine's own words" "cannot execute the ingest engine" "$JO"
has "...and the repair" "exakit update json-tables" "$JO"
lacks "...without blaming a valid file" "It must be one JSON document" "$JO"

printf '\n== an interrupted append is never resumed by dropping the table ==\n'

# The folder loop writes in the crumb what the table held before it touched it,
# so a later run knows whether the rows there are all its own. The upload stub
# shows the crumb as the loop left it during the write.
IR="$WORK/inter"; mkdir -p "$IR/cache"; EXAKIT_CACHE_DIR="$IR/cache"
printf 'a,b\n1,2\n' > "$IR/sales.csv"
exapump_upload() { printf 'upload %s -> %s crumb=%s\n' "$(basename "$1")" "$2" "$(cat "$IR/cache/load-inflight" 2>/dev/null)" >> "$LOADED"; return 0; }
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.SALES|5000\n'; }
: > "$LOADED"
( EXAKIT_SCHEMA=T EXAKIT_ON_EXISTING=append exakit_load_local_folder "$IR" ) >/dev/null 2>&1
has "an append records the 5,000 rows that were there" "upload sales.csv -> T.SALES crumb=T.SALES|5000" "$(cat "$LOADED")"
# ...then the run is killed mid-file: the crumb stays, the table holds 5,050.
printf 'T.SALES|5000\n' > "$IR/cache/load-inflight"
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.SALES|5050\n'; }
: > "$LOADED"
IRO="$( ( EXAKIT_SCHEMA=T exakit_load_local_folder "$IR" ) 2>&1 )"
lacks "the next run drops nothing" "DROP TABLE" "$(cat "$LOADED")"
lacks "...and loads nothing over it" "upload sales.csv" "$(cat "$LOADED")"
lacks "...and does not call it half-loaded and reload from scratch" "reloading from scratch" "$IRO"
has "...but says what happened" "An interrupted run was adding sales.csv to T.SALES" "$IRO"
# A table that was absent before the interrupted write is resumed, as before.
printf 'T.SALES|absent\n' > "$IR/cache/load-inflight"
exakit_table_rows_listing() { printf 'EXAKIT.LISTING_ANSWERED|1\nT.SALES|50\n'; }
: > "$LOADED"
IRO="$( ( EXAKIT_SCHEMA=T exakit_load_local_folder "$IR" ) 2>&1 )"
has "a table that was absent before is still resumed" "DROP TABLE IF EXISTS T.SALES" "$(cat "$LOADED")"
has "...and the file loaded again" "upload sales.csv -> T.SALES crumb=T.SALES|absent" "$(cat "$LOADED")"

printf '\n== German number formats never load as wrong numbers ==\n'

# DAT-04, seen on a live database: exapump read Menge 1.234 / 12.500 as DOUBLE
# 1.234 / 12.5 and "Beleg Nr." 0000001237 and PLZ 01067 as 1237 and 1067, under
# a verified row count and a green check. Those columns are created as text,
# from exapump's own dry-run schema, before exapump loads into the table.
eval "exapump_upload() $(declare -f _real_exapump_upload | sed 1d)"
GN="$WORK/german"; mkdir -p "$GN"
printf 'Beleg Nr.;Menge;Betrag;Ort\n0000001237;1.234;1.234,56;Bonn\n4500001234;12.500;99,00;Ulm\n' > "$GN/sap.csv"
printf 'id,amount\n1,1.234\n2,12.5\n' > "$GN/plain.csv"
cat > "$GN/gpump" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$GN_LOG"
case "$*" in
    sql*EXA_ALL_COLUMNS*) printf '%b\n' "$GN_COLS" ;;
    upload*--dry-run*) cat <<'DDL'
Columns:
  "Beleg Nr.": DECIMAL(36,0)
  "Menge": DOUBLE

CREATE TABLE T.SAP (
    "Beleg Nr." DECIMAL(36,0),
    "Menge" DOUBLE,
    "Betrag" VARCHAR(2000000),
    "Ort" VARCHAR(2000000)
);
DDL
    ;;
esac
exit 0
STUB
chmod +x "$GN/gpump"
GN_LOG="$GN/argv"; export GN_LOG GN_COLS
exapump_cli() { printf '%s\n' "$GN/gpump"; }
check "csv_guard names the columns that would load as wrong numbers" "2" \
    "$(run_python "$ROOT/setup/lib/csv_guard.py" numbers "$GN/sap.csv" ';' | grep -c .)"
check "...and none in a comma file whose dots are decimals" "0" \
    "$(run_python "$ROOT/setup/lib/csv_guard.py" numbers "$GN/plain.csv" ',' | grep -c . || true)"
: > "$GN_LOG"; GN_COLS='EXAKIT.COLUMNS_ANSWERED|0|'
GNO="$( (EXAKIT_NUMBER_GUARD=1 exapump_upload "$GN/sap.csv" T.SAP) 2>&1 )"; GNRC=$?
check "a German export loads" "0" "$GNRC"
has "...into a table created first" "sql -p starter-kit CREATE TABLE T.SAP (" "$(cat "$GN_LOG")"
has "...the leading-zero column as text" '"Beleg Nr." VARCHAR(2000000)' "$(cat "$GN_LOG")"
has "...and the thousands-dot column as text" '"Menge" VARCHAR(2000000)' "$(cat "$GN_LOG")"
check "...created before the upload" "yes" \
    "$(_c="$(grep -n 'CREATE TABLE' "$GN_LOG" | cut -d: -f1)"; _u="$(grep -n '^upload' "$GN_LOG" | grep -v dry-run | cut -d: -f1)"; [ -n "$_c" ] && [ -n "$_u" ] && [ "$_c" -lt "$_u" ] && echo yes || echo no)"
has "the reader is told which columns were kept as text" "Kept as text in T.SAP" "$GNO"
has "...and why" "leading zeros (0000001237) would be dropped" "$GNO"
: > "$GN_LOG"; GN_COLS='EXAKIT.COLUMNS_ANSWERED|0|\nEXAKIT_COL|1|DECIMAL(36,0)\nEXAKIT_COL|2|DOUBLE\n"EXAKIT_COL|3|VARCHAR(2000000) UTF8"'
GNO="$( (EXAKIT_NUMBER_GUARD=1 exapump_upload "$GN/sap.csv" T.SAP) 2>&1 )"; GNRC=$?
check "a table that exists with such a column as a number is refused" "1" "$GNRC"
has "...naming the column and its type" 'column "Menge" is DOUBLE' "$GNO"
has "...with the remedy" "EXAKIT_ON_EXISTING=replace" "$GNO"
check "...and nothing is uploaded" "0" "$(grep '^upload' "$GN_LOG" | grep -vc dry-run || true)"
: > "$GN_LOG"
( exapump_upload "$GN/sap.csv" T.SAP ) >/dev/null 2>&1
check "a bundled dataset's upload (no guard) is untouched" "0" "$(grep -c EXA_ALL_COLUMNS "$GN_LOG" || true)"

printf '\n== one JSON file with the engine missing says it is installing it ==\n'

# MCX-01: `exakit data-load <file>.json` with JSON Tables not installed installed
# the engine (about a minute) with nothing on screen: the install's output goes
# to the log, which silences every spinner inside it, and only a folder load had
# a bar to say it. Run on a real pty (a spinner draws only on a terminal), with
# the real marketplace install around a stubbed add-on install. The add-on
# install's own bar-end used to stop the caller's spinner too, leaving its last
# frame frozen on screen with the cursor hidden.
JM="$WORK/jsonmissing"; mkdir -p "$JM"
cat > "$JM/run.sh" <<JMEOF
ROOT="$ROOT"; W="$JM/w"; rm -rf "\$W"; mkdir -p "\$W/h" "\$W/k" "\$W/b"
HOME="\$W/h"; EXAKIT_HOME="\$W/k"; EXAKIT_BIN_DIR="\$W/b"; export HOME
. "\$ROOT/setup/lib/ui.sh"; . "\$ROOT/setup/lib/common.sh"; . "\$ROOT/setup/lib/exapump.sh"
EXAKIT_LOG_FILE="\$W/log"; : > "\$EXAKIT_LOG_FILE"
_exakit_json_tables_load_module() { return 0; }
_exakit_json_tables_ready() { [ -f "\$W/ready" ]; }
_exakit_addon_applicable() { return 0; }
json_tables_install() { run_logged sleep 1; : > "\$W/ready"; }
exakit_record_ownership() { :; }
exakit_install_addon_skills() { :; }
exakit_file_already_landed() { :; }
prompt_text() { printf '%s\n' "\$2"; }
_exakit_json_tables_bin() { printf '%s\n' "\$W/no-engine"; }
printf '{"id": 1}\n' > "\$W/orders.json"
if [ "\${1:-}" = ensure ]; then _exakit_json_tables_ensure; echo "JM-ENSURED=\$?"; exit 0; fi
EXAKIT_DATA_FILE="\$W/orders.json" EXAKIT_DATA_TABLE="T.ORDERS" exakit_load_local_file
echo "JM-RC=\$?"
JMEOF
JM_PTY="none"
if command -v script >/dev/null 2>&1; then
    if script -q /dev/null /bin/echo probe </dev/null >/dev/null 2>&1; then JM_PTY="bsd"
    elif script -q -c "/bin/echo probe" /dev/null </dev/null >/dev/null 2>&1; then JM_PTY="util-linux"
    fi
fi
jm_run() { # jm_run <pty|plain> [ensure]: the screen, escape codes removed
    case "$1|$JM_PTY" in
        pty\|bsd)        LC_ALL=en_US.UTF-8 TERM=xterm-256color script -q /dev/null bash "$JM/run.sh" ${2:-} </dev/null ;;
        pty\|util-linux) LC_ALL=C.UTF-8 TERM=xterm-256color script -q -c "bash $JM/run.sh ${2:-}" /dev/null </dev/null ;;
        plain\|*)        bash "$JM/run.sh" ${2:-} </dev/null ;;
    esac 2>&1 | LC_ALL=C tr '\r' '\n' | LC_ALL=C sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g'
}
if [ "$JM_PTY" = none ]; then
    printf '  skip no script(1) for a pty here\n'
else
    JMO="$(jm_run pty)"
    has "a JSON file with no engine says it is installing it" "Installing the JSON engine (" "$JMO"
    has "...the load carries on after it" "JM-RC=1" "$JMO"
    # The next line printed after the install starts on a clean row: the
    # spinner's last frame is not left behind with it glued on.
    JMO="$(jm_run pty ensure)"
    has "...the install ends" "JM-ENSURED=0" "$JMO"
    lacks "...with its spinner cleared, not frozen beside the next line" "s)JM-ENSURED" "$JMO"
    lacks "...and no line of its own is left behind" "Installing add-on" "$JMO"
fi
JMO="$(jm_run plain)"
lacks "off a terminal there is no spinner text" "Installing the JSON engine" "$JMO"
has "...and the load still runs" "JM-RC=1" "$JMO"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
