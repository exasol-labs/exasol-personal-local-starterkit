#!/usr/bin/env bash
# Driven by tests/lib/tty-replay.py under a real pty: the table's whole life, so
# the replay can assert what a terminal is actually left holding.
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\nweather|City weather daily history\n'
}
UI_TABLE_TITLE="Datasets to load"; S="$W/t"
exakit_data_table_build "$S"; ui_table_tick "$S" "$EXAKIT_TABLE_DEFAULTS"
# The selection phase leaves its table drawn, exactly as ui_table_menu does.
ui_table_render "$S" 0
ui_table_begin "$S" || exit 0
ui_table_set "$S" 2 running 20 83 6 "loading 8 data files"; sleep 1
ui_table_set "$S" 2 done "" "" "" "" "completed · 8 tables, 173,745 rows  (4s)"
ui_table_set "$S" 3 running 24 100 4 "loading 1 data file"; sleep 1
ui_table_set "$S" 3 done "" "" "" "" "completed · 2 tables, 108,050 rows  (1s)"
ui_table_set "$S" 4 done "" "" "" "" "completed · 2 tables,  10,970 rows  (2s)"
sleep 1
ui_table_end "$S"
rm -rf "$W"
