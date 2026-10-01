#!/bin/sh
# legacy-fault-exapump.sh — an exapump whose database fails on request.
#
# Installed into a sandbox as `exapump` by tests/legacy-crossing-resilience.sh
# and reached through EXAKIT_EXAPUMP_BIN AND through PATH, so no fix in the kit
# is the only thing standing between the suite and a real binary. It answers
# the four subcommands the crossing uses - `sql`, `export`, `upload`, and the
# readiness probe that is a `sql` - and takes its faults from files in
# $EXAKIT_FAULT_DIR. Every call is appended to exapump.calls, argv verbatim.
#
#   db.answer_after   the probe answers from this call on; "never" never  (1)
#   db.tables         SCHEMA.TABLE per line, what EXA_ALL_TABLES reports  (none)
#   db.rows           SCHEMA.TABLE|ROWS per line, the row count the
#                     sample-data check reads off EXA_ALL_TABLES           (none)
#   db.columns        SCHEMA.TABLE|NAME<<:>>TYPE per line                 (none)
#   export.fail       SCHEMA.TABLE per line whose export fails
#   export.rows       the CSV body every successful export writes         (A,B/1,2)
#   newdb.answers     "no" makes the NEW database's probe fail            (yes)
#   import.exists     SCHEMA.TABLE per line whose CREATE TABLE fails
#   import.schema_rc  exit code of CREATE SCHEMA                          (0)
#   upload.fail       SCHEMA.TABLE per line whose upload fails
#
# The failure shapes are the REAL ones: a failed export still creates its
# output file first (exapump opens the file before it runs the query), and a
# CREATE TABLE for a table that exists fails while CREATE SCHEMA IF NOT EXISTS
# for an existing schema does not.

_dir="${EXAKIT_FAULT_DIR:?EXAKIT_FAULT_DIR must point at the scenario control directory}"
_read() { if [ -f "$_dir/$1" ]; then cat "$_dir/$1"; else printf '%s' "$2"; fi; }
_listed() { [ -f "$_dir/$1" ] && grep -qxF -- "$2" "$_dir/$1"; }
printf '%s\n' "$*" >> "$_dir/exapump.calls"

_sub="$1"; shift
# Every subcommand takes -p <profile> first; keep it for the assertions that
# read the log, then drop it.
[ "$1" = "-p" ] && shift 2

case "$_sub" in
    sql)
        _sql="$*"
        case "$_sql" in
            *EXAKIT_NEW_OK*)
                [ "$(_read newdb.answers yes)" = no ] || printf 'EXAKIT_NEW_OK\n'
                exit 0 ;;
            *EXAKIT_LEGACY_OK*)
                _n="$(( $(_read probe.count 0) + 1 ))"; printf '%s' "$_n" > "$_dir/probe.count"
                _after="$(_read db.answer_after 1)"
                [ "$_after" != never ] && [ "$_n" -ge "$_after" ] && printf 'EXAKIT_LEGACY_OK\n'
                exit 0 ;;
            # The row-count query names EXA_ALL_TABLES too, so it is told apart by
            # its own sentinel, and BEFORE the table listing.
            *EXAKIT_LR*)
                [ -f "$_dir/db.rows" ] && sed 's/^/EXAKIT_LR[/; s/|/<<:>>/; s/$/]/' "$_dir/db.rows"
                exit 0 ;;
            *EXA_ALL_TABLES*)
                [ -f "$_dir/db.tables" ] && sed 's/^/EXAKIT_LT[/; s/$/]/' "$_dir/db.tables"
                exit 0 ;;
            *EXA_ALL_COLUMNS*)
                _s="$(printf '%s' "$_sql" | sed -n "s/.*COLUMN_SCHEMA = '\([^']*\)'.*/\1/p")"
                _t="$(printf '%s' "$_sql" | sed -n "s/.*COLUMN_TABLE = '\([^']*\)'.*/\1/p")"
                [ -f "$_dir/db.columns" ] && grep -F -- "$_s.$_t|" "$_dir/db.columns" \
                    | sed 's/^[^|]*|/EXAKIT_LC[/; s/$/]/'
                exit 0 ;;
            *"CREATE SCHEMA"*)
                exit "$(_read import.schema_rc 0)" ;;
            *"CREATE TABLE"*)
                _target="$(printf '%s' "$_sql" | sed -n 's/.*CREATE TABLE "\([^"]*\)"\."\([^"]*\)".*/\1.\2/p')"
                _listed import.exists "$_target" && exit 1
                exit 0 ;;
        esac
        exit 0 ;;
    export)
        _table=""; _out=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --table) _table="$2"; shift ;;
                # The crossing names the table as a quoted query; the fault
                # lists say S.T.
                --query) _table="$(printf '%s' "$2" | sed -n 's/.*FROM "\([^"]*\)"\."\([^"]*\)".*/\1.\2/p')"; shift ;;
                -o) _out="$2"; shift ;;
            esac
            shift
        done
        # The file is created BEFORE the query is known to work - the real
        # exapump does this, and it is why a failed export leaves a 0-byte file.
        [ -n "$_out" ] && : > "$_out"
        _listed export.fail "$_table" && exit 1
        [ -n "$_out" ] && _read export.rows 'A,B
1,2' > "$_out"
        exit 0 ;;
    upload)
        _table=""
        while [ $# -gt 0 ]; do
            case "$1" in --table) _table="$2"; shift ;; esac
            shift
        done
        # The crossing hands the target as "S"."T"; the fault lists say S.T.
        _plain="$(printf '%s' "$_table" | sed 's/"//g')"
        _listed upload.fail "$_plain" && exit 1
        exit 0 ;;
esac
exit 0
