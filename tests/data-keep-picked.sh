#!/usr/bin/env bash
# data-keep-picked.sh — once the data question is answered, its table shows only
# what is being loaded: the datasets picked (and the file, when one was), as
# plain rows, each with its progress. The datasets left unticked, the parent,
# the external source and Skip have no part in it.
#
#   bash tests/data-keep-picked.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;; *) FAIL=$((FAIL + 1)); printf '  FAIL %s: [%s] not found\n' "$1" "$2" ;; esac; }
lacks() { case "$3" in *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL %s: [%s] found\n' "$1" "$2" ;; *) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;; esac; }

echo "the progress keeps only the picked rows (a real pty):"
if command -v python3 >/dev/null 2>&1; then
    out="$(python3 "$ROOT/tests/lib/tty-replay.py" "$ROOT/tests/lib/data-keep-picked-scenario.sh" "$ROOT" "Data to load" '\r' 2>&1)"
    screen="$(printf '%s\n' "$out" | sed -n '/=== FINAL SCREEN ===/,/=== tables on screen/p')"
    has "one table, at every instant" "worst instant: 1 tables on screen" "$out"
    has "the picked datasets load in it" "Smart-meter energy" "$screen"
    has "...both of them" "City weather" "$screen"
    lacks "the dataset left unticked is gone" "TPC-H" "$screen"
    lacks "...the parent too" "Sample datasets" "$screen"
    lacks "...the file row" "Your file or folder" "$screen"
    lacks "...the external source" "external source" "$screen"
    lacks "...and Skip" "Skip" "$screen"
    lacks "...and the tree with them" "├─" "$screen"
    has "each load still finds its row" "IDS=energy,weather," "$out"
fi

echo "without a terminal, the same trim:"
export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
# shellcheck disable=SC1091
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
run_python_any() { python3 "$@"; }
exakit_pending_datasets() { printf 'tpch|TPC-H\nenergy|Energy\nweather|Weather\n'; }
EXAKIT_TABLE_STATE="$WORK/table"
exakit_data_table_build "$EXAKIT_TABLE_STATE"
EXAKIT_DATA_LOAD_SELECTION="weather,local"
exakit_data_table_keep_picked
check "the rows: the picked dataset and the file, plain" "plain|Weather plain|Your file or folder: CSV, Parquet, JSON" \
    "$(cut -d'|' -f1,2 "$EXAKIT_TABLE_STATE" | tr '\n' ' ' | sed 's/ $//')"
check "the ids follow" "weather,local," "$(printf '%s' "$EXAKIT_TABLE_IDS" | tr '\n' ',')"
check "the file row's number follows" "2" "$EXAKIT_TABLE_ROW_LOCAL"
check "a dataset's row is found" "1" "$(exakit_data_table_row weather)"
EXAKIT_DATA_LOAD_SELECTION="none"
before="$(cat "$EXAKIT_TABLE_STATE")"
exakit_data_table_keep_picked
check "nothing picked: nothing touched" "$before" "$(cat "$EXAKIT_TABLE_STATE")"

echo "the Windows twin:"
PS="$(cat "$ROOT/setup/lib/exapump.ps1")"
if command -v pwsh >/dev/null 2>&1; then
    psout="$(EXAKIT_HOME="$WORK/pskit" EXAKIT_BIN_DIR="$WORK/psbin" pwsh -NoProfile -Command "
        \$ErrorActionPreference = 'Stop'
        . '$ROOT/setup/lib/exakit-common.ps1'; . '$ROOT/setup/lib/exapump.ps1'
        function Get-ExakitPendingDatasets { @([pscustomobject]@{Id='tpch';Label='TPC-H'},[pscustomobject]@{Id='energy';Label='Energy'},[pscustomobject]@{Id='weather';Label='Weather'}) }
        New-ExakitDataTable -FinalLabel 'Skip'
        \$script:ExakitDataPicked = @('weather','local')
        Limit-ExakitDataTableToPicked
        'ROWS=' + ((@(\$script:UiTable.Rows | ForEach-Object { \$_.Kind + ':' + \$_.Label })) -join ';')
        'IDS=' + (\$script:ExakitTableIds -join ',')
        'ROW=' + (Get-ExakitDataTableRow -Id 'weather') + ' LOCAL=' + \$script:ExakitTableRowLocal" 2>&1)"
    has "PowerShell: the picked dataset and the file, plain" "ROWS=plain:Weather;plain:Your file or folder: CSV, Parquet, JSON" "$psout"
    has "...the ids follow" "IDS=weather,local" "$psout"
    has "...each load finds its row" "ROW=1 LOCAL=2" "$psout"
fi
has "trims the same way" "function Limit-ExakitDataTableToPicked" "$PS"
_run_range='/^function Start-ExakitDataTableRun {/,/^}/p'      # assigned first: bash 3.2
has "...right before the progress starts" "Limit-ExakitDataTableToPicked" "$(sed -n "$_run_range" "$ROOT/setup/lib/exapump.ps1")"
_menu_range='/^exakit_data_load_menu() {/,/ui_table_begin/p'
has "the shell's data-load menu trims before it animates" "exakit_data_table_keep_picked" "$(sed -n "$_menu_range" "$ROOT/setup/lib/exapump.sh")"
has "...and so does the install's data step" "exakit_data_table_keep_picked" "$(cat "$ROOT/setup/lib/common.sh")"

printf '\ndata-keep-picked.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
