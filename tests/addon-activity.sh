#!/usr/bin/env bash
# The activity sits directly above the active bar without changing frame height.
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
printf 'group|Select All|1|idle||||||||\ntee|udf-devkit|1|running|40|65|40|1|installing|||\ncorner|dash-server|1|idle||||||||\n' > "$WORK/table"
: > "$WORK/table.activity"
ui_table_frame "$WORK/table" 0
height="$UI_TABLE_LINES"
ui_spin_begin 'Downloading the Python ML container'
ui_spin_end
ui_table_frame "$WORK/table" 0
case "$UI_TABLE_FRAME" in *'Downloading the Python ML container'*) ;; *) echo 'FAIL missing download activity'; exit 1 ;; esac
[ "$UI_TABLE_LINES" = "$height" ]
printf '%s\n' "$UI_TABLE_FRAME" | python3 -c 'import sys; lines=sys.stdin.read().splitlines(); i=next(i for i,l in enumerate(lines) if "udf-devkit" in l); assert "Downloading the Python ML container" in lines[i-1]; assert lines[i-1].index("Downloading") == lines[i].index("#")'
exakit_addon_activity 'Checking packages'
ui_table_frame "$WORK/table" 0
case "$UI_TABLE_FRAME" in *'Checking packages'*) ;; *) echo 'FAIL missing check activity'; exit 1 ;; esac
case "$UI_TABLE_FRAME" in *'Downloading the Python'*) echo 'FAIL stale activity'; exit 1 ;; esac
[ "$UI_TABLE_LINES" = "$height" ]
[ "$(sed -n '2p' "$WORK/table" | cut -d'|' -f5)" = 40 ]
exakit_addon_activity "$(printf '%120s' x)"
ui_table_frame "$WORK/table" 0
printf '%s\n' "$UI_TABLE_FRAME" | python3 -c 'import sys; assert max(len(s.rstrip("\n")) for s in sys.stdin) <= 80'
EXAKIT_ADDON_TABLE_ROW=3
ui_table_set "$WORK/table" 3 running 40 65 40 'installing'
exakit_addon_activity 'Starting dashboard service'
ui_table_frame "$WORK/table" 0
[ "$UI_TABLE_LINES" = "$height" ]
printf '%s\n' "$UI_TABLE_FRAME" | python3 -c 'import sys; lines=sys.stdin.read().splitlines(); i=next(i for i,l in enumerate(lines) if "dash-server" in l); assert "Starting dashboard service" in lines[i-1]; assert sum("Starting dashboard service" in l for l in lines)==1'
echo 'PASS phase directly above the active bar, aligned, moves between rows, constant height'
