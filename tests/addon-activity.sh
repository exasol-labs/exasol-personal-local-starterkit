#!/usr/bin/env bash
# The activity above a marketplace table changes without moving the frame.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export EXAKIT_HOME="$WORK/home" EXAKIT_BIN_DIR="$WORK/bin"
. "$ROOT/setup/lib/ui.sh"
. "$ROOT/setup/lib/common.sh"
UI_FANCY=0
ui_columns() { printf 80; }
EXAKIT_ADDON_TABLE_STATE="$WORK/table"
EXAKIT_ADDON_TABLE_ROW=2
printf 'group|Select All|1|idle||||||||\nlast|udf-devkit|1|running|40|65|40|1|installing|||\n' > "$WORK/table"
: > "$WORK/table.activity"
ui_table_frame "$WORK/table" 0
height="$UI_TABLE_LINES"
ui_spin_begin 'Downloading the Python ML container'
ui_spin_end
ui_table_frame "$WORK/table" 0
case "$UI_TABLE_FRAME" in *'Downloading the Python ML container'*) ;; *) echo 'FAIL missing download activity'; exit 1 ;; esac
[ "$UI_TABLE_LINES" = "$height" ]
exakit_addon_activity 'Checking packages'
ui_table_frame "$WORK/table" 0
case "$UI_TABLE_FRAME" in *'Checking packages'*) ;; *) echo 'FAIL missing check activity'; exit 1 ;; esac
case "$UI_TABLE_FRAME" in *'Downloading the Python'*) echo 'FAIL stale activity'; exit 1 ;; esac
[ "$UI_TABLE_LINES" = "$height" ]
[ "$(sed -n '2p' "$WORK/table" | cut -d'|' -f5)" = 40 ]
exakit_addon_activity "$(printf '%120s' x)"
ui_table_frame "$WORK/table" 0
printf '%s\n' "$UI_TABLE_FRAME" | python3 -c 'import sys; assert max(len(s.rstrip("\n")) for s in sys.stdin) <= 80'
echo 'PASS activity changes, frame height and progress retained, long text fits'
